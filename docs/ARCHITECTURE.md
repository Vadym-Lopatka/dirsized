# dirsized: code architecture and module contracts

DESIGN.md says what the tool does and why. This file says how the code is split and what the
interfaces between modules are. If code and this file disagree, the code is right. Fix this file.

Zig version: **0.16.0** (pinned). No dependencies. See `ZIG-NOTES.md` for verified 0.16 API facts.

## Principles (apply to every module)

1. **Smallest thing that works.** No abstraction without two users. No option without a need in DESIGN.md.
2. **Folders only.** Nothing in the daemon's memory is proportional to the number of files.
3. **No allocation on hot paths.** A query, an event, and a folder read reuse caller-owned buffers.
4. **One owner thread mutates the table.** Workers only read the disk and post results.
5. **State-based updates.** Results are applied by comparing disk state with the table (DESIGN.md section 6), so a duplicated, late or reordered result must be harmless.
6. **Paths are bytes.** Never assume UTF-8, never assume no newline. Names are compared byte-exact.
7. **Errors are values.** No panics on bad input, bad config, vanished folders or permission errors. `unreachable` only for real invariants.
8. **Every module has unit tests in the same file** and passes `zig test src/<file>.zig` standalone where it has no OS dependency.
9. **Comments say why, not what.** Match the density of existing code. No banner comments.
10. Platform code lives only in `scan_darwin.zig`, `scan_linux.zig`, `watch_darwin.zig`, `watch_linux.zig`. Everything else is portable.

## Layout

```
build.zig, build.zig.zon     build, `zig build test`, cross target
Makefile                     build, install, uninstall, test, test-emacs, test-linux
LICENSE                      MIT license
src/main.zig                 entry: calls cli.run, maps result to exit code
src/cli.zig                  argument parsing, output formats, exit codes
src/config.zig               TOML-subset parser, Config, validation
src/ignore.zig               .gitignore-syntax rules for folders
src/table.zig                the folder table (pure data structure, no I/O)
src/scan.zig                 FolderRead type + `readFolder`, selects the platform file
src/scan_darwin.zig          getattrlistbulk reader (+ readdir/lstat fallback)
src/scan_linux.zig           getdents64 + statx reader
src/scanner.zig              worker pool + owner-side apply loop
src/server.zig, proto.zig    socket server and wire protocol
src/paths.zig                socket, lock, snapshot and metrics log paths
src/metrics.zig              the optional metrics log (off by default)
src/watch.zig                Change type, platform selection
src/watch_darwin.zig         FSEvents watcher
src/watch_linux.zig          inotify watcher
src/snapshot.zig             snapshot file
src/daemon.zig               the daemon: poll loop, generations, debounce, config reload
dist/                        launchd plist, systemd unit, macOS signing script
emacs/                       Emacs client for Dired (dirsized.el, tests, fake server, README)
test/e2e.sh                  end-to-end test, same script on macOS and in Docker
test/docker.sh               runs e2e.sh in Debian, Fedora and Alpine containers
test/linux-unit.sh           runs the Linux-only unit tests in a container
.github/workflows/ci.yml     CI
docs/DESIGN.md               what the tool does and why
docs/ZIG-NOTES.md            verified Zig 0.16 API notes
docs/research/               early experiments and the prior-art search
```

## table.zig

Pure data structure. No syscalls, no threads, no logging. Owner thread only.

