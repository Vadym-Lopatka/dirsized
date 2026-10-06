// scan2 <framework-path>...: dlopen each, decode MOVZ/MOVK pairs in __TEXT forming _IO*('J',nr,len) codes (APFS group), print unique ones with counts.
// build: clang -o scan2 scan2.c
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
int main(int c,char**v){
 for(int a=1;a<c;a++){dlopen(v[a],RTLD_LAZY);
  for(uint32_t i=0;i<_dyld_image_count();i++){ if(strcmp(_dyld_get_image_name(i),v[a]))continue;
   const struct mach_header_64*h=(void*)_dyld_get_image_header(i); unsigned long sz; uint32_t*b=(uint32_t*)getsegmentdata(h,"__TEXT",&sz);
   printf("== %s\n",v[a]); uint32_t seen[64];int ns=0,cnt[64]={0};
   for(unsigned long k=0;k+1<sz/4;k++){uint32_t w=b[k]; if((w&0xffe00000)!=0x52800000)continue; uint32_t imm=(w>>5)&0xffff,rd=w&31; if((imm&0xff00)!=0x4a00)continue;
     uint32_t n=b[k+1]; if((n&0xffe00000)!=0x72a00000||(n&31)!=rd)continue; uint32_t code=(((n>>5)&0xffff)<<16)|imm; int f=-1;for(int j=0;j<ns;j++)if(seen[j]==code)f=j; if(f<0&&ns<64){seen[ns]=code;f=ns++;} if(f>=0)cnt[f]++;}
   for(int j=0;j<ns;j++)printf("  0x%08x dir=%u nr=%u len=%u x%d\n",seen[j],seen[j]>>29,seen[j]&0xff,(seen[j]>>16)&0x1fff,cnt[j]);}}}
