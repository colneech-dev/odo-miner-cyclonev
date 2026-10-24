/* test_near_miss.c -- sw/near_miss.h: the threshold parse and the hit test.
 * Prints "PASS <id> ..." / "FAIL <id> ..." and exits non-zero on any FAIL. */
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "near_miss.h"

static int fails;
#define CHECK(id, cond, msg) do { \
    if (cond) printf("PASS %s %s\n", id, msg); \
    else { printf("FAIL %s %s\n", id, msg); fails++; } } while (0)

int main(void)
{
    /* N1 the default, and everything unusable falls back to it */
    CHECK("N1a", near_miss_ratio_parse(NULL) == 0.1, "unset -> 0.1");
    CHECK("N1b", near_miss_ratio_parse("") == 0.1, "empty -> 0.1");
    CHECK("N1c", near_miss_ratio_parse("abc") == 0.1, "non-numeric -> 0.1");
    CHECK("N1d", near_miss_ratio_parse("0.25x") == 0.1, "trailing garbage -> 0.1");
    CHECK("N1e", near_miss_ratio_parse("0") == 0.1, "zero -> 0.1");
    CHECK("N1f", near_miss_ratio_parse("-0.5") == 0.1, "negative -> 0.1");
    CHECK("N1g", near_miss_ratio_parse("1.5") == 0.1, "above 1 -> 0.1");
    CHECK("N1h", near_miss_ratio_parse("nan") == 0.1, "nan -> 0.1");

    /* N2 valid values are taken as given */
    CHECK("N2a", fabs(near_miss_ratio_parse("0.25") - 0.25) < 1e-12, "0.25 accepted");
    CHECK("N2b", near_miss_ratio_parse("1") == 1.0, "exactly 1 accepted");
    CHECK("N2c", fabs(near_miss_ratio_parse("0.001") - 0.001) < 1e-12, "0.001 accepted");

    /* N3 the hit test: >= is inclusive, below is not */
    CHECK("N3a", near_miss_hit(1000.0, 10000.0, 0.1) == 1, "exactly at the ratio is a hit");
    CHECK("N3b", near_miss_hit(999.9, 10000.0, 0.1) == 0, "just below is not");
    CHECK("N3c", near_miss_hit(169591.0, 354151.2, 0.1) == 1, "the Pi's 47.9% share is a hit");
    CHECK("N3d", near_miss_hit(1.5, 26907.0, 0.1) == 0, "a normal share is not");
    CHECK("N3e", near_miss_hit(5000.0, 10000.0, 0.5) == 1, "ratio 0.5 respected");
    CHECK("N3f", near_miss_hit(4999.0, 10000.0, 0.5) == 0, "ratio 0.5 respected (below)");

    /* N4 a missing network difficulty never fires, whatever the share is */
    CHECK("N4a", near_miss_hit(1e9, 0.0, 0.1) == 0, "net_diff 0 -> no hit");
    CHECK("N4b", near_miss_hit(1e9, -5.0, 0.1) == 0, "net_diff negative -> no hit");
    CHECK("N4c", near_miss_hit(1e9, NAN, 0.1) == 0, "net_diff nan -> no hit");
    CHECK("N4d", near_miss_hit(0.0, 100.0, 0.1) == 0, "zero share -> no hit");

    printf("test_near_miss: %s\n", fails ? "FAILED" : "all passed");
    return fails ? 1 : 0;
}
