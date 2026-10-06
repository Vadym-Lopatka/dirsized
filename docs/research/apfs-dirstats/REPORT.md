# Step 0: APFS directory statistics on macOS 27.0.1

Labels: MEASURED (run on this machine), HEADERS (from SDK files), GUESS.
All write tests ran inside a scratch APFS disk image. No real folder was flagged.

## Answer

**Yes.** On macOS 27.0.1 the kernel returns the recursive size of a folder in constant time,
about 7 us per call, for 112 descendants and for 204,200 alike. A normal user process can do it,
with no root and no entitlement. It is a private, undocumented `fsctl` and is in no SDK header.
The folder must be flagged first. The published claim "only when flagged while empty" is FALSE here:
flagging an already populated folder works, and the kernel builds the initial totals itself.

Both codes were decoded from system machine code (MEASURED):

- `APFSIOC_MAINTAIN_DIR_STATS` = `0x80084a02`, `_IOW('J',2,u64)`. It sets the flag.
- `APFSIOC_DIR_STATS_OP` = `0xc1104a71`, `_IOWR('J',113,272 bytes)`.
  Request `{u32 version=3; u32 op=0 (GET); u32 flags=1}`.

On `fsctl(path, 0xc1104a71, buf, 0)` the 272-byte buffer reads as u64 slots:
slot 3 = folder inode, slot 6 = generation counter, slot 7 = descendants, slot 8 = allocated bytes.
Slot meanings are GUESSED from a log-string order; slots 7 and 8 are proven against ground truth.

What the value is (MEASURED):

- Allocated bytes, byte-identical to `du -sk` x 1024. It is not the logical size.
- It includes subfolders at any depth, including ones created later.
- Each folder counts as a descendant but adds 0 bytes. The flagged folder itself is not counted.
- Hard links are counted once. Clones are counted in full, like `du`.
- Sparse files and symlinks add 0 bytes.
- Totals persist across unmount and remount.

## Key numbers (MEASURED: 100-file tree vs 200,000-file tree in 4,200 folders)

| Method | Small (112 descendants) | Large (204,200 descendants) |
|---|---|---|
| fsctl GET | 7.1 us | 7.05 us |
| `dirstat_np` | 0.29 ms | 266-276 ms warm, 1449 ms cold |
| `du -sk` | 0.00 s | 2.55 s warm |
| `find` + `stat` | - | 0.57 s |

- First GET after a remount: 0.7-3.2 ms. After that 7-22 us.
- Flagging a populated large tree: 5.2 s, one time (kernel walk).
- Creating 100,000 files in a flagged folder: 32.5 s vs 31.2 s unflagged (one run each, about 4 %, maybe noise).
- Large tree ground truth: logical 300,117,000 B, allocated 819,200,000 B.
  GET and the `dirstat_np` walk both returned 819,200,000 and 204,200 descendants.

## Surprises and limits

- `dirstat_np` exists in libsystem_darwin but not in the SDK. It is a user-space walk
  (`getattrlistbulk` plus a file-id hash set for hard-link dedupe) with no fast path.
  Flags with bit 0 always return ENOTSUP (45), even on a flagged folder. Its struct and signature are GUESSED.
- `dirstat_np` counts a hard-link name in descendants; GET counts it once. Bytes are equal.
- The flag is per folder:
  - A new subfolder is not flagged (GET returns ENOTSUP), but its contents are counted in the flagged parent.
  - Flagging a nested child works and each folder keeps its own totals.
  - `cp -R` of a flagged folder gives an unflagged copy. A rename keeps the flag.
- No real folder is flagged. Checked: `~`, `~/prog`, `~/Library`, `~/Library/Caches`, `~/Downloads`,
  `~/Documents`, `~/Desktop`, `/Applications`, `/`, `/System/Volumes/Data`, `/Users`, `/Library`,
  `/usr/local`, `/opt/homebrew`, `~/.emacs.d`, and the depth-1 children of `~` and `~/Library`.
  All returned ENOTSUP. Finder does not use it.
- The private `+[SASupport enableDirStatsForPath:...]` (SpaceAttribution.framework) only sends op SET
  (`flags=0x1c`) and fails with ENOTSUP. The real enabler is `0x80084a02`. The name is a GUESS by
  elimination: it is the only other 'J' code in ContainerManagerCommon, which logs
  "Enabled APFSIOC_MAINTAIN_DIR_STATS", and calling it made GET start working.
- The MAINTAIN value argument is ignored (`val=0` also enables). **No off switch was found.**
- Other attributes and tools return nothing useful (MEASURED):
  `ATTR_DIR_ALLOCSIZE` = 0, `ATTR_DIR_IOBLOCKSIZE` = 0, `ATTR_DIR_DATALENGTH` = 4096 (not recursive),
  `ATTR_DIR_ENTRYCOUNT` = direct children only, private `ATTR_CMNEXT` size attributes = 0,
  `stat` gives the entry size with `st_blocks` = 0, `mdls kMDItemFSSize` = child count,
  no `diskutil apfs` verb reads directory stats, Finder via `osascript` returned `missing value`.

