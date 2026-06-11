import struct
import binascii

def serialize_header(version, prevhash_le, merkleroot_le, ntime, nbits, nonce):
    return struct.pack(
        "<I32s32sIII",
        version,
        binascii.unhexlify(prevhash_le),
        binascii.unhexlify(merkleroot_le),
        ntime,
        nbits,
        nonce
    )
