# Design: `dirsized`, a folder size daemon

This document describes what the code does.

Section 14 shows each target with its measured result.
The measured results come from one machine (macOS).
Section 16.2 lists the two checks that need a real Linux computer.
Section 21 gives the facts about the scan speed.
Language of this document: Simplified Technical English (ASD-STE100).

## 1. Goal

The daemon keeps the total size of each folder in memory.
A client with an open connection gets the size of a folder in less than 1 millisecond.
The daemon does the slow work one time. Then it only follows the changes.

The goal that we can prove is this:
`dirsized` gives the fastest answer for current folder sizes on macOS and Linux, with a small and known memory use.

The daemon must be simple to build, to install, and to remove.
An agent or a person must be able to configure it with a change to one file.

### What the goal does not include

`dirsized` cannot be better than each other tool in each property. Section 16 gives the facts.

## 2. Primary decisions

| Subject | Decision | Reason |
|---|---|---|
| Records | Folders only. No record for a file. | A disk has many more files than folders. |
| Update rule | Read one folder again and compare it with its record. | The rule is safe when an event comes two times. |
| Language | Zig, version 0.16.0. No dependencies. | See section 2.1. |
| Threads | One owner thread for the table. | No locks. No lock errors. |
| Query | Unix socket. An editor connects directly. | No new process for each query. |
| Scope | Only the roots in the configuration file. | A smaller table and a shorter first scan. |
| Configuration | One TOML file. Exclude rules use the `.gitignore` syntax. | Two known standards. |
| Privileges | None. The daemon runs as the user on macOS and on Linux. | A simple and safe installation. |
| Interfaces | Only public interfaces of the system. | A private interface can change, and it can need a permission. |
| Sequence | macOS first. Linux is the second delivery and is mandatory. | The Linux part does not change the table or the server. |

### 2.1 Language: Zig

Zig is the simpler language for this design, for these reasons:

- The daemon is system calls and flat arrays. Zig calls the C interfaces of macOS and Linux directly, with no wrapper library.
- The table uses indexes, not pointers. Thus the safety rules of Rust give little help here.
- Zig builds a static Linux binary on a Mac with one command. The Linux build needs no container.
- The project has no dependencies. You do not download or update libraries.

Zig has two costs:

- Zig is not at version 1.0, and a new version can change the language. Thus the project uses one fixed version: 0.16.0.
- The standard library of Zig has no TOML parser. The project has its own small parser.

The parser reads only what the configuration file needs: comments, two keys, and arrays of strings.
It reads each correct TOML form of these items. It gives an error for all other content.

The build uses the `ReleaseSafe` mode. In this mode, the binary stops when an index is out of range.

## 3. Parts

The daemon has five parts:

- The scanner reads the folder tree of each root.
- The table keeps the sizes in memory.
- The watcher gets the change events from the kernel.
- The server gives answers to queries on a Unix socket.
- The snapshot file keeps a copy of the table on the disk.

The table, the server, the configuration, and the command line are the same on the two systems.
Only the scanner and the watcher have a different source file for each system.

## 4. Rules for the size

- The size of a folder is the sum of the lengths of all the regular files below it.
- The length is the logical length, as `ls -l` shows it. It is not the space that the file uses on the disk.
- Hard link: the daemon counts the file in each folder where the file has a name.
- Symbolic link: the daemon does not count the link and does not follow it.
- APFS clone or reflink: the daemon counts the full length of each copy.
- Other volumes below a root: the daemon does not read them. It does not go into a folder that is a mount point.

The logical length is the only value that the events keep correct.
The space on the disk can change later with no event.

A sparse file, for example a disk image, shows its full logical length. The `status` command tells you this.

A sum of lengths that is larger than 2^64 wraps. A wrong value is better than a stop of the daemon.

### Accuracy

The goal is a fast and light answer for each folder. The goal is not a count of each byte at each moment.
Thus a value can be different from the disk for a short time. Section 8 gives the known case.

## 5. Table

The table is a tree in flat arrays and one name area.
The table does not keep full paths, because full paths use too much memory.

The node array has one node of 32 bytes for each folder:

| Field | Bytes | Content |
|---|---|---|
| `total` | 8 | `own` plus the `total` of each child folder |
| `own` | 8 | Sum of the lengths of the files that are directly in the folder |
| `parent` | 4 | Index of the parent node |
| `first_child` | 4 | Index of the first child node |
| `next_sibling` | 4 | Index of the next child of the same parent |
| `name` | 4 | 29 bits: position of the name in the name area. 3 bits: state of the node. |

The child links let the daemon list, delete, and move the child folders without a full scan of the array.

The child index is an open-address hash table of 4-byte node indexes.
Its key is the pair of the parent index and the hash of the folder name.
A query divides the path into its names. Then it does one lookup in the child index for each name.

On Linux, a second array keeps the watch number of each node. This adds 4 bytes for each folder.

### Removed nodes

- A list of free nodes lets the daemon use a removed node again.
- The table counts the bytes of the names of removed folders.
- When these bytes are more than the bytes of the live names, `shrinkToFit` compacts the name area.
- Node numbers do not change.
- The daemon writes the arrays of the table to the snapshot file as they are.
- After the first full scan, the daemon gives unused capacity back (`shrinkToFit`).

