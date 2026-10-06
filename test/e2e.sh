#!/bin/sh
# End-to-end test of the dirsized command line. Usage: sh test/e2e.sh [BINARY]
#
# Every expected value comes from find(1) + stat(1), never from dirsized itself.
# Portable POSIX sh: it runs unchanged on macOS and in Debian, Fedora and Alpine containers.
#
# Part 1 runs the command line without a daemon (--scan). Part 2 starts `dirsized daemon` with
# a private HOME and checks it against the same references, through changes to the tree.
#
# Environment:
#   DIRSIZED_E2E_NO_WATCH=1  skip the checks that need change events (a platform without a watcher;
#                            macOS and Linux both have one now, so nothing needs it by default)
#   DIRSIZED_E2E_BURST=N     files made in one burst (default 100000, as in DESIGN.md 16.1; the whole script then takes about 30 s on macOS)

# shellcheck disable=SC2086  # $MODE and $STATFMT are word lists on purpose

BIN=${1:-./zig-out/bin/dirsized}
case $BIN in /*) ;; *) BIN=$PWD/$BIN ;; esac
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/dirsized-e2e.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)          # dirsized prints real paths; /var is a symlink on macOS
cleanup() {
    if [ -n "$DPID" ]; then
        kill "$DPID" 2>/dev/null
        sleep 0.3
        kill -9 "$DPID" 2>/dev/null
    fi
    chmod -R u+rwx "$T" 2>/dev/null
    rm -rf "$T" "$DH"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
HOME=$T/home                   # a private HOME: the user's real config is never read
export HOME
CONF=$HOME/.config/dirsized/config.toml
mkdir -p "$HOME"
# The daemon's socket lives under HOME, and a socket path is limited to 104 bytes on macOS,
# so part 2 uses a short HOME of its own.
unset XDG_RUNTIME_DIR XDG_CACHE_HOME
DH=$(mktemp -d /tmp/ds.XXXXXX) || exit 2
DH=$(cd "$DH" && pwd -P)
DPID=

TREE=$T/tree
LST=$T/lst
OUT=$T/out
ERR=$T/err
TAB=$(printf '\t')
LC_ALL=C
export LC_ALL

MODE=--scan
ds() { "$BIN" $MODE "$@"; }

if stat -c %s / >/dev/null 2>&1; then STATFMT="-c %s"; else STATFMT="-f %z"; fi  # GNU or BSD

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
bad() { failed=$((failed + 1)); echo "FAIL - $1"; }

run() { "$@" >"$OUT" 2>"$ERR"; rc=$?; }

assert_rc() {
    if [ "$rc" = "$2" ]; then ok "$1 (exit $2)"; else bad "$1: exit $rc, want $2"; fi
}
assert_str() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$2] got [$3]"; fi
}
# cmp is not in every minimal image (Fedora has no diffutils); cksum is in coreutils and busybox.
if command -v cmp >/dev/null 2>&1; then
    same_file() { cmp -s "$1" "$2"; }
else
    same_file() { [ "$(cksum <"$1")" = "$(cksum <"$2")" ]; }
fi
assert_files() {  # name want-file got-file
    if same_file "$2" "$3"; then ok "$1"; else
        bad "$1"
        od -c "$2" | head -5 | sed 's/^/    want: /'
        od -c "$3" | head -5 | sed 's/^/    got:  /'
    fi
}
assert_empty() {  # name file
    if [ ! -s "$2" ]; then ok "$1"; else bad "$1: not empty"; head -3 "$2" | sed 's/^/    /'; fi
}
assert_grep() {  # name fixed-string file
    if grep -F -- "$2" "$3" >/dev/null; then ok "$1"; else bad "$1: no [$2]"; head -3 "$3" | sed 's/^/    /'; fi
}

# ---- reference: sum of regular-file lengths, from find + stat ----------------------------

cat >"$T/ref.sh" <<'REF'
#!/bin/sh
# ref.sh STATFMT DIR...  ->  BYTES<TAB>ok<TAB>DIR<NUL> for each DIR
fmt=$1; shift
for d; do
    n=$(find "$d" -type f -exec stat $fmt {} + | awk '{ s += $1 } END { printf "%.0f", s }')
    printf '%s\tok\t%s\000' "$n" "$d"
done
REF
ref() { sh "$T/ref.sh" "$STATFMT" "$@"; }

# Sum of file lengths below DIR, leaving out every folder that matches the find expression.
ref_pruned() {  # DIR find-expression...
    rp_dir=$1; shift
    find "$rp_dir" \( -type d \( "$@" \) -prune \) -o -type f -exec stat $STATFMT {} + |
        awk '{ s += $1 } END { printf "%.0f\n", s }'
}

# Newline -> \001, NUL -> newline: one line per record, safe to sort even with odd names.
lines() { tr '\n\000' '\001\n'; }

# Number of child folders of $1, counted without parsing names.
child_count() { find "$1" -mindepth 1 -maxdepth 1 -type d -exec printf x \; | wc -c | tr -d ' '; }

bytes_of() { ds -0 "$1" | lines | cut -f1; }

# ---- fixtures ----------------------------------------------------------------------------

file() { dd if=/dev/zero of="$1" bs="$2" count=1 2>/dev/null; }          # exact size > 0
sparse() { dd if=/dev/null of="$1" bs=1 seek="$2" count=0 2>/dev/null; }  # length without blocks

make_tree() {
    nl=$(printf 'a\nb')
    cafe=$(printf 'caf\303\251')
    nihon=$(printf '\346\227\245\346\234\254')
    mkdir -p "$TREE/empty" "$TREE/proj/sub/deep/er" "$TREE/proj/sub/node_modules" \
        "$TREE/proj/node_modules" "$TREE/proj/build" "$TREE/node_modules" "$TREE/build" \
        "$TREE/sparse" "$TREE/links" "$TREE/hl/sub" "$TREE/with space" "$TREE/nl$nl/x${nl}y" \
        "$TREE/many" "$TREE/$cafe" "$TREE/$nihon/sub"
    : >"$TREE/proj/empty.txt"
    file "$TREE/f_1" 1
    file "$TREE/f_1023" 1023
    file "$TREE/f_4096" 4096
    file "$TREE/proj/a.txt" 10
    file "$TREE/proj/sub/b.bin" 5000
    file "$TREE/proj/sub/deep/c" 123
    file "$TREE/proj/sub/deep/er/d" 77
    file "$TREE/proj/node_modules/n" 111
    file "$TREE/proj/sub/node_modules/m" 222
    file "$TREE/proj/build/x" 333
    file "$TREE/node_modules/z" 444
    file "$TREE/build/y" 555
    sparse "$TREE/sparse/disk.img" 5242880
    ln -s ../proj "$TREE/links/linkdir"
    ln -s ../f_4096 "$TREE/links/linkfile"
    ln -s /nonexistent "$TREE/links/dangling"
    file "$TREE/hl/orig" 4000
    ln "$TREE/hl/orig" "$TREE/hl/copy"
    ln "$TREE/hl/orig" "$TREE/hl/sub/copy2"
    file "$TREE/with space/a b.txt" 12
    file "$TREE/nl$nl/in${nl}side" 321
    file "$TREE/nl$nl/x${nl}y/z" 2
    file "$TREE/$cafe/f" 70
    file "$TREE/$nihon/sub/g" 9
    i=1
    while [ $i -le 3000 ]; do printf 'ab%s' "$i" >"$TREE/many/f$i"; i=$((i + 1)); done
}

# Children with distinct sizes, one tie (tie_a < tie_b), an empty folder, a sparse 1.5 GiB file.
make_lst() {
    cafe=$(printf 'caf\303\251')
    mkdir -p "$LST/huge" "$LST/big" "$LST/mid" "$LST/tie_b" "$LST/tie_a" "$LST/zero" \
        "$LST/ten k" "$LST/$cafe"
    sparse "$LST/huge/f" 1610612736
    file "$LST/big/f" 3145728
    file "$LST/$cafe/f" 1048576
    file "$LST/ten k/f" 10240
    file "$LST/mid/f" 1536
    file "$LST/tie_a/f" 1024
    file "$LST/tie_b/f" 1024
}

# ---- checks ------------------------------------------------------------------------------

test_every_folder() {
    find "$TREE" -type d -exec "$BIN" --scan -0 -- {} + >"$T/got" 2>"$ERR"
    find "$TREE" -type d -exec sh "$T/ref.sh" "$STATFMT" {} + >"$T/want"
    n=$(find "$TREE" -type d -exec printf x \; | wc -c | tr -d ' ')
    assert_files "all $n folders: -0 value equals the find+stat sum" "$T/want" "$T/got"
    assert_empty "all folders: no stderr output" "$ERR"
}

test_symlinks_and_links() {
    run ds -0 "$TREE/links"
    assert_str "symlinks to a file and to a folder add 0 bytes" 0 "$(lines <"$OUT" | cut -f1)"
    run ds -l -0 "$TREE/links"
    assert_empty "a symlink to a folder is not a child" "$OUT"
    run ds -0 "$TREE/hl"
    assert_str "hard link counted at each name (3 x 4000)" 12000 "$(lines <"$OUT" | cut -f1)"
    run ds -0 "$TREE/links/linkdir"
    assert_str "a symlink as PATH is resolved to its target" "$TREE/proj" "$(lines <"$OUT" | cut -f3)"
    run ds -0 "$TREE/sparse"
    assert_str "a sparse file counts its full length" 5242880 "$(lines <"$OUT" | cut -f1)"
}

test_list() {
    run ds -l -0 "$TREE"
    assert_rc "-l on the big tree" 0
    lines <"$OUT" | sort >"$T/got"
    find "$TREE" -mindepth 1 -maxdepth 1 -type d -exec sh "$T/ref.sh" "$STATFMT" {} + | lines | sort >"$T/want"
    assert_files "-l children and sizes equal the find+stat sums" "$T/want" "$T/got"
    assert_str "-l lists children only, one record each" "$(child_count "$TREE")" "$(tr -cd '\000' <"$OUT" | wc -c | tr -d ' ')"
    lines <"$OUT" >"$T/got"
    sort -t "$TAB" -k1,1nr -k3 "$T/got" >"$T/want"
    assert_files "-l order: size descending, ties by name" "$T/want" "$T/got"

    run ds -l "$LST"
    find "$LST" -mindepth 1 -maxdepth 1 -type d -exec sh "$T/ref.sh" "$STATFMT" {} + | lines |
        sort -t "$TAB" -k1,1nr -k3 >"$T/want"
    assert_files "-l with a tie matches the sorted reference" "$T/want" "$OUT"
    run ds -l -n 3 "$LST"
    head -3 "$T/want" >"$T/want3"
    assert_files "-n 3 keeps the 3 largest" "$T/want3" "$OUT"
    run ds -ln3 "$LST"
    assert_files "-ln3 is -l -n 3" "$T/want3" "$OUT"
    run ds -n 1 "$LST/mid" "$LST/big"
    assert_str "-n without -l keeps the first PATH given" "$LST/mid" "$(cut -f3 "$OUT")"
    run ds -n 0 "$LST"
    assert_empty "-n 0 prints nothing" "$OUT"
    ( cd "$LST" && ds -0 ) >"$OUT" 2>"$ERR"
    assert_str "no PATH means the current folder" "$LST" "$(lines <"$OUT" | cut -f3)"
}

test_human() {
    run ds -lh "$LST"
    cut -f1 "$OUT" >"$T/got"
    printf '%s\n' 1.5G 3.0M 1.0M 10K 1.5K 1.0K 1.0K 0 >"$T/want"
    assert_files "-h like ls -h (1.5G 3.0M 1.0M 10K 1.5K 1.0K 0)" "$T/want" "$T/got"
    run ds -h "$LST/zero" "$LST/huge"
    assert_str "-h: 0 stays 0" "0 1.5G" "$(cut -f1 "$OUT" | tr '\n' ' ' | sed 's/ $//')"
}

test_nul_roundtrip() {
    nl=$(printf 'a\nb')
    d=$TREE/nl$nl
    run ds -0 "$d"
    ref "$d" >"$T/want"
    assert_files "-0 keeps the newline in a folder name" "$T/want" "$OUT"
    assert_str "-0 gives exactly one NUL per record" 1 "$(tr -cd '\000' <"$OUT" | wc -c | tr -d ' ')"
}

test_json() {
    run ds --json -l "$LST"
    assert_rc "--json -l" 0
    assert_grep "--json: object shape" '{"path":"'"$LST"'/huge","bytes":1610612736,"state":"ok"}' "$OUT"
    assert_str "--json: one line, newline-terminated" 1 "$(wc -l <"$OUT" | tr -d ' ')"
    nl=$(printf 'a\nb')
    run ds --json "$TREE/nl$nl"
    assert_grep "--json escapes a newline in a name" 'nla\u000ab"' "$OUT"
    run ds --json "$T/missing"
    assert_grep "--json: a missing path is state none" '"bytes":0,"state":"none"}]' "$OUT"
    if command -v python3 >/dev/null 2>&1; then
        py='import json,sys
for x in json.load(sys.stdin): print("%d\t%s\t%s" % (x["bytes"], x["state"], x["path"]))'
        run ds --json -l "$LST"
        PYTHONIOENCODING=utf-8 python3 -c "$py" <"$OUT" >"$T/got"
        ds -l "$LST" >"$T/want"
        assert_files "--json parses and has the same numbers" "$T/want" "$T/got"
        run ds --json -l "$TREE"
        got=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <"$OUT")
        assert_str "--json of the big tree is valid and has every child" "$(child_count "$TREE")" "$got"
    else
        echo "ok - (python3 missing: skipped the JSON parse checks)"
    fi
}

write_config() { mkdir -p "$(dirname "$CONF")"; cat >"$CONF"; }

test_excludes() {
    write_config <<'CONF'
exclude = [
  "node_modules/",
  "/build/",
  "!/proj/node_modules/",
]
CONF
    # Rules apply below the PATH, which acts as the root.
    want=$(ref_pruned "$TREE" -path "$TREE/node_modules" -o -path "$TREE/proj/sub/node_modules" -o -path "$TREE/build")
    assert_str "name pattern, anchored pattern and negation (PATH = tree)" "$want" "$(bytes_of "$TREE")"
    want=$(ref_pruned "$TREE/proj" -name node_modules -o -path "$TREE/proj/build")
    assert_str "anchored rules are relative to the PATH (PATH = proj)" "$want" "$(bytes_of "$TREE/proj")"
    run ds -l "$TREE"
    if cut -f3 "$OUT" | grep -E '/(node_modules|build)$' >/dev/null; then bad "-l hides excluded children"; else ok "-l hides excluded children"; fi
    run ds -l "$TREE/proj"
    if cut -f3 "$OUT" | grep -F "$TREE/proj/node_modules" >/dev/null; then bad "-l (PATH = proj) hides node_modules"; else ok "-l (PATH = proj) hides node_modules"; fi
    rm -f "$CONF"
    assert_str "without a config nothing is excluded" "$(ref "$TREE" | lines | cut -f1)" "$(bytes_of "$TREE")"
}

test_check() {
    write_config <<CONF
# test config
roots = ["$TREE"]
exclude = [
  "node_modules/",
  "/build/",
  "!/proj/node_modules/",
]
CONF
    run ds check
    assert_rc "check on a valid file" 0
    assert_str "check: the first line is ok" ok "$(head -1 "$OUT")"
    assert_grep "check: shows the resolved root" "root$TAB$TREE" "$OUT"
    assert_grep "check: shows the rule count" "rules${TAB}3" "$OUT"
    run ds check "$TREE/node_modules"
    assert_rc "check PATH: excluded folder" 1
    assert_grep "check PATH: names the rule and its line" 'rule "node_modules/" (line 4)' "$OUT"
    run ds check "$TREE/proj/node_modules"
    assert_rc "check PATH: folder kept by a negation" 0
    assert_grep "check PATH: names the negation and its line" 'kept by rule "!/proj/node_modules/" (line 6)' "$OUT"
    run ds check "$TREE/proj/sub"
    assert_rc "check PATH: counted folder" 0
    assert_grep "check PATH: says counted" "counted$TAB$TREE/proj/sub" "$OUT"
    run ds check "$T"
    assert_rc "check PATH: outside every root" 1
    assert_grep "check PATH: says outside" "outside$TAB$T" "$OUT"
    run ds check "$T/missing"
    assert_rc "check PATH: missing path" 1

    write_config <<CONF
# broken
roots = ["$TREE"]
bogus = 1
CONF
    run ds check
    assert_rc "check on a broken file" 2
    assert_grep "check: PATH:LINE: message" "config.toml:3:" "$ERR"
    assert_empty "check: nothing on stdout when broken" "$OUT"
    run ds -0 "$TREE"
    assert_rc "scan with a broken config" 2
    assert_grep "scan: names the line of the broken config" "config.toml:3:" "$ERR"
    assert_empty "scan: nothing on stdout when the config is broken" "$OUT"

    write_config <<'CONF'
exclude = ["ok/", ""]
CONF
    run ds check
    assert_rc "check: empty pattern" 2
    assert_grep "check: empty pattern reported at its line" "config.toml:1:" "$ERR"

    rm -f "$CONF"
    run ds check
    assert_rc "check without a config file" 0
    assert_grep "check without a file says defaults apply" "defaults apply" "$OUT"
}

test_exit_codes() {
    run ds -0 "$TREE"
    assert_rc "all ok" 0
    run ds "$T/missing"
    assert_rc "missing path" 1
    assert_str "missing path: a record with state none" "0${TAB}none${TAB}$T/missing" "$(cat "$OUT")"
    run ds "$LST" "$T/missing" "$TREE/f_1"
    assert_rc "missing and file paths, the others still answered" 1
    assert_str "every PATH gets one parseable record" 3 "$(grep -c "^[0-9]*${TAB}[a-z]*${TAB}/" "$OUT")"
    assert_str "a file is not a folder: state none" none "$(sed -n 3p "$OUT" | cut -f2)"
    for args in "--bogus" "-x" "-n" "-n x" "-l a b" "--json -0" "status a" "check a b"; do
        # shellcheck disable=SC2086
        run ds $args
        assert_rc "usage error: $args" 2
        assert_empty "usage error: $args leaves stdout empty" "$OUT"
        assert_grep "usage error: $args points to --help" "Try 'dirsized --help'." "$ERR"
    done
    for args in "$LST" "-l $LST" "status"; do
        # shellcheck disable=SC2086
        run "$BIN" $args
        assert_rc "no daemon, no --scan: $args" 3
        assert_empty "no daemon: $args leaves stdout empty" "$OUT"
        assert_grep "no daemon: $args explains --scan" "use --scan" "$ERR"
    done
    run "$BIN" --help
    assert_rc "--help" 0
    assert_grep "--help shows usage" "Usage:" "$OUT"
    cp "$OUT" "$T/help.out"
    run "$BIN" help
    assert_rc "help" 0
    assert_str "help prints the same as --help" "$(cat "$T/help.out")" "$(cat "$OUT")"
    assert_empty "help leaves stderr empty" "$ERR"
    run "$BIN" "-?"
    assert_rc "-? is an unknown option" 2
    assert_grep "-? is named in the error" "unknown option -?" "$ERR"
    run "$BIN" help extra
    assert_rc "help takes no PATH" 2
    run "$BIN" --version
    assert_str "--version" "dirsized 0.1.0" "$(cat "$OUT")"
    run ds -- "$LST"
    assert_rc "-- ends options" 0
    mkdir -p "$T/dashes/-l/sub" "$T/dashes/status" "$T/dashes/help"
    ( cd "$T/dashes" && ds -0 -- -l ) >"$OUT" 2>"$ERR"
    assert_str "-- lets a PATH start with a dash" "$T/dashes/-l" "$(lines <"$OUT" | cut -f3)"
    ( cd "$T/dashes" && ds ./status ) >"$OUT" 2>"$ERR"
    assert_str "./status is a folder, not the command" "$T/dashes/status" "$(cut -f3 "$OUT")"
    ( cd "$T/dashes" && ds ./help ) >"$OUT" 2>"$ERR"
    assert_str "./help is a folder, not the command" "$T/dashes/help" "$(cut -f3 "$OUT")"
    "$BIN" --scan -l "$TREE" 2>"$ERR" | head -1 >/dev/null
    assert_empty "a closed stdout (| head -1) is quiet" "$ERR"
}

test_partial() {
    if [ "$(id -u)" = 0 ]; then echo "ok - (running as root: skipped the mode 000 checks)"; return; fi
    mkdir -p "$T/perm/ok" "$T/perm/locked/inner"
    file "$T/perm/ok/f" 100
    file "$T/perm/locked/f" 50
    chmod 000 "$T/perm/locked"
    run ds -0 "$T/perm"
    assert_rc "a mode 000 folder below PATH" 4
    assert_str "state partial on the ancestor, readable files counted" "100${TAB}partial" "$(lines <"$OUT" | cut -f1,2)"
    run ds -l "$T/perm"
    assert_rc "-l with an unreadable child" 4
    assert_str "-l: the locked child is partial" partial "$(grep "/locked\$" "$OUT" | cut -f2)"
    assert_str "-l: its sibling stays ok" ok "$(grep "/ok\$" "$OUT" | cut -f2)"
    run ds -0 "$T/perm/locked"
    assert_rc "a mode 000 folder as PATH" 4
    chmod 755 "$T/perm/locked"
}

# ---- part 2: the daemon -----------------------------------------------------------------

BURST=${DIRSIZED_E2E_BURST:-100000}
SOCK=$DH/.cache/dirsized/sock

# wait_for SECONDS COMMAND...  succeeds as soon as COMMAND does, polling every 0.2 s
wait_for() {
    wf_n=$(($1 * 5)); shift
    while [ "$wf_n" -gt 0 ]; do
        "$@" && return 0
        sleep 0.2
        wf_n=$((wf_n - 1))
    done
    return 1
}
status_is() { "$BIN" status 2>/dev/null | grep -qx "state: $1"; }
status_has() { "$BIN" status 2>/dev/null | grep -F -- "$1" >/dev/null; }
status_lacks() { ! status_has "$1"; }
# total_is DIR BYTES: the daemon's value for DIR is BYTES
total_is() { [ "$(bytes_of "$1")" = "$2" ]; }
excluded_is() { [ "$("$BIN" "$1" 2>/dev/null | cut -f2)" = excluded ]; }

# Every folder below $1 (default TREE) against find + stat, in one pass.
compare_all() {  # label [DIR]
    ca_dir=${2:-$TREE}
    find "$ca_dir" -type d -exec "$BIN" -0 -- {} + >"$T/got" 2>"$ERR"
    find "$ca_dir" -type d -exec sh "$T/ref.sh" "$STATFMT" {} + >"$T/want"
    n=$(find "$ca_dir" -type d -exec printf x \; | wc -c | tr -d ' ')
    assert_files "$1: all $n folders equal the find+stat sum" "$T/want" "$T/got"
    assert_empty "$1: no stderr output" "$ERR"
}

start_daemon() {
    "$BIN" daemon >"$T/daemon.log" 2>&1 &
    DPID=$!
}

test_daemon_start() {
    HOME=$DH
    CONF=$HOME/.config/dirsized/config.toml
    MODE=
    write_config <<CONF
roots = ["$TREE", "$LST"]
CONF
    start_daemon
    if wait_for 60 status_is ok; then ok "daemon starts and scans: status says ok"; else
        bad "daemon did not reach state ok in 60 s"
        "$BIN" status | sed 's/^/    /'
        sed 's/^/    log: /' "$T/daemon.log"
        return 1
    fi
    run "$BIN" status
    assert_rc "status" 0
    assert_str "status: first key is proto" "proto: 1" "$(head -1 "$OUT")"
    # `watches` and `watch_limit` exist on Linux only.
    keys=$(sed 's/:.*//' "$OUT" | grep -v '^watch' | tr '\n' ' ')
    assert_str "status: keys and their order" "proto version pid state folders memory rss queued slow events snapshot_age verify_age root root " "$keys"
    assert_grep "status: lists the root" "root: $TREE" "$OUT"
    assert_str "status: pid is the daemon" "pid: $DPID" "$(grep '^pid:' "$OUT")"
    run "$BIN" daemon
    assert_rc "a second daemon exits 2" 2
    assert_grep "a second daemon says why" "another daemon" "$ERR"
    run "$BIN" status
    assert_rc "the first daemon still answers" 0
    return 0
}

