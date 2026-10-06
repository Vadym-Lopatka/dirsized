// findstr <needle> <glob-ish substring list...>: dlopen frameworks whose dir name contains a substring, then
// report which loaded image contains <needle> in its __TEXT,__cstring. build: clang -o findstr findstr.c
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
int main(int c,char**v){
  const char*dirs[]={"/System/Library/PrivateFrameworks","/System/Library/Frameworks",0};
  for(int d=0;dirs[d];d++){DIR*D=opendir(dirs[d]);struct dirent*e;while((e=readdir(D))){
    for(int i=2;i<c;i++) if(strcasestr(e->d_name,v[i])){char p[512];char n[256];snprintf(n,sizeof n,"%s",e->d_name);char*dot=strstr(n,".framework");if(dot)*dot=0;
      snprintf(p,sizeof p,"%s/%s/%s",dirs[d],e->d_name,n);dlopen(p,RTLD_LAZY);break;}}}
  for(uint32_t i=0;i<_dyld_image_count();i++){
    const struct mach_header_64*h=(void*)_dyld_get_image_header(i); unsigned long sz;
    char*s=(char*)getsegmentdata(h,"__TEXT",&sz); if(!s)continue;
    if(memmem(s,sz,v[1],strlen(v[1])))printf("FOUND in %s\n",_dyld_get_image_name(i));}
}
