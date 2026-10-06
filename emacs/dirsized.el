;;; dirsized.el --- Real folder sizes in Dired, from the dirsized daemon  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Vadym Lopatka

;; Author: Vadym Lopatka <2900687+Vadym-Lopatka@users.noreply.github.com>
;; Maintainer: Vadym Lopatka <2900687+Vadym-Lopatka@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, unix
;; URL: https://github.com/Vadym-Lopatka/dirsized
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The dirsized daemon keeps the total size of every folder in memory and
;; answers on a Unix socket.  This package asks it for the folders shown in
;; Dired and puts the totals over the size column, as overlays.  Emacs never
;; waits for the daemon.  If the daemon is not running, Dired looks as usual.
;;
;; Setup:
;;
;;   (add-to-list 'load-path "/path/to/dirsized/emacs")
;;   (require 'dirsized)
;;   (global-dirsized-mode 1)
;;
;; Commands: `dirsized-mode', `global-dirsized-mode', `dirsized-sort-by-size',
;; `dirsized-status'.
;;
;; Wire protocol (version 1): requests are `size PATH NUL', `list PATH NUL'
;; and `status NUL'.  Answers are records `BYTES TAB STATE TAB NAME NUL',
;; ended by an empty record.  Answers come back in request order.

;;; Code:

(require 'dired)
(require 'subr-x)
(require 'seq)

(defvar dirsized-mode)

;;;; Options

(defgroup dirsized nil
  "Real folder sizes in Dired."
  :group 'dired
  :prefix "dirsized-")

(defcustom dirsized-socket nil
  "Path of the daemon socket, or nil for the default of this system."
  :type '(choice (const :tag "Default" nil) file))

(defcustom dirsized-format 'human
  "How to show a size.
`human' is like \"ls -h\" (1024-based).  `bytes' is the plain number.  A
function gets the size in bytes and returns a string."
  :type '(choice (const :tag "Human readable" human)
                 (const :tag "Bytes" bytes)
                 (function :tag "Function")))

(defcustom dirsized-refresh-interval 5
  "Seconds between refreshes of the Dired buffers that are shown, or nil."
  :type '(choice (const :tag "Off" nil) number))

(defcustom dirsized-idle-limit 60
  "Seconds of idle time after which the refresh pauses, or nil."
  :type '(choice (const :tag "Never" nil) number))

(defcustom dirsized-pending-interval 2
  "Seconds to wait before asking again after a not final value was shown."
  :type 'number)

(defcustom dirsized-reconnect-interval 5
  "Least number of seconds between two tries to reach the daemon."
  :type 'number)

(defface dirsized-face
  '((t :inherit default))
  "Face of a final folder size.")

(defface dirsized-pending-face
  '((t :inherit shadow :slant italic))
  "Face of a folder size that is not final (scanning, partial, stale).")

;;;; Socket path

(defun dirsized--socket-path ()
  "Return the path of the daemon socket."
  (cond
   (dirsized-socket (expand-file-name dirsized-socket))
   ((eq system-type 'darwin)
    (expand-file-name "~/.cache/dirsized/sock"))
   (t
    (let ((run (getenv "XDG_RUNTIME_DIR"))
          (cache (getenv "XDG_CACHE_HOME")))
      (cond
       ((and run (> (length run) 0) (eq (aref run 0) ?/))
        (expand-file-name "dirsized/sock" run))
       ((and cache (> (length cache) 0) (eq (aref cache 0) ?/))
        (expand-file-name "dirsized/sock" cache))
       (t (expand-file-name "~/.cache/dirsized/sock")))))))

;;;; Connection and parser

(defvar dirsized--proc nil
  "The shared connection to the daemon, or nil.")

(defvar dirsized--fail-time nil
  "Time (float seconds) of the last failed connection, or nil.")

(defvar dirsized--queue nil
  "Pending requests, oldest first.  Each is a vector [VERB CALLBACK ACC ERR].")

(defvar dirsized--queue-tail nil
  "Last cons cell of `dirsized--queue'.")

(defvar dirsized--partial nil
  "Reversed list of the pieces of the frame that is not complete yet.")

(defun dirsized--enqueue (req)
  "Add REQ at the end of the queue."
  (let ((cell (list req)))
    (if dirsized--queue-tail
        (setcdr dirsized--queue-tail cell)
      (setq dirsized--queue cell))
    (setq dirsized--queue-tail cell)))

(defun dirsized--dequeue ()
  "Remove and return the oldest request."
  (let ((req (car dirsized--queue)))
    (setq dirsized--queue (cdr dirsized--queue))
    (unless dirsized--queue (setq dirsized--queue-tail nil))
    req))

(defun dirsized--call (req ok data)
  "Call the callback of REQ with OK and DATA.  Never signal an error."
  (condition-case err
      (funcall (aref req 1) ok data)
    (error (message "dirsized: %s" (error-message-string err)))))

(defun dirsized--flush ()
  "Fail every pending request and forget the partial frame."
  (let ((queue dirsized--queue))
    (setq dirsized--queue nil
          dirsized--queue-tail nil
          dirsized--partial nil)
    (dolist (req queue)
      (dirsized--call req nil "connection lost"))))

(defun dirsized--drop (proc)
  "Forget the connection PROC, if it is the current one, and fail the queue."
  (when (eq proc dirsized--proc)
    (setq dirsized--proc nil
          dirsized--fail-time (float-time))
    (dirsized--flush)))

(defun dirsized--sentinel (proc _event)
  "Process sentinel: forget PROC when it is no longer open."
  (unless (process-live-p proc)
    (dirsized--drop proc)))

(defun dirsized--finish (req)
  "Deliver the finished request REQ to its callback."
  (if (aref req 3)
      (dirsized--call req nil (aref req 3))
    (dirsized--call req t (nreverse (aref req 2)))))

(defun dirsized--frame (frame)
  "Handle the complete answer record FRAME (a unibyte string, no NUL)."
  (let ((req (car dirsized--queue))
        (len (length frame)))
    (when req
      (cond
       ((= len 0)
        (dirsized--dequeue)
        (dirsized--finish req))
       ((and (> len 1) (eq (aref frame 0) ?!) (eq (aref frame 1) ?\t))
        (aset req 3 (substring frame 2)))
       ((eq (aref req 0) 'status)
        (let ((tab (string-search "\t" frame)))
          (when tab
            (push (cons (substring frame 0 tab) (substring frame (1+ tab)))
                  (aref req 2)))))
       (t
        (let* ((t1 (string-search "\t" frame))
               (t2 (and t1 (string-search "\t" frame (1+ t1)))))
          (when t2
            (push (list (string-to-number (substring frame 0 t1))
                        (intern (substring frame (1+ t1) t2))
                        (substring frame (1+ t2)))
                  (aref req 2)))))))))

(defun dirsized--filter (_proc chunk)
  "Process filter: split CHUNK at NUL bytes and handle each frame.
The work is proportional to the size of CHUNK."
  (condition-case err
      (let ((start 0)
            (len (length chunk))
            pos)
        (while (and (< start len)
                    (setq pos (string-search "\0" chunk start)))
          (let ((piece (substring chunk start pos)))
            (when dirsized--partial
              (setq piece (apply #'concat
                                 (nreverse (cons piece dirsized--partial)))
                    dirsized--partial nil))
            (dirsized--frame piece))
          (setq start (1+ pos)))
        (when (< start len)
          (push (if (= start 0) chunk (substring chunk start))
                dirsized--partial)))
    (error (message "dirsized: %s" (error-message-string err)))))

(defun dirsized--connection ()
  "Return the live connection, or try to open one, or return nil.
This never signals an error and never waits for the daemon.  After a
failure it does not try again before `dirsized-reconnect-interval'."
  (cond
   ((and dirsized--proc (process-live-p dirsized--proc)) dirsized--proc)
   ((and dirsized--fail-time
         (< (- (float-time) dirsized--fail-time) dirsized-reconnect-interval))
    nil)
   (t
    (when dirsized--proc (dirsized--drop dirsized--proc))
    (condition-case nil
        (let ((proc (make-network-process
                     :name "dirsized" :family 'local
                     :service (dirsized--socket-path)
                     :coding 'binary :noquery t
                     :filter #'dirsized--filter
                     :sentinel #'dirsized--sentinel)))
          (setq dirsized--proc proc
                dirsized--fail-time nil
                dirsized--partial nil)
          proc)
      (error
       (setq dirsized--fail-time (float-time))
       nil)))))

(defun dirsized-disconnect ()
  "Close the connection to the daemon."
  (interactive)
  (let ((proc dirsized--proc))
    (when proc
      (setq dirsized--proc nil)
      (dirsized--flush)
      (ignore-errors (delete-process proc)))))

(defun dirsized--encode (string)
  "Encode STRING with the file name coding system."
  (encode-coding-string
   string (or file-name-coding-system default-file-name-coding-system 'utf-8)))

(defun dirsized--decode (string)
  "Decode the unibyte STRING with the file name coding system."
  (decode-coding-string
   string (or file-name-coding-system default-file-name-coding-system 'utf-8)))

(defun dirsized--request (verb path callback)
  "Send VERB (`size', `list' or `status') for PATH.
CALLBACK gets two arguments later: OK and the data.  Return non-nil if
the request was sent."
  (let ((proc (dirsized--connection)))
    (when proc
      (condition-case nil
          (progn
            (dirsized--enqueue (vector verb callback nil nil))
            (process-send-string
             proc
             (if (eq verb 'status)
                 "status\0"
               (concat (symbol-name verb) " " (dirsized--encode path) "\0")))
            t)
        (error
         (dirsized--drop proc)
         nil)))))

;;;; Formatting

(defun dirsized--format-human (n)
  "Format N bytes like \"ls -h\": 512, 1.5K, 23M, 4.2G."
  (if (< n 1024)
      (number-to-string n)
    (let ((i 1) (d 1024))
      (while (and (< i 6) (>= n (* d 1024)))
        (setq i (1+ i) d (* d 1024)))
      (let ((unit (aref "KMGTPE" (1- i))))
        (if (< n (* 10 d))
            (let ((tenths (/ (+ (* n 10) d -1) d)))
              (if (>= tenths 100)
                  (format "%d%c" (/ tenths 10) unit)
                (format "%d.%d%c" (/ tenths 10) (% tenths 10) unit)))
          (let ((v (/ (+ n d -1) d)))
            (if (and (>= v 1024) (< i 6))
                (format "1.0%c" (aref "KMGTPE" i))
              (format "%d%c" v unit))))))))

(defun dirsized--format (n)
  "Return the text for N bytes, as `dirsized-format' says."
  (cond
   ((functionp dirsized-format) (format "%s" (funcall dirsized-format n)))
   ((eq dirsized-format 'bytes) (number-to-string n))
   (t (dirsized--format-human n))))

;;;; Size column

(defconst dirsized--date-re
  (concat "\\(?:"
          ;; ISO: 2024-01-02 10:00[:00.123456789 +0100]
          "[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9][ \t]+[0-9:.]+\\(?:[ \t]+[-+][0-9]+\\)?"
          ;; ISO short: 01-02 10:00
          "\\|[0-9][0-9]-[0-9][0-9][ \t]+[0-9:]+"
          ;; month day time-or-year: Jan  5 12:00
          "\\|[^ \t]+[ \t]+[0-9]+\\.?[ \t]+[0-9:]+"
          ;; day month time-or-year: 5. Jan 12:00
          "\\|[0-9]+\\.?[ \t]+[^ \t]+[ \t]+[0-9:]+"
          "\\)")
  "Regexp for the date and time fields of a long listing line.")

(defconst dirsized--size-re
  (concat "\\(?:^\\|[ \t]\\)\\([0-9][0-9.,]*[BkKMGTPEZY]?\\)[ \t]+"
          dirsized--date-re "[ \t]*\\'")
  "Regexp for the size field, at the end of the text before the file name.")

(defun dirsized--size-token ()
  "With point at the start of a file name, find the size field of the line.
Return (BEG . END) or nil.  Point is not preserved."
  (let ((name-start (point))
        (bol (line-beginning-position)))
    (save-restriction
      (narrow-to-region bol name-start)
      (goto-char (point-max))
      (when (re-search-backward dirsized--size-re nil t)
        (cons (match-beginning 1) (match-end 1))))))

(defun dirsized--parse-listing-size (token)
  "Return the number of bytes that the listing field TOKEN means."
  (let* ((last (aref token (1- (length token))))
         (idx (and (not (<= ?0 last ?9)) (not (memq last '(?. ?,)))
                   (string-search (string (upcase last)) "BKMGTPEZY")))
         (num (string-to-number
               (replace-regexp-in-string
                "," "." (if idx (substring token 0 -1) token)))))
    (round (* num (expt 1024 (or idx 0))))))

;;;; Overlays

(put 'dirsized 'evaporate t)

(defun dirsized--overlay-p (ov)
  "Return non-nil if OV is one of ours."
  (eq (overlay-get ov 'category) 'dirsized))

(defun dirsized--overlays (beg end)
  "Return our overlays between BEG and END."
  (let (res)
    (dolist (ov (overlays-in beg end))
      (when (dirsized--overlay-p ov) (push ov res)))
    res))

(defun dirsized--remove-overlays (&optional beg end)
  "Delete our overlays between BEG and END (default: the whole buffer)."
  (dolist (ov (dirsized--overlays (or beg (point-min)) (or end (point-max))))
    (delete-overlay ov)))

(defun dirsized--volatile-state-p (state)
  "Return non-nil if STATE is not final."
  (memq state '(scanning partial stale)))

(defun dirsized--make-overlay (tok name value)
  "Put an overlay on the size field TOK (BEG . END) for NAME and VALUE.
VALUE is (BYTES . STATE)."
  (let* ((beg (car tok))
         (end (cdr tok))
         (text (dirsized--format (car value)))
         (n (string-width text))
         (w (- end beg))
         (avail (save-excursion
                  (goto-char beg)
                  (skip-chars-backward " " (line-beginning-position))
                  (- beg (point))))
         (ext (if (> n w) (min (- n w) (max 0 (1- avail))) 0))
         (target (+ w ext))
         (face (if (eq (cdr value) 'ok) 'dirsized-face 'dirsized-pending-face))
         (shown (concat (make-string (max 0 (- target n)) ?\s)
                        (propertize text 'face face)))
         (ov (make-overlay (- beg ext) end nil t nil)))
    (overlay-put ov 'category 'dirsized)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'display shown)
    (overlay-put ov 'dirsized-name name)
    (overlay-put ov 'dirsized-value value)
    (overlay-put ov 'dirsized-text text)
    ov))

;;;; Per-buffer state

(defvar-local dirsized--cache nil
  "Hash table: absolute folder path -> (BYTES . STATE).")

(defvar-local dirsized--inflight 0
  "Number of `list' requests of this buffer that have no answer yet.")

(defvar-local dirsized--retry-timer nil
  "Timer that asks again after a not final value was shown.")

(defvar-local dirsized--case-alist nil
  "Alist TRUE-DIR -> spelling that the daemon knows, for this buffer.
Used on case-insensitive volumes, where the daemon compares paths exactly.")

(defvar-local dirsized--truenames nil
  "Alist DIR -> its truename without trailing slash, for this buffer.")

(defvar-local dirsized--answers nil
  "Hash table: folder -> (DATA . VOLATILE), the last answer and its result.
VOLATILE is non-nil if the sizes shown from DATA were not final.")

(defun dirsized--subdir-regions ()
  "Return a list (DIR BEG END) for every directory in the Dired buffer."
  (let ((max (save-restriction (widen) (point-max)))
        entries res)
    (dolist (e dired-subdir-alist)
      (when (markerp (cdr e))
        (push (cons (car e) (marker-position (cdr e))) entries)))
    (setq entries (sort entries (lambda (a b) (< (cdr a) (cdr b)))))
    (while entries
      (let ((e (pop entries)))
        (push (list (car e) (cdr e)
                    (if entries (cdr (car entries)) max))
              res)))
    (nreverse res)))

(defun dirsized--true-dir (dir)
  "Return the path of DIR for the daemon: truename, no trailing slash.
On a case-insensitive volume this is the spelling found on disk, once known."
  (let ((td (or (cdr (assoc dir dirsized--truenames))
                (let ((v (directory-file-name (file-truename dir))))
                  (push (cons dir v) dirsized--truenames)
                  v))))
    (or (cdr (assoc td dirsized--case-alist)) td)))

(defun dirsized--name-regexp (name)
  "Return a regexp that matches NAME only, ignoring case.
`directory-files' matches case-sensitively, so each letter is a class."
  (concat "\\`"
          (mapconcat (lambda (c)
                       (if (eq (upcase c) (downcase c))
                           (regexp-quote (string c))
                         (string ?\[ (downcase c) (upcase c) ?\])))
                     name "")
          "\\'"))

(defun dirsized--disk-case (path)
  "Return PATH (absolute, no trailing slash) as spelled on disk, or nil.
Walk the components and match each one in its folder, ignoring case."
  (let ((cur "/"))
    (catch 'done
      (dolist (comp (split-string path "/" t))
        (let* ((names (directory-files cur nil (dirsized--name-regexp comp) t))
               (hit (if (member comp names) comp (car names))))
          (unless hit (throw 'done nil))
          (setq cur (concat (if (equal cur "/") "/" (concat cur "/")) hit))))
      cur)))

(defun dirsized--case-retry (dir true-dir data)
  "Return the on-disk spelling of TRUE-DIR to ask again with, or nil.
DATA is the answer for TRUE-DIR.  This is tried once per folder, and only
if the daemon has no node (state `none') on a case-insensitive volume."
  (when (and (not (assoc true-dir dirsized--case-alist))
             (seq-find (lambda (r) (and (equal (nth 2 r) ".")
                                        (eq (nth 1 r) 'none)))
                       data)
             (ignore-errors (file-name-case-insensitive-p dir)))
    (let ((fixed (or (ignore-errors (dirsized--disk-case true-dir))
                     true-dir)))
      (push (cons true-dir fixed) dirsized--case-alist)
      (push (cons fixed fixed) dirsized--case-alist)
      (and (not (equal fixed true-dir)) fixed))))

(defun dirsized--key (true-dir name)
  "Return the cache key of the entry NAME in TRUE-DIR."
  (cond ((equal name ".") true-dir)
        ((equal true-dir "/") (concat "/" name))
        (t (concat true-dir "/" name))))

(defun dirsized--store (true-dir records)
  "Put RECORDS, the answer for TRUE-DIR, in the cache."
  (let ((prefix (if (equal true-dir "/") "/" (concat true-dir "/")))
        old)
    (when (> (hash-table-count dirsized--cache) 0)
      (maphash (lambda (k _v)
                 (when (and (string-prefix-p prefix k)
                            (not (string-search "/" k (length prefix))))
                   (push k old)))
               dirsized--cache)
      (dolist (k old) (remhash k dirsized--cache)))
    (remhash true-dir dirsized--cache)
    (dolist (r records)
      (puthash (dirsized--key true-dir (dirsized--decode (nth 2 r)))
               (cons (nth 0 r) (nth 1 r))
               dirsized--cache))))

(defun dirsized--region-of (dir)
  "Return (BEG . END) of the directory DIR in this buffer, or nil."
  (let ((r (assoc dir (dirsized--subdir-regions))))
    (and r (cons (nth 1 r) (nth 2 r)))))

(defun dirsized--apply-dir (dir &optional true-dir)
  "Show the cached sizes on the folder lines of DIR in this buffer.
TRUE-DIR is the truename of DIR, if known.  Only overlays whose value
changed are replaced.  Return non-nil if a value that is not final was
shown."
  (let ((reg (dirsized--region-of dir))
        (volatile nil))
    (when (and reg (> (hash-table-count dirsized--cache) 0))
      (save-match-data
        (save-excursion
          (save-restriction
            (widen)
            (let* ((true-dir (or true-dir (dirsized--true-dir dir)))
                   (beg (car reg))
                   (end (cdr reg))
                   (old (make-hash-table :test 'equal)))
              (dolist (ov (dirsized--overlays beg end))
                (puthash (overlay-get ov 'dirsized-name) ov old))
              (goto-char beg)
              (while (< (point) end)
                (let ((start (dired-move-to-filename)))
                  (if (not start)
                      (forward-line 1)
                    (let* ((nend (dired-move-to-end-of-filename t))
                           (name (and nend (buffer-substring-no-properties
                                            start nend)))
                           (val (and name (not (equal name ".."))
                                     (gethash (dirsized--key true-dir name)
                                              dirsized--cache))))
                      (when (and val (memq (cdr val)
                                           '(ok scanning partial stale)))
                        (when (dirsized--volatile-state-p (cdr val))
                          (setq volatile t))
                        (let ((ov (gethash name old)))
                          (if (and ov (overlay-buffer ov)
                                   (equal (overlay-get ov 'dirsized-value) val)
                                   (equal (overlay-get ov 'dirsized-text)
                                          (dirsized--format (car val))))
                              (remhash name old)
                            (goto-char start)
                            (let ((tok (dirsized--size-token)))
                              (when tok
                                (when ov (delete-overlay ov))
                                (remhash name old)
                                (dirsized--make-overlay tok name val))))))
                      (goto-char (or nend start))
                      (forward-line 1)))))
              (maphash (lambda (_k ov) (delete-overlay ov)) old))))))
    volatile))

(defun dirsized--apply-all ()
  "Show the cached sizes in every directory of this buffer."
  (let (volatile)
    (dolist (r (dirsized--subdir-regions))
      (when (dirsized--apply-dir (car r)) (setq volatile t)))
    (if volatile
        (dirsized--schedule-retry)
      (dirsized--cancel-retry))
    volatile))

(defun dirsized--cancel-retry ()
  "Cancel the retry timer of this buffer."
  (when (timerp dirsized--retry-timer) (cancel-timer dirsized--retry-timer))
  (setq dirsized--retry-timer nil))

(defun dirsized--schedule-retry ()
  "Ask again soon, because a value that is not final was shown."
  (unless (timerp dirsized--retry-timer)
    (setq dirsized--retry-timer
          (run-with-timer dirsized-pending-interval nil
                          #'dirsized--retry (current-buffer)))))

(defun dirsized--retry (buf)
  "Query the buffer BUF again, if it is shown."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq dirsized--retry-timer nil)
      (when (and dirsized-mode (get-buffer-window buf t)
                 (= dirsized--inflight 0))
        (dirsized--query-buffer)))))

;;;; Queries

(defun dirsized--handle-list (buf dir true-dir ok data)
  "Handle the answer for DIR (TRUE-DIR) of buffer BUF.
OK and DATA are as in `dirsized--request'."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq dirsized--inflight (max 0 (1- dirsized--inflight)))
      (when (and ok dirsized-mode dirsized--cache
                 (derived-mode-p 'dired-mode)
                 (assoc dir dired-subdir-alist))
        (let ((fixed (dirsized--case-retry dir true-dir data))
              (last (gethash dir dirsized--answers)))
          (cond
           (fixed (dirsized--send-list buf dir fixed))
           ;; Same answer as last time: the overlays are already right.
           ((equal data (car last))
            (if (cdr last) (dirsized--schedule-retry) (dirsized--cancel-retry)))
           (t
            (dirsized--store true-dir data)
            (let ((volatile (dirsized--apply-dir dir true-dir)))
              (puthash dir (cons data volatile) dirsized--answers)
              (if volatile
                  (dirsized--schedule-retry)
                (dirsized--cancel-retry))))))))))

(defun dirsized--send-list (buf dir true-dir)
  "Send a `list' for TRUE-DIR on behalf of DIR in BUF.  Count it in flight.
Return non-nil if it was sent."
  (with-current-buffer buf
    (setq dirsized--inflight (1+ dirsized--inflight))
    (or (dirsized--request
         'list true-dir
         (lambda (ok data)
           (dirsized--handle-list buf dir true-dir ok data)))
        (progn (setq dirsized--inflight (max 0 (1- dirsized--inflight)))
               nil))))

(defun dirsized--forget-killed ()
  "Drop the answers and truenames of subdirectories that this buffer no longer shows."
  (maphash (lambda (dir _)
             (unless (assoc dir dired-subdir-alist) (remhash dir dirsized--answers)))
           dirsized--answers)
  (setq dirsized--truenames
        (seq-filter (lambda (e) (assoc (car e) dired-subdir-alist)) dirsized--truenames)))

(defun dirsized--query-buffer ()
  "Send one `list' query for each directory shown in the current buffer.
Do nothing if the daemon cannot be reached."
  (when (and dirsized-mode dirsized--cache
             (derived-mode-p 'dired-mode)
             (not (file-remote-p default-directory))
             (dirsized--connection))
    (dirsized--forget-killed)
    (let ((buf (current-buffer))
          (regions (dirsized--subdir-regions))
          (go t))
      (while (and go regions)
        (let ((dir (car (pop regions))))
          (unless (file-remote-p dir)
            (unless (dirsized--send-list buf dir (dirsized--true-dir dir))
              (setq go nil))))))))

(defun dirsized--after-readin ()
  "Hook for `dired-after-readin-hook': show cached sizes, ask for new ones."
  (when (and dirsized-mode (not (file-remote-p default-directory)))
    (condition-case err
        (progn
          (setq dirsized--truenames nil)
          (dirsized--apply-all)
          (dirsized--query-buffer))
      (error (message "dirsized: %s" (error-message-string err))))))

;;;; Refresh timer

(defvar dirsized--timer nil
  "The one timer that refreshes all shown Dired buffers.")

(defun dirsized--live-buffers ()
  "Return the buffers where `dirsized-mode' is on."
  (let (res)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'dirsized-mode b) (push b res)))
    res))

(defun dirsized--ensure-timer ()
  "Start the refresh timer if it is wanted and not running."
  (when (and dirsized-refresh-interval (not (timerp dirsized--timer)))
    (setq dirsized--timer
          (run-with-timer dirsized-refresh-interval nil #'dirsized--tick))))

(defun dirsized--shown-buffers ()
  "Return the `dirsized-mode' buffers that are in a window now."
  (let (res)
    (walk-windows
     (lambda (w)
       (let ((b (window-buffer w)))
         (when (and (buffer-local-value 'dirsized-mode b) (not (memq b res)))
           (push b res))))
     'no-minibuf 'visible)
    res))

(defun dirsized--away-p ()
  "Return non-nil if the user was idle longer than `dirsized-idle-limit'."
  (let ((idle (current-idle-time)))
    (and dirsized-idle-limit idle (> (float-time idle) dirsized-idle-limit))))

(defun dirsized--tick ()
  "Refresh the shown Dired buffers, then plan the next tick."
  (setq dirsized--timer nil)
  (when (dirsized--live-buffers)
    (unless (dirsized--away-p)
      (condition-case err
          (dolist (b (dirsized--shown-buffers))
            (with-current-buffer b
              (when (= dirsized--inflight 0)
                (dirsized--query-buffer))))
        (error (message "dirsized: %s" (error-message-string err)))))
    (dirsized--ensure-timer)))

(defun dirsized--maybe-shutdown (&optional except)
  "Stop the timer and close the connection if no buffer uses the mode.
The buffer EXCEPT, if given, is not counted: it is going away."
  (unless (delq except (dirsized--live-buffers))
    (when (timerp dirsized--timer) (cancel-timer dirsized--timer))
    (setq dirsized--timer nil)
    (dirsized-disconnect)))

(defun dirsized--teardown ()
  "Hook for `kill-buffer-hook' and `change-major-mode-hook'.
The current buffer stops using the mode: drop its timer and overlays, and
shut down the shared state if it was the last one."
  (dirsized--cancel-retry)
  (save-restriction (widen) (dirsized--remove-overlays))
  (dirsized--maybe-shutdown (current-buffer)))

;;;; Minor modes

;;;###autoload
(define-minor-mode dirsized-mode
  "Show real folder sizes in this Dired buffer, from the dirsized daemon."
  :lighter " Dsz"
  :group 'dirsized
  (cond
   (dirsized-mode
    (cond
     ((not (derived-mode-p 'dired-mode))
      (setq dirsized-mode nil)
      (user-error "Dirsized mode works in Dired buffers only"))
     ((file-remote-p default-directory)
      (setq dirsized-mode nil))
     (t
      (setq dirsized--cache (make-hash-table :test 'equal)
            dirsized--answers (make-hash-table :test 'equal))
      (add-hook 'dired-after-readin-hook #'dirsized--after-readin 90 t)
      (add-hook 'change-major-mode-hook #'dirsized--teardown nil t)
      (add-hook 'kill-buffer-hook #'dirsized--teardown nil t)
      (dirsized--ensure-timer)
      (when (> (buffer-size) 0)
        (dirsized--after-readin)))))
   (t
    (remove-hook 'dired-after-readin-hook #'dirsized--after-readin t)
    (remove-hook 'change-major-mode-hook #'dirsized--teardown t)
    (remove-hook 'kill-buffer-hook #'dirsized--teardown t)
    (dirsized--cancel-retry)
    (save-restriction (widen) (dirsized--remove-overlays))
    (setq dirsized--cache nil
          dirsized--answers nil
          dirsized--truenames nil
          dirsized--case-alist nil
          dirsized--inflight 0)
    (dirsized--maybe-shutdown))))

(defun dirsized--turn-on ()
  "Turn on `dirsized-mode' in a local Dired buffer."
  (when (and (derived-mode-p 'dired-mode)
             (not (file-remote-p default-directory)))
    (dirsized-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-dirsized-mode dirsized-mode
  dirsized--turn-on
  :group 'dirsized)

;;;; Sorting

(defun dirsized--entries (beg end)
  "Return the file entries between BEG and END.
Each is a list (START STOP NAME LISTING-SIZE).  START and STOP are the
bounds of the whole entry, including its line break."
  (let (res)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((bol (line-beginning-position))
              (start (dired-move-to-filename)))
          (if (not start)
              (forward-line 1)
            (let* ((nend (or (dired-move-to-end-of-filename t) start))
                   (name (buffer-substring-no-properties start nend))
                   (tok (progn (goto-char start) (dirsized--size-token)))
                   (size (if tok
                             (dirsized--parse-listing-size
                              (buffer-substring-no-properties
                               (car tok) (cdr tok)))
                           0)))
              (goto-char nend)
              (forward-line 1)
              (push (list bol (point) name size) res))))))
    (nreverse res)))

;;;###autoload
(defun dirsized-sort-by-size (&optional smallest-first)
  "Sort the lines of the current directory listing by size, largest first.
With prefix argument SMALLEST-FIRST, smallest first.  Folders use the
daemon values, files use their size from the listing.  Type \\`g' to get
the order of Dired back."
  (interactive "P")
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not a Dired buffer"))
  (let* ((dir (dired-current-directory))
         (reg (or (dirsized--region-of dir)
                  (user-error "Cannot find the directory in this buffer")))
         (true-dir (dirsized--true-dir dir))
         (file (dired-get-filename nil t))
         (inhibit-read-only t)
         (modified (buffer-modified-p))
         (cache (or dirsized--cache (make-hash-table :test 'equal)))
         entries fixed sortable)
    (save-excursion
      (save-restriction
        (widen)
        (setq entries (dirsized--entries (car reg) (cdr reg)))
        (when entries
          (dolist (e entries)
            (if (member (nth 2 e) '("." ".."))
                (push e fixed)
              (let ((v (gethash (dirsized--key true-dir (nth 2 e)) cache)))
                (push (cons (if (and v (memq (cdr v)
                                             '(ok scanning partial stale)))
                                (car v)
                              (nth 3 e))
                            e)
                      sortable))))
          (setq fixed (nreverse fixed)
                sortable (nreverse sortable))
          ;; The entries must be one block, else we do not touch the buffer.
          (let ((prev nil) (block t))
            (dolist (e entries)
              (when (and prev (/= prev (nth 0 e))) (setq block nil))
              (setq prev (nth 1 e)))
            (unless block (user-error "Cannot sort this listing")))
          (let* ((sorted (sort sortable
                               (lambda (a b)
                                 (if smallest-first
                                     (< (car a) (car b))
                                   (> (car a) (car b))))))
                 (strings (mapcar (lambda (e)
                                    (buffer-substring (nth 0 e) (nth 1 e)))
                                  (append fixed (mapcar #'cdr sorted))))
                 (first (nth 0 (car entries)))
                 (last (nth 1 (car (last entries)))))
            (delete-region first last)
            (goto-char first)
            (dolist (s strings) (insert s))))))
    (when dirsized--cache
      (dirsized--apply-dir dir true-dir))
    (when file (dired-goto-file file))
    (restore-buffer-modified-p modified)))

;;;; Status

;;;###autoload
(defun dirsized-status ()
  "Ask the daemon for its status and show it in a help buffer."
  (interactive)
  (unless (dirsized--request
           'status ""
           (lambda (ok data)
             (if (not ok)
                 (message "dirsized: %s" data)
               (with-help-window "*dirsized status*"
                 (dolist (kv data)
                   (princ (format "%s: %s\n" (dirsized--decode (car kv))
                                  (dirsized--decode (cdr kv)))))))))
    (message "dirsized: the daemon is not reachable")))

(provide 'dirsized)

;;; dirsized.el ends here