test_daemon_queries() {
    compare_all "initial scan"
    run "$BIN" -l -0 "$TREE"
    lines <"$OUT" | sort >"$T/got"
    find "$TREE" -mindepth 1 -maxdepth 1 -type d -exec sh "$T/ref.sh" "$STATFMT" {} + | lines | sort >"$T/want"
    assert_files "daemon -l: children and sizes equal the find+stat sums" "$T/want" "$T/got"
    lines <"$OUT" >"$T/got"
    sort -t "$TAB" -k1,1nr -k3 "$T/got" >"$T/want"
    assert_files "daemon -l: size descending, ties by name" "$T/want" "$T/got"

    run "$BIN" -lh "$LST"
    cut -f1 "$OUT" >"$T/got"
    printf '%s\n' 1.5G 3.0M 1.0M 10K 1.5K 1.0K 1.0K 0 >"$T/want"
    assert_files "daemon -lh: 1.5G 3.0M 1.0M 10K 1.5K 1.0K 1.0K 0" "$T/want" "$T/got"
    find "$LST" -mindepth 1 -maxdepth 1 -type d -exec sh "$T/ref.sh" "$STATFMT" {} + | lines |
        sort -t "$TAB" -k1,1nr -k3 >"$T/want"
    run "$BIN" -l "$LST"
    assert_files "daemon -l with a tie matches the sorted reference" "$T/want" "$OUT"
    run "$BIN" -ln3 "$LST"
    head -3 "$T/want" >"$T/want3"
    assert_files "daemon -ln3 keeps the 3 largest" "$T/want3" "$OUT"
    run "$BIN" -n 1 "$LST/mid" "$LST/big"
    assert_str "daemon -n without -l keeps the first PATH given" "$LST/mid" "$(cut -f3 "$OUT")"
    run "$BIN" -h "$LST/zero" "$LST/huge"
    assert_str "daemon -h" "0 1.5G" "$(cut -f1 "$OUT" | tr '\n' ' ' | sed 's/ $//')"

    nl=$(printf 'a\nb')
    run "$BIN" -0 "$TREE/nl$nl"
    ref "$TREE/nl$nl" >"$T/want"
    assert_files "daemon -0 keeps the newline in a folder name" "$T/want" "$OUT"
    run "$BIN" --json -l "$LST"
    assert_rc "daemon --json -l" 0
    assert_grep "daemon --json: object shape" '{"path":"'"$LST"'/huge","bytes":1610612736,"state":"ok"}' "$OUT"
    run "$BIN" --json "$TREE/nl$nl"
    assert_grep "daemon --json escapes a newline in a name" 'nla\u000ab"' "$OUT"
    run "$BIN" -0 "$TREE/links/linkdir"
    assert_str "daemon: a symlink as PATH is resolved first" "$TREE/proj" "$(lines <"$OUT" | cut -f3)"

    run "$BIN" "$T/missing"
    assert_rc "daemon: a missing path" 1
    assert_str "daemon: a missing path gives state none" "0${TAB}none${TAB}$T/missing" "$(cat "$OUT")"
    run "$BIN" "$TREE/f_4096"
    assert_rc "daemon: a file is not a folder" 1
    assert_str "daemon: a file gives state none" none "$(cut -f2 "$OUT")"
    run "$BIN" "$T"
    assert_rc "daemon: a folder outside every root" 1
    assert_str "daemon: outside gives state none" none "$(cut -f2 "$OUT")"
    run "$BIN" -l "$T/missing"
    assert_rc "daemon -l on a missing path" 1
    run "$BIN" "$LST" "$T/missing" "$TREE/f_1"
    assert_str "daemon: one record for each PATH, in order" "$LST $T/missing $TREE/f_1 " "$(cut -f3 "$OUT" | tr '\n' ' ')"

    # Many PATHs: the answers are bigger than what the server buffers for a slow reader, so the
    # client must read while it still sends (it once wrote everything first and deadlocked).
    set --
    i=0
    while [ $i -lt 20000 ]; do set -- "$@" .; i=$((i + 1)); done
    run sh -c 'cd "$1" && shift && exec "$0" "$@"' "$BIN" "$TREE" "$@"
    assert_rc "daemon: 20000 PATHs in one call" 0
    assert_str "daemon: 20000 PATHs give 20000 records" "20000" "$(wc -l <"$OUT" | tr -d ' ')"

    if command -v python3 >/dev/null 2>&1; then
        run "$BIN" status --json
        keys=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(k for k in d if not k.startswith("watch")))' <"$OUT")
        assert_str "status --json: valid, same keys" "proto version pid state folders memory rss queued slow events snapshot_age verify_age root" "$keys"
        roots=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["root"]), d["state"], type(d["pid"]).__name__, type(d["snapshot_age"]).__name__)' <"$OUT")
        assert_str "status --json: roots are an array, numbers are numbers (the first scan was saved)" "2 ok int int" "$roots"
        py='import socket,sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"bogus\0size /x\0")
