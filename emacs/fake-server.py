#!/usr/bin/env python3
"""Fake dirsized daemon for the tests of dirsized.el (stdlib only).

Speaks protocol version 1 on a Unix socket and answers `list`, `size` and
`status` by walking a real directory tree.  Sizes are the sum of the regular
files below a folder (symlinks are not followed).

Options:
  --chunk N        send the answer in pieces of N bytes (0 = one piece)
  --chunk-sleep S  pause between pieces, seconds (default 0.002)
  --delay S        wait S seconds before each answer
  --state NAME=ST  folders with this base name get state ST (repeatable)
  --exact-case     a path must match the case on disk, else state none
  --log FILE       append every request, one per line (repr of the bytes)
"""
import argparse
import os
import socket
import sys
import threading
import time

args = None


def tree_size(path):
    total = 0
    try:
        with os.scandir(path) as it:
            for e in it:
                try:
                    if e.is_symlink():
                        continue
                    if e.is_dir(follow_symlinks=False):
                        total += tree_size(e.path)
                    elif e.is_file(follow_symlinks=False):
                        total += e.stat(follow_symlinks=False).st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total


def exact_case(path):
    cur = b"/"
    for comp in path.split(b"/"):
        if not comp:
            continue
        try:
            if comp not in os.listdir(cur):
                return False
        except OSError:
            return False
        cur = os.path.join(cur, comp)
    return True


def state_of(name):
    return args.states.get(os.path.basename(name), b"ok")


def record(size, state, name):
    return b"%d\t%s\t%s\0" % (size, state, name)


def answer(req):
    if req == b"status":
        pairs = [(b"proto", b"1"), (b"version", b"fake"),
                 (b"pid", str(os.getpid()).encode()),
                 (b"state", b"ok"), (b"folders", b"0")]
        return b"".join(k + b"\t" + v + b"\0" for k, v in pairs) + b"\0"
    verb, sep, path = req.partition(b" ")
    if not sep or verb not in (b"size", b"list") or not path.startswith(b"/"):
        return b"!\tbad-request\tbad request\0\0"
    if len(path) > 1 and path.endswith(b"/"):
        path = path[:-1]
    exists = os.path.isdir(path) and not os.path.islink(path)
    if exists and args.exact_case and not exact_case(path):
        exists = False
    if verb == b"size":
        if not exists:
            return record(0, b"none", path) + b"\0"
        return record(tree_size(path), state_of(path), path) + b"\0"
    if not exists:
        return record(0, b"none", b".") + b"\0"
    out = [record(tree_size(path), state_of(path), b".")]
    with os.scandir(path) as it:
        for e in it:
            if e.is_dir(follow_symlinks=False):
                out.append(record(tree_size(e.path), state_of(e.name), e.name))
    out.append(b"\0")
    return b"".join(out)


def send(conn, data):
    if args.chunk <= 0:
        conn.sendall(data)
        return
    for i in range(0, len(data), args.chunk):
        conn.sendall(data[i:i + args.chunk])
        time.sleep(args.chunk_sleep)


def serve(conn):
    buf = b""
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            buf += data
            while b"\0" in buf:
                req, _, buf = buf.partition(b"\0")
                if args.log:
                    with open(args.log, "a") as f:
                        f.write(repr(req) + "\n")
                if args.delay:
                    time.sleep(args.delay)
                send(conn, answer(req))
    except OSError:
        pass
    finally:
        conn.close()


def main():
    global args
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("--chunk", type=int, default=0)
    ap.add_argument("--chunk-sleep", type=float, default=0.002)
    ap.add_argument("--delay", type=float, default=0)
    ap.add_argument("--state", action="append", default=[])
    ap.add_argument("--exact-case", action="store_true")
    ap.add_argument("--log")
    args = ap.parse_args()
    args.states = {}
    for s in args.state:
        k, _, v = s.partition("=")
        args.states[os.fsencode(k)] = v.encode()
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    srv.listen(8)
    print("ready", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