```zig
pub const NodeId = u32;
pub const none: NodeId = std.math.maxInt(u32);

pub const Node = extern struct {      // exactly 32 bytes; comptime-asserted
    total: u64,        // own + total of every child
    own: u64,          // sum of logical lengths of regular files directly inside
    parent: NodeId,    // `none` for a root
    first_child: NodeId,
    next_sibling: NodeId,
    name: u32,         // low 29 bits: offset into the name area; high 3 bits: flags
};

pub const Flags = packed struct(u3) {
    pending: bool = false,  // not read yet (or a re-read is owed after creation)
    denied: bool = false,   // could not be read (permission)
    recheck: bool = false,  // a re-read is owed but the value is believed current; never changes `state`
};

pub const State = enum { ok, scanning, partial };   // `stale`, `excluded` and `none` are decided by the daemon

pub const Table = struct {
    pub fn init(gpa: Allocator) Table;
    pub fn deinit(self: *Table) void;

    pub fn addRoot(self: *Table, abs_path: []const u8) !NodeId;      // flags.pending = true
    pub fn removeRoot(self: *Table, id: NodeId) void;
    pub fn roots(self: *const Table) []const Root;                   // Root = struct { path: []const u8, node: NodeId }

    pub fn lookup(self: *const Table, abs_path: []const u8) ?NodeId; // longest root prefix, then one index probe per name
    pub fn child(self: *const Table, parent: NodeId, name: []const u8) ?NodeId;
    pub fn children(self: *const Table, parent: NodeId) ChildIterator; // next() ?NodeId
    pub fn name(self: *const Table, id: NodeId) []const u8;           // for a root: its full path
    pub fn pathOf(self: *const Table, id: NodeId, out: *std.ArrayList(u8), gpa: Allocator) !void;

    pub fn total(self: *const Table, id: NodeId) u64;
    pub fn state(self: *const Table, id: NodeId) State;

    /// The update rule, DESIGN.md section 6 steps 4-7. `child_names` is the complete list of
    /// child folders now on disk. Clears `pending` and `denied` on `id`, not `recheck`. New
    /// children are created with `pending = true`. They are appended to `new_children`, with the
    /// kept children that are still `pending`; the caller must read each of them. Children no longer on disk are removed with their whole subtree.
    /// Returns true when `own`, the child set, or a `pending` / `denied` flag changed.
    pub fn applyRead(self: *Table, id: NodeId, own: u64, child_names: []const []const u8,
                     new_children: *std.ArrayList(NodeId), gpa: Allocator) !bool;

    /// The folder could not be read. Keeps its last known value and children, sets `denied`,
    /// clears `pending`. Returns true when a flag changed. Fails only with OutOfMemory (a new
    /// entry in the side map).
    pub fn applyDenied(self: *Table, id: NodeId) Allocator.Error!bool;

    pub fn count(self: *const Table) usize;         // live nodes
    pub fn memoryBytes(self: *const Table) usize;   // all arrays, capacity not length
};
```

Rules:

- **State without subtree walks.** `state(id)` must be O(1). Keep one sparse side map,
  `below: NodeId -> {pending, denied}`, holding for each ancestor the number of descendants with
  each flag. An entry exists only while a count is non-zero, so the map is empty in steady state
  (pending) or tiny (denied). Every flag change walks the
  parent chain once. Answer: pending self or below -> `scanning`; else denied self or below
  -> `partial`; else `ok`.
- **Totals.** Any change of `own`, and any add/remove of a subtree, walks the parent chain once and
  adjusts `total`. Sums wrap (`+%`, `-%`) instead of panicking: a wrong size is better than a crash.
- **Names** live in one byte area: one length byte, then the bytes (max 255). The area grows by
  appending. The table counts the bytes of freed names (`dead_names`). `shrinkToFit` compacts the
  area and patches the offsets when dead bytes are more than live bytes.
  A root's name is its full path and is stored in the roots list, not in the name area.
- **Child index**: open addressing over `u32` node ids, key = (parent id, name bytes), hash of
  both. Grows at 70 % load. Deletion uses backward shift, so there are no tombstones. Lookup
  compares parent then bytes.
- **Free list**: removed nodes are chained and reused.
- Capacity limits are errors, not panics: more than 2^29 bytes of names or 2^32-2 nodes -> `error.TableFull`.
- `applyRead` must be idempotent: calling it twice with the same input changes nothing the second time.

More rules of the implementation:

- Every fallible operation reserves all memory first and then mutates, so an allocation failure
  leaves the table unchanged.
- `addRoot` can return `error.InvalidPath` / `error.RootExists`; `applyRead` can return
  `error.NameTooLong` / `error.TableFull`. `pathOf` appends to `out`.
- Callers must pass canonical absolute paths (no trailing slash, no `//`). `child_names` must not
  point into the table's own name area.
- Production code removes folders only through `applyRead` on the parent (it drops every gone
  child in one pass). There is no public `remove`.
- **`stale` is not per node.** It is a condition of a whole generation, decided by the daemon.

## scan.zig / scan_darwin.zig / scan_linux.zig

Reads **one** folder, not recursive. Called from worker threads; touches no shared state.

```zig
/// `Transient`: EMFILE, ENFILE, ENOMEM (resource pressure). A new try may work.
pub const ReadError = error{ AccessDenied, NotFound, NotDir, Transient, Unexpected };

/// The one mapping from an errno to a `ReadError`, used by both readers.
pub fn mapErrno(e: anytype) ReadError;

pub const FolderRead = struct {
    own: u64 = 0,                       // sum of logical lengths of regular files (the sum wraps)
    names: std.ArrayList(u8) = .empty,  // child folder names, each followed by a 0 byte
    count: u32 = 0,                     // number of child folders in `names`
    wd: i32 = -1,                       // Linux with `ReadOptions.inotify_fd`: watch number of this folder
    watch_failed: bool = false,         // the watch could not be added (user limit); the folder was read
    entry_errors: u32 = 0,              // entries that could not be inspected (not counting vanished ones)
    pub fn reset(self: *FolderRead) void;                 // keep capacity
    pub fn deinit(self: *FolderRead, gpa: Allocator) void;
    pub fn iterator(self: *const FolderRead) NameIterator; // next() ?[]const u8
};

pub const ReadOptions = struct { inotify_fd: i32 = -1 };   // Linux: add a watch before the open

/// `out` is reset first and reused across calls, so a warm reader does not allocate.
pub fn readFolder(gpa: Allocator, dir_path: [:0]const u8, opts: ReadOptions, out: *FolderRead) (ReadError || Allocator.Error)!void;
```

