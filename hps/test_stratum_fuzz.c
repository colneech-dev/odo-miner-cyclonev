/* test_stratum_fuzz.c — malformed-input regression for the hand-rolled Stratum
 * parser. The pool is an untrusted network peer; this asserts the parser rejects
 * (or at least never crashes / corrupts memory on) garbage, especially the cases
 * hardened in the 2026-06-28 review pass: parse_hex_u32 length bound, NaN
 * difficulty, overlong extranonce1 / >32 merkle branches, coinb2 check.
 *
 * The handlers are static, so we #include the .c directly. Build with ASan to
 * catch any out-of-bounds read in find_json_key / the hex scanners:
 *   make test_stratum_fuzz   (see hps/Makefile; adds -fsanitize=address)
 */
#include "stratum.c"   /* pulls in the static handlers + parse_hex_u32 */

#include <assert.h>
#include <math.h>

static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { \
    fprintf(stderr, "FAIL: %s\n", (msg)); fails++; } } while (0)

static void reset_ctx(stratum_ctx_t *c)
{
    stratum_init(c, "h", "1", "u", "p");
    c->extranonce1_len  = 4;
    c->extranonce2_size = 4;
    c->subscribed = true;
}

int main(void)
{
    stratum_ctx_t ctx;

    /* ---- parse_hex_u32 boundary table ---- */
    uint32_t v = 0xdeadbeef;
    CHECK(parse_hex_u32("", &v) == -1,            "empty hex must reject");
    CHECK(parse_hex_u32("g", &v) == -1,           "non-hex must reject");
    CHECK(parse_hex_u32("123456789", &v) == -1,   "9 hex digits (overflow) must reject");
    CHECK(parse_hex_u32("1d00ffff", &v) == 0 && v == 0x1d00ffff, "8 digits ok");
    CHECK(parse_hex_u32("0", &v) == 0 && v == 0,  "single 0 ok");
    CHECK(parse_hex_u32("ffffffff", &v) == 0 && v == 0xffffffff, "max u32 ok");

    /* ---- handle_set_difficulty: non-finite / non-positive must not poison ---- */
    reset_ctx(&ctx);
    ctx.difficulty = 1.0;
    handle_set_difficulty(&ctx, "[nan]");
    CHECK(isfinite(ctx.difficulty) && ctx.difficulty > 0.0, "NaN difficulty rejected");
    handle_set_difficulty(&ctx, "[1e400]");   /* overflow -> inf */
    CHECK(isfinite(ctx.difficulty) && ctx.difficulty > 0.0, "inf difficulty rejected");
    handle_set_difficulty(&ctx, "[-5]");
    CHECK(ctx.difficulty > 0.0, "negative difficulty rejected");
    handle_set_difficulty(&ctx, "[0]");
    CHECK(ctx.difficulty > 0.0, "zero difficulty rejected");
    handle_set_difficulty(&ctx, "[1024.5]");
    CHECK(ctx.difficulty == 1024.5, "valid difficulty accepted");

    /* ---- handle_notify: malformed params must reject (-1), never crash ---- */
    const char *bad_notify[] = {
        "[]",                                            /* empty */
        "[\"j\"",                                        /* truncated */
        "[\"j\",\"\",\"\",\"\",[],\"\",\"\",\"\",true]", /* empty hex fields */
        "[\"j\",\"00\",\"00\",\"00\",[],\"zzzzzzzz\",\"1d00ffff\",\"5f5e1000\",true]", /* non-hex version */
        "[\"j\",\"00\",\"00\",\"00\",[],\"000000000\",\"1d00ffff\",\"5f5e1000\",true]", /* 9-digit version */
        /* prevhash wrong length (not 64 hex) -> reject */
        "[\"j\",\"00\",\"00\",\"00\",[],\"00000001\",\"1d00ffff\",\"5f5e1000\",true]",
        NULL
    };
    for (int i = 0; bad_notify[i]; i++) {
        reset_ctx(&ctx);
        int r = handle_notify(&ctx, bad_notify[i]);
        CHECK(r == -1, bad_notify[i]);   /* every one must be rejected */
    }

    /* >32 merkle branches must reject (truncation -> wrong root), not accept */
    {
        reset_ctx(&ctx);
        char big[4096];
        size_t o = 0;
        /* valid-looking prefix with a 64-hex prevhash, then 40 "00" branches */
        o += (size_t)snprintf(big + o, sizeof(big) - o,
            "[\"j\",\"%064d\",\"01\",\"02\",[", 0);
        for (int b = 0; b < 40; b++)
            o += (size_t)snprintf(big + o, sizeof(big) - o, "%s\"%064d\"", b ? "," : "", 0);
        snprintf(big + o, sizeof(big) - o, "],\"00000001\",\"1d00ffff\",\"5f5e1000\",true]");
        int r = handle_notify(&ctx, big);
        CHECK(r == -1, ">32 merkle branches must reject");
    }

    /* ---- handle_subscribe_result: overlong EN1 / huge EN2_SIZE stay bounded ---- */
    {
        reset_ctx(&ctx);
        char buf[512], en1[200];
        memset(en1, 'a', sizeof(en1) - 1); en1[sizeof(en1) - 1] = 0;   /* 199 hex chars */
        snprintf(buf, sizeof(buf),
            "{\"result\":[[[\"mining.notify\",\"s\"]],\"%s\",99999999999999999999]}", en1);
        handle_subscribe_result(&ctx, buf);   /* must not crash */
        CHECK(ctx.extranonce2_size >= 0 && ctx.extranonce2_size <= JOB_MAX_EXTRANONCE,
              "EN2_SIZE clamped to [0,JOB_MAX_EXTRANONCE]");
    }

    /* handle_result on garbage must not crash */
    reset_ctx(&ctx);
    handle_result(&ctx, "not json at all");
    handle_result(&ctx, "{\"id\":");

    if (fails == 0) { printf("All stratum fuzz checks passed.\n"); return 0; }
    fprintf(stderr, "%d stratum fuzz check(s) failed.\n", fails);
    return 1;
}
