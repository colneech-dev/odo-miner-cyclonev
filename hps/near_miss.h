/*
 * near_miss.h -- always log a share that came close to being a BLOCK.
 *
 * WHY: solo mining only pays when one share beats the whole network's
 * difficulty. The per-share "[pipe] SHARE" lines are the only record of how
 * close the boards have come, and they rotate out of the journal in about two
 * days (and may be sampled with K7_SHARE_LOG_EVERY). On 2026-10-24 the question
 * "should a block have been found?" could only be answered for the last ~2.5
 * days. A near-miss line is rare, so it can be kept forever and is never
 * sampled.
 *
 * A share is a NEAR-MISS when its achieved difficulty is at least RATIO times
 * the network difficulty of its own job (both in the miner's diff-1 convention,
 * 0xFFFF << 208) and it is not itself a block (blocks print "*** BLOCK FOUND
 * ***" instead).
 *
 * ODOD_NEAR_MISS_RATIO=r   r in (0, 1]; default 0.1. Unset, empty, non-numeric,
 *                        <= 0 or > 1 all mean the default, so behaviour only
 *                        changes if an operator opts in with a valid value.
 *
 * At a network difficulty of ~27,000 and a pool difficulty near 1, about one
 * share in ~2,700 reaches 10%: a line every few hours per board.
 */
#ifndef NEAR_MISS_H
#define NEAR_MISS_H

#include <stdlib.h>

#define NEAR_MISS_RATIO_DEFAULT 0.1

/* Parse the environment value; anything unusable means the default. */
static inline double near_miss_ratio_parse(const char *s)
{
    char *end;
    double v;
    if (!s || !*s)
        return NEAR_MISS_RATIO_DEFAULT;
    v = strtod(s, &end);
    if (*end != '\0' || !(v > 0.0) || v > 1.0)
        return NEAR_MISS_RATIO_DEFAULT;
    return v;
}

/* d = the share's achieved difficulty, net_diff = its job's network difficulty.
 * Never fires on a missing/zero/negative network difficulty. */
static inline int near_miss_hit(double d, double net_diff, double ratio)
{
    if (!(net_diff > 0.0) || !(d > 0.0))
        return 0;
    return d >= ratio * net_diff;
}

#endif