Counting rules (DESIGN.md section 4):

- Regular file: add its logical length (data fork length, what `ls -l` shows). Hard links are not deduplicated.
- Directory: record its name **unless it is a mount point** (do not cross into other volumes).
  macOS: `ATTR_DIR_MOUNTSTATUS` with bit `DIR_MNTSTATUS_MNTPOINT`. `ATTR_CMN_DEVID` does not work for
  this (it returns the parent's device; measured, see docs/ZIG-NOTES.md section 5). Fallback path and
  Linux: compare the entry's `st_dev` with the folder's.
- Symlink (to anything), socket, fifo, device: ignore.
- Never follow a symlink, including `dir_path` itself as the final component (open with no-follow + directory flags).
- An entry that reports a per-entry error (not "gone meanwhile"), and a malformed record, add
  to `FolderRead.entry_errors`. The entry may be a folder, so the owner does not trust the child
  list: the scanner keeps the last known value and children and marks the folder `denied`
  (state `partial`). An entry that vanished during the read is not an error.
- Errors map as follows: EACCES and EPERM -> `AccessDenied`; ENOENT -> `NotFound`; ENOTDIR and
  ELOOP -> `NotDir`; EMFILE, ENFILE and ENOMEM -> `Transient`; others, EIO and EAGAIN too ->
  `Unexpected`. A folder that fails with an I/O error again and again must end as `denied`, not be
  retried for ever.
- macOS: `getattrlistbulk` with a buffer of at least 64 KiB, asking only for name, object type,
  mount status, per-entry error, and file data length. The reader does not use `FSOPT_PACK_INVAL_ATTRS`:
  a record holds only the fields that its returned set announces. If the volume returns ENOTSUP
  (`.OPNOTSUPP` in `std.c.E`), fall back to `readdir` + `fstatat(AT_SYMLINK_NOFOLLOW)`.
- Linux: `getdents64` + `statx`. With `ReadOptions.inotify_fd` the reader adds the inotify watch
  before it opens the folder. If the read then fails, it removes that watch again.

## ignore.zig

```zig
pub const Match = struct { excluded: bool, rule: ?u32 };   // rule = index of the deciding pattern

pub const Rules = struct {
    pub fn compile(gpa: Allocator, patterns: []const []const u8, bad: *?u32) !Rules; // error.BadPattern, bad.* = index
    pub fn deinit(self: *Rules, gpa: Allocator) void;

    /// One folder, given relative to its root with no leading or trailing slash ("prog/app/target").
    /// Does not look at ancestors: the scanner never descends into an excluded folder.
    pub fn match(self: *const Rules, rel_path: []const u8, ignore_case: bool) Match;

    /// For `check PATH`: tests each ancestor from the top, returns the first exclusion found.
    pub fn explain(self: *const Rules, rel_path: []const u8, ignore_case: bool) Match;
};
```

Semantics are exactly DESIGN.md section 13.3 (gitignore rules, applied to folders only): trailing `/` optional,
leading or inner `/` anchors to the root, `*` `?` `[...]` do not cross `/`, `**` as a whole segment
crosses any depth, `!` negates, last matching rule wins, `\` escapes. Blank patterns are errors.
No regex engine: a small iterative matcher, no recursion deeper than the pattern.

## config.zig

```zig
pub const Diag = struct { line: u32 = 0, message: []const u8 = "" };  // message lives in a thread-local buffer: use it before the next parse

pub const Config = struct {
    roots: []const []const u8,     // as written, `~` not yet expanded
    exclude: []const []const u8,
    metrics: bool = false,         // write the metrics log
    pub fn parse(gpa: Allocator, text: []const u8, diag: *Diag) !Config;   // error.BadConfig + diag
    pub fn deinit(self: *Config) void;                                     // one arena
};

pub fn defaultPath(gpa: Allocator, home: []const u8) ![]u8;   // <home>/.config/dirsized/config.toml
/// The one place where the exclude patterns are compiled. error.BadConfig + diag (with the line).
pub fn compileRules(gpa: Allocator, cfg: *const Config, diag: *Diag) !ignore.Rules;
/// Expands `~`, resolves to real absolute paths, drops the trailing slash, rejects nested or
/// duplicate roots and (macOS) the root "/". error.BadConfig + diag.
pub fn resolveRoots(gpa: Allocator, cfg: *const Config, home: []const u8, diag: *Diag) ![][]u8;
```

- Missing file, empty file, or a missing key -> defaults: `roots = ["~"]`, `exclude = []`,
  `metrics = false`.
- The parser accepts every valid TOML spelling of: comments, the three top-level keys, arrays of
  strings (basic `"..."` with all TOML escapes, literal `'...'`; multi-line arrays, trailing comma,
  comments inside arrays), and `true` / `false` for `metrics`. Anything else (other keys, tables, other value types, multi-line
  strings) is `error.BadConfig` with the line number and a message a person can act on.
- Parsing is pure (no file system); `resolveRoots` is the only part that touches the disk.

## scanner.zig

```zig
pub const Scanner = struct {
    pub fn init(gpa: Allocator, io: std.Io, threads: u32) !Scanner;   // io: 0.16 Mutex/Condition need it
    pub fn deinit(self: *Scanner) void;                    // joins workers

    /// Owner thread. Reads the whole subtree below `id` and applies results to `table`
    /// until nothing is pending. Skips folders excluded by `rules` (relative to their root).
    pub fn scanSubtree(self: *Scanner, table: *Table, rules: *const Rules, id: NodeId) !void;
};

pub fn defaultThreads() u32;   // CPU count, at least 1, at most 4
```

- **The table is the frontier.** Folders waiting to be read are the `pending` nodes; the owner keeps
  only a stack of their `NodeId`s (4 bytes each). A path is materialised (`pathOf`) only when a
  job is handed to a worker, and at most `2 x threads` jobs are in flight. Nothing proportional to the
  frontier is allocated besides that stack. A popped id whose node is no longer pending is skipped
  (it was removed or already read).
- Jobs carry the folder's **path**, not a node id. A result is applied with `table.lookup(path)`;
  if the node is gone, the result is dropped. This stays correct later, when the daemon removes
  nodes while reads are in flight.
- **Workers apply the exclude rules**: a worker drops excluded child names from its result before
  posting it (rules are immutable and the job knows where the root prefix ends). An excluded folder
  therefore never gets a node.
- Job/result objects (path buffer + `FolderRead`) are pooled and reused; a warm scan does not allocate per folder.
- Results reach the owner through a mutex-protected queue plus a condition variable. A worker
  also writes one byte to the wake pipe (`setWakeFd`) after it posts a result, so the daemon's
  `poll` loop wakes when there is something to apply.
- Each worker owns one `FolderRead` and reuses it. Job paths come from a per-scanner pool.
- `AccessDenied` and `Unexpected` -> `table.applyDenied`. A read with `entry_errors` or a result
  that the table cannot hold (`NameTooLong`, `TableFull`) -> `applyDenied` too, so the folder is
  `partial` and not read again in a loop. Every denied path goes through one helper. It calls
  the hook with the result of `applyDenied`, so a folder that turns from readable to denied counts
  as a change and one that was denied already does not. After a read that failed, the read is
  empty (`wd` is -1).
- `NotFound`/`NotDir` on a root -> denied (the root stays, unreadable). On any other folder
  the scanner marks the parent `recheck` and queues the parent once, not the folder itself. The
  parent's read drops the gone child. If the child is back, the read of the parent hands it out
  again because it is still `pending` (`applyRead` appends kept pending children to `new_children`).
- `Transient` -> the scan or pump returns `error.Transient`. The result is dropped and its
  folder goes back through `requeue` (`pending` stays, or `recheck` is set again), so the daemon
  reads it again after its retry delay.
- Default threads = CPU count, capped at 4 (measured: more threads only add kernel lock contention).

## main.zig / cli.zig

`pub fn main(init: std.process.Init) !u8` calls `cli.run(init) !u8`; the return value is the exit code.
`init` is the only source of the allocator, `io`, arguments and environment in Zig 0.16.

Command surface and exit codes are exactly DESIGN.md section 12. Without a daemon, and without
`--scan`, `dirsized [PATH]`, `-l` and `status` print
`dirsized: daemon is not running (use --scan to read the disk directly)` to stderr and exit 3.
`--scan` loads the config only for the exclude rules and treats each PATH as its own root.

- Output goes through one buffered writer, flushed once.
- Default line: `BYTES<TAB>STATE<TAB>PATH\n`. `-0` replaces `\n` with NUL. `-h` prints sizes like `ls -h`
  (1024-based, `K M G T`, one decimal below 10). `--json` prints one array of
  `{"path":..., "bytes":..., "state":...}`; path bytes that are not valid UTF-8 are escaped as `\u00XX`.
- `-l` sorts by size, largest first; ties by name. `-n N` cuts after sorting.
- Unknown flag or bad usage -> message on stderr, exit 2. `help` (a command word like `status`; no PATH) and `--help` print the same text.
  `--version` prints the version. Both exit 0. There is no `-?`.
- Paths are made absolute and real (`realpath`) before use.

## Daemon contracts

### Flags and states (table.zig)

```zig
pub const Flags = packed struct(u3) { pending: bool, denied: bool, recheck: bool };
pub const State = enum { ok, scanning, partial };     // `stale` is decided by the daemon
```

- `pending`: the content is unknown (new folder). Gives `scanning` to the node and all ancestors.
- `recheck`: a re-read is owed, but the value is believed current (event, verification, restart, or a `denied` folder at start).
  It has **no effect on the state** and no entry in the `below` map. So a busy disk does not make
  every answer `scanning`.
- `markRecheck(id) bool`: sets the bit, returns true if it was clear. No allocation.
- `needsRead(id) bool`: `pending or recheck`.
- **Lost-update rule.** The scanner clears `recheck` when it *dispatches* the read
  (`takeRecheck(id)`), not when it applies the result. `applyRead` / `applyDenied` clear only
  `pending` / `denied`. An event that arrives while a read is in flight sets `recheck` again and
  the folder is read once more.
- `lookupDeepest(abs_path) ?struct { id: NodeId, exact: bool }`: the deepest node on the path;
  null when no root contains the path.
- `shrinkToFit()`: gives unused capacity back (ids do not change).
- Snapshot support: `image()` borrows the raw arrays; `fromImage(...)` takes owned arrays and
  rebuilds the `below` map from the flags in one linear pass. A free node must be recognisable in
  that pass (`parent == free_mark`). No per-node work besides that pass: load must stay a few
  `read` calls.
- Linux only: `enableAux()` adds a parallel `u32` array (the inotify watch number, `none` = no
  watch). `setAux/getAux`. Freeing a node with an aux value appends `{id, aux}` to `freed`,
  which the owner drains after each apply. Without `enableAux` nothing is allocated.

### scanner.zig in the daemon

The daemon does not call `scanSubtree`. It drives the same pool from its poll loop:

```zig
pub fn setWakeFd(self: *Scanner, fd: std.c.fd_t) void;  // a worker writes 1 byte after it posts a result
pub fn enqueue(self: *Scanner, id: NodeId) !void;       // caller already set pending or recheck
pub fn pump(self: *Scanner, table: *Table, rules: *const Rules) Error!void;
        // apply every ready result, then dispatch. Never blocks.
pub fn isIdle(self: *const Scanner) bool;               // nothing on the stack, nothing in flight
pub fn discard(self: *Scanner) void;                    // block until in_flight == 0, drop results, clear the stack
pub fn setLowPriority(self: *Scanner, low: bool) void;  // workers switch their I/O policy before the next job
pub var case_by_root: []const bool                      // letter case of each root, same order as `table.roots()`; also set by the `--scan` path
pub var read_opts: scan.ReadOptions                     // copied into each job (Linux: the inotify fd)
pub var on_applied: ?Hook                               // owner side, see below
```

`Hook` is `struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, table: *Table, id: NodeId, read: *const scan.FolderRead, changed: bool) void }`.
The hook runs after every applied read of a folder: after a successful `applyRead` (`changed` is
its result), and after every denied result (`changed` is the result of `applyDenied`). So the
Linux watcher can bind the watch that the read added. After a read that failed with an error,
`read.wd` is -1 and the reader removed its watch: the watcher has nothing to bind.

`dispatch` reads a folder when `needsRead(id)` and calls `takeRecheck(id)` first.

### watch.zig, watch_darwin.zig, watch_linux.zig

The owner thread gets changes; it never sees FSEvents or inotify types.

```zig
pub const Change = union(enum) {
    path: struct { path: []const u8, subtree: bool },  // macOS: absolute folder path; subtree = re-read all below
    node: NodeId,                                      // Linux: the folder of that watch
    everything,                                        // queue overflow: re-read every root
};

