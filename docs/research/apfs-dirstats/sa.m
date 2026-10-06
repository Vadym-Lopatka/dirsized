// sa <enable|get|enableget> <path> [options]: call private SpaceAttribution +[SASupport ...] dir-stats methods.
// Signatures from objc type encodings (i44@0:8@16i24q28^{?=QQQQQ}36): (NSString *path, int fd, int64 options, uint64_t info[5]) -> int.
// Run with DYLD_INSERT_LIBRARIES=./libtrace.dylib to log fsctl codes. Scratch paths only.
// build: clang -fobjc-arc -framework Foundation -o sa sa.m
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(int c,char**v){ @autoreleasepool{
 dlopen("/System/Library/PrivateFrameworks/SpaceAttribution.framework/SpaceAttribution",RTLD_NOW);
 Class k=objc_getClass("SASupport"); NSString*p=[NSString stringWithUTF8String:v[2]]; long long opt=c>3?atoll(v[3]):0;
 uint64_t info[5]={0}; int r;
 if(!strcmp(v[1],"enable")) r=((int(*)(Class,SEL,id,int,long long))objc_msgSend)(k,sel_registerName("enableDirStatsForPath:orFD:withOptions:"),p,-1,opt);
 else if(!strcmp(v[1],"enableget")) r=((int(*)(Class,SEL,id,int,long long,void*))objc_msgSend)(k,sel_registerName("enableDirStatInfoForPath:orFD:withOptions:andGetInfo:"),p,-1,opt,info);
 else r=((int(*)(Class,SEL,id,int,long long,void*))objc_msgSend)(k,sel_registerName("getDirStatInfoForPath:orFD:withOptions:info:"),p,-1,opt,info);
 printf("%s opt=%lld -> ret=%d info={%llu,%llu,%llu,%llu,%llu}\n",v[1],opt,r,info[0],info[1],info[2],info[3],info[4]);
}}