## Not determined

- Whether MAINTAIN needs folder ownership or write access.
- Whether it works on the real Data volume, a FileVault volume, external or network volumes.
  Only an unencrypted disk-image volume was tested.
- How to clear the flag.
- What op SET is for. The meaning of slots 4, 5 and 9-11.
- Compressed (decmpfs) files, packages and bundles, mount points, firmlinks, snapshots below a flagged folder.
- Behaviour after a crash. `fsck_apfs` has repair code for stale dir stats, so drift is possible (GUESS).
- Write cost when many nested folders are flagged.
- Cold-cache timing for `du` and the walk (no `purge` without sudo).

## Evidence (raw output, MEASURED)

`dlprobe`: `dirstat_np FOUND, fsctl FOUND, ffsctl FOUND, getattrlistbulk FOUND, apfs_dirstat absent`.
`grep -rn dirstat $SDK/usr/include` returns nothing. `attr.h` lines 525-537 and 559-572 list the
ATTR_DIR_* and ATTR_CMNEXT_* names (HEADERS).

Where the codes come from:

- Interposing `fsctl` while calling `+[SASupport getDirStatInfo...]` logged
  `fsctl(.., 0xc1104a71 [dir=6 grp='J' nr=113 len=272], opts=1) -> -1 errno=45`.
- `scan2` decodes MOVZ/MOVK pairs. ContainerManagerCommon contains only `0xc1104a71` and `0x80084a02`.
- Strings in the dyld shared cache: `APFSIOC_DIR_STATS_OP`, `APFSIOC_MAINTAIN_DIR_STATS`, and
  "Getting dir stats version:%d flags:0x%llx dir_stats_id:%llu gen_count:%llu descendants:%llu
  physical_size:%llu clone_size:%llu purgeable_size:%llu purgeable_urgency:%d".

Flagging empty and populated folders (`dsop`):

```
get e3                     -> errno=45
maintain e3 1              -> ok
get e3                     -> ok  u64: 3 0 0 204332 204333 0 1 0 0 0 0 0
maintain small (populated) -> u64: 3 0 0 16 204353 0 1 112 409600 0 0 0
maintain large (populated) -> u64: 3 0 0 129 204354 0 1 204200 819200000 0 0 0
time dsop maintain pre/x (fresh 200k tree) -> 5.214 s total
```

Constant time (2000 GETs each): small 7.11 us/call, large 7.05 us/call, e3 7.08 us/call.

Semantics (flagged folder `sem`, physical bytes after each step):

```
10 MB random file        desc=1  10002432
cp -c clone              desc=2  20004864
cp copy                  desc=3  30007296
hardlink                 desc=3  30007296
symlink                  desc=4  30007296
1 GB sparse              desc=5  30007296
5 MB ditto copy          desc=6  35008512   (du -sk 34188 KB = 35,008,512 B)
d1 +3 MB                 desc=8  38010880
mv d1 out                desc=6  35008512
mv d1 in                 desc=8
mv 2 MB folder in        desc=10 40013824
rename d2 within         unchanged
```

Staleness (`stale.py`, GET right after each step):

```
created, 0 bytes            gen=2  desc=1 phys=0
50 MB written, fd open      gen=5  phys=50003968   (no fsync needed)
ftruncate to 10 MB          gen=6  phys=10002432
unlinked                    gen=9  desc=0 phys=0
unlinked while still open   desc=0 phys=0
```

Persistence: after detach and re-attach, the same numbers and generation counters came back.

## Probe sources

`gen.c`, `probe.c`, `ds.c`, `dlprobe.c`, `dsop.c`, `trace.c`, `sa.m`, `cls.m`, `findsa.m`,
`findstr.c`, `scan2.c`, `exp1.sh`, `exp2.sh`, `stale.py`. Build with `./build.sh`.
`dsop maintain` and `dsop set` are for scratch paths only.

## Independent re-check (independent run, fresh 1 GB scratch image)

```
get t (populated, unflagged)   -> errno=45
maintain t                     -> ok
bench 2000 GETs on t           -> 6.41 us/call, descendants=304 physical=5459968
du -sk t                       -> 5332 KB = 5459968 B        (exact match)
write 2 MB to t/new/open, fd still open, GET at once
                               -> gen=493 descendants=306 physical=5459968   (bytes NOT yet counted)
du after the fd closed         -> 7462912 B
get t/new (new subfolder)      -> errno=45
get /Users/me/prog (read only) -> errno=45
```

Confirmed: flagging a populated folder works, GET is constant time and equals `du`,
a new subfolder is not flagged, and no real folder is flagged.

**One result differs from the first run:** in this run 2 MB written through an open descriptor
was not in the total when GET ran right after the write. The first run (`stale.py`) saw 50 MB at once.
So the value can lag for data that the kernel did not yet allocate. How long is not measured.
Do not claim "never stale".
