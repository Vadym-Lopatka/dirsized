// Probe: which candidate symbols exist in libSystem (dlsym)?
#include <dlfcn.h>
#include <stdio.h>
int main(){const char*n[]={"dirstat_np","fsctl","ffsctl","getattrlistbulk","getattrlist","fgetattrlist","getattrlistat","apfs_dirstat","dirstat","fdirstat_np",0};
for(int i=0;n[i];i++)printf("%-18s %s\n",n[i],dlsym(RTLD_DEFAULT,n[i])?"FOUND":"absent");}