pub const Watcher = struct {
    pub fn init(gpa: Allocator, wake_fd: std.c.fd_t) !Watcher;
    pub fn deinit(self: *Watcher) void;
    /// Start watching `roots`. `saved` is the blob of an earlier `saveState` or null.
    /// `.resumed`: every change since the blob will be delivered, then `caughtUp()` turns true.
    /// `.fresh`: only changes from now on; the caller must read every folder.
    pub fn start(self: *Watcher, roots: []const []const u8, saved: ?[]const u8) !enum { resumed, fresh };
    pub fn stop(self: *Watcher) void;
    pub fn pollFd(self: *const Watcher) std.c.fd_t;    // Linux: the inotify fd. macOS: -1 (it writes to wake_fd)
    pub fn drain(self: *Watcher, ctx: anytype) !void;  // macOS. Owner thread; calls ctx.onChange(Change) for each change
    pub fn caughtUp(self: *const Watcher) bool;
    pub fn checkpoint(self: *Watcher) void;            // owner: "all drained changes are in the table now"
    pub fn saveState(self: *const Watcher, out: *std.ArrayList(u8), gpa: Allocator) !void;  // state at the last checkpoint
};
```

Linux only (`watch_linux.zig`). `drain` has another signature there, and the watcher has more calls:

```zig
pub fn drain(self: *Watcher, table: *Table, ctx: anytype) !void;   // needs the table: clears aux on IN_IGNORED, skips freed nodes
pub fn readOptions(self: *const Watcher) scan.ReadOptions;         // for `Scanner.read_opts`: the inotify fd
pub fn bind(self: *Watcher, wd: i32, id: NodeId) BindError!void;   // binds wd to node; error.WatchGone if release removed that wd
pub fn onApplied(self: *Watcher, table: *Table, id: NodeId, read: *const scan.FolderRead) void;  // body of the scanner hook
pub fn release(self: *Watcher, table: *Table) void;                // drain `table.freed`, remove the watches of freed nodes
pub fn quiet(self: *Watcher) void;                                 // no result in flight: forget `dead` and `unbound` wds
saturated: bool,                                                    // the last `drain` filled its read buffer: more events wait
pub fn watchCount(self: *const Watcher) usize;                     // watches bound now
pub fn watchLimit() ?usize;                                        // fs.inotify.max_user_watches, null if unreadable
```

The daemon must call `release` right after every `Scanner.pump`, before anything else touches
the table. A freed node id can be reused, and `release` removes the map entries of freed nodes.
Then it calls `drain` again, because a result that was applied can owe a re-read.

- macOS: one plain stream per device (`FSEventStreamCreate`, absolute paths; the relative form
  takes one path only and lost events on a mounted image), folder-level events,
  latency 0.3 s, dispatch queue. The callback copies paths into a locked buffer and writes one
  byte to `wake_fd`. Blob = per device: UUID (`FSEventsCopyUUIDForDevice`) + last event id at the
  checkpoint. `start` returns `.fresh` when the blob is missing, a UUID differs, or a saved id is
  above the current event id (the ids wrapped). `checkpoint` takes the highest id that `drain`
  gave out. `checkpoint` never takes the
  current event id, because it can be ahead of what the stream delivered. On a quiet disk no id
  moves, and a restart replays more. It does
  nothing while a stream still replays history.
  Flags `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `RootChanged`, `Mount` and `Unmount` ->
  `subtree = true`. Flags `UserDropped`, `KernelDropped` and `EventIdsWrapped` also give
  `Change.everything`, because the path of such an event can lie above every root.