### Flags and states

The 3 bits of the `name` field are flags, not a state. A node has these flags:

| Flag | Meaning |
|---|---|
| `pending` | The content is unknown (a new folder). The node and each parent have the state `scanning`. |
| `denied` | The daemon could not read the folder. The node and each parent have the state `partial`. |
| `recheck` | A re-read is owed, but the value is believed current. The flag does not change the state. |

`recheck` has no effect on the state. Thus a busy disk does not change each answer to `scanning`.
The scanner clears `recheck` when it starts the read, not when it applies the result.
An event that comes during a read sets `recheck` again, and the daemon reads the folder one more time.

The table gives the state `ok`, `scanning`, or `partial` for a node.
The state `stale` is a state of a whole table generation, not of a node.
A generation is `stale` in two cases:

- After a restart with a snapshot file, until the watcher has caught up and the scanner is idle.
- While the daemon scans a new configuration. The daemon then answers from the old table, which does not change.

In a `stale` generation, each `ok` value is shown as `stale`. The states `scanning`, `partial`, `excluded`, and `none` do not change.

Each answer contains the state.

| State | Meaning |
|---|---|
| `ok` | The value is complete and current. |
| `scanning` | The scanner did not complete this folder or a folder below it. |
| `partial` | The daemon could not read a folder below this folder. The value is too small. |
| `stale` | The value is from the snapshot file or from the old table. A scan is not complete. |
| `excluded` | A rule in the configuration file excludes this folder. It has no record. |
| `none` | The path is not below a root, or it does not exist. |

The states `scanning` and `partial` go up to each parent. The state `stale` applies to the whole generation.

## 6. Update rule

There is only one update rule. The first scan, an event, and a correction after an error all use it.

To update a folder, the daemon does these steps:

1. Read the items of that one folder. Do not read the child folders.
2. Calculate the new `own` from the regular files.
3. Make the list of the child folders.
4. Add the difference between the new `own` and the previous `own` to the folder and to each parent.
5. Compare the list of child folders with the child nodes.
6. For each child folder that has no node, make a node. Then update that child folder with this same rule.
7. For each child node that has no folder, subtract its `total` from each parent. Then remove the node and all nodes below it.

The rule uses the state of the disk, not the content of the event.
Thus an event that comes two times, or events that the kernel merged, do not cause an error.

A moved folder is a removed folder in one parent and a new folder in a different parent.
The daemon scans the moved folder again. This is slower than a direct move of the node, but it is simpler.

### Errors during a read

- The daemon cannot read a folder because of a permission: the folder gets the flag `denied`. It keeps its last value and its child nodes.
  The daemon reads the folder again when an event arrives for it, at each start, and at the verification scan. A read that succeeds clears the flag.
- An item in a folder that the daemon cannot inspect, or a record that the system gives in a wrong form, has the same result. The item can be a folder.
  Thus the daemon does not trust the list of child folders, and the folder gets the state `partial`.
- A folder is not found, or is not a folder any more: the daemon reads the parent again. The read of the parent removes the child node.
  A root that is gone stays in the table with the flag `denied`.
- A temporary error (no free file descriptors, no memory): the daemon reads the folder again after 1 second.
- Any other error, for example an I/O error: the folder gets the flag `denied`. A repeated error must not keep the daemon busy for ever.

### Sequence of the watcher and the scanner

The daemon always starts the watcher before it reads a folder.
If the sequence is the opposite, the daemon does not see a change that occurs between the read and the start.

### Limits on the event rate

- The owner thread collects the events for 1 second. It updates each changed folder only one time.
  While the generation is `stale`, the owner thread does not wait.
- If a folder changes continuously, the daemon updates it after a longer interval. The interval doubles each time, to a maximum of 30 seconds.
  The daemon keeps this data in a small array of fixed size. The memory does not grow.
- Slow folders: if a read of a folder took T >= 50 milliseconds, the daemon does not read that folder again before 20 x T.
  The maximum wait is 10 minutes.
  The daemon keeps this data for up to 64 folders. When the array is full, the entry that expires first is replaced.
  When the two rules apply, the later time is used.
  The first scan and the verification scan do not wait.
- The daemon ignores an event for an excluded folder before it does other work.

The reason for the slow-folder rule: a folder with approximately 1 000 000 files needs 3 to 13 seconds of kernel time to read.
A build tool can write into such a folder each second. Without the rule, the daemon reads that folder all the time.

## 7. Threads

The owner thread does all the work on the table:

- It gets the events from the watcher.
- It applies the update rule.
- It gives the answers to the queries.

Worker threads only read folders. The daemon starts one worker for each CPU, but not more than 4. A worker thread sends the result to the owner thread through a queue.
The result is the folder, the new `own`, and the list of the child folders.
Thus a query gets an answer during a scan, and the table needs no lock.

On macOS, FSEvents calls the daemon on a dispatch queue. That call only writes to a pipe to start the owner thread.