buf = b""
while buf.count(b"\0") < 4:
    d = s.recv(4096)
    if not d: break
    buf += d
print(buf.split(b"\0")[0].decode())'
        assert_str "garbage on the socket gets an error record" "!${TAB}bad-request${TAB}expected: size PATH, list PATH or status" "$(python3 -c "$py" "$SOCK")"
        run "$BIN" status
        assert_rc "the daemon survives a garbage request" 0
    else
        echo "ok - (python3 missing: skipped the status --json and garbage checks)"
    fi
}

# DESIGN.md 16.1 step 5, then wait for the daemon to catch up and compare every folder again.
test_daemon_changes() {
    nl=$(printf 'a\nb')
    cafe=$(printf 'caf\303\251')
    file "$TREE/proj/new1" 100
    echo "more data" >>"$TREE/proj/a.txt"
    dd if=/dev/zero of="$TREE/f_4096" bs=100 count=1 2>/dev/null     # shorter
    rm "$TREE/f_1023"
    rm -rf "$TREE/proj/sub/deep"
    mkdir -p "$TREE/new/l1/l2/l3/l4/l5"
    file "$TREE/new/l1/l2/l3/l4/l5/leaf" 17
    file "$TREE/new/l1/top" 3
    mv "$TREE/proj/build" "$TREE/proj/build2"                        # same parent
    mv "$TREE/with space" "$TREE/proj/moved"                         # other parent
    ln "$TREE/hl/orig" "$TREE/hl/copy3"
    ln -s ../proj "$TREE/links/newlink"
    mkdir -p "$TREE/odd name/with${nl}newline/$cafe"
    file "$TREE/odd name/with${nl}newline/$cafe/data" 41
    file "$TREE/odd name/x y" 5
    mkdir -p "$TREE/burst"
    i=0
    while [ $i -lt 50 ]; do mkdir -p "$TREE/burst/d$i"; i=$((i + 1)); done
    i=0
    while [ $i -lt "$BURST" ]; do printf 'x' >"$TREE/burst/d$((i % 50))/f$i"; i=$((i + 1)); done
    want=$(ref "$TREE" | lines | cut -f1)
    if wait_for 10 total_is "$TREE" "$want"; then ok "after the changes the root total matches the reference ($BURST files in the burst)"; else
        bad "root total after the changes: want $want got $(bytes_of "$TREE")"
    fi
    wait_for 10 status_is ok
    compare_all "after the changes"
    assert_str "the daemon saw events" 1 "$("$BIN" status | awk '/^events:/ { print ($2 > 0) }')"
}