- Linux: one inotify fd. The **worker** adds the watch before it opens the folder
  (`scan.ReadOptions.inotify_fd`; result in `FolderRead.wd`, `-1` + `watch_failed` at the limit).
  The daemon's `on_applied` hook calls `Watcher.onApplied`. It stores `wd` with `table.setAux` and in
  the watcher's `wd -> node` hash map (`Watcher.bind(wd, id)`); a failed watch gives the node
  `denied` (state `partial`). An event for a wd that is not bound yet (the folder changed before
  the owner applied the read) is remembered. `bind` then forgets that wd and queues the node for one re-read.
  `IN_IGNORED` for a bound live node -> unbind and `Change.node` (the read adds the watch again).
  `IN_Q_OVERFLOW` -> `.everything`. Freed nodes: `inotify_rm_watch` only if the map still binds
  that wd to that node id. Blob is empty; `start` always returns `.fresh`.

### daemon.zig

One owner thread, one `poll()` loop over: listen socket, client sockets, the wake pipe, the
watcher fd. No other thread touches the table. The version string is `0.1.1` (`daemon.version`).
On Linux, after a drain that found events, the watcher fd stays out of the poll set for 100 ms.
The kernel then merges a write storm into one wakeup. There is no hold when that drain filled its
read buffer (`Watcher.saturated`): more events wait, and a hold could overflow the kernel queue.