## 8. macOS

| Function | Interface |
|---|---|
| Read a folder | `getattrlistbulk`. If the volume does not support it, `readdir` and `lstat`. |
| Get changes | FSEvents with folder events, one stream for each device, with absolute paths (`FSEventStreamCreate`) |
| Low priority for a scan | `setiopolicy_np` with `IOPOL_THROTTLE` |

`getattrlistbulk` gives names and lengths in one call. A `stat` call for each file is not necessary.
The daemon asks for the error attribute of each item, because one item can have an error. An item with an error makes the folder `partial`.

The daemon does not use `FSEventStreamCreateRelativeToDevice`. This function takes only one path.
A second path makes the start fail. On a mounted disk image, a stream with the path of a sub-folder gave no events (measured on macOS 27).
The latency of the stream is 0.3 seconds.

### Missing events

When the load is high, FSEvents does not always send all the events.
FSEvents then sets a flag: `MustScanSubDirs`, `UserDropped`, or `KernelDropped`.
If an event has `MustScanSubDirs`, the daemon scans that folder and all folders below it again.
If an event has `UserDropped` or `KernelDropped`, the daemon scans each root again, because the path of the event can be above the roots.
A subtree event for a path above the roots marks each root below that path.

### Files that stay open

FSEvents sends the event for a changed file when the program closes the file.
A test on macOS 27.0.1 showed this (`docs/research/fsevents-open-file`):

- A program wrote 3 MB to an open file in 32 seconds, with one `fsync`. FSEvents sent no event.
- FSEvents sent the event less than 1 second after the program closed the file.
- The result was the same with folder events and with file events.

Thus the value does not include data that a program added to a file that is still open.
This is an accepted limit. The value becomes correct when the program closes the file, or at the next verification scan.
Linux does not have this limit, because `inotify` sends an event for each write.

### Restart

FSEvents keeps the event history on the disk. Each event has an ID.
The snapshot file contains the ID of the last event that the daemon applied (the checkpoint).
The ID moves only by the IDs of events that FSEvents delivered and the daemon applied. The daemon never takes the current system event ID: it can be ahead of the delivered events, and a restart would lose an event.
After a long quiet time, a restart replays more history. This is harmless.
After a restart, the daemon gets all the events from that ID and applies the update rule.
At each start, the daemon also reads each denied folder again. A permission can change while the daemon is off, and FSEvents does not always report that change.
The replayed event IDs are not in order. The daemon keeps the maximum ID.
The replay is complete when FSEvents sends the `HistoryDone` flag. Until then, the generation is `stale`.

The daemon reads each folder again (a full scan) as an alternative in these conditions:

- The snapshot file is missing or its checksum is incorrect.
- The UUID of the event database changed (`FSEventsCopyUUIDForDevice`). This shows that macOS erased the history (lost history).
- The saved event ID is higher than the current event ID. This shows that the IDs started again from zero (`EventIdsWrapped`).
- The roots or the exclude rules changed.

### Verification scan

Apple states that the event history is not a complete record.
Thus the daemon does a full scan at low priority each 7 days and corrects the table.

### Protected folders

macOS prevents access to some folders, for example `~/Library/Mail`.
The daemon gives the state `partial` to such a folder and to its parents. The `status` command shows each such folder (at most 100).
To include these folders, give the "Full Disk Access" permission to the binary.

## 9. Linux

### Decision: `inotify`, with no privileges

| Function | Interface |
|---|---|
| Read a folder | `getdents64` and `statx`, in a pool of worker threads. Mount points: `stx_mnt_id`. |
| Get changes | `inotify`, one watch for each folder |
| Low priority for a scan | `ioprio_set` with the idle class |

`fanotify` with a filesystem mark is not applicable:

- It needs `CAP_SYS_ADMIN`. A user service of `systemd` cannot get that capability.
- A daemon with that capability can show the sizes of folders that the user cannot read.
- It does not work on a btrfs subvolume. Some Linux distributions put `/home` on a btrfs subvolume.
- It gets the events of all users on the filesystem.
- It needs special privileges in a Docker container.

`inotify` works for a usual user, on each filesystem, and in a Docker container.
The design does not use `io_uring`. A pool of threads is simpler and is not slower for `statx`.

### Cost of `inotify`

- The kernel uses memory for each watch. The estimate is 1 KB for each folder. This is kernel memory, not memory of the daemon.
- The kernel has a limit: `fs.inotify.max_user_watches`. If the daemon gets to the limit, the remaining folders get the state `partial`.
- The `status` command shows the number of watches and the limit.

### Events

A worker thread adds the watch to a folder before it opens the folder.
The watch number comes back with the result of the read. The owner thread stores it in the second array of the table.
A hash map gives the node for each watch number. An array does not work, because the watch numbers grow without bound.
If the watch cannot be added because of the limit, the node gets the flag `denied`, and its state is `partial`.
If a read fails, the worker removes the watch that it added.

A folder can change after the worker adds the watch and before the owner thread applies the read. The daemon remembers the event for that watch.
When the owner thread binds the watch to the node, it reads the folder again.

