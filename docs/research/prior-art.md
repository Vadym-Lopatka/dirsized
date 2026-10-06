# dirsized prior-art search

Date of search: 2026-10-05. Method notes: "opened" means I fetched the page or read the file (WebFetch or `gh api`). WebFetch returns a model summary, so quotes are as returned. Items marked **(snippet)** come only from a web-search result summary, and I did not open the page. Items marked **UNVERIFIED** are from memory or unconfirmed.

## 1. Direct answer

No tool found does exactly what dirsized plans: a small cross-platform user daemon, folder-only records, FSEvents + inotify, answers over a Unix socket in under a millisecond. But the idea is not new, and several tools are close.

- **macOS:** WhatSize (commercial GUI, since 2015) merges FSEvents into cached measurements live; `diskr` (TUI, 2026) persists sizes and replays FSEvents on relaunch. Neither is a daemon with a query API.
- **Linux:** nothing close. FSearch and gosearch are per-file name indexes with live watchers, with no folder totals found.
- **Cross-platform:** `jlevy/fdu` (Rust, Aug 2026) has `--watch`, a long-lived index and Rust/Python APIs, but it is per-process and per-file. `mwo-dk/coxswain` (Sept 2026) has a shared index helper daemon that sums folder sizes, but it is a file manager, and the helper speaks a private loopback-TCP protocol. Everything 1.5 (Windows only) is the exact idea on NTFS, and CephFS/Qumulo/Lustre-Robinhood do it at the filesystem level.

So: the niche (small folder-only daemon with a stable socket and CLI, for editors and agents) looks open, but two or three fresh projects are converging on it, so check fdu and coxswain again before building.

## 2. Candidates

Columns: how sizes are obtained / stays current without rescans / queryable by other programs / gap vs dirsized.

### 2a. Closest (live or incremental, macOS and/or Linux)