SNAP=$DH/.cache/dirsized/table

# Every folder of both roots, counted by find: what the table holds before any exclude rule.
folder_count() { find "$TREE" "$LST" -type d -exec printf x \; | wc -c | tr -d ' '; }

# Waits for the new daemon's socket, then for the state ok, and compares every folder.
restart_and_compare() {  # label
    start_daemon
    wait_for 10 status_has "snapshot_age"
    wait_for 120 status_is ok
    if status_is ok; then ok "$1: state ok"; else bad "$1: no state ok in 120 s"; sed 's/^/    log: /' "$T/daemon.log"; fi
    compare_all "$1"
}

stop_daemon() {
    kill -TERM "$DPID"
    wait "$DPID"
    DPID=
}

# DESIGN.md 16.1 step 6. A killed daemon cannot save: the snapshot is the one from the end of
# the first scan, and everything that changed since must come back through the event history
# (macOS) or the full re-read (Linux).
test_daemon_restart() {
    nl=$(printf 'a\nb')
    ls "$SNAP" >/dev/null 2>&1 || bad "no snapshot file after the first scan"
    kill -9 "$DPID"
    wait "$DPID" 2>/dev/null
    DPID=
    # While the daemon is down.
    file "$TREE/proj/while_down" 1234
    rm -rf "$TREE/proj/node_modules"
    rm -rf "$TREE/odd name"
    mkdir -p "$TREE/down/a/b/c" "$TREE/down/with${nl}nl"
    file "$TREE/down/a/b/c/leaf" 99
    file "$TREE/down/with${nl}nl/x" 7
    file "$TREE/many/late" 5
    restart_and_compare "after kill -9 and changes while down"
    want=$(ref "$TREE" | lines | cut -f1)
    assert_str "root total after the restart" "$want" "$(bytes_of "$TREE")"

    # A clean stop writes a snapshot; the next start must use it.
    stop_daemon
    start_daemon
    wait_for 10 status_has "snapshot_age"
    run "$BIN" status
    if grep -q '^snapshot_age: -' "$OUT"; then bad "snapshot_age is - right after a start with a snapshot"; else ok "snapshot_age is set right after a start with a snapshot"; fi
    n=$(folder_count)
    assert_grep "the daemon loaded all $n folders from the snapshot" "loaded $n folders from the snapshot" "$T/daemon.log"
    wait_for 120 status_is ok
    compare_all "after a clean restart from the snapshot"

    # A damaged snapshot: truncated, then overwritten in the middle. Both mean a full scan.
    stop_daemon
    size=$(stat $STATFMT "$SNAP")
    head -c $((size / 2)) "$SNAP" >"$SNAP.cut" && mv "$SNAP.cut" "$SNAP"
    file "$TREE/proj/after_cut" 321
    restart_and_compare "truncated snapshot"
    assert_grep "a truncated snapshot is ignored" "snapshot ignored" "$T/daemon.log"
    stop_daemon
    size=$(stat $STATFMT "$SNAP")
    printf 'GARBAGE GARBAGE GARBAGE' | dd of="$SNAP" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
    file "$TREE/proj/after_garbage" 654
    restart_and_compare "snapshot with overwritten bytes"
    assert_grep "a damaged snapshot is ignored" "snapshot ignored" "$T/daemon.log"
    rm -f "$SNAP.cut"
}