If the kernel removes a watch (`IN_IGNORED`) for a live node, the daemon reads the folder again. That read adds a new watch.
A removed node gives its watch back, but only if the hash map still binds that watch number to that node.
If the kernel queue is full, the kernel sends `IN_Q_OVERFLOW`. The daemon then scans each root again.
After a batch of events, the daemon does not poll the `inotify` descriptor for 100 milliseconds.
Thus the kernel merges a storm of writes into one wake-up.
There is one exception: if the batch filled the read buffer, more events wait, and the daemon does not hold.
A long hold could fill the kernel queue (16 384 events) and cause `IN_Q_OVERFLOW`.

### Restart

`inotify` has no event history, and the daemon must add all the watches again.
Thus the daemon reads each folder again after each restart. This includes each denied folder. The snapshot file has an empty watcher blob.
During that scan, the server gives the values from the snapshot file with the state `stale`.

### Not included

- Changes that a different computer makes on a network filesystem. The kernel does not send events for them.
- A privileged mode with `fanotify` for very large trees. It can be a later addition.

## 10. Snapshot file

- Location: `~/.cache/dirsized/table`. On Linux, `XDG_CACHE_HOME` replaces `~/.cache` if it is set.
- The daemon writes the file each 5 minutes if a read changed the table, once after the first full scan, once after each verification scan, and when it stops (`SIGTERM`, `SIGINT`, `SIGHUP`).
  An event alone does not count as a change. On a stop, the daemon always writes the file when the first full scan is complete (the checkpoint of the watcher may have moved).
  If the first scan is not complete, the daemon writes the file only if a read changed the table since the last save.
  An idle computer causes no periodic save.
- The file contains the raw arrays of the table: `nodes`, `names`, and `slots`. A save is a few large writes. A load is a few large reads.
- Measured for 125 000 folders: the file has 6.8 MB, a save takes 1 to 2 milliseconds, and a load takes approximately 1 millisecond.
- The daemon writes a temporary file, does `fsync`, and then renames it. Thus a failure cannot damage the file.
- The header contains a magic value, a format version, a checksum (XxHash3 of all data after the field), a hash of the configuration, the lengths of the sections, the free list, and the times of the last verification and the last save.
  The hash of the configuration covers the exclude rules and the letter-case mode of each root. The file also contains the roots and the watcher data (section 8).
- If the size, the checksum, the version, or the configuration hash is not correct, the daemon ignores the file and does a full scan. A bad file does not stop the daemon.
- After a load, the daemon queues each node that has the flag `pending` or `recheck`.
- The lock file `~/.cache/dirsized/lock` makes sure that only one daemon runs. A second daemon exits with code 2.

## 11. Server and protocol

The socket path is fixed for each system:

- macOS: `~/.cache/dirsized/sock`
- Linux: `$XDG_RUNTIME_DIR/dirsized/sock`

On Linux, if `XDG_RUNTIME_DIR` is not set, the socket is in the cache folder.
The folder of the socket has mode 0700. The server also does a check of the user ID of the client (`getpeereid` or `SO_PEERCRED`).

A path can contain a line break or a tab. Thus the protocol uses the NUL character as the separator.
One connection can send many queries.

```
request :  size SP PATH NUL  |  list SP PATH NUL  |  status NUL
size    :  BYTES TAB STATE TAB PATH NUL  NUL
list    :  BYTES TAB STATE TAB . NUL  { BYTES TAB STATE TAB NAME NUL }  NUL
status  :  { KEY TAB VALUE NUL }  NUL
error   :  ! TAB CODE TAB MESSAGE NUL NUL        CODE = bad-request | too-long
```

- `size` gives one record for the path.
- `list` starts with a record named `.` for the folder itself. Then it gives one record for each child folder. The records are not sorted.
  If the folder has no node, the answer has only the `.` record.
- `status` gives `KEY TAB VALUE` records. The keys are in this order:
  `proto` (the value is 1), `version`, `pid`, `state` (`ok`, `scanning`, `stale`, or `partial`), `folders`, `memory` (bytes of the table),
  `rss` (resident memory of the daemon process, in bytes), `queued`, `slow` (folders that the slow-folder rule holds back), `events`, `snapshot_age`, `verify_age` (seconds, or `-` if never),
  and `root` (one for each root).
  These keys can follow: `watches` and `watch_limit` (Linux), `watch_error` (the name of the error, if the watcher could not start; the daemon tries again each 60 seconds),
  `config_error`, and `denied` (one for each folder that the daemon cannot read, at most 100).
  While a configuration error is set, `state` is `partial`, not `ok`.
- A client can send many requests without waiting. The answers come in the same order.
- A request that is longer than `PATH_MAX` + 16 bytes gets the error `too-long`, and the server closes the connection.
- The sockets do not block. If a client does not read, the server keeps up to 16 MiB of output. Then it closes the connection.
- The server serves up to 32 clients. If all 32 places are in use, a new connection closes the client that was silent for the longest time.
  With a free place, the server never closes a client because it is idle.