| Name | URL | Platform | Maintained? | How sizes obtained | Current w/o rescans? | Queryable by others? | Gap vs dirsized |
|---|---|---|---|---|---|---|---|
| fdu | https://github.com/jlevy/fdu | macOS, Linux, Windows | Created 2026-08-08; v0.3.0 2026-09-30 | Parallel walk (`getattrlistbulk` / `getdents64`+`statx`), per-file index | Yes: `--watch` (FSEvents/inotify). Design doc says the macOS watcher re-walks the whole root on every rename, ~48% of a core on a 476k-entry root | Rust + Python APIs, JSONL change stream, long-lived `OpenedIndex`. README has no daemon or socket (grep found none) | Per-process, per-root, per-file records (~190 B/entry), not a shared daemon. Closest design neighbour; its research docs are the best source of lessons (section 3) |
| WhatSize (macOS) | https://www.whatsizemac.com/release-notes/ | macOS | Yes: 8.2.9, 2026-08-31 | Measurement scan, cached | v6.1.5 (2015-01-05) "Initial support for Apple's FSEvents. This allows WhatSize to be synchronized with file system changes in real time" | No CLI/AppleScript/helper mentioned in release notes | GUI app, commercial, no query API, no Linux |
| diskr | https://github.com/milobeans/diskr | macOS | Pushed 2026-08-07; 1 star | `getattrlistbulk`, lazy per-directory | On relaunch, "replays macOS FSEvents since the previous session to revalidate only the directories that actually changed" (README). Not resident | TUI only | Not a daemon; replay on launch only; macOS only |
| petal | https://github.com/hohaivu/petal/pull/3 | macOS | Created 2026-10-02 | Scan tree plus FSEvents event ID cached per root | Incremental rescan via history replay; falls back to full scan on hard links, `MustScanSubDirs`, dropped events, ID wrap, mount change | GUI app | Replay-on-rescan, not resident; GUI; falls back to full scan on `/` because of hard links (PR text) |
| Coxswain | https://github.com/mwo-dk/coxswain | macOS, Linux, Windows | Created 2026-09-29; pushed 2026-10-05 (very new) | Index helper holds a per-file index; folder size is "a sum it has at hand" ([folder-sizes.md](https://github.com/mwo-dk/coxswain/blob/main/docs/panels/folder-sizes.md)) | Helper has its own watcher (inotify/FSEvents) plus a full rebuild every hour ([names.md](https://github.com/mwo-dk/coxswain/blob/main/docs/search/names.md)); folder-sizes.md says "its walk every ten minutes" (the two docs disagree) | Helper is a launchd/systemd user agent; apps talk to it over loopback TCP with a token file ([helper.md](https://github.com/mwo-dk/coxswain/blob/main/docs/search/helper.md)). It is internal, not a documented CLI/API | Closest to the daemon shape. File manager first; per-file index; private protocol; sums only inside "folders search reads" |
| Everything 1.5 | https://www.voidtools.com/support/everything/options/ | Windows only | Yes (voidtools) | NTFS index + USN journal | Yes: "Size information is maintained in real time." "Requires an additional 8 bytes of memory per folder." Excluded files not counted | Everything Server / SDK / ES CLI (**UNVERIFIED** details). Forum says a Linux/Unix server could exist if the protocol were opened ([thread](https://www.voidtools.com/forum/viewtopic.php?t=12868), snippet only) | Windows only; the same idea. Void says maintaining folder sizes "can be expensive in Everything 1.4" ([forum](https://www.voidtools.com/forum/viewtopic.php?t=7594)) |
| Robinhood Policy Engine | https://github.com/cea-hpc/robinhood | Linux (Lustre best; any POSIX via scan) | Pushed 2026-09-04 | MySQL DB of file metadata; `rbh-du` queries the DB | Lustre: reads MDT changelogs. Others: scans | `rbh-du`, `rbh-report` CLI over MySQL | HPC, needs MySQL; no inotify path; per-file DB |
| Qumulo | https://www.theregister.com/2017/12/08/qumulo_and_the_tree_walking_problem/ | Appliance | Commercial | Real-time aggregates inside the filesystem | Yes (article says "real-time aggregates"; mechanism not disclosed there) | REST API ([qumulo.github.io](https://qumulo.github.io/), snippet) | Storage appliance |
| CephFS rstats | https://ceph.io/geen-categorie/recursive-accounting-for-size-ctime-etc/ | Linux (CephFS) | Yes | MDS keeps recursive bytes/files/ctime per directory | Yes, eventually: "There may be some delay before the recursive stats propagate up the hierarchy... pushed up at least once every minute or something" | xattr `ceph.dir.rbytes` | Only CephFS. Known; delay quote is useful |

### 2b. Index with live watcher, but no folder totals found

| Name | URL | Platform | Maintained? | How | Current? | Queryable? | Gap |
|---|---|---|---|---|---|---|---|
| Cardinal | https://github.com/cardisoft/cardinal | macOS 12+ | v0.1.23 2026-03-24; pushed 2026-07-23; MIT | Per-file name index, Rust | FSEvents (README does not say; changelog mentions ignored paths) | GUI; no CLI/API in README | I grepped the repo source and docs: only a `size:` file filter. CHANGELOG line 52 mentions "folder size ranking" but I found no recursive-size code. Treat as no folder totals |
| EverythingMac (alesloa) | https://github.com/alesloa/everything-mac | macOS | Pushed 2026-06-24 | Name index | "An FSEvents watcher folds new, renamed, and deleted files back into the index so it never needs a full rescan" | No CLI/API mentioned | No folder sizes documented |
| MacEverything, seedds/EverythingMac | https://github.com/hoanglong149/MacEverything , https://github.com/seedds/EverythingMac | macOS | 2026-09 | Name search (seedds = Cardinal engine fork) | FSEvents (snippet) | n/a | Search only (not opened beyond repo metadata) |
| gosearch | https://github.com/ozeidan/gosearch/ | Linux 5.1+ | 53 commits; date not seen | Name index in `gosearchServer` | fanotify, real time | Client talks to server (systemd) | Names only; README silent on directory sizes. Shows the client/server shape on Linux |
| FSearch | https://github.com/cboxdoerfer/fsearch | Linux | Pushed 2026-10-04 | Name index | inotify/fanotify per a search snippet; the README I opened says nothing about it | GUI; README points CLI users to find/fzf/locate | Names only |
| Baloo / LocalSearch | https://wiki.archlinux.org/title/Baloo (snippet) | Linux | Yes | Content/name index | inotify; hits `max_user_watches` | CLI/D-Bus | No recursive folder size seen. Use: confirms the inotify-limit pain ([KDE forum](https://forum.kde.org/viewtopic.php%3Ff=154&t=166176.html), snippet) |

