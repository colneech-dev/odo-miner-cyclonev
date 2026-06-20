/* hps/miner_io_test.c
 *
 * Simple test utility for miner_io layer.
 * Usage: ./miner_io_test [uio_dev]
 *  - opens the UIO device (default /dev/uio0)
 *  - sends a test header (80 bytes of pattern) and a small nonce range
 *  - polls for a result up to a timeout and prints any found nonce/digest
 *
 * Compile: add to hps Makefile or compile with:
 *   gcc -O2 -Wall -o miner_io_test hps.minor_io.c hps.minor_io_test.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>
#include <unistd.h>

/* Forward declarations of miner_io API (provided by hps/miner_io.c) */
int miner_io_init(const char *uio_dev);
int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count);
int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_digest[32], uint32_t timeout_ms);
void miner_io_shutdown(void);

int main(int argc, char **argv) {
    const char *uio = NULL;
    if (argc > 1) uio = argv[1];

    printf("miner_io_test starting (uio=%s)\n", uio ? uio : "/dev/uio0");

    if (miner_io_init(uio) != 0) {
        fprintf(stderr, "miner_io_init failed\n");
        return 1;
    }

    /* Build an 80-byte test header (pattern) */
    uint8_t header[80];
    for (int i = 0; i < 80; ++i) header[i] = (uint8_t)(i & 0xFF);

    uint32_t start = 0;
    uint32_t count = 1000; /* small test range */

    printf("Dispatching nonce range start=%" PRIu32 " count=%" PRIu32 "\n", start, count);
    if (miner_io_dispatch_range(header, sizeof(header), start, count) != 0) {
        fprintf(stderr, "dispatch_range failed\n");
        miner_io_shutdown();
        return 2;
    }

    uint32_t found_nonce = 0;
    uint8_t digest[32];
    int poll_rc = miner_io_poll_result(&found_nonce, digest, 10000); /* 10s */
    if (poll_rc == 0) {
        printf("Found result nonce=%" PRIu32 "\n", found_nonce);
        printf("Digest: ");
        for (int i = 0; i < 32; ++i) printf("%02x", digest[i]);
        printf("\n");
    } else if (poll_rc == 110) { /* ETIMEDOUT often maps to 110 on Linux */
        printf("No result within timeout\n");
    } else if (poll_rc == -110) {
        /* negative errno - print message */
        fprintf(stderr, "miner_io_poll_result error: %d\n", poll_rc);
    } else {
        printf("miner_io_poll_result returned %d\n", poll_rc);
    }

    miner_io_shutdown();
    printf("Done\n");
    return 0;
}