- If the daemon refuses a connection, the client tries again 3 times, 2 milliseconds apart. Then it reports that the daemon does not run.
- The server does not resolve symbolic links. It ignores one `/` at the end of the path.

The path must be absolute and must have no symbolic links. The client makes it so with `realpath`.
This also corrects the letter case on a volume that ignores case.

## 12. Command line

The binary is the daemon and the client.

```
dirsized [PATH...]     size of each path, default "."
dirsized -l [PATH]     child folders with their sizes, largest first
dirsized status        state of the daemon, as key: value lines
dirsized check [PATH]  check of the configuration file
dirsized daemon        run the daemon in the foreground
dirsized help          the help text, on stdout; `--help` is the same
```

The help is plain text of at most 80 columns. It is complete: a program or an AI agent can use the tool from it.
`help` is a command word like `status`. It takes no PATH and no output option (`help x` is a usage error).
There is no `-?` option. With no argument, the command gives the size of `.` and never the help.

| Flag | Function |
|---|---|
| `-h` | Sizes with units: K, M, G |
| `-n N` | Only the N largest |
| `--json` | One JSON array of `{"path","bytes","state"}`. `bytes` is never in units. With `status`: one JSON object. A repeated key becomes an array. A byte of a path that is not UTF-8 is written as `\u00XX`. |
| `-0` | NUL character between the records. Use it for lossless paths: the path bytes are exact. |
| `--scan` | If the daemon does not run, read the disk directly. If the daemon runs, it answers. |
| `--` | End of the options. A path can start with `-`. |

The default output has one line for each path: `BYTES<TAB>STATE<TAB>PATH`.
If a folder has the name of a command (`status`, `check`, `daemon`, `help`), write it as a path, for example `./status`.

`dirsized check` shows each error in the file with its line number.
`dirsized check PATH` also shows the rule that excludes or includes that path.

| Exit code | Meaning |
|---|---|
| 0 | Success. All values have the state `ok`. |
| 1 | A path is excluded, is not below a root, or does not exist. |
| 2 | Incorrect command or incorrect configuration file. |
| 3 | The daemon does not run. |
| 4 | A value is not final: `scanning`, `partial`, or `stale`. The command shows the value. |

If more than one code applies, the command gives the first of this list: 2, 3, 1, 4.

A new process on macOS takes more than 1 millisecond.
Thus the target of 1 millisecond is for a client with an open connection, not for the command line.

## 13. Configuration

### 13.1 The file

The location is `~/.config/dirsized/config.toml` on macOS and on Linux.
The file has two keys. The daemon works with an empty file or with no file.

```toml
# Folders that the daemon monitors. "~" is the home folder.
roots = ["~"]

# Folders that the daemon ignores. The syntax is the syntax of .gitignore.
exclude = [
  "node_modules/",        # each folder with this name, at each depth
  "/Library/Caches/",     # only this path, from the top of a root
  "*.photoslibrary/",     # a name pattern
  "target/",
  "!/prog/app/target/",  # exception: count this folder
]
```

### 13.2 Rules for the roots

- A root must not be below a different root.
- On macOS, the root `/` is not permitted. The system volumes cause sizes that are counted two times.

### 13.3 Rules for the patterns

The patterns obey the `.gitignore` rules:

- A pattern with no `/`, or with a `/` only at the end, agrees with a folder at each depth.
- A pattern with a `/` at the start or in the middle starts at the top of a root.
- `*` agrees with all characters but `/`. `**` agrees with all depths.
- A `!` at the start makes an exception to a rule that comes before it.
- If two rules agree with a folder, the last rule wins.
- An exception cannot include a folder if a rule excludes its parent.

These rules are special for `dirsized`:

- A pattern applies only to folders, because the daemon keeps no file records.
- A pattern applies in each root. A pattern for only one root is not possible.
- The daemon compares names as the volume does: with or without letter case.
- The daemon does not read the `.gitignore` files of your projects. A folder that Git ignores can be very large.

An excluded folder has no record. Its size is not in the `total` of its parents.

### 13.4 Change of the file

The daemon has no watch on the file.
A query only wakes the main loop. The loop compares the change time, the size, and the inode of the file, but not more than one time each second.
The daemon does not read a file that changed less than 200 milliseconds ago. An editor can still write it.
The daemon sees a change at the next wake-up of the loop. Thus the first query after an edit can still get an answer from the old configuration.

If the file changed, the daemon does these steps:

1. Read the file and do a check of each key and each pattern.
2. If the file has an error, keep the previous configuration. Show the error in `status`.
   While the error is set, the daemon reads the file again each second, also if the file did not change. Thus a root that appears later (a disk that mounts late) is found.
3. If the file is correct and its hash is new, make a new table with a full scan. Use the previous table for answers, with the state `stale`, until the new table is complete.

An error in the file cannot stop the daemon and cannot erase the table.

### 13.5 Procedure for an agent

1. Change `~/.config/dirsized/config.toml`.
2. Do `dirsized check`. The exit code 0 shows that the file is correct.
3. Do `dirsized check <path>` for a path that must change.

## 14. Targets and results

The results are from one machine: macOS, with 125 000 folders and 2.45 million files under one root.
Linux was not measured.

