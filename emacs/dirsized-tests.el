;;; dirsized-tests.el --- Tests for dirsized.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L emacs -l emacs/dirsized-tests.el \
;;         -f ert-run-tests-batch-and-exit
;; Needs python3 (for emacs/fake-server.py).  The tests use /tmp because
;; the path of a Unix socket must be short.

;;; Code:

(require 'ert)
(require 'dired)
(require 'ls-lisp)
(require 'cl-lib)
(require 'seq)
(require 'wdired)
(require 'dirsized)

(defconst dirsized-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Folder of this file.")

(defvar dirsized-test--root nil "Temp folder of the running test.")
(defvar dirsized-test--server nil "Fake server process.")

;;;; Helpers

(defun dirsized-test--wait (pred &optional timeout)
  "Wait until PRED returns non-nil, at most TIMEOUT seconds.  Return PRED."
  (let ((deadline (+ (float-time) (or timeout 8)))
        res)
    (while (and (not (setq res (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    res))

(defun dirsized-test--write (file size)
  "Write a FILE of SIZE bytes; create the folders above it."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert (make-string size ?x)))))

(defun dirsized-test--make-tree (root)
  "Make the test tree in ROOT.  Return ROOT."
  (let ((w (lambda (rel size)
             (dirsized-test--write (expand-file-name rel root) size))))
    (funcall w "plain/a" 536)
    (funcall w "plain/sub/b" 1000)
    (funcall w "with space/a" 10240)
    (funcall w "tab\there/a" 700)
    (funcall w "ünï/a" (* 5 1024 1024))
    (funcall w "new\nline/a" 2048)
    (funcall w "afile" 100)
    (funcall w "bfile" 9000))
  root)

(defun dirsized-test--start-server (root &rest args)
  "Start the fake server with ARGS; return its socket path."
  (let* ((sock (expand-file-name "s" root))
         (proc (make-process
                :name "fake-dirsized" :noquery t :connection-type 'pipe
                :buffer (generate-new-buffer " *fake-dirsized*")
                :command (append (list "python3"
                                       (expand-file-name "fake-server.py"
                                                         dirsized-test--dir)
                                       sock)
                                 args))))
    (setq dirsized-test--server proc)
    (unless (dirsized-test--wait (lambda () (file-exists-p sock)) 10)
      (error "Fake server did not start"))
    (dirsized-test--wait (lambda () nil) 0.05)
    sock))

(defun dirsized-test--stop-server ()
  "Stop the fake server."
  (when (process-live-p dirsized-test--server)
    (delete-process dirsized-test--server))
  (setq dirsized-test--server nil))

(defmacro dirsized-test--with-env (&rest body)
  "Run BODY with a fresh temp root, no server, and clean client state."
  (declare (indent 0))
  `(let* ((dirsized-test--root (file-truename (make-temp-file "/tmp/dsz" t)))
          (dirsized-socket (expand-file-name "s" dirsized-test--root))
          (dirsized-refresh-interval nil)
          (dirsized-reconnect-interval 0)
          (dirsized-pending-interval 100)
          (dired-listing-switches "-al")
          (dired-use-ls-dired t)
          (insert-directory-program (or (executable-find "gls") "ls"))
          (ls-lisp-use-insert-directory-program t)
          (dirsized-test--server nil))
     (dirsized-disconnect)
     (setq dirsized--fail-time nil)
     (unwind-protect
         (progn ,@body)
       (dolist (b (buffer-list))
         (when (buffer-local-value 'dirsized-mode b)
           (with-current-buffer b (dirsized-mode -1))))
       (dirsized-disconnect)
       (dirsized-test--stop-server)
       (dolist (b (buffer-list))
         (when (derived-mode-p 'dired-mode) (ignore-errors (kill-buffer b))))
       (delete-directory dirsized-test--root t))))

(defun dirsized-test--tree ()
  "Make the standard tree in the test root and return its path."
  (dirsized-test--make-tree (expand-file-name "tree" dirsized-test--root)))

(defun dirsized-test--dired (dir &optional switches)
  "Open Dired on DIR with SWITCHES and turn the mode on."
  (let ((buf (dired-noselect dir switches)))
    (with-current-buffer buf (dirsized-mode 1))
    buf))

(defun dirsized-test--overlays (buf)
  "Return an alist (NAME . TEXT) of the overlays in BUF."
  (with-current-buffer buf
    (mapcar (lambda (ov)
              (cons (overlay-get ov 'dirsized-name)
                    (string-trim (substring-no-properties
                                  (overlay-get ov 'display)))))
            (dirsized--overlays (point-min) (point-max)))))

(defconst dirsized-test--expected
  '(("plain" . "1.5K") ("with space" . "10K") ("tab\there" . "700")
    ("ünï" . "5.0M") ("new\nline" . "2.0K"))
  "Expected overlay texts for the standard tree.")

(defun dirsized-test--wait-overlays (buf n)
  "Wait until BUF has at least N overlays."
  (dirsized-test--wait
   (lambda () (>= (length (dirsized-test--overlays buf)) n))))

(defun dirsized-test--check (buf &optional expected)
  "Check the overlays of BUF against EXPECTED (default the standard list)."
  (let ((ovs (dirsized-test--overlays buf)))
    (dolist (e (or expected dirsized-test--expected))
      (should (equal (cdr e) (cdr (assoc (car e) ovs)))))
    (with-current-buffer buf
      ;; Columns do not shift, and each overlay sits on the size field.
      (dolist (ov (dirsized--overlays (point-min) (point-max)))
        (save-excursion
          (goto-char (overlay-start ov))
          (let* ((bol (line-beginning-position))
                 (under (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov)))
                 (name-start (progn (goto-char (overlay-end ov))
                                    (dired-move-to-filename t)))
                 (raw (string-width (buffer-substring-no-properties
                                     bol name-start))))
            (should (string-match-p "\\`[ ]*[0-9][0-9.,]*[BKMGTPE]?\\'" under))
            (should (string-match-p
                     (concat "\\`[ \t]+" dirsized--date-re "[ \t]+\\'")
                     (buffer-substring-no-properties (overlay-end ov)
                                                     name-start)))
            (goto-char name-start)
            (should (= raw (current-column)))))))))

;;;; Unit tests

(ert-deftest dirsized-format-human ()
  (should (equal "0" (dirsized--format-human 0)))
  (should (equal "512" (dirsized--format-human 512)))
  (should (equal "1023" (dirsized--format-human 1023)))
  (should (equal "1.0K" (dirsized--format-human 1024)))
  (should (equal "1.5K" (dirsized--format-human 1536)))
  (should (equal "1.1K" (dirsized--format-human 1025)))
  (should (equal "10K" (dirsized--format-human 10240)))
  (should (equal "23M" (dirsized--format-human (* 23 1024 1024))))
  (should (equal "4.2G" (dirsized--format-human
                         (ceiling (* 4.15 1024 1024 1024)))))
  (should (equal "1.0M" (dirsized--format-human (1- (* 1024 1024)))))
  (let ((dirsized-format 'bytes))
    (should (equal "1536" (dirsized--format 1536))))
  (let ((dirsized-format (lambda (n) (format "<%d>" n))))
    (should (equal "<7>" (dirsized--format 7)))))

(ert-deftest dirsized-socket-path ()
  (let ((dirsized-socket nil)
        (system-type 'darwin))
    (should (equal (expand-file-name "~/.cache/dirsized/sock")
                   (dirsized--socket-path))))
  (let ((dirsized-socket nil)
        (system-type 'gnu/linux))
    (let ((process-environment '("XDG_RUNTIME_DIR=/run/user/7")))
      (should (equal "/run/user/7/dirsized/sock" (dirsized--socket-path))))
    (let ((process-environment '("XDG_CACHE_HOME=/c/x")))
      (should (equal "/c/x/dirsized/sock" (dirsized--socket-path))))
    (let ((process-environment '("XDG_RUNTIME_DIR=" "XDG_CACHE_HOME=")))
      (should (equal (expand-file-name "~/.cache/dirsized/sock")
                     (dirsized--socket-path)))))
  (let ((dirsized-socket "/x/y"))
    (should (equal "/x/y" (dirsized--socket-path)))))

(ert-deftest dirsized-size-token-switches ()
  "The size field is found for many listing formats."
  (dolist (case '(("  -rw-r--r--  1 vl  staff  1234 Oct  5 12:00 " . "1234")
                  ("  drwxr-xr-x  3 vl  4.0K Oct  5  2024 " . "4.0K")
                  ("  drwxr-xr-x  3 1000 1000   96 Jan  5 12:00 " . "96")
                  ("  12 4 drwxr-xr-x  3 vl staff 96 Jan  5 12:00 " . "96")
                  ("  drwxr-xr-x  3 vl staff 96 2024-01-02 10:00 " . "96")
                  ("  drwxr-xr-x  3 vl staff 96 2024-01-02 10:00:00.123456789 +0100 "
                   . "96")
                  ("  drwxr-xr-x  3 vl staff 96 01-02 10:00 " . "96")
                  ("  drwxr-xr-x  3 vl staff 96  5. Jan 12:00 " . "96")
                  ("  drwxr-xr-x. 3 vl staff 1.5M Okt.  5 12:00 " . "1.5M")))
    (with-temp-buffer
      (insert (car case) "name")
      (goto-char (- (point-max) 4))
      (let ((tok (dirsized--size-token)))
        (should tok)
        (should (equal (cdr case)
                       (buffer-substring-no-properties (car tok) (cdr tok))))))))

(ert-deftest dirsized-parse-frames-chunked ()
  "Frames split at any byte are parsed the same."
  (let* ((data (concat "10\tok\t.\0" "1536\tscanning\tna\tme\nx\0"
                       "0\tnone\tz\0" "\0"))
         (got nil))
    (dolist (size '(1 2 3 5 1000))
      (let ((dirsized--queue nil) (dirsized--queue-tail nil)
            (dirsized--partial nil))
        (dirsized--enqueue (vector 'list (lambda (ok d) (setq got (cons ok d)))
                                   nil nil))
        (let ((i 0))
          (while (< i (length data))
            (dirsized--filter nil (substring data i (min (length data)
                                                         (+ i size))))
            (setq i (+ i size))))
        (should (equal got '(t (10 ok ".") (1536 scanning "na\tme\nx")
                                 (0 none "z"))))
        (setq got nil)))))

(ert-deftest dirsized-parse-error-and-status ()
  (let ((dirsized--queue nil) (dirsized--queue-tail nil) (dirsized--partial nil)
        a b)
    (dirsized--enqueue (vector 'list (lambda (ok d) (setq a (cons ok d))) nil nil))
    (dirsized--enqueue (vector 'status (lambda (ok d) (setq b (cons ok d))) nil nil))
    (dirsized--filter nil "!\tbad-request\toops\0\0proto\t1\0state\tok\0\0")
    (should (equal a '(nil . "bad-request\toops")))
    (should (equal b '(t ("proto" . "1") ("state" . "ok"))))
    (should (null dirsized--queue))))

;;;; Integration tests

(ert-deftest dirsized-overlays-switches ()
  "Overlays are right for several listing switches."
  (dolist (sw '("-al" "-alh" "-lh" "-l" "-alo" "-alg" "-lhog" "-ali" "-als"))
    (dirsized-test--with-env
      (let* ((tree (dirsized-test--tree)))
        (dirsized-test--start-server dirsized-test--root)
        (let ((buf (dirsized-test--dired tree sw)))
          (should (dirsized-test--wait-overlays buf 5))
          (dirsized-test--check buf))))))

(ert-deftest dirsized-overlays-ls-lisp ()
  "Overlays are right with ls-lisp.
ls-lisp indents the second line of a name with a newline, so skip that name."
  (dolist (sw '("-al" "-alh" "-lh" "-alg" "-alo"))
    (dirsized-test--with-env
      (let* ((ls-lisp-use-insert-directory-program nil)
             (tree (dirsized-test--tree)))
        (dirsized-test--start-server dirsized-test--root)
        (let ((buf (dirsized-test--dired tree sw)))
          (should (dirsized-test--wait-overlays buf 4))
          (dirsized-test--check
           buf (assoc-delete-all "new\nline"
                                 (copy-sequence dirsized-test--expected))))))))

(ert-deftest dirsized-overlays-bsd-ls ()
  "Overlays are right with the macOS ls, which has no --dired."
  (skip-unless (eq system-type 'darwin))
  (dolist (sw '("-al" "-alh" "-lh"))
    (dirsized-test--with-env
      (let* ((insert-directory-program "/bin/ls")
             (dired-use-ls-dired nil)
             (tree (dirsized-test--tree)))
        (dirsized-test--start-server dirsized-test--root)
        (let ((buf (dirsized-test--dired tree sw)))
          (should (dirsized-test--wait-overlays buf 3))
          (dirsized-test--check
           buf '(("plain" . "1.5K") ("with space" . "10K") ("ünï" . "5.0M"))))))))

(ert-deftest dirsized-overlays-bytes-format ()
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree))
          (dirsized-format 'bytes))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (should (equal "1536" (cdr (assoc "plain" (dirsized-test--overlays buf)))))
        (should (equal "5242880+" (concat (cdr (assoc "ünï" (dirsized-test--overlays buf))) "+")))))))

(ert-deftest dirsized-chunked-replies ()
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root "--chunk" "3")
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (dirsized-test--check buf)))))

(ert-deftest dirsized-global-mode-and-states ()
  "The global mode turns on in Dired; states give faces; excluded gets none."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root
                                   "--state" "plain=scanning"
                                   "--state" "with space=excluded")
      (global-dirsized-mode 1)
      (unwind-protect
          (let ((buf (dired-noselect tree)))
            (should (buffer-local-value 'dirsized-mode buf))
            (should (dirsized-test--wait-overlays buf 3))
            (dirsized-test--wait (lambda () nil) 0.2)
            (let ((ovs (dirsized-test--overlays buf)))
              (should-not (assoc "with space" ovs))
              (should (assoc "plain" ovs)))
            (with-current-buffer buf
              (let ((ov (seq-find (lambda (o) (equal "plain" (overlay-get o 'dirsized-name)))
                                  (dirsized--overlays (point-min) (point-max))))
                    (ok (seq-find (lambda (o) (equal "ünï" (overlay-get o 'dirsized-name)))
                                  (dirsized--overlays (point-min) (point-max)))))
                (should (eq 'dirsized-face
                            (get-text-property 0 'face (overlay-get ok 'display))))
                (should (eq 'dirsized-pending-face
                            (get-text-property 0 'face (overlay-get ov 'display)))))))
        (global-dirsized-mode -1)))))

(ert-deftest dirsized-pipelined-subdir ()
  "Inserting a subdir sends one more query; the answers keep their order."
  (dirsized-test--with-env
    (let* ((tree (dirsized-test--tree))
           (log (expand-file-name "log" dirsized-test--root)))
      (dirsized-test--start-server dirsized-test--root "--log" log "--delay" "0.05")
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (dired-goto-file (expand-file-name "plain" tree))
          (dired-maybe-insert-subdir (expand-file-name "plain" tree)))
        ;; The subdir "sub" (1000 bytes) gets an overlay.
        (should (dirsized-test--wait
                 (lambda () (assoc "sub" (dirsized-test--overlays buf)))))
        (should (equal "1000" (cdr (assoc "sub" (dirsized-test--overlays buf)))))
        (with-temp-buffer
          (insert-file-contents log)
          (should (string-match-p
                   (regexp-quote (concat "list " (file-truename tree) "/plain"))
                   (buffer-string))))
        ;; Revert sends one query per directory, in one go.
        (with-current-buffer buf
          (setq dirsized--inflight 0)
          (revert-buffer)
          (should (= 2 dirsized--inflight)))
        (should (dirsized-test--wait
                 (lambda () (with-current-buffer buf (= 0 dirsized--inflight)))))
        (should (assoc "sub" (dirsized-test--overlays buf)))
        (should (assoc "plain" (dirsized-test--overlays buf)))))))

(ert-deftest dirsized-ls-recursive ()
  "Several directories from `ls -R' each get overlays."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree "-alR")))
        (should (dirsized-test--wait
                 (lambda () (assoc "sub" (dirsized-test--overlays buf)))))
        (should (equal "1000" (cdr (assoc "sub" (dirsized-test--overlays buf)))))))))

(ert-deftest dirsized-pipelining-order ()
  "Requests sent together are answered in order."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)) out)
      (dirsized-test--start-server dirsized-test--root "--chunk" "7")
      (dirsized--request 'size (concat (file-truename tree) "/plain")
                         (lambda (_ok d) (push (list 'a d) out)))
      (dirsized--request 'size (concat (file-truename tree) "/ünï")
                         (lambda (_ok d) (push (list 'b d) out)))
      (dirsized--request 'list "/nonexistent-dsz"
                         (lambda (_ok d) (push (list 'c d) out)))
      (should (dirsized-test--wait (lambda () (= 3 (length out)))))
      (should (equal '(a b c) (mapcar #'car (reverse out))))
      (should (= 1536 (car (car (cadr (assq 'a out))))))
      (should (= 5242880 (car (car (cadr (assq 'b out))))))
      (should (eq 'none (cadr (car (cadr (assq 'c out)))))))))

(ert-deftest dirsized-no-server ()
  "No server: no error, no overlays, retry later, reconnect when it is back."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree))
          (dirsized-reconnect-interval 1000))
      (let ((buf (dirsized-test--dired tree)))
        (dirsized-test--wait (lambda () nil) 0.1)
        (should (null (dirsized-test--overlays buf)))
        (should (null dirsized--proc))
        (should dirsized--fail-time)
        ;; Inside the retry window nothing is tried (no new fail time).
        (let ((t0 dirsized--fail-time))
          (with-current-buffer buf (revert-buffer))
          (should (= t0 dirsized--fail-time)))
        ;; The server comes back; the window is over.
        (dirsized-test--start-server dirsized-test--root)
        (setq dirsized-reconnect-interval 0)
        (with-current-buffer buf (revert-buffer))
        (should (dirsized-test--wait-overlays buf 5))
        (dirsized-test--check buf)
        ;; The server dies: the connection drops silently.
        (dirsized-test--stop-server)
        (should (dirsized-test--wait (lambda () (null dirsized--proc))))
        (with-current-buffer buf (revert-buffer))
        (should (= 0 dirsized--inflight))
        ;; Dired shows its usual values again, or the cached ones.
        (with-current-buffer buf
          (should (dired-goto-file (expand-file-name "plain" tree))))))))

(ert-deftest dirsized-sort-by-size ()
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree))
            (names (lambda ()
                     (save-excursion
                       (let (res)
                         (goto-char (point-min))
                         (while (not (eobp))
                           (let ((f (dired-get-filename 'no-dir t)))
                             (when (and f (dired-move-to-filename))
                               (push f res)))
                           (forward-line 1))
                         (nreverse res))))))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (let ((before (funcall names))
                (inhibit-read-only nil))
            (should (equal '("." "..") (seq-take before 2)))
            (setq buffer-read-only t)
            (dired-goto-file (expand-file-name "plain" tree))
            (dired-mark 1)
            (dired-goto-file (expand-file-name "plain" tree))
            (dirsized-sort-by-size)
            (should (equal '("." ".." "ünï" "with space" "bfile" "new\nline"
                             "plain" "tab\there" "afile")
                           (funcall names)))
            (should (equal (expand-file-name "plain" tree)
                           (dired-get-filename nil t)))
            (should (equal (list (expand-file-name "plain" tree))
                           (dired-get-marked-files)))
            (should (= 6 (length (dirsized-test--overlays buf))))
            (dirsized-test--check buf)
            (dirsized-sort-by-size t)
            (should (equal '("." ".." "afile" "tab\there" "plain" "new\nline"
                             "bfile" "with space" "ünï")
                           (funcall names)))
            (dirsized-test--check buf)
            ;; g gives the order of Dired back.
            (revert-buffer)
            (should (equal before (funcall names)))))))))

(ert-deftest dirsized-mode-off-and-commands ()
  "Mode off removes everything; marks, wdired and dired-do still work."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (dired-goto-file (expand-file-name "afile" tree))
          (dired-mark 1)
          (should (equal (list (expand-file-name "afile" tree))
                         (dired-get-marked-files)))
          (dired-unmark-all-marks)
          ;; wdired
          (wdired-change-to-wdired-mode)
          (should (= 6 (length (dirsized-test--overlays buf))))
          (wdired-abort-changes)
          (should (derived-mode-p 'dired-mode))
          ;; dired-do-copy
          (dired-goto-file (expand-file-name "afile" tree))
          (dired-mark 1)
          (let ((target (file-name-as-directory
                         (expand-file-name "target" dirsized-test--root))))
            (make-directory target)
            (cl-letf (((symbol-function 'dired-mark-read-file-name)
                       (lambda (&rest _) target)))
              (dired-do-copy))
            (should (file-exists-p (expand-file-name "afile" target)))))))))

(ert-deftest dirsized-mode-off ()
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (dirsized-mode -1)
          (should (null (dirsized-test--overlays buf)))
          (should (null dirsized--cache))
          (should-not (memq #'dirsized--after-readin dired-after-readin-hook))
          (should-not (local-variable-p 'dired-after-readin-hook))
          (revert-buffer))
        (dirsized-test--wait (lambda () nil) 0.2)
        (should (null (dirsized-test--overlays buf)))
        ;; Last buffer off: connection closed.
        (should (null dirsized--proc))))))

(ert-deftest dirsized-refresh ()
  "The timer re-queries shown buffers and replaces only changed overlays."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree))
          (dirsized-refresh-interval 0.1))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree))
            (hidden (dirsized-test--dired (expand-file-name "plain" (dirsized-test--tree)))))
        (set-window-buffer (selected-window) buf)
        (should (dirsized-test--wait-overlays buf 5))
        (let ((old (with-current-buffer buf
                     (mapcar (lambda (o) (cons (overlay-get o 'dirsized-name) o))
                             (dirsized--overlays (point-min) (point-max))))))
          (dirsized-test--write (expand-file-name "plain/more" tree) 1024)
          (should (dirsized-test--wait
                   (lambda () (equal "2.5K" (cdr (assoc "plain" (dirsized-test--overlays buf)))))))
          (let ((new (with-current-buffer buf
                       (mapcar (lambda (o) (cons (overlay-get o 'dirsized-name) o))
                               (dirsized--overlays (point-min) (point-max))))))
            (should-not (eq (cdr (assoc "plain" old)) (cdr (assoc "plain" new))))
            (should (eq (cdr (assoc "ünï" old)) (cdr (assoc "ünï" new))))))
        ;; A buffer that is not shown is not queried.
        (should (equal 0 (with-current-buffer hidden dirsized--inflight)))
        (should-not (memq hidden (dirsized--shown-buffers)))))))

(ert-deftest dirsized-same-answer-is-not-applied ()
  "An answer equal to the last one skips the store and the overlay work."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)) (stores 0) (trues 0))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (should (dirsized-test--wait (lambda () (= 0 dirsized--inflight)))))
        (advice-add 'dirsized--store :before
                    (lambda (&rest _) (setq stores (1+ stores)))
                    '((name . dsz-count-store)))
        (advice-add 'file-truename :before
                    (lambda (&rest _) (setq trues (1+ trues)))
                    '((name . dsz-count-truename)))
        (unwind-protect
            (with-current-buffer buf
              (dotimes (_ 3)
                (dirsized--query-buffer)
                (should (dirsized-test--wait (lambda () (= 0 dirsized--inflight)))))
              (should (= 0 stores))
              (should (= 0 trues))
              ;; A change still comes through.
              (dirsized-test--write (expand-file-name "plain/more" tree) 1024)
              (dirsized--query-buffer)
              (should (dirsized-test--wait
                       (lambda () (equal "2.5K" (cdr (assoc "plain" (dirsized-test--overlays buf)))))))
              (should (= 1 stores)))
          (advice-remove 'dirsized--store 'dsz-count-store)
          (advice-remove 'file-truename 'dsz-count-truename))))))

(ert-deftest dirsized-killed-subdir-is-forgotten ()
  "A subdirectory that left the buffer keeps no answer and no truename."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (should (dirsized-test--wait (lambda () (= 0 dirsized--inflight))))
          (let ((shown (car (car dired-subdir-alist))))
            (puthash "/gone/" (cons nil nil) dirsized--answers)
            (push (cons "/gone/" "/gone") dirsized--truenames)
            (should (gethash shown dirsized--answers))
            (dirsized--query-buffer)
            (should-not (gethash "/gone/" dirsized--answers))
            (should-not (assoc "/gone/" dirsized--truenames))
            (should (gethash shown dirsized--answers))))))))

(ert-deftest dirsized-tick-pauses-when-away ()
  "The refresh tick sends nothing when the user was idle for long."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)) (idle 0))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (set-window-buffer (selected-window) buf)
        (should (dirsized-test--wait-overlays buf 5))
        (with-current-buffer buf
          (should (dirsized-test--wait (lambda () (= 0 dirsized--inflight))))
          (cl-letf (((symbol-function 'current-idle-time)
                     (lambda () (seconds-to-time idle))))
            (setq idle 120)
            (dirsized--tick)
            (should (= 0 dirsized--inflight))
            (setq idle 1)
            (dirsized--tick)
            (should (= 1 dirsized--inflight))))))))

(ert-deftest dirsized-regions-while-narrowed ()
  "A narrowed buffer, as in `dired-insert-subdir', still gives sane regions."
  (dirsized-test--with-env
    (let* ((tree (dirsized-test--tree))
           (buf (dired-noselect tree)))
      (with-current-buffer buf
        (narrow-to-region (point-min) (+ (point-min) 5))
        (let ((r (car (dirsized--subdir-regions))))
          (should (<= (nth 1 r) (nth 2 r)))
          (should (= (nth 2 r) (save-restriction (widen) (point-max)))))))))

(ert-deftest dirsized-disk-case-lists-one-name ()
  "The on-disk walk asks `directory-files' for one name, never for all."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)) (matches nil))
      (advice-add 'directory-files :before
                  (lambda (_dir _full match &rest _) (push match matches))
                  '((name . dsz-log-match)))
      (unwind-protect
          (should (equal (concat tree "/plain/sub")
                         (dirsized--disk-case (concat tree "/plain/sub"))))
        (advice-remove 'directory-files 'dsz-log-match))
      (when (file-name-case-insensitive-p tree)
        (should (equal (concat tree "/plain/sub")
                       (dirsized--disk-case (concat tree "/PLAIN/Sub")))))
      (should matches)
      (should (cl-every #'stringp matches)))))

(ert-deftest dirsized-status ()
  (dirsized-test--with-env
    (dirsized-test--start-server dirsized-test--root)
    (let (got)
      (should (dirsized--request 'status "" (lambda (ok d) (setq got (cons ok d)))))
      (should (dirsized-test--wait (lambda () got)))
      (should (car got))
      (should (equal "1" (cdr (assoc "proto" (cdr got)))))
      (dirsized-status)
      (should (dirsized-test--wait (lambda () (get-buffer "*dirsized status*"))))
      (with-current-buffer "*dirsized status*"
        (should (string-match-p "proto: 1" (buffer-string))))
      (kill-buffer "*dirsized status*"))))

;;;; Shutdown when buffers go away

(defun dirsized-test--idle-p ()
  "Return non-nil if the shared connection and the refresh timer are gone."
  (and (null dirsized--proc) (null dirsized--timer)))

(ert-deftest dirsized-kill-last-buffer-shuts-down ()
  "Killing the last mode buffer closes the connection and cancels timers."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree))
          (dirsized-refresh-interval 1))
      (dirsized-test--start-server dirsized-test--root "--state" "plain=scanning")
      (let ((a (dirsized-test--dired tree))
            (b (dirsized-test--dired (expand-file-name "plain" tree)))
            retry timer)
        (should (dirsized-test--wait-overlays a 5))
        (should (dirsized-test--wait
                 (lambda () (with-current-buffer a
                              (timerp dirsized--retry-timer)))))
        (setq retry (buffer-local-value 'dirsized--retry-timer a)
              timer dirsized--timer)
        (should (timerp timer))
        (should dirsized--proc)
        ;; One buffer is left: nothing is shut down.
        (kill-buffer b)
        (should (timerp dirsized--timer))
        (should dirsized--proc)
        (kill-buffer a)
        (should (dirsized-test--idle-p))
        (should-not (memq retry timer-list))
        (should-not (memq timer timer-list))))))

(ert-deftest dirsized-change-major-mode-shuts-down ()
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree))
          (dirsized-refresh-interval 1))
      (dirsized-test--start-server dirsized-test--root "--state" "plain=scanning")
      (let ((buf (dirsized-test--dired tree)) retry)
        (should (dirsized-test--wait-overlays buf 5))
        (should (dirsized-test--wait
                 (lambda () (with-current-buffer buf
                              (timerp dirsized--retry-timer)))))
        (setq retry (buffer-local-value 'dirsized--retry-timer buf))
        (with-current-buffer buf (fundamental-mode))
        (should (dirsized-test--idle-p))
        (should-not (memq retry timer-list))
        (should (null (dirsized-test--overlays buf)))))))

;;;; dired-hide-details-mode

(defun dirsized-test--line-widths (buf)
  "Return the pixel width of every line of BUF, which must be shown."
  (with-current-buffer buf
    (save-excursion
      (let (res)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((bol (line-beginning-position))
                (eol (line-end-position)))
            (push (car (window-text-pixel-size
                        nil bol (min (point-max) (1+ eol))))
                  res))
          (forward-line 1))
        (nreverse res)))))

(defun dirsized-test--widths-without-ours (buf ovs)
  "Return the line widths of BUF with the display strings of OVS off."
  (let ((displays (mapcar (lambda (o) (overlay-get o 'display)) ovs)))
    (dolist (ov ovs) (overlay-put ov 'display nil))
    (unwind-protect (dirsized-test--line-widths buf)
      (cl-mapc (lambda (o d) (overlay-put o 'display d)) ovs displays))))

(ert-deftest dirsized-hide-details ()
  "Hidden details: nothing of ours shows, nothing shifts.  Shown: intact."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)))
      (dirsized-test--start-server dirsized-test--root)
      (let ((buf (dirsized-test--dired tree)))
        (set-window-buffer (selected-window) buf)
        (should (dirsized-test--wait-overlays buf 5))
        (let* ((ovs (with-current-buffer buf
                      (dirsized--overlays (point-min) (point-max))))
               (displays (mapcar (lambda (o) (overlay-get o 'display)) ovs))
               (shown-on (dirsized-test--line-widths buf)))
          ;; Details shown: no column shifts.
          (should (equal shown-on (dirsized-test--widths-without-ours buf ovs)))
          (with-current-buffer buf (dired-hide-details-mode 1))
          ;; Details hidden: the lines look the same as without our overlays.
          (let ((hidden-on (dirsized-test--line-widths buf)))
            (should (equal hidden-on
                           (dirsized-test--widths-without-ours buf ovs)))
            (should (< (apply #'max hidden-on) (apply #'max shown-on))))
          (with-current-buffer buf (dired-hide-details-mode -1))
          ;; Shown again: the very same overlays, texts and widths.
          (should (equal (sort (copy-sequence ovs)
                               (lambda (a b) (< (overlay-start a) (overlay-start b))))
                         (sort (with-current-buffer buf
                                 (dirsized--overlays (point-min) (point-max)))
                               (lambda (a b) (< (overlay-start a) (overlay-start b))))))
          (should (equal displays (mapcar (lambda (o) (overlay-get o 'display))
                                          ovs)))
          (should (equal shown-on (dirsized-test--line-widths buf)))
          (dirsized-test--check buf))))))

;;;; Letter case on case-insensitive volumes

(defun dirsized-test--count-log (log re)
  "Count the lines of the file LOG that match RE."
  (with-temp-buffer
    (insert-file-contents log)
    (let ((case-fold-search nil))
      (how-many re (point-min)))))

(ert-deftest dirsized-case-insensitive-volume ()
  "A wrong spelling is fixed once, with one extra query, and cached."
  (dirsized-test--with-env
    (skip-unless (file-name-case-insensitive-p dirsized-test--root))
    (let* ((tree (dirsized-test--tree))
           (log (expand-file-name "log" dirsized-test--root))
           (bad (concat (file-name-directory tree) "TREE"))
           (walks 0))
      (dirsized-test--start-server dirsized-test--root "--exact-case"
                                   "--log" log)
      (advice-add 'dirsized--disk-case :before
                  (lambda (&rest _) (setq walks (1+ walks)))
                  '((name . dsz-count-walk)))
      (unwind-protect
          (let ((buf (dirsized-test--dired bad)))
            (should (dirsized-test--wait-overlays buf 5))
            (dirsized-test--check buf)
            (should (= 1 walks))
            (with-current-buffer buf (revert-buffer))
            (should (dirsized-test--wait
                     (lambda () (with-current-buffer buf
                                  (= 0 dirsized--inflight)))))
            (should (= 1 walks))
            (dirsized-test--check buf)
            ;; The wrong spelling went out once, the right one twice.
            (should (= 1 (dirsized-test--count-log log "/TREE'$")))
            (should (= 2 (dirsized-test--count-log log "/tree'$"))))
        (advice-remove 'dirsized--disk-case 'dsz-count-walk)))))

(ert-deftest dirsized-case-correct-spelling-no-walk ()
  "With the right spelling the on-disk walk never runs."
  (dirsized-test--with-env
    (let ((tree (dirsized-test--tree)) (walks 0))
      (dirsized-test--start-server dirsized-test--root "--exact-case")
      (advice-add 'dirsized--disk-case :before
                  (lambda (&rest _) (setq walks (1+ walks)))
                  '((name . dsz-count-walk)))
      (unwind-protect
          (let ((buf (dirsized-test--dired tree)))
            (should (dirsized-test--wait-overlays buf 5))
            (should (= 0 walks)))
        (advice-remove 'dirsized--disk-case 'dsz-count-walk)))))

;;;; Real daemon

(defconst dirsized-test--repo-root
  (file-name-directory (directory-file-name dirsized-test--dir))
  "Root folder of the repository.")

(defun dirsized-test--tree-total (dir)
  "Return the sum of the lengths of the files below DIR."
  (let ((sum 0))
    (dolist (f (directory-files-recursively dir ""))
      (unless (file-symlink-p f)
        (cl-incf sum (file-attribute-size (file-attributes f)))))
    sum))

(defun dirsized-test--home-env (home)
  "Return `process-environment' with HOME as home and no XDG paths.
Entries without `=' unset a variable, so a test daemon never uses the
socket or snapshot of the daemon that is installed."
  (append (list (concat "HOME=" home) "XDG_RUNTIME_DIR" "XDG_CACHE_HOME")
          process-environment))

(defun dirsized-test--real-status-ok-p (bin home)
  "Return non-nil if \"BIN status\" with HOME says `state: ok'."
  (let ((process-environment (dirsized-test--home-env home))
        (default-directory "/"))
    (with-temp-buffer
      (and (eq 0 (ignore-errors (call-process bin nil t nil "status")))
           (progn (goto-char (point-min))
                  (re-search-forward "^state: ok$" nil t))))))

(ert-deftest dirsized-real-daemon ()
  "Sizes from the real daemon equal the folder totals and follow changes."
  (let ((bin (expand-file-name "zig-out/bin/dirsized" dirsized-test--repo-root)))
    (skip-unless (file-executable-p bin))
    (let* ((home (file-truename (make-temp-file "/tmp/dszh" t)))
           (tree (expand-file-name "tree" home))
           (dirsized-socket (expand-file-name ".cache/dirsized/sock" home))
           (dirsized-refresh-interval 1)
           (dirsized-reconnect-interval 0)
           (dirsized-pending-interval 1)
           (dired-listing-switches "-al")
           (daemon nil))
      (dirsized-disconnect)
      (setq dirsized--fail-time nil)
      (unwind-protect
          (progn
            (dirsized-test--make-tree tree)
            (make-directory (expand-file-name ".config/dirsized" home) t)
            (with-temp-file (expand-file-name ".config/dirsized/config.toml" home)
              (insert (format "roots = [%S]\n" (file-truename tree))))
            (setq daemon
                  (let ((process-environment (dirsized-test--home-env home))
                        (default-directory "/"))
                    (make-process :name "real-dirsized" :noquery t
                                  :connection-type 'pipe
                                  :buffer (generate-new-buffer " *real-dirsized*")
                                  :command (list bin "daemon"))))
            (should (dirsized-test--wait
                     (lambda () (dirsized-test--real-status-ok-p bin home))
                     20))
            (let* ((buf (dirsized-test--dired tree))
                   (expect
                    (lambda ()
                      (mapcar
                       (lambda (d)
                         (cons d (dirsized--format
                                  (dirsized-test--tree-total
                                   (expand-file-name d tree)))))
                       '("plain" "with space" "tab\there" "ünï" "new\nline"))))
                   (matches
                    (lambda ()
                      (let ((ovs (dirsized-test--overlays buf)))
                        (cl-every (lambda (e) (equal (cdr e) (cdr (assoc (car e) ovs))))
                                  (funcall expect))))))
              (set-window-buffer (selected-window) buf)
              (should (dirsized-test--wait matches 10))
              (dirsized-test--check buf (funcall expect))
              (dirsized-test--write (expand-file-name "plain/sub/big" tree)
                                    (* 1024 1024))
              (should (equal "1.1M" (cdr (assoc "plain" (funcall expect)))))
              (should (dirsized-test--wait matches 5))
              (dirsized-test--check buf (funcall expect))))
        (dolist (b (buffer-list))
          (when (buffer-local-value 'dirsized-mode b)
            (with-current-buffer b (dirsized-mode -1))))
        (dirsized-disconnect)
        (when daemon
          (when (process-live-p daemon) (kill-process daemon))
          (dirsized-test--wait (lambda () (not (process-live-p daemon))) 3)
          (when (buffer-live-p (process-buffer daemon))
            (kill-buffer (process-buffer daemon))))
        (dolist (b (buffer-list))
          (when (derived-mode-p 'dired-mode) (ignore-errors (kill-buffer b))))
        (delete-directory home t)))))

;;;; Speed

(ert-deftest dirsized-5000-folders ()
  "A folder with 5000 sub-folders: report the time of each step."
  (dirsized-test--with-env
    (let* ((tree (expand-file-name "big" dirsized-test--root))
           (n 5000))
      (make-directory tree)
      (dotimes (i n)
        (make-directory (expand-file-name (format "folder-number-%05d" i) tree)))
      (dirsized-test--write (expand-file-name "folder-number-00007/f" tree) 5000)
      (dirsized-test--start-server dirsized-test--root)
      (let* ((buf (dirsized-test--dired tree))
             (tf 0.0) (th 0.0) (tq nil))
        ;; The first answer may have arrived already; revert to measure.
        (dirsized-test--wait (lambda () nil) 0.5)
        (advice-add 'dirsized--filter :around
                    (lambda (f &rest a)
                      (let ((t0 (float-time)))
                        (prog1 (apply f a) (cl-incf tf (- (float-time) t0)))))
                    '((name . dsz-time-filter)))
        (advice-add 'dirsized--handle-list :around
                    (lambda (f &rest a)
                      (let ((t0 (float-time)))
                        (prog1 (apply f a) (cl-incf th (- (float-time) t0)))))
                    '((name . dsz-time-handle)))
        (unwind-protect
            (with-current-buffer buf
              (dirsized--remove-overlays)
              (clrhash dirsized--cache)
              (clrhash dirsized--answers)
              (let ((t0 (float-time)))
                (dirsized--query-buffer)
                (setq tq (- (float-time) t0)))
              (should (dirsized-test--wait
                       (lambda () (>= (length (dirsized--overlays (point-min) (point-max)))
                                      n))
                       30)))
          (advice-remove 'dirsized--filter 'dsz-time-filter)
          (advice-remove 'dirsized--handle-list 'dsz-time-handle))
        (message "dirsized 5000 folders: send=%.1f ms, filter (parse)=%.1f ms, apply overlays=%.1f ms"
                 (* 1000 tq) (* 1000 tf) (* 1000 th))
        (should (< tq 0.05))
        (should (< tf 0.5))
        (should (< th 1.5))
        (with-current-buffer buf
          (let ((sorted nil))
            (let ((t0 (float-time)))
              (dirsized-sort-by-size)
              (setq sorted (- (float-time) t0)))
            (message "dirsized 5000 folders: sort+reapply=%.1f ms" (* 1000 sorted))
            (goto-char (point-min))
            (dired-goto-file (expand-file-name "folder-number-00007" tree))
            (should (equal "folder-number-00007"
                           (progn (goto-char (point-min))
                                  (forward-line 3)
                                  (dired-get-filename 'no-dir))))))))))

(ert-deftest dirsized-parse-speed-bytes ()
  "A 5000-record answer in 1-byte chunks is parsed in linear time."
  (let* ((data (apply #'concat
                      (append (list "100\tok\t.\0")
                              (mapcar (lambda (i) (format "%d\tok\tfolder-number-%05d\0" i i))
                                      (number-sequence 1 5000))
                              (list "\0"))))
         got)
    (let ((dirsized--queue nil) (dirsized--queue-tail nil) (dirsized--partial nil))
      (dirsized--enqueue (vector 'list (lambda (_ok d) (setq got d)) nil nil))
      (let ((t0 (float-time)))
        (dotimes (i (length data))
          (dirsized--filter nil (substring data i (1+ i))))
        (message "dirsized parse of %d bytes in 1-byte chunks: %.1f ms"
                 (length data) (* 1000 (- (float-time) t0)))
        (should (< (- (float-time) t0) 2.0))))
    (should (= 5001 (length got)))))

(provide 'dirsized-tests)

;;; dirsized-tests.el ends here
