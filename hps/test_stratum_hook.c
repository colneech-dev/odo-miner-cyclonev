/* test_stratum_hook.c -- the stratum client's on_submit_result hook, driven through the REAL hps/stratum.c over a
 * socketpair: submit two shares, let a fake pool reply "duplicate share" to one and result:true to the other, and
 * check the hook saw exactly those two, with the right ids and accept flags, and that the tallies still move.
 * Prints "PASS <id> ..." / "FAIL <id> ..." (the runner greps '^FAIL'). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include "stratum.h"
#include "job.h"

static int fails;
#define CHECK(id, cond, msg) do { \
    if (cond) printf("PASS %s %s\n", id, msg); \
    else { printf("FAIL %s %s\n", id, msg); fails++; } } while (0)

static struct { int calls; uint64_t id[4]; int acc[4]; char line[4][300]; void *user; } seen;

static void hook(void *user, uint64_t id, bool accepted, const char *line)
{
    int i = seen.calls++;
    seen.user = user;
    if (i < 4) {
        seen.id[i] = id;
        seen.acc[i] = accepted;
        snprintf(seen.line[i], sizeof seen.line[i], "%s", line);
    }
}

static uint64_t id_in(const char *sent, int nth)   /* the nth "id":N in what the miner sent */
{
    const char *p = sent;
    for (int i = 0; i <= nth; i++) {
        p = strstr(p, "\"id\":");
        if (!p) return 0;
        p += 5;
        if (i == nth) return strtoull(p, NULL, 10);
    }
    return 0;
}

int main(void)
{
    stratum_ctx_t ctx;
    int sv[2];
    char sent[2048], reply[1024];
    job_t job;

    if (stratum_init(&ctx, "127.0.0.1", "1", "worker", "x") != 0) { puts("FAIL setup stratum_init"); return 2; }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { puts("FAIL setup socketpair"); return 2; }
    ctx.fd = sv[0];
    ctx.authorized = true;
    ctx.on_submit_result = hook;
    ctx.on_submit_result_user = (void *)&seen;

    memset(&job, 0, sizeof job);
    snprintf(job.job_id, sizeof job.job_id, "00000ee9");
    job.ntime = 0x6adc4ca3u;

    CHECK("H1a", stratum_submit_share(&ctx, &job, 0xbbde1728u) >= 0, "first submit sent");
    CHECK("H1b", stratum_submit_share(&ctx, &job, 0x0c8b61b2u) >= 0, "second submit sent");
    memset(sent, 0, sizeof sent);
    ssize_t n = recv(sv[1], sent, sizeof sent - 1, 0);
    uint64_t id1 = id_in(sent, 0), id2 = id_in(sent, 1);
    CHECK("H1c", n > 0 && id1 != 0 && id2 == id1 + 1, "the miner sent two submits with consecutive ids");

    /* the pool: reject the first (miningcore's reply shape, from the 2026-10-24 reject), accept the second */
    snprintf(reply, sizeof reply,
             "{\"result\":false,\"error\":{\"code\":22,\"message\":\"duplicate share\",\"data\":null},\"id\":%llu}\n"
             "{\"result\":true,\"error\":null,\"id\":%llu}\n", (unsigned long long)id1, (unsigned long long)id2);
    CHECK("H2a", write(sv[1], reply, strlen(reply)) == (ssize_t)strlen(reply), "pool reply written");
    stratum_poll(&ctx, 1000);

    CHECK("H2b", seen.calls == 2, "the hook ran once per reply");
    CHECK("H2c", seen.id[0] == id1 && seen.acc[0] == 0, "first call: the rejected id, accepted=false");
    CHECK("H2d", seen.id[1] == id2 && seen.acc[1] == 1, "second call: the accepted id, accepted=true");
    CHECK("H2e", strstr(seen.line[0], "duplicate share") != NULL, "the hook got the raw reply (reason available)");
    CHECK("H2f", seen.user == (void *)&seen, "the user pointer is passed through");
    CHECK("H2g", ctx.shares_rejected == 1 && ctx.shares_accepted == 1, "the tallies still move: 1 rejected, 1 accepted");

    /* a reply to an id we never sent is not a share result: no hook, no tally */
    seen.calls = 0;
    snprintf(reply, sizeof reply, "{\"result\":false,\"error\":null,\"id\":999999}\n");
    if (write(sv[1], reply, strlen(reply)) < 0) puts("FAIL write");
    stratum_poll(&ctx, 1000);
    CHECK("H3a", seen.calls == 0 && ctx.shares_rejected == 1, "an unknown id does not reach the hook or the tallies");

    /* with NO hook installed everything still works (the default) */
    ctx.on_submit_result = NULL;
    CHECK("H4a", stratum_submit_share(&ctx, &job, 0x1111u) >= 0, "submit with no hook");
    memset(sent, 0, sizeof sent);
    (void)recv(sv[1], sent, sizeof sent - 1, 0);
    snprintf(reply, sizeof reply, "{\"result\":false,\"error\":[21,\"Job not found\",null],\"id\":%llu}\n", (unsigned long long)id_in(sent, 0));
    if (write(sv[1], reply, strlen(reply)) < 0) puts("FAIL write");
    seen.calls = 0;
    stratum_poll(&ctx, 1000);
    CHECK("H4b", seen.calls == 0 && ctx.shares_rejected == 2, "no hook: no call, the reject is still counted");

    close(sv[0]); close(sv[1]);
    printf("test_stratum_hook: %s\n", fails ? "FAILED" : "all passed");
    return fails ? 1 : 0;
}
