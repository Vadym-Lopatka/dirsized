// Try dirstat_np (not in SDK; resolved via dlsym). Guessed signature, see REPORT.
// build: clang -o ds ds.c ; run: ./ds <path> [flags]
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <time.h>
typedef int (*fn_t)(const char*, uint64_t, void*, size_t);
int main(int c,char**v){
  fn_t f=(fn_t)dlsym(RTLD_DEFAULT,"dirstat_np"); if(!f){puts("no sym");return 1;}
  uint64_t buf[16]; memset(buf,0xAB,sizeof buf);
  unsigned long fl=c>2?strtoul(v[2],0,0):0;
  struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);
  int r=f(v[1],fl,buf,sizeof buf);
  clock_gettime(CLOCK_MONOTONIC,&b);
  printf("ret=%d errno=%d(%s) %.3f ms\n",r,r?errno:0,r?strerror(errno):"",(b.tv_sec-a.tv_sec)*1e3+(b.tv_nsec-a.tv_nsec)/1e6);
  for(int i=0;i<6;i++)printf(" [%d]=0x%llx (%llu)\n",i,buf[i],buf[i]);
}