- **Generation** = `{ table, rules, roots, ignore_case per root, config hash }`. `live` is the one
  the scanner and watcher maintain; `serving` answers queries. They differ only while a new
  config is being scanned; then `serving` is frozen and all its answers are `stale`. When `live`
  becomes idle, `serving` is freed and replaced. Before a switch: `scanner.discard()`, `watcher.stop()`.
- **Start**: lock file (`flock`, a second daemon exits 2) -> config -> snapshot (if its config
  hash matches) -> `watcher.start` **before any read** -> no snapshot: roots are `pending`;
  snapshot + `.fresh`: every node gets `recheck`; snapshot + `.resumed`: only the folders flagged at save time and each `denied` folder (`recheckDenied`: `markOne`, as for an event; if the read fails again, the folder stays `denied`). With a snapshot
  the generation is `stale` until `watcher.caughtUp()` and the scanner is idle.
- **Change handling**: drop if `rules.explain(rel)` excludes the path. `lookupDeepest`; set
  `recheck` on that node (for `subtree`: on every node below it). Newly flagged ids go to `dirty`.
  A `subtree` change whose path is above the roots (`/`, `/Users`) marks every root below it.
  `Change.everything` (queue overflow, `UserDropped`, `KernelDropped`, wrapped ids) marks every
  root: the daemon re-reads everything.
