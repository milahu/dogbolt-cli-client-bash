# dogbolt CLI client in bash

upload an executable binary file to dogbolt.org  
and download all decompiled source files to src/

issue: https://github.com/decompiler-explorer/decompiler-explorer/issues/130

## example output

```sh
echo '#include <stdio.h>'$'\n''int main() { printf("hello '$RANDOM'\n"); return 0; }' | tee test.c
gcc -o test test.c
./dogbolt.sh test
```

```
binary path: test
binary size: 15760
binary hash: sha256:8c307ffd4198b34b5bdc5ad93ebb9606ff92a8154e9c558898d2c19172be70bf
uploading binary
binary id: 874c5de3-a98d-40d4-bae3-14ce5cadbe69
fetching decompiler names
decompiler names: BinaryNinja Boomerang Ghidra Hex-Rays RecStudio Reko Relyze RetDec Snowman angr dewolf
fetching results
writing src/boomerang-0.5.2/error.txt
writing src/recstudio-4.1/test.c
fetched 2 of 11 results. retrying in 20 seconds
fetching results
writing src/binary-ninja-3.5.4526/test.c
writing src/reko-0.11.2.0/test.c
fetched 4 of 11 results. retrying in 20 seconds
fetching results
writing src/hex-rays-8.3.0.230608/test.c
writing src/dewolf-0.1.3/error.txt
fetched 6 of 11 results. retrying in 20 seconds
fetching results
writing src/snowman-0.1.2-21/test.cpp
writing src/retdec-4.0-446/test.c
fetched 8 of 11 results. retrying in 20 seconds
fetching results
writing src/ghidra-10.3.3/test.c
writing src/relyze-3.7.0/test.c
writing src/angr-9.2.70/test.c
fetched all results
```
