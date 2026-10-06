// cls: list classes+methods of SpaceAttribution whose names mention dirstat/maintain.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
int main(){@autoreleasepool{
 const char*img="/System/Library/PrivateFrameworks/SpaceAttribution.framework/Versions/A/SpaceAttribution";
 dlopen(img,RTLD_NOW); unsigned n; const char**names=objc_copyClassNamesForImage(img,&n); printf("%u classes\n",n);
 for(unsigned i=0;i<n;i++){Class c=objc_getClass(names[i]);
  for(int meta=0;meta<2;meta++){unsigned m;Method*l=class_copyMethodList(meta?object_getClass(c):c,&m);
   for(unsigned j=0;j<m;j++){const char*s=sel_getName(method_getName(l[j]));
    if(strcasestr(s,"dirstat")||strcasestr(s,"maintain")) printf("%s%s %s  enc=%s\n",meta?"+":"-",names[i],s,method_getTypeEncoding(l[j]));}}}
}}