- **Debounce**: `dirty` is flushed to the scanner 1 s after its first entry (at once while
  `stale`). A folder flushed again within twice its interval doubles its interval (1 s -> 30 s
  max) and waits; the per-folder state lives in a small fixed direct-mapped array, so memory does
  not grow.
- **Slow folders**: after a read of a folder took T >= 50 ms (wall time of `readFolder`, measured by
  the worker, `Scanner.last_read_ns`), its next read from `dirty` starts no sooner than 20 x T
  (max 10 min) after the previous one ended. A fixed array of 64 entries (id, parent and name
  offset to detect a reused id, not-before time); when full the entry that expires first is
  replaced. It combines with the back-off by taking the later time. The initial scan and the
  verification never wait.
- **Quiescent** (dirty empty, scanner idle, watcher drained): `watcher.checkpoint()`; first time
  after a scan: `table.shrinkToFit()`.
- **Snapshot** (`paths.snapshot`, little endian: header with magic, version, XxHash3 checksum of
  everything after it, config hash = spec hash + each root's ignore_case, section lengths,
  free list, last verification and save time in unix seconds; then roots, watcher blob, and the
  raw `nodes`, `names`, `slots` arrays) every 5 min if a read changed the table (an event alone
  does not count; the daemon counts the reads whose `applyRead` returned true), once right after
  the first full scan, after each verification scan, and at SIGTERM, SIGINT and SIGHUP (on a stop
  always, once the first scan is complete, because the watcher checkpoint may have moved; before
  that, only if a read changed the table). A second signal ends the daemon at once. The load verifies size, checksum, version and config
  hash and then `fromImage`; any problem means a full scan. After a load every node with
  `pending` or `recheck` is queued again. **Verification**: every
  7 days (time kept in the snapshot) every node gets `recheck` and the workers run at low I/O priority.
- **Config**: a query only wakes the loop. The loop checks the file at most once per second: it
  compares a stamp (mtime, size, inode). A file that was changed less than 200 ms ago is not read
  yet (an editor may still write it). Bad file: keep everything, show the error in `status`. Good
  file with a new hash: build a new generation. While a config error is set, the loop reads the
  file again every second even if it did not change, so a root that appears later (a disk that
  mounts late) is picked up. The daemon sees an edit at the next wake-up of the loop, so the first
  query after an edit may still be answered from the old config.
- `status` shows the state `partial`, not `ok`, while a config error is set (also when the table says `ok`).
- Answer state: no root contains the path -> `none`; excluded -> `excluded`; node exists ->
  table state, `ok` shown as `stale` while the generation is stale; no node -> `scanning` if the
  deepest existing ancestor is scanning, else `none`.
- Logs go to stderr, one line per event worth a line. Nothing per query, nothing per change.
- **Metrics** (only with `metrics = true`): `handle` times each request, `onApplied` reports each
  folder read, the loop reports each turn, and the loop arms one more timer (`Metrics.sample_at`,
  every 60 s). The key is not in the spec hash: a change opens or closes the log and starts no scan.
  A config that parses but has a bad root or pattern still sets the metrics (`Bad.metrics`); one that
  does not parse keeps them as they were. A new generation that cannot be built leaves them alone too. When the metrics go off and when the daemon stops, the
  open window is written first.

### metrics.zig

The optional metrics log (DESIGN.md section 13.6). It knows nothing of the table or the server:
the daemon calls it and passes a `Gauges` value for each sample.