test_daemon_config() {
    mkdir -p "$TREE/node_modules/inner"
    sleep 1.5   # let the folder reach the table before the rule hides it
    # Step 7: an exclude rule. `check` first, as DESIGN.md 13.5 says.
    write_config <<CONF
roots = ["$TREE", "$LST"]
exclude = ["node_modules/"]
CONF
    run "$BIN" check
    assert_rc "check on the new config" 0
    if wait_for 10 excluded_is "$TREE/node_modules"; then ok "the next query picks up the new config: node_modules is excluded"; else
        bad "node_modules is still not excluded after 10 s"
    fi
    wait_for 30 status_is ok
    run "$BIN" "$TREE/node_modules"
    assert_rc "an excluded folder gives exit 1" 1
    assert_str "an excluded folder answers excluded" "0${TAB}excluded${TAB}$TREE/node_modules" "$(cat "$OUT")"
    run "$BIN" "$TREE/node_modules/inner"
    assert_str "a folder below an excluded one answers excluded too" excluded "$(cut -f2 "$OUT")"
    run "$BIN" -l "$TREE"
    if cut -f3 "$OUT" | grep -F "$TREE/node_modules" >/dev/null; then bad "-l hides the excluded folder"; else ok "-l hides the excluded folder"; fi
    want=$(ref_pruned "$TREE" -name node_modules)
    assert_str "the root total is the reference minus the excluded folders" "$want" "$(bytes_of "$TREE")"
    find "$TREE" -type d \( -name node_modules -prune \) -o -type d -print >"$T/dirs"
    : >"$T/got"
    : >"$T/want"
    while IFS= read -r d; do
        # A name with a newline breaks the line reader; those two folders are checked above.
        [ -d "$d" ] || continue
        printf '%s\n' "$(bytes_of "$d")" >>"$T/got"
        printf '%s\n' "$(ref_pruned "$d" -name node_modules)" >>"$T/want"
    done <"$T/dirs"
    assert_files "every folder equals the reference without the excluded folders" "$T/want" "$T/got"

    # An unreadable folder: a new root, so this also tests a change of the roots.
    if [ "$(id -u)" != 0 ]; then
        mkdir -p "$T/dperm/ok" "$T/dperm/locked/inner"
        file "$T/dperm/ok/f" 100
        file "$T/dperm/locked/f" 50
        chmod 000 "$T/dperm/locked"
        write_config <<CONF
roots = ["$TREE", "$LST", "$T/dperm"]
exclude = ["node_modules/"]
CONF
        if wait_for 10 status_has "root: $T/dperm"; then ok "a new root is picked up"; else bad "the new root never showed in status"; fi
        wait_for 30 status_is partial
        run "$BIN" -0 "$T/dperm"
        assert_rc "an unreadable folder: exit 4" 4
        assert_str "the readable files count, the state is partial" "100${TAB}partial" "$(lines <"$OUT" | cut -f1,2)"
        run "$BIN" status
        assert_grep "status lists the unreadable folder" "denied: $T/dperm/locked" "$OUT"
        chmod 755 "$T/dperm/locked"
    fi

    # Step 8: a broken file changes nothing but status.
    before=$(bytes_of "$TREE")
    write_config <<CONF
roots = ["$TREE", "$LST"]
bogus = 1
CONF
    run "$BIN" check
    assert_rc "check on the broken config" 2
    if wait_for 10 status_has "config_error: "; then ok "status shows config_error"; else bad "no config_error in status"; fi
    run "$BIN" status
    assert_grep "config_error names the file and line" "config.toml:2:" "$OUT"
    assert_str "the previous config still answers: same total" "$before" "$(bytes_of "$TREE")"
    run "$BIN" "$TREE/node_modules"
    assert_str "the previous config still excludes node_modules" excluded "$(cut -f2 "$OUT")"
    run "$BIN" status
    assert_rc "status works with a broken config" 0

    # Back to a good file: the error goes away and the new rules apply.
    write_config <<CONF
roots = ["$TREE", "$LST"]
CONF
    if wait_for 10 status_lacks "config_error"; then ok "a good config clears config_error"; else bad "config_error stays"; fi
    wait_for 30 status_is ok
    assert_str "without the rule everything is counted again" "$(ref "$TREE" | lines | cut -f1)" "$(bytes_of "$TREE")"

    # A root that is not there yet (a disk that is not mounted at login) is retried, and the
    # state is not ok meanwhile. The config file does not change.
    write_config <<CONF
roots = ["$TREE", "$T/later"]
CONF
    if wait_for 10 status_has "config_error: "; then ok "a missing root shows as config_error"; else bad "no config_error for a missing root"; fi
    if status_is ok; then bad "state says ok with a config error"; else ok "state is not ok with a config error"; fi
    mkdir -p "$T/later"
    file "$T/later/f" 7
    if wait_for 10 status_lacks "config_error"; then ok "the root that appears is picked up without a config change"; else bad "config_error stays after the root appeared"; fi
    wait_for 30 status_is ok
    assert_str "the new root is counted" 7 "$(bytes_of "$T/later")"
    write_config <<CONF
roots = ["$TREE", "$LST"]
CONF
    wait_for 10 status_lacks "root: $T/later"
    wait_for 30 status_is ok
}