### 2c. File managers and UIs (on-demand or cached sizes)

| Name | URL | Platform | How | Current w/o rescans? | Queryable? | Gap |
|---|---|---|---|---|---|---|
| show-folder-size-nautilus | https://github.com/doggylover314/show-folder-size-nautilus | Linux | `Gio measure_disk_usage`, disk cache keyed by path+mtime | Partial: GFileMonitor on visible folders (limits: 256 watched, 512 deep, 1M cache entries); changes mark ancestors outdated, re-measure at most 1/s | "no external API" (opened) | Nautilus only; watches only what is on screen |
| yazi | https://github.com/sxyazi/yazi/issues/544 | macOS, Linux | Computes dir size lazily when sorting by size | No. Stale until restart (issue open, labels enhancement/waiting) | No | Per-process cache; stale |
| broot | https://github.com/Canop/broot | macOS, Linux | Sizes computed in background; cached | Cache invalidated by its own ops/F5 ([HN](https://news.ycombinator.com/item?id=21998638), snippet) | No | In-process |
| dired-du | https://github.com/emacsmirror/dired-du | Emacs | Calls `du` (or Lisp) on demand | No. Docs warn it "might be very slow" for whole buffers | No | The client we want to speed up. Shows demand is real |
| dirvish | https://github.com/alexluigit/dirvish | Emacs | File-size attribute (files / counts) | n/a | n/a | No recursive size; snippet says no precomputed daemon |
| eza `--total-size` | https://github.com/eza-community/eza | unix | Walk on every call | No | CLI | Full walk each time |
| Finder "Calculate all sizes" | https://eclecticlight.co/2019/02/06/how-big-is-that-folder-what-happened-to-apfs-fast-directory-sizing/ | macOS | Finder computes; "if the Finder happens to have it cached... blazingly quick, if probably inaccurate; if it has to calculate it afresh, then you're in for a long wait" | Cache with unknown invalidation | No | Not exposed |
| Dolphin, Nemo, Thunar, Double Commander, Marta, ForkLift, Path Finder | (search results only) | | On-demand per folder; Dolphin has a "folder size" depth setting ([KDE discuss](https://discuss.kde.org/t/dolphin-consistent-folder-sizes-between-filesystems/49431), snippet) | No | No | I found no page showing any of them keeps a background live index. ForkLift/Path Finder/Marta internals **UNVERIFIED** |

### 2d. Scan-based disk tools (no live mode found)

| Name | URL | Notes |
|---|---|---|
| duc | https://github.com/zevv/duc | On-disk index; issue [#205](https://github.com/zevv/duc/issues/205) (2018, open) proposes incremental reread of directories with changed timestamps; no event watching |
| gdu | https://github.com/dundee/gdu | `--db` SQLite/Badger persistent store, `-r` read saved analysis (README). Issue [#142](https://github.com/dundee/gdu/issues/142): maintainer says fsnotify "can be used for this, although the recursive watch on Linux will be probably quite costly for larger directories" |
| dust | https://github.com/bootandy/dust | Issue [#205](https://github.com/bootandy/dust/issues/205) asked for filesystem monitoring so updates are incremental; maintainer replied "Nope" |
| ncdu, dua, diskus, pdu | https://github.com/Byron/dua-cli , https://github.com/sharkdp/diskus , https://github.com/KSXGitHub/parallel-disk-usage | Fast scans. Searched their issues for watch/inotify/daemon: no live-mode feature found |
| idu | https://github.com/cloudengio/idu | "incremental, database backed, du": database + incremental rescans, no events. Last push 2025-01-15 |
| QDirStat | https://github.com/shundhammer/qdirstat | `.qdirstat.cache.gz` files written by cron; no watcher (snippet) |
| WizTree | https://diskanalyzer.com/whats-new | MFT scan; snippet says folder sizes update live when files are deleted in the app; no background index |
| DaisyDisk, GrandPerspective, OmniDiskSweeper, TreeSize, FolderSizes, Space Lens | (search results) | Manual scans. Search summary: DaisyDisk has no background activity. CleanMyMac Space Lens "menu helper" claim is unclear (snippet); **UNVERIFIED** |
| Prometheus dirsize exporter | https://github.com/2i2c-org/prometheus-dirsize-exporter | Periodic walk with an IOPS budget, e.g. every 60 min; "information about a directory may not be exactly correct" |
| node_exporter textfile `directory-size.sh`, Netdata filecheck | https://github.com/prometheus-community/node-exporter-textfile-collector-scripts/blob/master/directory-size.sh | `du -sb` on a timer (snippet) |
| Diskover | https://github.com/diskoverdata/diskover-community | Crawler into Elasticsearch; re-crawls (no events found) |
| Starfish | https://starfishstorage.com/ | Postgres index; "repeatedly scans the file system and compares the results to the previous state"; directory aggregates (snippet) |
| Sweep, space-scout, brewprune, disktracker | various | Cleaners and trackers; no live folder-size service found (Sweep README opened: daemon reclaims space on schedule or low disk, not a size server) |
| trashd issue #68 | https://github.com/faratech/trashd/issues/68 | Irrelevant app; cited only as an example of directory-size cache rebuilds re-walking unchanged trees (24,006 `statx` calls) |

### 2e. Filesystem and kernel features (already known, verified where cheap)

| Feature | URL | Verdict |
|---|---|---|
| APFS fast directory sizing | https://eclecticlight.co/2019/02/06/how-big-is-that-folder-what-happened-to-apfs-fast-directory-sizing/ ; https://mjtsai.com/blog/2025/01/13/what-happened-to-apfs-fast-directory-sizing/ | Exists (`INODE_MAINTAIN_DIR_STATS`, `total_size`). Must be set on a directory (per the guide, empty); no public high-level API; Jim Luther: promised feature "never really hooked up". The fdu research found it can be set on populated trees without privilege (see section 3) |
| XFS/ext4 project quotas, ZFS, btrfs qgroups | https://github.com/jlevy/fdu/blob/main/docs/project/research/research-2026-09-27-disk-growth-change-sources.md | fdu's survey calls Linux XFS/ext4 project quotas "the only true as-it-happens per-tree accounting found", but they need root |
| bcachefs | https://bcachefs.org/bcachefs-principles-of-operation.pdf (snippet) | Project quotas usable as subdirectory quotas; no recursive folder-size feature seen |
| Dell OneFS | https://www.dell.com/support/kbdoc/en-kw/000009755/how-to-accurately-determine-space-usage-of-individual-shares-or-quotas-on-isilon (snippet) | Directory (accounting) quotas give near-real-time sizes after an initial scan |
| Spotlight / mdls | fdu research, "Spotlight Is Not a Source" | Not usable: new files unqueryable after 7 min in their test; hidden dirs excluded; per-file only |
| Watchman | https://facebook.github.io/watchman/docs/cmd/query | Only per-file `size`; no directory aggregates (opened) |
| fd, plocate | not checked | Per-file name search; no folder totals. **UNVERIFIED** here |

## 3. Lessons to steal

1. **FSEvents misses writes to files held open until last close.** Content events fire at last close of the file description (or last unmap); `fsync` changes nothing. On a live agent-state root, 11 of 26 growing files were held open and carried 99.8% of in-place growth bytes; 56% of gross growth over an hour was in held-open files. Logs and SQLite WAL files are exactly this. Source: fdu research [Answer in Brief and Resident Monitoring](https://github.com/jlevy/fdu/blob/main/docs/project/research/research-2026-09-27-disk-growth-change-sources.md). Their fix: re-`stat` same-user open-for-write files via libproc (about 15 ms, 45 ms median under load, 7.3 s worst), and keep a periodic reconcile. Our DESIGN.md already has a verification scan; make sure it also covers this case, and decide whether to add a periodic open-writer re-stat. This is the top risk to the "numbers stay correct" claim on macOS.
2. **Do not escalate renames to whole-root rescans.** The `notify` crate's FSEvents backend reports unpaired `ItemRenamed`; fdu escalated each one to a full-root reconcile: 172 reconciles/hour, 48% of a core, 6.9 GB/hour of snapshot rewrites on a 476k-entry root. 61.5% of raw events carried `ItemRenamed` (atomic temp-file writes). Same source. Treat renames per path and re-stat only the affected parent directories.
3. **Treat events as hints; verify with `stat`.** Same source says tools that stay correct (restic, Borg, Kopia) compare `stat` facts on every run, and every FSEvents consumer (Watchman, git fsmonitor, CCC, SuperDuper, Time Machine) keeps a full-scan fallback. Jujutsu issues show silent staleness bugs: empty answers read as "clean" ([#10097](https://github.com/jj-vcs/jj/pull/10097)), ~90 files hidden for nine hours ([#10130](https://github.com/jj-vcs/jj/pull/10130)). Supports the "verification scan" design.
4. **FSEvents rules to follow.** Apple's guide: coalesced events set `kFSEventStreamEventFlagMustScanSubDirs`, "you must recursively rescan the path"; kernel/user dropped events also set it and require a full scan; event IDs persist across reboots and `sinceWhen` replays history ([FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)). The guide says FSEvents reports directories and you rescan them. (UNVERIFIED from memory: newer macOS also has a per-file-events flag; check before relying on either model.) Petal's fallback list (hard links on changed path, MustScanSubDirs, dropped events, ID wrap, mount change, history/UUID reset, Full Disk Access change) is a ready checklist ([PR](https://github.com/hohaivu/petal/pull/3)).
5. **Replay cost is a property of the volume's journal, not your root.** About 0.12 s per compressed MB of journal behind the cursor plus ~10 µs per matching record. A day took 45 s on a churning scratch volume and 1.8 s on a quiet internal volume. "Receiving the expected event quickly says nothing about when the replay completes." Source: fdu research. Budget a time limit on restart replay and fall back to a scan (our section 10/Restart design).
6. **Memory per entry.** fdu's per-file index costs about 190 B/entry (1.3 GB for 6.7M entries); Everything keeps folder sizes at 8 bytes per folder (1M folders = 8 MB, [forum](https://www.voidtools.com/forum/viewtopic.php?t=7594)). Supports the folder-only design. fdu's own conclusion for home scale is "a dirty-directory recorder should replace the full resident index" (same research doc). Same direction as dirsized.
7. **Resident cost benchmark.** fdu `--watch` on 476k entries: median 442 MB RSS, peak 906 MB; 326 raw events/min average, bursts to 1,443; startup to first report 60 s cold. About 1% of a core in reconcile-free windows. Use as a yardstick for our soak test. Source: same doc.
8. **Linux: inotify pitfalls.** Man page: queue overflow always emits `IN_Q_OVERFLOW` and excess events are dropped; rename pair (`IN_MOVED_FROM/TO`) shares a cookie but is "not guaranteed" to be consecutive; new subdirectories race: files may exist before the watch is added, so scan right after adding ([inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html)). Wingolog's critique: overflow, TOCTTOU, no cross-watch ordering ([post](https://wingolog.org/archives/2018/05/21/correct-or-inotify-pick-one)). Watchman: overflow triggers a recrawl; memory exhaustion poisons the watch ([troubleshooting](https://facebook.github.io/watchman/docs/troubleshooting)). Confirms the design's overflow-then-rescan rule.
9. **fanotify is not a drop-in.** Directory marks are not recursive; whole-filesystem marks are recursive but the man page ties the risky capability to `CAP_SYS_ADMIN`; create/delete/move events need Linux 5.1+ ([fanotify(7)](https://man7.org/linux/man-pages/man7/fanotify.7.html)). fdu's survey says unprivileged fanotify inode marks work on 5.13+ and filesystem marks need `CAP_SYS_ADMIN` ([survey](https://github.com/jlevy/fdu/blob/main/docs/project/research/research-2026-09-27-disk-growth-change-sources.md)). gosearch uses fanotify on 5.1+ ([README](https://github.com/ozeidan/gosearch/)). Keep inotify as the default (our decision), note fanotify as a later option.
10. **Ship a periodic full rebuild anyway.** Coxswain: watcher plus hourly full rebuild "which catches anything the watcher missed" ([names.md](https://github.com/mwo-dk/coxswain/blob/main/docs/search/names.md)); and when inotify limits are exceeded, only the rebuild catches changes in the rest. Matches our verification scan.
11. **Show staleness instead of hiding it.** CephFS pushes recursive stats up "at least once every minute or something" ([Ceph blog](https://ceph.io/geen-categorie/recursive-accounting-for-size-ctime-etc/)); the 2i2c exporter says sizes "may not be exactly correct immediately". Our `ok`/non-`ok` status per value follows this.
12. **Nautilus extension limits as a user-tolerance data point.** It watches only visible folders (limits 256 / 512), throttles re-measure to once per second, marks ancestors outdated on change ([repo](https://github.com/doggylover314/show-folder-size-nautilus)). "Mark ancestors dirty" is the same propagate-up update rule we use, but it re-measures instead of applying deltas.
13. **Hard links and permissions are the known correctness traps** for any recursive-size cache: Raymond Chen lists hard links (double count; update fan-out) and permission disclosure ([Old New Thing](https://devblogs.microsoft.com/oldnewthing/?p=19123)). Ceph counts only the primary link ([blog](https://ceph.io/geen-categorie/recursive-accounting-for-size-ctime-etc/)). Petal falls back to a full scan on hard links. Make the hard-link rule explicit in DESIGN.md and test it.
14. **APFS dir stats might be an optional macOS accelerator.** The fdu research found `apfs.util -M` can mark populated directories without privileges and totals were exact vs a walk; a pruned refresh took 1.04 s vs 7.9-9.7 s on a 225k-entry tree. But marking a populated 225k-entry root was a synchronous 66 s kernel operation that slowed concurrent creates/deletes (p90 5.9 ms to 70 ms), it uses a private `fsctl`, and Apple's forums report First Aid drift. Their verdict: park it. Apple's own DiskSpaceDiagnostics service uses it. This is relevant to your step-0 APFS probe in `step0/apfs-dirstats`. Source: fdu research doc.
15. **Interfaces:** gdu's `--db` (SQLite/Badger) and Coxswain's token file next to a loopback port both show the persistent-store + local-IPC pattern. Our Unix socket + snapshot file is simpler and avoids TCP exposure. Source: [gdu README](https://github.com/dundee/gdu), [Coxswain helper.md](https://github.com/mwo-dk/coxswain/blob/main/docs/search/helper.md).

## 4. Why it may not exist

- **Filesystems skip it on purpose.** Raymond Chen: the filesystem "doesn't care", and hard links, per-user permissions, and write amplification (metadata "could not be lazy-written") make it a bad default ([article](https://devblogs.microsoft.com/oldnewthing/?p=19123)). HN comment on APFS: dir-size caching "is wasteful for /tmp... because it makes file creation and deletion slightly slower" ([HN](https://news.ycombinator.com/item?id=22546831)).
- **APFS shipped the feature but Apple never finished it.** Opt-in on empty directories, no easy API, Finder does not use it ([Eclectic Light](https://eclecticlight.co/2019/02/06/how-big-is-that-folder-what-happened-to-apfs-fast-directory-sizing/), [Tsai](https://mjtsai.com/blog/2025/01/13/what-happened-to-apfs-fast-directory-sizing/)).
- **Watching is costly and leaky.** inotify needs one watch per directory and has overflow; "recursive watch on Linux will be probably quite costly for larger directories" (gdu maintainer, [issue #142](https://github.com/dundee/gdu/issues/142)). FSEvents coalesces and cannot see open writers (lesson 1). Watchman and jj needed repeated recrawls and fixes.
- **Maintainers of scanners decline.** dust: "Nope" to filesystem monitoring ([#205](https://github.com/bootandy/dust/issues/205)); duc's incremental idea has sat open since 2018 ([#205](https://github.com/zevv/duc/issues/205)). Scanners are fast enough (fdu: 0.1 s at 12k entries, 5.7 s at 452k, 18.6 s at 1.5M) that a cache does not look worth the correctness risk.
- **GUI file managers choose on-demand.** Finder and Linux file managers compute sizes only when asked, citing CPU/battery and many recursive queries (search snippets: [MacRumors how-to](https://www.macrumors.com/how-to/reveal-finder-folder-sizes-macos/), [Nautilus/GNOME search](https://github.com/doggylover314/show-folder-size-nautilus)). Void planned a "Total size" column computed from disk on demand because maintaining sizes is expensive and aggregated results double-count duplicates ([forum](https://www.voidtools.com/forum/viewtopic.php?t=7594)).
- **The good solutions sit in the storage layer** (CephFS, Qumulo, Lustre+Robinhood, OneFS quotas, project quotas), which is not available on a laptop's APFS/ext4.
- **Everything's trick (NTFS journal) has no equivalent.** Forum: a direct port may not be possible because Everything uses NTFS metadata ([forum](https://www.voidtools.com/forum/viewtopic.php?t=6917), snippet). Linux has no persistent change journal (fdu research); macOS has FSEvents history but it is slow and incomplete for open writers.
- **The niche is only now being tried.** Coxswain, fdu, petal and diskr were all created or active in 2026; none is a small daemon with a stable query socket.

## 5. Search log

Tools: WebSearch (summary results), WebFetch (page summaries), `gh api` (GitHub search and file reads), crates.io API, `npm search`, `brew search`. GitHub repo search ANDs terms, so multi-word queries often returned nothing; those are listed anyway.

**Web searches (WebSearch):**
1. daemon keeps recursive directory sizes up to date inotify incremental du cache
2. fsevents directory size cache daemon macOS live folder sizes
3. Linux file manager show folder size instantly "directory size" index inotify github
4. "du" daemon "inotify" keeps directory sizes updated "instead of rescanning" tool
5. is there a tool that keeps directory sizes up to date in real time like Everything folder size Linux
6. Everything search folder size index "folder size" real-time update Linux macOS alternative
7. macOS Finder show folder sizes instantly all folders alternative live background index Mac
8. Hacker News "du" cache directory sizes filesystem should maintain recursive size why not (and two follow-ups it ran itself)
9. duc disk usage daemon watch inotify update index incrementally issue
10. yazi directory size calculation sort by size cache
11. dired-du emacs recursive directory size
12. Dolphin KDE folder size recursive details view Baloo
13. Cardinal fast file search macOS index folder size FSEvents Everything for Mac
14. Robinhood policy engine Lustre changelog directory sizes rbh-du
15. Diskover directory sizes index crawl Elasticsearch inotify incremental
16. voidtools Everything "folder size" index real-time USN journal
17. Qumulo real-time directory aggregates
18. Starfish storage metadata index rolling scan
19. QDirStat cache file inotify
20. Baobab monitors home directory changes
21. bcachefs recursive directory size accounting
22. voidtools "Index folder size" "8 bytes" real time
23. CephFS ceph.dir.rbytes propagation delay
24. Apple APFS fast directory sizing getattrlist
25. Path Finder / ForkLift folder size cache
26. WhatSize watch/monitor FSEvents
27. broot --sizes background cache
28. FSearch folder size index inotify
29. Baloo directory size inotify limits
30. eBPF / fanotify disk usage per directory
31. unix.stackexchange keep track of directory sizes continuously inotify daemon
32. reddit folder size Linux file manager instantly Everything
33. lobste.rs / HN instant directory sizes why don't filesystems cache recursive size
34. Ask Different Finder folder size FSEvents
35. dirvish/dired async directory size cache daemon
36. gdu --use-storage persistent database
37. DaisyDisk / GrandPerspective / Disk Diag / Space Lens continuous monitoring
38. Syncthing per-directory size stats
39. osquery / netdata / node_exporter directory size
40. FUSE overlay tracks directory sizes quota
41. Isilon / WekaFS / GPFS / Lustre fast directory size
42. python watchdog directory size daemon pypi
43. Rust fsevents disk usage TUI persistent cache FSEvents replay (this found fdu, petal, disktracker)
44. Linux file managers folder size column Nautilus/Nemo/Thunar/Dolphin
45. Tracker/LocalSearch folder size
46. ncdu/dust/dua watch/inotify feature request
47. WizTree real-time update MFT
48. voidtools forum Everything for Linux/macOS
49. TreeSize / FolderSizes real-time NTFS change journal

**GitHub repo searches (`gh api search/repositories`), many returned zero hits:** directory size daemon inotify; live folder size fsevents; recursive directory size cache daemon; incremental du inotify; disk usage daemon realtime index; directory sizes unix socket daemon; folder size cache watcher dired; dirsize in:name; foldersize in:name; du cache daemon fanotify; directory size inotify; folder size fsevents; disk usage inotify; disk usage fsevents; du daemon; directory size watch incremental; disk usage monitor realtime directory; folder sizes daemon; recursive size inotify; directory sizes live; disk usage index watch; ncdu inotify; disk usage fanotify; dired folder size; recursive directory size filesystem events cache; topic:disk-usage (inotify / fsevents / daemon); topic:du daemon; topic:directory-size; topic:folder-size; topic:disk-usage-analyzer watch; topic:everything-search; du fsevents; du inotify; directory size fsnotify; dirsize daemon; recursive size daemon; disk usage daemon; realtime du; live du. Useful hits: sooua/Sweep, shenwei356/dirsize, Ridikul/dsize, 2i2c prometheus exporter (none live).

**GitHub issue searches:** dundee/gdu, Byron/dua-cli, bootandy/dust, zevv/duc, sharkdp/diskus, KSXGitHub/parallel-disk-usage, sxyazi/yazi, Canop/broot for watch/inotify/live/daemon/incremental.

**crates.io API queries:** "directory size", "disk usage", "folder size", "dirsize", "du daemon", "directory size watcher", "inotify size", "fsevents size", "disk usage cache". Hits worth opening: coxswain, diskr, inowatch (file watch daemon, not sizes), kache-fs, ccdu. Others are scanners.

**npm search:** "directory size watch", "folder size watch", "disk usage watch", "du daemon watch" (only fb-watchman, scanners). **brew search:** `/size/`, `/disk/` (found whatsize, diskwatch, daisydisk, omnidisksweeper, etc.; only whatsize checked).

**Not searched or not done:** PyPI and pkg.go.dev directly (only via web search), AUR, Codeberg/GitLab, Reddit/Lobsters directly (web-search only, no real threads returned), Stack Overflow/Unix.SE directly, VS Code Marketplace (only a GitHub hit: vscode-folder-size, per-file/folder on demand), Windows "Folder Size" shell extension history, Maestral/Dropbox, osquery, Marta/Thunar/Nemo internals, Spotlight `mdls` on directories (relied on fdu research), Everything Server protocol details. Suggested extensions: search Codeberg and sr.ht for "du" + "inotify"; read fdu `explorations/change-sources/os-facilities/survey.md`; read Coxswain source for its folder-size sum and watcher; ask in the Emacs and Hacker News communities.
