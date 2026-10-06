# dirsized

[![ci](https://github.com/Vadym-Lopatka/dirsized/actions/workflows/ci.yml/badge.svg)](https://github.com/Vadym-Lopatka/dirsized/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Folder sizes, instantly.** A tiny daemon that always knows the size of every folder.

| The same folder, 2.45 million files | Time |
|---|---|
| `du -sh ~/prog` | 47 s |
| `dirsized -h ~/prog` | 0.004 s |

One run on one Mac. `dirsized` paid for this before: its first scan of that folder took 15 s, one time.

## Why

"How big is this folder?" is a simple question. The answer is slow.
`du` reads every file, every time. File managers show `4096` or `--` for a folder, because the real number costs too much.

The disk does not change that much. So why count again?

## How

`dirsized` reads your folders one time. Then it listens to the file system (FSEvents on macOS, inotify on Linux) and reads again only the folders that change.
All totals stay in memory. A question is one lookup.

- **Fast.** 4 ms from the command line. About 9 µs on an open socket.
- **Light.** It keeps a record for each folder, not for each file: 54 bytes per folder. About 20 MB of memory for 125 000 folders. No CPU use when the disk is quiet.
- **Current.** A change on the disk is usually in the totals about one second later. A folder that changes all the time is read less often: the wait grows up to 30 s.
- **Quick to start.** On macOS a restart loads a snapshot in 7 ms and replays what it missed, with no new scan. On Linux a restart reads the folders again; until that ends, answers have the state `stale`.
- **Small.** One binary of about 700 KB on macOS. Zig, no dependencies. No root, no `sudo`.
- **Easy to use from other programs.** A plain Unix socket, `--json`, NUL-separated output, clear exit codes. Good for editors, scripts and AI agents.

The numbers are measured on one Mac, with 2.45 million files in 125 000 folders. Your numbers will differ.

## Install

You need:

- macOS or Linux.
- [Zig 0.16.0](https://ziglang.org/download/) (`brew install zig`). On macOS also the Xcode command line tools.
- `~/.local/bin` in your `PATH`.

```sh
git clone https://github.com/Vadym-Lopatka/dirsized
cd dirsized
make install
```

This puts the binary in `~/.local/bin` and starts a service for your user. It does not use `sudo`.

**macOS.** The service is a `launchd` agent. The first `make install` does not start it. It opens the Full Disk Access settings: add `~/.local/bin/dirsized` there, then run `make install` again. Without this permission, macOS asks you about each protected folder.
You do this one time. `make install` signs the binary with a local key, so later builds keep the permission. See "Good to know" for the cost of that key.

**Linux.** The service is a `systemd --user` unit. Without `systemd`, start `dirsized daemon` by hand.

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

Exit codes: 0 all `ok`; 1 a path is missing, not a folder, excluded or outside the roots; 2 bad usage or config;
3 daemon not running; 4 a value is not final (`scanning`, `partial`, `stale`).
If several apply, the order is 2, 3, 1, 4.

All commands and options: `dirsized help`.
The help is complete. A script or an AI agent can use the tool from that one command.

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

`exclude` uses the `.gitignore` syntax, for folders only. You do not restart the daemon: it reads the new file at the next query.

```sh
dirsized check               # is the file correct?
dirsized check ~/prog/app    # is this folder counted? which rule decides?
```

A bad file does not stop the daemon. `dirsized status` shows the error.

## Emacs

Dired shows the real size of every folder. Emacs never waits. It needs Emacs 28.1 or later.

```elisp
(add-to-list 'load-path "/path/to/dirsized/emacs")
(require 'dirsized)
(global-dirsized-mode 1)
```

More in [emacs/README.md](emacs/README.md).

## Good to know

- Sizes are file lengths, as `ls -l` shows. They are not disk blocks, so the number can differ from `du`. A sparse file counts with its full length: a Docker disk image can show hundreds of GB. Exclude such a folder if the total misleads you.
- Hard links count in each folder. Symbolic links and other volumes are skipped.
- Until the first scan ends, answers have the state `scanning`.
- macOS sends no event while a program keeps a file open. The size grows when the program closes the file.
- The events of the system can miss a change. So the daemon reads everything again every 7 days, in the background, and corrects the totals.
- macOS protects some folders (for example `~/Library/Mail`). Without Full Disk Access they get the state `partial`, and `status` lists them. If you give the permission later, restart the daemon: `launchctl kickstart -k gui/$(id -u)/local.dirsized`.
- The local signing key on macOS is in `~/.config/dirsized/signing.keychain-db`. Any program that runs as you can use it to sign itself and get the permissions you gave to `dirsized`. `make uninstall PURGE=1` removes the key.
- A cloud folder with online-only files (for example Google Drive) can fail to read. It then has the state `partial`. Exclude it if you want `ok`.
- Linux uses one inotify watch for each folder. If `status` shows that `watches` reaches `watch_limit`, raise it: `sudo sysctl fs.inotify.max_user_watches=1048576`.
- Linux is tested in containers (Debian, Fedora, Alpine) and in CI. The `systemd` service and btrfs subvolumes are not yet tested on a real computer. Reports are welcome.

## Files

| What | Where |
|---|---|
| Binary | `~/.local/bin/dirsized` |
| Config | `~/.config/dirsized/config.toml` |
| Socket | `~/.cache/dirsized/sock` (Linux: `$XDG_RUNTIME_DIR/dirsized/sock`) |
| Snapshot | `~/.cache/dirsized/table` (Linux: `$XDG_CACHE_HOME` replaces `~/.cache`) |
| Log | `~/.cache/dirsized/log` (Linux: `journalctl --user -u dirsized`) |
| Service | macOS: `~/Library/LaunchAgents/local.dirsized.plist`. Linux: `~/.config/systemd/user/dirsized.service` |
| Signing key (macOS) | `~/.config/dirsized/signing.keychain-db` |

## Uninstall

```sh
make uninstall             # stops the service; removes the binary, the service file, the socket, the snapshot and the log
make uninstall PURGE=1     # also removes ~/.config/dirsized: the config file and the signing key
```

`make uninstall` keeps your config and the signing key, so a later install needs no new permission.

Two things you remove by hand:

- macOS: the `dirsized` line in System Settings > Privacy & Security > Full Disk Access.
- Emacs: the lines you added to `init.el`.

## Inside

- [docs/DESIGN.md](docs/DESIGN.md): decisions, rules, measured results.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules and contracts.
- [docs/research](docs/research): prior art and the experiments behind the design.
- Tests: `make test`, `make test-emacs`, and `make test-linux` (Docker).

## License

[MIT](LICENSE)
