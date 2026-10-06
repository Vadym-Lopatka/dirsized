# dirsized

[![ci](https://github.com/Vadym-Lopatka/dirsized/actions/workflows/ci.yml/badge.svg)](https://github.com/Vadym-Lopatka/dirsized/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Folder sizes, instantly.** A tiny daemon that always knows the size of every folder.

| The same folder, 2.45 million files | Time |
|---|---|
| `du -sh ~/prog` | 47 s |
| `dirsized -h ~/prog` | 0.004 s |

## Why

"How big is this folder?" is a simple question. The answer is slow.
`du` reads every file, every time. File managers show `4096` or `--` for a folder, because the real number costs too much.

The disk does not change that much. So why count again?

## How

`dirsized` reads your folders one time. Then it listens to the file system (FSEvents on macOS, inotify on Linux) and reads again only the folders that change.
All totals stay in memory. A question is one lookup.

- **Fast.** 4 ms from the command line. About 9 µs on an open socket.
- **Light.** 54 bytes for each folder. About 20 MB of memory for 2.4 million files. No CPU use when the disk is quiet.
- **Always current.** A change on the disk is in the totals about one second later.
- **Quick to start.** A restart loads a snapshot in 7 ms and replays what it missed. No new scan.
- **Small.** One static binary. Zig, no dependencies. No root, no `sudo`.
- **Easy to use from other programs.** A plain Unix socket, `--json`, NUL-separated output, clear exit codes. Good for editors, scripts and AI agents.

Numbers are from one Mac: 2.45 million files in 125 000 folders.

## Install

You need [Zig 0.16.0](https://ziglang.org/download/) (`brew install zig`) and macOS or Linux.

```sh
git clone https://github.com/Vadym-Lopatka/dirsized
cd dirsized
make install
```

This puts the binary in `~/.local/bin` and starts a service for your user (`launchd` on macOS, `systemd --user` on Linux).
Check it:

```sh
dirsized status        # "state: ok" means the first scan is done
```

The first scan runs one time. It took 15 s for 2.45 million files.

## Use

```sh
dirsized -h ~/prog           # size of one folder
dirsized -lh ~/prog          # child folders, largest first
dirsized -lhn 5 .            # the 5 largest
dirsized --json ~/a ~/b      # JSON: [{"path","bytes","state"}]
dirsized --scan -h /srv      # no daemon: read the disk now
```

```console
$ dirsized -lhn 3 ~/prog
4.7G    ok      /Users/me/prog/game
1.7G    ok      /Users/me/prog/app
1.2G    ok      /Users/me/prog/site
```

Each line is `BYTES<TAB>STATE<TAB>PATH`. STATE is `ok`, `scanning`, `partial`, `stale`, `excluded` or `none`.

Exit codes: 0 all `ok`; 1 a path is missing, excluded or outside the roots; 2 bad usage or config;
3 daemon not running; 4 a value is not final (`scanning`, `partial`, `stale`).
If several apply, the order is 2, 3, 1, 4.

All commands and options: `dirsized --help`.

## Configure

The daemon works with no config file. It then follows your home folder.
To change that, write `~/.config/dirsized/config.toml`:

```toml
roots = ["~"]
exclude = [
  "node_modules/",       # each folder with this name
  "/Library/Caches/",    # only this path, from the top of a root
  "!/prog/app/target/",  # exception: count this one
]
```

`exclude` uses the `.gitignore` syntax, for folders only. The daemon sees the change by itself.

```sh
dirsized check               # is the file correct?
dirsized check ~/prog/app    # is this folder counted? which rule decides?
```

A bad file does not stop the daemon. `dirsized status` shows the error.

## Emacs

Dired shows the real size of every folder. Emacs never waits.

```elisp
(add-to-list 'load-path "/path/to/dirsized/emacs")
(require 'dirsized)
(global-dirsized-mode 1)
```

More in [emacs/README.md](emacs/README.md).

## Good to know

- Sizes are file lengths, as `ls -l` shows. They are not disk blocks, so the number can differ from `du`. Hard links count in each folder. Symbolic links and other volumes are skipped.
- Until the first scan ends, answers have the state `scanning`.
- macOS sends no event while a program keeps a file open. The size grows when the program closes the file.
- macOS protects some folders (for example `~/Library/Mail`). They get the state `partial`, and `status` lists them. Give Full Disk Access to the binary to count them.
- Linux uses one inotify watch for each folder. If `status` shows that `watches` reaches `watch_limit`, raise it: `sudo sysctl fs.inotify.max_user_watches=1048576`.
- Linux is tested in Docker (Debian, Fedora, Alpine). The `systemd` service and btrfs subvolumes are not yet tested on a real computer. Reports are welcome.

## Files

| What | Where |
|---|---|
| Config | `~/.config/dirsized/config.toml` |
| Socket | `~/.cache/dirsized/sock` (Linux: `$XDG_RUNTIME_DIR/dirsized/sock`) |
| Snapshot | `~/.cache/dirsized/table` |
| Log | `~/.cache/dirsized/log` (Linux: `journalctl --user -u dirsized`) |

## Uninstall

```sh
make uninstall             # binary, service, socket, snapshot
make uninstall PURGE=1     # also the config file
```

## Inside

- [docs/DESIGN.md](docs/DESIGN.md): decisions, rules, measured results.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules and contracts.
- [docs/research](docs/research): prior art and the experiments behind the design.
- Tests: `make test`, `make test-emacs`, and `make test-linux` (Docker).

## License

[MIT](LICENSE)
