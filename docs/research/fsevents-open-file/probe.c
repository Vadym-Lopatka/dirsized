// Does FSEvents report a change while a file is still open, or only at close?
// build: clang -O2 -framework CoreServices -o probe probe.c    run: ./probe [file-events]
// Watches a fresh temp folder with folder-level events (default) or file-level events,
// then writes to one file in steps and prints when each event arrives.
#include <CoreServices/CoreServices.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static double t0;
static const char *phase = "start";
static double now(void) { return CFAbsoluteTimeGetCurrent() - t0; }

static void cb(ConstFSEventStreamRef s, void *info, size_t n, void *paths,
               const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    char **p = paths;
    for (size_t i = 0; i < n; i++)
        printf("  %6.2fs EVENT during [%s] flags=0x%05x %s\n", now(), phase, (unsigned)flags[i],
               strrchr(p[i], '/') ? strrchr(p[i], '/') : p[i]);
    fflush(stdout);
}

static void step(const char *name) { phase = name; printf("%6.2fs %s\n", now(), name); fflush(stdout); }

int main(int argc, char **argv) {
    int file_events = argc > 1 && !strcmp(argv[1], "file-events");
    char dir[] = "/tmp/fseprobe.XXXXXX";
    if (!mkdtemp(dir)) return 1;
    char real[1024]; realpath(dir, real);
    CFStringRef path = CFStringCreateWithCString(NULL, real, kCFStringEncodingUTF8);
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)&path, 1, &kCFTypeArrayCallBacks);
    FSEventStreamCreateFlags fl = kFSEventStreamCreateFlagNoDefer | (file_events ? kFSEventStreamCreateFlagFileEvents : 0);
    FSEventStreamRef s = FSEventStreamCreate(NULL, cb, NULL, arr, kFSEventStreamEventIdSinceNow, 0.1, fl);
    FSEventStreamSetDispatchQueue(s, dispatch_queue_create("probe", NULL));
    FSEventStreamStart(s);
    t0 = CFAbsoluteTimeGetCurrent();
    printf("mode: %s, folder %s\n", file_events ? "file events" : "folder events", real);
    sleep(1);

    char f[1100]; snprintf(f, sizeof f, "%s/log", real);
    static char buf[1 << 20]; memset(buf, 'x', sizeof buf);
    step("create file, keep it open");
    int fd = open(f, O_CREAT | O_WRONLY, 0644); sleep(3);
    step("write 1 MB, still open");
    write(fd, buf, sizeof buf); sleep(4);
    step("write 1 MB more, still open");
    write(fd, buf, sizeof buf); sleep(4);
    step("fsync, still open");
    fsync(fd); sleep(4);
    struct stat st; stat(f, &st);
    printf("        (stat now says %lld bytes)\n", (long long)st.st_size);
    step("write 1 MB more, wait 20 s, still open");
    write(fd, buf, sizeof buf); sleep(20);
    step("close");
    close(fd); sleep(3);
    step("append 1 MB with open+write+close");
    fd = open(f, O_WRONLY | O_APPEND); write(fd, buf, sizeof buf); close(fd); sleep(3);
    step("done");
    FSEventStreamStop(s); FSEventStreamInvalidate(s);
    unlink(f); rmdir(real);
    return 0;
}
