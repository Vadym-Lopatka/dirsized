// probe <dir>: queries every directory-size candidate on <dir>, with timing. Read-only.
// build: clang -O2 -o probe probe.c
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/stat.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
typedef int (*dsfn)(const char*, uint64_t, void*, size_t);
static void try_dirstat(const char*p,uint64_t fl){
  dsfn f=(dsfn)dlsym(RTLD_DEFAULT,"dirstat_np"); uint64_t b[8]={0}; double t=now();
  int r=f(p,fl,b,sizeof b); t=now()-t;
  if(r)printf("dirstat_np flags=%llu: FAIL errno=%d (%s) %.3f ms\n",fl,errno,strerror(errno),t);
  else printf("dirstat_np flags=%llu: total_size=%llu descendants=%llu  %.3f ms\n",fl,b[0],b[1],t);
}
int main(int c,char**v){
  const char*p=v[1];
  try_dirstat(p,0); try_dirstat(p,1); try_dirstat(p,2); try_dirstat(p,3);
  // getattrlist directory attrs
  struct attrlist al; memset(&al,0,sizeof al); al.bitmapcount=ATTR_BIT_MAP_COUNT;
  al.dirattr=ATTR_DIR_LINKCOUNT|ATTR_DIR_ENTRYCOUNT|ATTR_DIR_ALLOCSIZE|ATTR_DIR_IOBLOCKSIZE|ATTR_DIR_DATALENGTH;
  struct {uint32_t len; attribute_set_t ret; uint32_t v[8];} __attribute__((packed)) buf;
  al.commonattr=ATTR_CMN_RETURNED_ATTRS;
  memset(&buf,0,sizeof buf); double t=now();
  int r=getattrlist(p,&al,&buf,sizeof buf,FSOPT_PACK_INVAL_ATTRS); t=now()-t;
  if(r)printf("getattrlist dirattr: FAIL errno=%d %s\n",errno,strerror(errno));
  else{ printf("getattrlist dirattr: returned dirattr=0x%x (asked 0x%x) %.3f ms:",buf.ret.dirattr,al.dirattr,t);
    int k=0; for(uint32_t bit=1;bit<=0x20;bit<<=1) if(buf.ret.dirattr&bit&al.dirattr) printf(" [attr 0x%x]=%u",bit,buf.v[k++]); puts(""); }
  // ATTR_CMN_EXT private size / clone attrs via forkattr
  struct attrlist a2; memset(&a2,0,sizeof a2); a2.bitmapcount=ATTR_BIT_MAP_COUNT; a2.commonattr=ATTR_CMN_RETURNED_ATTRS; a2.forkattr=ATTR_CMNEXT_PRIVATESIZE|ATTR_CMNEXT_RECURSIVE_GENCOUNT|ATTR_CMNEXT_EXT_FLAGS;
  struct {uint32_t len; attribute_set_t ret; uint64_t v[4];} __attribute__((packed)) b2; memset(&b2,0,sizeof b2);
  r=getattrlist(p,&a2,&b2,sizeof b2,FSOPT_ATTR_CMN_EXTENDED|FSOPT_PACK_INVAL_ATTRS);
  if(r)printf("getattrlist cmnext: FAIL errno=%d %s\n",errno,strerror(errno));
  else printf("getattrlist cmnext: returned forkattr=0x%x (asked 0x%x) vals=%llu %llu %llu\n",b2.ret.forkattr,a2.forkattr,b2.v[0],b2.v[1],b2.v[2]);
  struct stat st; stat(p,&st); printf("stat: st_size=%lld st_blocks=%lld (x512=%lld) nlink=%d\n",(long long)st.st_size,(long long)st.st_blocks,(long long)st.st_blocks*512,st.st_nlink);
}
