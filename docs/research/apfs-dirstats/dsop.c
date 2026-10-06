// dsop <maintain|get|set> <path> [val]: raw fsctl probes for APFS dir stats. SCRATCH PATHS ONLY for maintain/set.
//  maintain: fsctl(path, APFSIOC_MAINTAIN_DIR_STATS = 0x80084a02 [_IOW('J',2,u64)], &val)   (code decoded from SpaceAttribution/ContainerManagerCommon machine code)
//  get/set : fsctl(path, APFSIOC_DIR_STATS_OP = 0xc1104a71 [_IOWR('J',113,272 bytes)])  struct {u32 version=3; u32 op(0=get,1=set); u32 flags; ...}
// build: clang -o dsop dsop.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
int fsctl(const char*,unsigned long,void*,unsigned int);
int main(int c,char**v){
  const char*cmd=v[1],*p=v[2]; unsigned long long val=c>3?strtoull(v[3],0,0):1;
  if(!strcmp(cmd,"maintain")){ uint64_t x=val; int r=fsctl(p,0x80084a02,&x,0); printf("MAINTAIN val=%llu -> %d errno=%d (%s)\n",val,r,r?errno:0,r?strerror(errno):"ok"); return 0;}
  if(!strcmp(cmd,"bench")){ // bench <path> [N]: time N GETs, print last values
    int n=c>3?atoi(v[3]):1000; uint32_t b[68]; struct timespec t0,t1; int r=0; clock_gettime(CLOCK_MONOTONIC,&t0);
    for(int i=0;i<n;i++){memset(b,0,sizeof b);b[0]=3;b[2]=1;r=fsctl(p,0xc1104a71,b,0);} clock_gettime(CLOCK_MONOTONIC,&t1);
    uint64_t*q=(uint64_t*)b; double us=((t1.tv_sec-t0.tv_sec)*1e9+(t1.tv_nsec-t0.tv_nsec))/1e3/n;
    printf("bench %d GETs on %s: ret=%d, %.2f us/call, gen=%llu descendants=%llu physical=%llu\n",n,p,r,us,(unsigned long long)q[6],(unsigned long long)q[7],(unsigned long long)q[8]); return 0;}
  uint32_t b[68]; memset(b,0,sizeof b); b[0]=3; b[1]=!strcmp(cmd,"set"); b[2]=b[1]?(c>3?(uint32_t)val:0x1c):1;
  int r=fsctl(p,0xc1104a71,b,0); int e=errno;
  printf("DIR_STATS_OP %s -> %d errno=%d (%s)\n",cmd,r,r?e:0,r?strerror(e):"ok");
  if(!r){ printf("  raw u32:"); for(int i=0;i<68;i++){ if(i%8==0)printf("\n  [%02d]",i); printf(" %08x",b[i]);} puts("");
    uint64_t*q=(uint64_t*)b; printf("  u64 view:"); for(int i=0;i<12;i++)printf(" %llu",(unsigned long long)q[i]); puts("");}
}
