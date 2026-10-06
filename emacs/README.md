# dirsized for Emacs

Dired shows the real total size of every folder, from the dirsized daemon.
Emacs never waits. If the daemon is off, Dired looks as usual.
It needs Emacs 28.1 or later.

Put this in init.el:

    (add-to-list 'load-path "/path/to/dirsized/emacs")
    (require 'dirsized)
    (global-dirsized-mode 1)

Remote (TRAMP) folders are skipped.

## Commands

- `dirsized-mode`: on or off in one Dired buffer. `global-dirsized-mode` does it for all Dired buffers.
- `dirsized-sort-by-size`: sort the listing by size, largest first. With a
  prefix argument, smallest first. Press `g` to get Dired's order back.
  Suggested key: `(define-key dired-mode-map "z" #'dirsized-sort-by-size)`
  (`z` is free in Dired. `S` is taken by `dired-do-symlink`.)
- `dirsized-status`: show the status of the daemon.
- `dirsized-disconnect`: close the connection to the daemon.

## Options

- `dirsized-socket`: socket path. Default: the daemon's default path.
- `dirsized-format`: `human`, `bytes`, or a function.
- `dirsized-refresh-interval`: seconds between refreshes of shown buffers (5, nil = off).
- `dirsized-idle-limit`: seconds of idle time after which refreshing pauses (60, nil = never).
- `dirsized-reconnect-interval`: least seconds between connect tries (5).
- `dirsized-pending-interval`: seconds before asking again after a non-final value (2).
- Faces: `dirsized-face`, `dirsized-pending-face`.

An answer that is the same as the last one is not applied again.
