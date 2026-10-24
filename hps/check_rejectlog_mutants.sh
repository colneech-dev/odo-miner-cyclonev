#!/bin/sh
# check_rejectlog_mutants.sh -- NEGATIVE CONTROLS for test_reject_log.c, plus wiring checks on the miner.
# Recompiles the test against mutated copies of sw/reject_log.h; each must FAIL.
#   M1 the ring matches a slot without checking the id (an overwritten id is mistaken for a new one)
#   M2 the array-shape error ([21,"Job not found",null]) code is no longer read
#   M3 the reason is not made safe: double quotes survive into the one-line field
#   M4 the age is computed backwards (then - now)
#   M5 the object-shape code is no longer read
# WIRING (the helper is tested and never used otherwise), all in miner_pipe.c:
#   W1 install_stratum_hooks() is called after BOTH stratum_init() sites (stratum_init memsets the context)
#   W2 shares are submitted only through submit_tracked() (no bare stratum_submit_share(&st, ...) elsewhere)
#   W3 on_submit_result() persists to PIPE_REJECT_PATH
set -u
CC=${CC:-gcc}
HERE=$(cd "$(dirname "$0")" && pwd)
HDR=$HERE/reject_log.h
MINER=$HERE/miner_pipe.c
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tr -d '\r' < "$HDR" > "$W/orig.h"
rc=0
mut() {   # <name> <sed expression>
    mkdir -p "$W/$1"
    sed "$2" "$W/orig.h" > "$W/$1/reject_log.h"
    cp "$HERE/test_reject_log.c" "$W/$1/test_reject_log.c"     # same dir as the header: a quoted include looks there FIRST
    if cmp -s "$W/orig.h" "$W/$1/reject_log.h"; then echo "$1: mutation did not apply"; rc=1; return; fi
    if ! $CC -std=c11 -w -I"$W/$1" -o "$W/$1/t" "$W/$1/test_reject_log.c"; then echo "$1: did not compile"; rc=1; return; fi
    if "$W/$1/t" | grep -q '^FAIL'; then echo "$1: detected by $("$W/$1/t" | grep '^FAIL' | sed 's/^FAIL *//; s/ .*//' | paste -sd'|' -)"
    else echo "$1: NOT detected -- test_reject_log is blind to it"; rc=1; fi
}
mut M1 's/return (s->used \&\& s->id == id) ? s : NULL;/return s->used ? s : NULL;/'
mut M2 's/if (end != q) \*code = v;/(void)v;/'
mut M3 "s/(c == '\"' ? '\\\\'' : ' ')/'\"'/"
mut M4 's/(long)(now - rec->t)/(long)(rec->t - now)/'
mut M5 's/if (cc) \*code = strtol(cc + 1, NULL, 10);/(void)cc;/'
M=$W/miner.c
tr -d '\r' < "$MINER" > "$M"
n=$(grep -c 'install_stratum_hooks(&st);' "$M")
# the call after BOTH stratum_init() sites (startup and the failover to the backup pool)
if [ "$n" = 2 ]; then echo "W1: hooks installed after both stratum_init sites"
else echo "W1: install_stratum_hooks(&st) appears $n times, want 2 (one per stratum_init site)"; rc=1; fi
bare=$(grep -n 'stratum_submit_share(' "$M" | grep -v 'static int submit_tracked' | grep -v 'int rc = stratum_submit_share(st, job, nonce);' | grep -v '^[0-9]*: *[/*]' | wc -l)
if [ "$bare" = 0 ]; then echo "W2: every share goes through submit_tracked()"
else echo "W2: $bare bare stratum_submit_share() call(s) bypass the submit ring"; rc=1; fi
if grep -q 'reject_persist(text);' "$M" && grep -q 'PIPE_REJECT_PATH' "$M"; then echo "W3: rejects are persisted to PIPE_REJECT_PATH"
else echo "W3: on_submit_result does not persist"; rc=1; fi
exit $rc
