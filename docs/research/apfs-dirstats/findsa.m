// Locate which image hosts SASupport and dump the IMP address for the dirstat methods.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
int main(){ @autoreleasepool{
 const char*fw[]={"StorageManagement","StorageKit","StorageManagementService","DiskManagement","StorageUI",0};
 for(int i=0;fw[i];i++){char p[256];snprintf(p,sizeof p,"/System/Library/PrivateFrameworks/%s.framework/%s",fw[i],fw[i]);dlopen(p,RTLD_NOW);}
 Class c=objc_getClass("SASupport"); printf("class=%p\n",c);
 if(c){ unsigned n; Method*m=class_copyMethodList(object_getClass(c),&n); for(unsigned i=0;i<n;i++){ IMP im=method_getImplementation(m[i]); Dl_info d; dladdr((void*)im,&d); printf("%s %p %s\n",sel_getName(method_getName(m[i])),im,d.dli_fname);} }
}}
