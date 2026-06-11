// odocrypt_wrapper.cpp — portable C ABI wrapper around the consensus
// OdoCrypt PoW hash, for the Python test harness (ctypes).
//
// Builds on Linux/WSL (libodocrypt.so) and Windows/MSVC (odocrypt.dll) from
// the repo's upstream/odo-miner/src/crypto sources — see build_odocrypt_lib.*.
//
// Replicates DigiByte's HashOdo without pulling in DigiByte's uint256:
//   cipher = header(80) + 0x01 + zeros;  OdoCrypt(key).Encrypt;
//   KeccakP800_Permute_12rounds;  first 32 bytes = PoW hash (internal LE).

#include <stdint.h>
#include <string.h>

#include "odocrypt.h"
extern "C" {
#include "KeccakP-800-SnP.h"
void KeccakP800_Permute_12rounds(void *state);
}

#if defined(_WIN32)
#define ODO_EXPORT __declspec(dllexport)
#else
#define ODO_EXPORT __attribute__((visibility("default")))
#endif

extern "C" ODO_EXPORT
void odocrypt_hash_header(const uint8_t *header80, uint32_t key, uint8_t *out32)
{
    char cipher[KeccakP800_stateSizeInBytes] = {};
    memcpy(cipher, header80, OdoCrypt::DIGEST_SIZE);   // 80 bytes
    cipher[OdoCrypt::DIGEST_SIZE] = 1;
    OdoCrypt(key).Encrypt(cipher, cipher);
    KeccakP800_Permute_12rounds(cipher);
    memcpy(out32, cipher, 32);
}