| Item | Target | Result |
|---|---|---|
| Memory of the daemon on macOS | 50 to 60 bytes for each folder | Table: 6.8 MB, 54 bytes for each folder. Resident memory of the process: approximately 18 MB. |
| Memory of the daemon on Linux | 60 to 70 bytes for each folder | Not measured. The second array adds 4 bytes for each folder. |
| Kernel memory on Linux | Approximately 1 KB for each folder | Not measured. |
| CPU with no changes on the disk | Near 0 % | 0 |
| Query time with an open connection | Less than 100 microseconds | Median approximately 9 microseconds |
| Start with a snapshot file | Less than 50 milliseconds | 6 to 7 milliseconds, from the start of the daemon to the first answer |
| Delay between a change and the new value | 1 to 2 seconds | Not measured. The debounce is 1 second. |
| Command line call | Not a target | Approximately 7 milliseconds (`dirsized -lh` on the root with 125 000 folders) |
| First scan | Not a target | Approximately 15 seconds for 2.45 million files. See section 21. |

There is no target for the size of the binary. A small binary has no value for the user.

## 15. Build, installation, and removal

The repository has a `Makefile`. Each target does only the commands that this section shows.
You can do the commands manually. The result is the same.

| Target | Function |
|---|---|
| `make build` | Builds the binary |
| `make install` | Installs the binary and the service for the current user |
| `make uninstall` | Removes the binary, the service, and the cache folder (socket, snapshot file, lock file, log) |
| `make uninstall PURGE=1` | Also removes the configuration file |
| `make test` | Does the unit tests and the full test on this computer |
| `make test-emacs` | Does the tests of the Emacs client in a batch Emacs |
| `make test-linux` | Builds for Linux, does the Linux unit tests, and does the full test in Docker |

`make install` and `make uninstall` do not use `sudo`. They change only files in the home folder.

### 15.1 macOS

Necessary tools: Zig 0.16.0 and the Xcode command line tools.

Build:

```sh
zig build -Doptimize=ReleaseSafe
```

Install:

```sh
install -d ~/.local/bin ~/.config/dirsized ~/.cache/dirsized
install -m 755 zig-out/bin/dirsized ~/.local/bin/dirsized
install -d ~/Library/LaunchAgents
launchctl bootout gui/$(id -u)/local.dirsized 2>/dev/null   # only if an older copy runs
sed "s|@HOME@|$HOME|g" dist/local.dirsized.plist > ~/Library/LaunchAgents/local.dirsized.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.dirsized.plist
```