```zig
pub const interval_ns = 60 s;
pub const Hist;    // durations in power-of-two buckets: add(ns), quantile(permille), exact max
pub const Top;     // the 3 slowest of a window with their paths: takes(ns), put(ns, verb, bytes, path)
pub const Gauges;  // what the daemon knows at a sample: state, folders, rss, queued, clients, events ...

pub const Metrics = struct {
    sample_at: i64,                                    // the loop must wake up then while `on()`
    pub fn setPath(m, path) error{NameTooLong}!void;   // `paths.metrics`
    pub fn on(m) bool;
    pub fn enable(m, now, version, events) bool;       // opens the file (append, 0600), writes `start`
    pub fn disable(m) void;                            // writes `stop`, closes
    pub fn request(m, verb, path, ns, bytes) void;
    pub fn read(m, ns) bool;                           // true: one of the slowest, call `slowRead`
    pub fn slowRead(m, ns, path) void;
    pub fn loopTurn(m, ns) void;
    pub fn sample(m, now, gauges) void;                // one `sample` line, then the slowest lines; new window
};
```

- Fixed size, no allocation. Each line is built in a stack buffer and written with one `write`.
- Off (`fd == -1`): every function is safe to call and writes nothing. The daemon tests `on()`
  first only to save the clock reads.
- Processor time and `rss_max` come from `getrusage(RUSAGE_SELF)` (`ru_maxrss` is bytes on macOS,
  kilobytes on Linux).
- At 4 MiB (checked against the real file size) the file is renamed to `metrics.log.1` and a new
  one is opened; if either step fails, the open file is emptied and used again. A write that fails
  (full disk) loses that line only.

### server.zig, proto.zig, paths.zig

`paths.zig`: socket, lock and snapshot paths (DESIGN.md sections 10, 11; Linux without
`XDG_RUNTIME_DIR` uses the cache folder). The config path is `config.defaultPath`. The daemon has
no log file: it writes to stderr, and the launchd plist sends stderr to `~/.cache/dirsized/log`. The metrics log
(`paths.metrics`, `<cache>/metrics.log`) is a different file and exists only with `metrics = true`. `proto.zig` is pure (no I/O), used by server and client;
it also has `writeJsonString`, which the command line and the metrics log share.

```
request :  size SP PATH NUL  |  list SP PATH NUL  |  status NUL
size    :  BYTES TAB STATE TAB PATH NUL  NUL
list    :  BYTES TAB STATE TAB . NUL  { BYTES TAB STATE TAB NAME NUL }  NUL     (unsorted; only the "." record if the folder has no node)
status  :  { KEY TAB VALUE NUL }  NUL
error   :  ! TAB CODE TAB MESSAGE NUL NUL        CODE = bad-request | too-long
```

- PATH is absolute; one trailing `/` is ignored. The server does not resolve symlinks.
- status keys, in this order: `proto` (1), `version`, `pid`, `state` (ok | scanning | stale |
  partial), `folders`, `memory` (bytes of the table), `rss` (resident memory of the daemon process, bytes),
  `queued`, `slow` (dirty folders held back by the slow-folder rule), `events`, `snapshot_age`,
  `verify_age` (seconds, `-` if never), `root` (one per root), then optional: `watches`,
  `watch_limit` (Linux), `watch_error` (error name; the watcher could not start and is retried every 60 s),
  `config_error`, `denied` (one per unreadable folder, at most 100).
- Requests can be pipelined; answers come in the same order. A request longer than
  PATH_MAX + 16 gets `too-long` and the connection is closed. Sockets are non-blocking; a client
  that does not read gets its output buffered up to 16 MiB (checked after each request), then it is closed.
  When a write would block, the server compacts the output buffer: it drops the bytes that are
  already written, if they are 64 KiB or more or more than the bytes still pending. So a client
  that reads slowly does not make the buffer grow.
  The client helper interleaves sending and reading (`poll`), so any number of PATHs works. The
  listen backlog is 128. When all 32 slots are busy, a new connection evicts the client that has
  been silent longest, whatever its state. With free slots no client is ever closed for idleness.
  When `accept` fails with EMFILE/ENFILE the listen socket is left out of the poll set for 1 s.
  The client `connect` retries ECONNREFUSED 3 times, 2 ms apart, before it reports "no daemon"
  (a busy daemon with a full backlog refuses too).
- The socket folder is 0700. The peer uid must equal ours (`getpeereid` / `SO_PEERCRED`).

### cli.zig with a daemon

`dirsized [PATH..]`, `-l`, `status` connect to the socket. No daemon: exit 3, or with `--scan`
read the disk as before. `status` prints `key: value` lines (`--json`: one object; repeated keys
become arrays). `dirsized daemon` runs `daemon.run` in the foreground.

## Testing

- `zig build test` runs all unit tests. `test/e2e.sh` runs the end-to-end checks of DESIGN.md
  section 16. `test/linux-unit.sh` runs the Linux-only unit tests in a container.
  `make test-emacs` runs the Emacs tests.
- Reference value for sizes in any test: sum of lengths of regular files found by walking the
  tree without following symlinks and without crossing devices. Never `du` default output.
