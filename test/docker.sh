#!/bin/sh
# Runs test/e2e.sh in clean containers as a non-root user. Usage: test/docker.sh [BINARY]
# Called by `make test-linux` after zig-out/linux/bin/dirsized was built for the host CPU.
# Env: IMAGES (default "debian:stable-slim fedora:latest alpine:latest"),
#      DIRSIZED_E2E_BURST (passed on to the script).
#
# The binary and the script are bind-mounted read-only. HOME and the test tree are in the
# container's own /tmp, never on a bind mount: inotify events from a host folder are unreliable.
set -u

cd "$(dirname "$0")/.." || exit 2
bin=${1:-zig-out/linux/bin/dirsized}
images=${IMAGES:-debian:stable-slim fedora:latest alpine:latest}
case $bin in /*) ;; *) bin=$PWD/$bin ;; esac
[ -x "$bin" ] || { echo "no executable at $bin (run make test-linux)" >&2; exit 2; }
script=$PWD/test/e2e.sh

if ! docker info >/dev/null 2>&1; then
    case "$(uname -s)" in
    Darwin)
        echo "Docker is not running, starting it" >&2
        open -a Docker || true
        i=0
        while ! docker info >/dev/null 2>&1; do
            i=$((i + 1))
            if [ "$i" -gt 60 ]; then
                echo "Docker did not start within 2 minutes" >&2
                exit 2
            fi
            sleep 2
        done
        ;;
    *)
        echo "Docker is not running" >&2
        exit 2
        ;;
    esac
fi

summary=
failed=0
for image in $images; do
    echo "== $image"
    log=$(mktemp "${TMPDIR:-/tmp}/dirsized-docker.XXXXXX")
    # No --privileged, no added capabilities; uid 1000 has no entry in /etc/passwd, which is why HOME is set by hand.
    # `sh` is the image's own: dash, bash or busybox ash. The script is POSIX sh.
    docker run --rm --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
        -e HOME=/tmp/home -e TMPDIR=/tmp -e DIRSIZED_E2E_BURST="${DIRSIZED_E2E_BURST:-100000}" \
        -w /tmp \
        -v "$bin:/dirsized:ro" -v "$script:/e2e.sh:ro" \
        "$image" sh /e2e.sh /dirsized >"$log" 2>&1
    rc=$?
    grep -v '^ok' "$log"
    line=$(grep '^passed ' "$log" | tail -1)
    [ -n "$line" ] || line="no result line"
    if [ "$rc" -eq 0 ]; then
        summary="$summary$image: PASS ($line)
"
    else
        summary="$summary$image: FAIL, exit $rc ($line)
"
        failed=$((failed + 1))
    fi
    rm -f "$log"
done

echo
echo "== summary"
printf '%s' "$summary"
[ "$failed" -eq 0 ]
