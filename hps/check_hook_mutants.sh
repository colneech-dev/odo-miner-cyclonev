#!/bin/sh
# check_hook_mutants.sh -- NEGATIVE CONTROLS for test_stratum_hook.c.
# Each is a mutated COPY of stratum.c compiled against the same test; every one must FAIL:
#   M1 the hook is never called
#   M2 the accepted flag is inverted
#   M3 the hook gets the wrong request id (id + 1)
#   M4 a reject is no longer counted in shares_rejected
set -u
CC=${CC:-gcc}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
build() {   # <dir> <stratum.c to use>
    $CC -std=c11 -D_DEFAULT_SOURCE -w -I"$HERE" -o "$1/t" "$HERE/test_stratum_hook.c" "$2" \
        "$HERE/job.c" "$HERE/odocrypt_header.c" -lm 2>"$1/cc.log" || { cat "$1/cc.log"; return 1; }
}
tr -d '\r' < "$HERE/stratum.c" > "$W/stratum_lf.c"
build "$W" "$W/stratum_lf.c" || exit 2
"$W/t" >/dev/null 2>&1 || { echo "the unmutated test fails"; exit 1; }
rc=0
mut() {   # <name> <sed expr>
    mkdir -p "$W/$1"
    sed "$2" "$W/stratum_lf.c" > "$W/$1/stratum.c"
    cmp -s "$W/$1/stratum.c" "$W/stratum_lf.c" && { echo "$1: mutation did not apply"; rc=1; return; }
    build "$W/$1" "$W/$1/stratum.c" || { rc=1; return; }
    if "$W/$1/t" 2>/dev/null | grep -q '^FAIL'; then echo "$1: detected by $("$W/$1/t" 2>/dev/null | grep '^FAIL' | cut -d' ' -f2 | paste -sd'|' -)"
    else echo "$1: NOT detected"; rc=1; fi
}
mut M1 's/if (ctx->on_submit_result)$/if (0)/'
mut M2 's/ctx->on_submit_result_user, id, ok, line);/ctx->on_submit_result_user, id, !ok, line);/'
mut M3 's/ctx->on_submit_result_user, id, ok, line);/ctx->on_submit_result_user, id + 1, ok, line);/'
mut M4 's/^\( *\)ctx->shares_rejected++;/\1(void)0;/'
exit $rc