After `bootout`, wait until `launchctl print gui/$(id -u)/local.dirsized` fails. Then do the next commands.
The `Makefile` waits up to 5 seconds.
If the path of your home folder has one of the characters `&`, `<`, `\`, or `|`, the `sed` command above is not safe.
The `Makefile` escapes these characters for XML and for `sed`. Use `make install` in this case.

The plist (`dist/local.dirsized.plist`) starts `~/.local/bin/dirsized daemon` at load.
`KeepAlive` has `SuccessfulExit` set to false: launchd starts the daemon again after an exit with an error, and not after an exit with code 0.
The daemon writes its log to `~/.cache/dirsized/log`.

Make sure that the daemon runs:

```sh
dirsized status
```

Remove:

```sh
launchctl bootout gui/$(id -u)/local.dirsized
# wait until `launchctl print gui/$(id -u)/local.dirsized` fails
rm ~/Library/LaunchAgents/local.dirsized.plist
rm ~/.local/bin/dirsized
rm -r ~/.cache/dirsized
```

To remove the configuration also:

```sh
rm -r ~/.config/dirsized
```

### 15.2 Linux

Necessary tools: Zig 0.16.0. The system must have `systemd` with user services.

Build:

```sh
zig build -Doptimize=ReleaseSafe
```

Install:

```sh
install -D -m 755 zig-out/bin/dirsized ~/.local/bin/dirsized
install -D -m 644 dist/dirsized.service ~/.config/systemd/user/dirsized.service
systemctl --user daemon-reload
systemctl --user enable dirsized
systemctl --user restart dirsized
```

`restart` also replaces a daemon that runs an older binary.
The unit (`dist/dirsized.service`) starts `%h/.local/bin/dirsized daemon` with `Nice=5`.
It has `Restart=on-failure` and `RestartPreventExitStatus=2`: a second daemon, which exits with code 2, is not started again.
It also has these hardening lines: `NoNewPrivileges=yes`, `RestrictAddressFamilies=AF_UNIX`, `LockPersonality=yes`, and `SystemCallArchitectures=native`.

Make sure that the daemon runs:

```sh
dirsized status
```

Remove:

```sh
systemctl --user disable --now dirsized
rm ~/.config/systemd/user/dirsized.service
systemctl --user daemon-reload
rm ~/.local/bin/dirsized
rm -r "${XDG_CACHE_HOME:-$HOME/.cache}/dirsized"
```

To remove the configuration also:

```sh
rm -r ~/.config/dirsized
```

If `status` shows that the watch limit is too small, an administrator must increase it:

```sh
sudo sysctl fs.inotify.max_user_watches=1048576
```

This is the only step that needs `sudo`, and it is optional.

A system without `systemd` can start the daemon with the command `dirsized daemon`.

## 16. Tests

### 16.0 What exists now

- Unit tests: `zig build test` runs them. On macOS, 170 tests pass.
- `test/e2e.sh`: 205 checks on macOS. The checks on Linux in Docker are 199 for each image.
- `test/linux-unit.sh`: builds the unit tests of `scan_linux.zig` and `watch_linux.zig` for Linux and runs them in a clean container as a non-root user. 115 tests pass.
- `test/docker.sh`: runs `test/e2e.sh` as a non-root user (uid 1000, all capabilities dropped, `no-new-privileges`) on Debian, Fedora, and Alpine. 0 checks failed on each image.
- `emacs/dirsized-tests.el`: 33 tests. One of them runs against the real daemon. The others use a fake server. `make test-emacs` runs them.

Run `make test`, `make test-emacs`, and `make test-linux` for the current numbers.

### 16.1 One test for the two systems

One shell script, `test/e2e.sh`, does the full test. It uses only the command line of `dirsized`.
`make test` runs the script on this computer. `make test-linux` runs the same script in Docker.

The script uses a reference value that does not come from `dirsized`:
the sum of the lengths of all regular files that `find` gives for a folder.
Do not use the default output of `du` as the reference. `du` counts disk blocks and the folders themselves.

The script does these steps:

1. Make a tree of folders and files in a temporary folder.
2. Write a configuration file with that folder as the only root.
3. Start `dirsized daemon`. Wait until `dirsized status` shows the state `ok`.
4. Compare the value of each folder with the reference.
5. Change the tree. Wait 3 seconds. Compare each folder again.
6. Stop the daemon with `SIGKILL`. Start it again. Compare each folder again.
7. Add an exclude rule. Do `dirsized check`. Compare each folder again.
8. Write an incorrect configuration file. Make sure that the daemon keeps the previous configuration.

Step 5 of this list does these changes:

- Make a file, add data to a file, and decrease the length of a file.
- Delete a file and delete a full tree.
- Make many levels of new folders in one command.
- Move a folder in the same parent and to a different parent.
- Make a hard link and a symbolic link.
- Make a name with a space, a line break, and characters that are not ASCII.
- Make 100 000 files in a short time, to cause many events. The variable `DIRSIZED_E2E_BURST` changes the number.

### 16.2 Linux in Docker

`make test-linux` does these steps:

1. Build a static Linux binary on this computer. Docker is not necessary for this step.
2. Run `test/linux-unit.sh`: the unit tests of the Linux watcher and scanner, in a clean container.
3. Run `test/docker.sh`: copy the binary into a clean container and run `test/e2e.sh` there.

The build command for step 1 of this list is:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
```

Use `x86_64-linux-musl` for a computer with an Intel or AMD processor.

Rules for the Docker test:

- The container runs as a usual user, with no special privileges. This proves the decision of section 9.
- The test tree must be in the filesystem of the container, not in a folder of the host. Events do not come reliably from a host folder.
- The container has no `systemd`. The script starts `dirsized daemon` directly.
- The test runs on three images: Debian, Fedora, and Alpine. The same static binary must work on all three.

One more test makes the watch limit small and makes sure that the daemon gives the state `partial`.
That test needs a privileged container, because it changes a kernel value. It is a separate target and it is not built.
A unit test of the watcher covers a failed watch (the folder gets the state `partial`).

Docker does not do a test of these items. Do them on a real Linux computer before a release.
These checks are not done:

- Installation and removal with `systemd`.
- A btrfs subvolume.

## 17. Other tools

| Tool | What it does | Comparison |
|---|---|---|
| CephFS | The filesystem keeps the size of each folder. | Better than `dirsized`: no daemon and no memory. Only on CephFS. |
| XFS and ext4 project quotas | The kernel counts the use of some folder trees. | Better for a small number of trees. Not for each folder. |
| ZFS datasets, btrfs qgroups | The filesystem counts each dataset or subvolume. | Better for a dataset. Not for a usual folder. |
| APFS folder statistics | The kernel keeps the size of a folder that has a flag. | Very fast, but not used. See section 17.1. |
| Everything (Windows) | Keeps folder sizes and follows the NTFS journal. | The same idea on a different system. `dirsized` is not the first. |
| Watchman | Follows events and keeps a record for each file. | Uses more memory for this task. More mature. |
| `fdu` | A scan tool with a watch mode and an index for each process. | A record for each file. No daemon and no socket. |
| `coxswain` | A file manager with a daemon that adds the folder sizes. | A record for each file. A private protocol. No command line. |
| WhatSize, `diskr`, `petal` | macOS tools that use FSEvents to update their sizes. | Not a daemon. Other programs cannot send a query. |
| `duc` | Keeps an index on the disk. Does not follow events. | Simpler and uses no memory. Its values become old. |
| `ncdu`, `gdu`, `dua`, `dust` | Fast scans with no daemon. | Simpler: no process runs. Each query is a full scan. |

