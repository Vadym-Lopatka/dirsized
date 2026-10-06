#!/bin/bash
# exp2: semantics of APFS dir stats (clone, hardlink, sparse, compressed, move, rename, nesting). Scratch only.
cd "$(dirname "$0")"
S=/Volumes/dsscratch/sem; rm -rf $S; mkdir $S; ./dsop maintain $S 1 >/dev/null
OUT=/Volumes/dsscratch/outside; rm -rf $OUT; mkdir $OUT
st(){ printf "%-46s" "$1"; ./dsop bench $S 1 | sed 's/.*ret=0, [0-9.]* us\/call, //'; }
echo "inode of $S: $(stat -f %i $S)"; ./dsop get $S | grep u64
st "empty"
head -c 10000000 /dev/urandom > $S/big10M; st "add 10 MB random file (logical 10000000)"
cp -c $S/big10M $S/clone10M; st "cp -c clone of 10 MB file"
./dsop get $S | grep u64
cp $S/big10M $S/copy10M; st "cp (real copy) of 10 MB file"
ln $S/big10M $S/hl10M; st "hardlink of 10 MB file"
ln -s $S/big10M $S/sym; st "symlink"
truncate -s 1000000000 $S/sparse1G; st "sparse file, logical 1 GB, nothing written"
yes "compressible text line" | head -c 5000000 > $OUT/text5M; ditto --hfsCompression $OUT/text5M $S/comp5M; ls -lO $S/comp5M | awk '{print "   flags:",$5,"logical",$6}'; st "ditto --hfsCompression of 5 MB text (logical 5000000)"
echo "du -sk (allocated KB): $(du -sk $S | cut -f1)   (clone/hardlink/compression per du)"
mkdir $S/d1; head -c 3000000 /dev/urandom > $S/d1/x3M; st "add folder d1 with 3 MB file"
mv $S/d1 $OUT/d1; st "mv d1 OUT of flagged folder"
mv $OUT/d1 $S/d1; st "mv d1 back IN"
mkdir $OUT/d2; head -c 2000000 /dev/urandom > $OUT/d2/y2M; mv $OUT/d2 $S/d2; st "mv a populated folder (2 MB) in from outside"
mv $S/d2 $S/d2renamed; st "rename d2 within"
echo "--- nested flag: flag subfolder d1 as well"; ./dsop maintain $S/d1 1; ./dsop bench $S/d1 1; st "parent after"
echo "--- copy a flagged folder (cp -R): is the copy flagged?"; cp -R $S $OUT/copyofS; ./dsop get $OUT/copyofS | head -1
echo "--- rename the flagged folder itself"; mv $S ${S}_r; ./dsop bench ${S}_r 1; mv ${S}_r $S
echo "--- chmod/ownership: extra file inside flagged without write perms"; echo ok
