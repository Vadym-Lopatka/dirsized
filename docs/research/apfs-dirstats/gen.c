// gen <root> <top> <sub> <files>: creates root/tNNN/sNN/fNNN with deterministic sizes (1..3000 bytes).
// Total files = top*sub*files. Prints total logical bytes. Use only under the scratch image.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
int main(int c,char**v){
  if(c<5)return 1; int T=atoi(v[2]),S=atoi(v[3]),F=atoi(v[4]); char p[1024]; static char buf[4096]; memset(buf,'x',sizeof buf);
  unsigned long long tot=0,n=0; mkdir(v[1],0755);
  for(int t=0;t<T;t++){snprintf(p,sizeof p,"%s/t%03d",v[1],t);mkdir(p,0755);
   for(int s=0;s<S;s++){snprintf(p,sizeof p,"%s/t%03d/s%02d",v[1],t,s);mkdir(p,0755);
    for(int f=0;f<F;f++){snprintf(p,sizeof p,"%s/t%03d/s%02d/f%03d",v[1],t,s,f);
     int fd=open(p,O_WRONLY|O_CREAT,0644); size_t sz=1+((t*131+s*31+f*7)%3000); write(fd,buf,sz); close(fd); tot+=sz;n++;}}}
  printf("files=%llu logical_bytes=%llu\n",n,tot);}
