# stale.py: does GET lag behind unflushed writes? (scratch only)
import os,subprocess
M="/Volumes/dsscratch/h"
def g(tag):
    out=subprocess.run(["./dsop","bench",M,"1"],capture_output=True,text=True).stdout
    print(f"{tag:42s}",out.split("us/call, ")[1].strip())
fd=os.open(M+"/f",os.O_WRONLY|os.O_CREAT)
g("created, 0 bytes written")
os.write(fd,b"a"*50_000_000); g("50 MB written, fd open, no fsync")
os.fsync(fd); g("after fsync")
os.ftruncate(fd,10_000_000); g("ftruncate to 10 MB")
os.close(fd); g("closed")
os.unlink(M+"/f"); g("unlinked")
fd=os.open(M+"/f2",os.O_WRONLY|os.O_CREAT); os.write(fd,b"a"*1000000); os.unlink(M+"/f2"); g("unlinked while still open (fd held)")
os.close(fd); g("fd closed")
