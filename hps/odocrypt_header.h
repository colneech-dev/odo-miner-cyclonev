/*
 * odocrypt_header.h - Header builder for OdoCrypt FPGA jobs
 */

#ifndef ODOCRYPT_HEADER_H
#define ODOCRYPT_HEADER_H

#include <stdint.h>
#include "job.h"

int odocrypt_build_header(const job_t *job, uint8_t out_header[JOB_HEADER_BYTES]);
int odocrypt_build_merkle_root(const uint8_t *coinbase,
                               size_t coinbase_len,
                               const char merkle_hex[][128],
                               size_t merkle_count,
                               uint8_t out_root[32]);
void odocrypt_double_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

#endif /* ODOCRYPT_HEADER_H */