test_daemon_stop() {
    kill -TERM "$DPID"
    wait "$DPID"
    rc=$?
    DPID=
    assert_str "SIGTERM stops the daemon with exit 0" 0 "$rc"
    if [ ! -S "$SOCK" ] && [ ! -e "$SOCK" ]; then ok "the socket file is removed"; else bad "the socket file is still there"; fi
    run "$BIN" "$LST"
    assert_rc "no daemon: exit 3" 3
    assert_grep "no daemon: the message" "daemon is not running" "$ERR"
    run "$BIN" --scan -0 "$LST"
    assert_rc "no daemon, --scan: reads the disk" 0
    start_daemon
    wait_for 60 status_is ok
    kill -INT "$DPID"
    wait "$DPID"
    assert_str "SIGINT also stops it with exit 0" 0 "$?"
    DPID=
    start_daemon
    wait_for 60 status_is ok
    kill -HUP "$DPID"
    wait "$DPID"
    assert_str "SIGHUP also stops it with exit 0" 0 "$?"
    DPID=
}

test_daemon() {
    test_daemon_start || return
    test_daemon_queries
    if [ -n "$DIRSIZED_E2E_NO_WATCH" ]; then
        echo "ok - (DIRSIZED_E2E_NO_WATCH: skipped the change-event checks)"
    else
        test_daemon_changes
    fi
    test_daemon_restart
    test_daemon_config
    test_daemon_stop
}

main() {
    make_tree
    make_lst
    test_every_folder
    test_symlinks_and_links
    test_list
    test_human
    test_nul_roundtrip
    test_json
    test_excludes
    test_check
    test_exit_codes
    test_partial
    test_daemon
    echo "passed $pass, failed $failed"
    [ "$failed" -eq 0 ]
}

main
