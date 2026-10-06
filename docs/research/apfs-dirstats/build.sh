#!/bin/sh
# Build all probes with one command: ./build.sh
set -e
cd "$(dirname "$0")"
clang -O2 -o gen gen.c            # tree generator (scratch only)
clang -O2 -o probe probe.c        # dirstat_np / getattrlist / stat probe (read-only)
clang -o ds ds.c                  # minimal dirstat_np caller
clang -o dlprobe dlprobe.c        # dlsym presence check
clang -o dsop dsop.c              # raw APFSIOC fsctl probe: maintain|get|set|bench
clang -dynamiclib -o libtrace.dylib trace.c   # fsctl/ioctl logging shim (DYLD_INSERT_LIBRARIES)
clang -fobjc-arc -framework Foundation -o sa sa.m        # calls private +[SASupport ...]
clang -fobjc-arc -framework Foundation -o cls cls.m      # lists SpaceAttribution methods
clang -fobjc-arc -framework Foundation -o findsa findsa.m
clang -o findstr findstr.c        # which image contains a string
clang -o scan2 scan2.c            # decode ioctl codes from arm64 MOVZ/MOVK
