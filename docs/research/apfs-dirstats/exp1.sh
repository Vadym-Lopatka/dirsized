#!/bin/bash
# exp1: dir-stats on a folder flagged while EMPTY; follow how GET changes. Scratch only.
cd "$(dirname "$0")"
M=/Volumes/dsscratch/e3
gt(){ echo "-- $1"; ./dsop get "$2" | grep "u64\|FAIL\|errno=[1-9]"; }
gt "initial (empty)" $M
for i in 1 2 3 4 5 6 7 8 9 10; do head -c 1000 /dev/zero | tr '\0' a > $M/f$i; done
gt "after 10 files x1000B" $M
mkdir $M/sub
gt "after mkdir sub (parent)" $M
gt "sub itself (inherited?)" $M/sub
for i in 1 2 3 4 5; do head -c 5000 /dev/zero | tr '\0' b > $M/sub/g$i; done
gt "after 5 files x5000B in sub (parent)" $M
gt "sub" $M/sub
cp -c $M/sub/g1 $M/clone1
gt "after clone (cp -c) of a 5000B file" $M
ln $M/f1 $M/hl1
gt "after hardlink of f1" $M
rm $M/f2
gt "after rm f2" $M
sync
echo "du -sk:"; du -sk $M
echo "ground truth:"; find $M -type f -exec stat -f %z {} + | awk '{s+=$1;n++}END{print "logical",s,"files",n}'
./ds $M 0
