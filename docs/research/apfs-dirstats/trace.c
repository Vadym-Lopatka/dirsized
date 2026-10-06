// DYLD_INSERT_LIBRARIES shim: logs fsctl/ffsctl/fsctlat/getattrlist* calls (request code, size) to stderr, then forwards.
// build: clang -dynamiclib -o libtrace.dylib trace.c
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
int fsctl(const char*,unsigned long,void*,unsigned int);
int ffsctl(int,unsigned long,void*,unsigned int);
#define INTERPOSE(n) __attribute__((used)) static struct{const void*a;const void*b;} _ip_##n __attribute__((section("__DATA,__interpose"))) = {(const void*)my_##n,(const void*)n}
static int my_fsctl(const char*p,unsigned long r,void*d,unsigned int o){
  unsigned char pre[32]={0}; if(d&&(r&0x1fff0000)){unsigned len=(r>>16)&0x1fff; if(len>32)len=32; for(unsigned i=0;i<len;i++)pre[i]=((unsigned char*)d)[i];}
  {unsigned len=(r>>16)&0x1fff; if(len>64)len=64; fprintf(stderr,"[trace]   data before:"); for(unsigned i=0;d&&i<len;i++)fprintf(stderr," %02x",((unsigned char*)d)[i]); fprintf(stderr,"\n");}
  int rc=fsctl(p,r,d,o); int e=errno; fprintf(stderr,"[trace] fsctl(%s, 0x%lx [dir=%lu grp='%c' nr=%lu len=%lu], opts=%u) -> %d errno=%d\n",p,r,r>>29,(char)((r>>8)&0xff),r&0xff,(r>>16)&0x1fff,o,rc,rc?e:0);
  fprintf(stderr,"[trace]   data after:");{unsigned len=(r>>16)&0x1fff; if(len>64)len=64; for(unsigned i=0;d&&i<len;i++)fprintf(stderr," %02x",((unsigned char*)d)[i]);} fprintf(stderr,"\n"); errno=e; return rc;}
static int my_ffsctl(int fd,unsigned long r,void*d,unsigned int o){
  int rc=ffsctl(fd,r,d,o); int e=errno; fprintf(stderr,"[trace] ffsctl(fd=%d, 0x%lx [grp='%c' nr=%lu len=%lu], opts=%u) -> %d errno=%d\n",fd,r,(char)((r>>8)&0xff),r&0xff,(r>>16)&0x1fff,o,rc,rc?e:0);
  fprintf(stderr,"[trace]   data after:");{unsigned len=(r>>16)&0x1fff; if(len>64)len=64; for(unsigned i=0;d&&i<len;i++)fprintf(stderr," %02x",((unsigned char*)d)[i]);} fprintf(stderr,"\n"); errno=e; return rc;}
INTERPOSE(fsctl);
INTERPOSE(ffsctl);
// also log ioctl (variadic: assume one pointer arg) and open/openat paths
#include <stdarg.h>
#include <fcntl.h>
#include <sys/ioctl.h>
static int my_ioctl(int fd,unsigned long r,...){va_list a;va_start(a,r);void*p=va_arg(a,void*);va_end(a);int rc=ioctl(fd,r,p);int e=errno;fprintf(stderr,"[trace] ioctl(fd=%d,0x%lx grp='%c' nr=%lu len=%lu)->%d errno=%d\n",fd,r,(char)((r>>8)&0xff),r&0xff,(r>>16)&0x1fff,rc,rc?e:0);errno=e;return rc;}
INTERPOSE(ioctl);