A wide search was done before the design (`docs/research/prior-art.md`). The search has approximately 50 web queries.
It did not find a tool for macOS and Linux that keeps folder records only and gives answers on a socket.
The idea is not new. Some of the tools in the table are from the year 2026.
The search found no tool of this type for Linux.

### 17.1 APFS folder statistics

A test of this function was done before the design, on macOS 27.0.1 (`docs/research/apfs-dirstats/REPORT.md`).

- A private call of the kernel gives the full size of a folder in approximately 7 microseconds.
- The folder must have a flag. A second private call sets the flag, also on a folder that has content.
- The value is the space on the disk, not the logical length.

`dirsized` does not use this function, for these reasons:

- The two calls are private and have no documentation. Apple can change them in each release.
- The test did not find a procedure to remove the flag.
- The test used only a disk image, not a real system volume.
- The daemon must work on each Mac with only public interfaces and no special permission.

## 18. Platform status

The code runs on macOS and on Linux. Two checks need a real Linux computer: installation and removal with `systemd`, and a btrfs subvolume (section 16.2).

## 19. Emacs client

The client is `emacs/dirsized.el`. `emacs/README.md` has the setup and the options.

- The client keeps one open connection to the socket. It does not close the connection while a Dired buffer uses it.
- When dired shows a folder, the client sends one `list` query. A process filter gets the answer, thus Emacs does not stop.
- The client shows each size as an overlay on the size column. A value that is not `ok` has a different face (`dirsized-pending-face`).
- A refresh timer asks again for the shown buffers (`dirsized-refresh-interval`, 5 seconds). After a value that is not final, the client asks again after 2 seconds (`dirsized-pending-interval`).
- If the connection fails, the client tries again after at least 5 seconds (`dirsized-reconnect-interval`).
- The refresh pauses when the user is idle for more than 60 seconds (`dirsized-idle-limit`). The timer keeps running, but it sends no query.
- If an answer is the same as the last answer for that folder, the client does not apply it again.
- The client needs Emacs 28.1 or later.
- `dirsized-sort-by-size` sorts the lines of the buffer by size, largest first. A prefix argument gives smallest first. The key `g` gives the order of Dired back.
- `dirsized-status` shows the state of the daemon.
- `dirsized-mode` switches the client on or off in one buffer. `global-dirsized-mode` does it for all Dired buffers.
- The client skips remote (TRAMP) folders.
- If the daemon does not run, dired shows the usual values.
- The tests run in a batch Emacs (`make test-emacs`). One test uses the real daemon. The others do not need it.

## 20. Open questions and items not yet tested

Each item shows its status:

- The access rules of macOS for a `launchd` agent that is not an application. The daemon runs as a `launchd` agent on one Mac with the root `~/prog`. Folders that macOS protects (for example `~/Library/Mail`) are not tested: they need Full Disk Access.
- The names of the length attributes of `getattrlistbulk`. Closed. The scanner asks for the name, the object type, the mount status, the error, and the file data length. The tests agree with `find`.
- The kernel memory for one `inotify` watch. Open. Nobody measured it.
- The default values of the `inotify` limits on current distributions. Open. The `status` command shows the limit that applies.
- That `realpath` gives the letter case of the disk on APFS. Open. The client uses `realpath`, but no test shows the letter case.

One more finding: on macOS, `ATTR_CMN_DEVID` returns the device of the parent folder, not of the folder. Thus the scanner finds a mount point with the flag `DIR_MNTSTATUS_MNTPOINT`.

## 21. Scan speed: what limits it

All numbers are from measurements on one macOS machine, with a tree of 2.45 million files in 125 000 folders.

- The time of a scan is kernel time. The first measure: 14.8 s in total, 14.5 s in the kernel, 0.3 s in user code.
- One folder costs approximately 45 microseconds in the kernel: 15 for the open, 20 for the first read, 10 for the last empty read.
- The kernel needs approximately 2 microseconds for each file when its cache is hot, and approximately 13 microseconds when it is cold.
- The cache of the kernel (vnode cache) holds 263 000 entries (`kern.maxvnodes`). Thus a full scan of 2.45 million files is always mostly cold.
- The giant-folder case: one folder has 999 697 files. It costs 3 seconds hot and 13 seconds cold.
  One thread reads it, because the kernel locks the folder.
  This is the reason for the slow-folder rule of section 6.
- The scanner is within 20 % of the kernel floor. A test tree took 0.64 s, and the C probe took 0.53 s.
- A first scan of this tree in less than 1 second is not possible with the public calls of macOS.
  The first scan is a one-time cost. After it, the answers come from memory.

Tried and rejected, with no gain:

- 8 or 16 threads: no gain, and more kernel spin.
- Many readers on the giant folder: 3 times slower.
- A cheap pass that reads only the names: the same cost.
- A lock around the big reads: no change.
- Fewer attributes: no change.
- `openat`: no change.
- A buffer of 1 MB: no change.

Ideas for a quiet machine that nobody tested: skip the empty last read, skip empty folders, keep each thread in its own sub-tree.
