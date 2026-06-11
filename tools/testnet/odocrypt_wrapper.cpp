// odocrypt_wrapper.cpp
#include <stdint.h>
#include <string.h>

#include "crypto/hashodo.h"
#include "crypto/odocrypt.h"

extern "C" {

// header80: pointer to 80-byte block header
// key:      Odocrypt key (uint32_t) from getblocktemplate "odokey"
// out32:    pointer to 32-byte buffer for resulting hash (little-endian)
__declspec(dllexport)
void odocrypt_hash_header(const uint8_t* header80, uint32_t key, uint8_t* out32)
{
    // HashOdo expects [begin, end) iterators
    const uint8_t* begin = header80;
    const uint8_t* end   = header80 + OdoCrypt::DIGEST_SIZE; // 80 bytes

    uint256 h = HashOdo(begin, end, key);
    memcpy(out32, h.data(), 32);
}

}
