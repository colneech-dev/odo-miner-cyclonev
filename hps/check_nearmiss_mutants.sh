#!/bin/sh
# check_nearmiss_mutants.sh -- NEGATIVE CONTROLS for test_near_miss.c, plus a wiring check.
# Recompiles the test against mutated copies of sw/near_miss.h; each must FAIL.
#   M1 the default ratio is no longer 0.1
#   M2 trailing garbage after a number is accepted
#   M3 the boundary is exclusive (> instead of >=)
#   M4 a zero / negative network difficulty can fire
#   M5 a ratio above 1 is accepted
# WIRING: miner_pipe.c must call near_miss_hit(d, nd, g_near_miss_ratio) in the find loop,
# or the header is tested and never used.
set -u
CC=${CC:-gcc}
HERE=$(cd "$(dirname "$0")" && pwd)
HDR=$HERE/near_miss.h
MINER=$HERE/miner_pipe.c
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tr -d '\r' < "$HDR" > "$W/orig.h"
rc=0
mut() {   # <name> <sed expression>
    mkdir -p "$W/$1"
    sed "$2" "$W/orig.h" > "$W/$1/near_miss.h"
    cp "$HERE/test_near_miss.c" "$W/$1/test_near_miss.c"     # same dir as the header: a quoted include looks there FIRST
    if cmp -s "$W/orig.h" "$W/$1/near_miss.h"; then echo "$1: mutation did not apply"; rc=1; return; fi
    if ! $CC -std=c11 -w -I"$W/$1" -o "$W/$1/t" "$W/$1/test_near_miss.c" -lm; then echo "$1: did not compile"; rc=1; return; fi
    if "$W/$1/t" | grep -q '^FAIL'; then echo "$1: detected by $("$W/$1/t" | grep '^FAIL' | sed 's/^FAIL *//; s/ .*//' | paste -sd'|' -)"
    else echo "$1: NOT detected -- test_near_miss is blind to it"; rc=1; fi
}
mut M1 's/#define NEAR_MISS_RATIO_DEFAULT 0.1/#define NEAR_MISS_RATIO_DEFAULT 0.5/'
mut M2 "s/if (\*end != '\\\\0' || /if (/"
mut M3 's/return d >= ratio \* net_diff;/return d > ratio * net_diff;/'
mut M4 's/if (!(net_diff > 0.0) || !(d > 0.0))/if (0)/'
mut M5 's/ || v > 1.0)/)/'
if tr -d '\r' < "$MINER" | grep -q 'near_miss_hit(d, nd, g_near_miss_ratio)'; then echo "W1: miner_pipe.c calls near_miss_hit in the find loop"
else echo "W1: miner_pipe.c does NOT call near_miss_hit(d, nd, g_near_miss_ratio) in the find loop"; rc=1; fi
exit $rc
