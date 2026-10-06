#!/bin/sh
# Cross-builds the unit tests of the given source files for Linux and runs each one in a clean
# container as a non-root user. Usage: test/linux-unit.sh [src/scan_linux.zig ...]
# Env: ZIG_TARGET (default: musl for this host's CPU, which is the Docker host's), IMAGE (default debian:stable-slim).
set -eu

cd "$(dirname "$0")/.."
[ "$#" -gt 0 ] || set -- src/scan_linux.zig src/watch_linux.zig
case "$(uname -m)" in
arm64 | aarch64) arch=aarch64 ;;
*) arch=x86_64 ;;
esac
target=${ZIG_TARGET:-$arch-linux-musl}
image=${IMAGE:-debian:stable-slim}

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

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirsized-linux-unit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

for src in "$@"; do
    name=$(basename "$src" .zig)
    echo "== build $src ($target)"
    zig test "$src" -target "$target" -lc --test-no-exec -femit-bin="$tmp/${name}_test"
done

# Binaries are bind-mounted read-only; the tests work in the container's own /tmp (not a host mount).
# Zig's test tmpDir is created under the cwd (.zig-cache/tmp), so cwd is the container's /tmp.
for src in "$@"; do
    name=$(basename "$src" .zig)
    echo "== run $name in $image as 1000:1000"
    docker run --rm --user 1000:1000 -w /tmp \
        -v "$tmp/${name}_test:/test/${name}_test:ro" \
        "$image" "/test/${name}_test"
done
echo "== all passed"
