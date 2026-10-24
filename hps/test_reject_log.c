/* test_reject_log.c -- sw/reject_log.h: reply parsing, the submit ring, the formatted line.
 * Prints "PASS <id> ..." / "FAIL <id> ..." and exits non-zero on any FAIL. */
#include <stdio.h>
#include <string.h>
#include "reject_log.h"

static int fails;
#define CHECK(id, cond, msg) do { \
    if (cond) printf("PASS %s %s\n", id, msg); \
    else { printf("FAIL %s %s\n", id, msg); fails++; } } while (0)

int main(void)
{
    char reason[REJECT_REASON_MAX];
    long code;
    int got;

    /* R1 the object shape (miningcore): the line the Pi actually logged on 2026-10-24 */
    got = reject_extract("{\"result\":false,\"error\":{\"code\":22,\"message\":\"duplicate share\",\"data\":null},\"id\":13239}",
                         reason, sizeof reason, &code);
    CHECK("R1a", got == 1 && strcmp(reason, "duplicate share") == 0, "object shape: reason");
    CHECK("R1b", code == 22, "object shape: code 22");

    /* R2 the classic array shape */
    got = reject_extract("{\"id\":5,\"result\":null,\"error\":[21,\"Job not found\",null]}", reason, sizeof reason, &code);
    CHECK("R2a", got == 1 && strcmp(reason, "Job not found") == 0, "array shape: reason");
    CHECK("R2b", code == 21, "array shape: code 21");
    got = reject_extract("{\"id\":5,\"result\":null,\"error\":[ 23 , \"Low difficulty share\" ,null]}", reason, sizeof reason, &code);
    CHECK("R2c", got == 1 && strcmp(reason, "Low difficulty share") == 0 && code == 23, "array shape with spaces");

    /* R3 no usable error: say so, never crash, code -1 */
    got = reject_extract("{\"result\":false,\"id\":9}", reason, sizeof reason, &code);
    CHECK("R3a", got == 0 && code == -1 && strstr(reason, "no error field"), "no error field is reported as such");
    got = reject_extract("{\"result\":null,\"error\":null,\"id\":9}", reason, sizeof reason, &code);
    CHECK("R3b", got == 0 && code == -1, "error:null is 'no error field'");
    got = reject_extract(NULL, reason, sizeof reason, &code);
    CHECK("R3c", got == 0 && strcmp(reason, "no reply") == 0, "NULL line");

    /* R4 hostile / odd text is made safe for a one-line quoted field */
    got = reject_extract("{\"error\":{\"code\":1,\"message\":\"bad \\\"share\\\"\\nline2\"}}", reason, sizeof reason, &code);
    CHECK("R4a", strchr(reason, '\n') == NULL && strchr(reason, '"') == NULL, "no newline or double quote survives");
    {
        char big[600]; memset(big, 'x', sizeof big); big[sizeof big - 1] = '\0';
        char line[800]; snprintf(line, sizeof line, "{\"error\":{\"code\":2,\"message\":\"%s\"}}", big);
        got = reject_extract(line, reason, sizeof reason, &code);
        CHECK("R4b", strlen(reason) == sizeof reason - 1, "an over-long reason is truncated to the buffer");
    }

    /* S1 the submit ring: id -> job/nonce, and an old id is not mistaken for a new one */
    {
        static struct submit_ring g;       /* zeroed: nothing used */
        const struct submit_rec *r;
        CHECK("S1a", submit_ring_find(&g, 13239) == NULL, "an unknown id is not found");
        submit_ring_put(&g, 13239, "00000ee9", 0xbbde1728u, 1000);
        r = submit_ring_find(&g, 13239);
        CHECK("S1b", r && strcmp(r->job, "00000ee9") == 0 && r->nonce == 0xbbde1728u && r->t == 1000, "recorded id is found with its job/nonce/time");
        CHECK("S1c", submit_ring_find(&g, 13240) == NULL, "a neighbouring id is not found");
        submit_ring_put(&g, 13239 + SUBMIT_RING_N, "00000fff", 1u, 2000);          /* same slot, a newer id */
        CHECK("S1d", submit_ring_find(&g, 13239) == NULL, "the overwritten id is no longer found (no stale match)");
        CHECK("S1e", submit_ring_find(&g, 13239 + SUBMIT_RING_N) != NULL, "the newer id is found");
        submit_ring_put(&g, 7, "0123456789012345678901234567890123456789", 1u, 1);   /* job id longer than the field */
        r = submit_ring_find(&g, 7);
        CHECK("S1f", r && strlen(r->job) == SUBMIT_JOBID_MAX - 1, "an over-long job id is truncated, not overrun");
    }

    /* F1 the line */
    {
        struct submit_rec rec; char out[300];
        memset(&rec, 0, sizeof rec); strcpy(rec.job, "00000ee9"); rec.nonce = 0xbbde1728u; rec.t = 1000; rec.id = 13239; rec.used = 1;
        reject_format(out, sizeof out, 13239, "duplicate share", 22, &rec, 1018);
        CHECK("F1a", strcmp(out, "REJECT reason=\"duplicate share\" code=22 job=00000ee9 nonce=0xbbde1728 age=18s id=13239") == 0, out);
        reject_format(out, sizeof out, 99, "Job not found", 21, NULL, 1018);
        CHECK("F1b", strstr(out, "job=? nonce=?") && strstr(out, "id 99 is not among the last 256"), "an id outside the ring says so");
    }

    printf("test_reject_log: %s\n", fails ? "FAILED" : "all passed");
    return fails ? 1 : 0;
}
