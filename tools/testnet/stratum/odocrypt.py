import ctypes

DLL_PATH = r"C:\digibyte-testnet\odocrypt\odocrypt.dll"

_odo = ctypes.CDLL(DLL_PATH)
_odo.odocrypt_hash_header.argtypes = [
    ctypes.c_void_p,
    ctypes.c_uint32,
    ctypes.c_void_p
]
_odo.odocrypt_hash_header.restype = None

def odocrypt_hash(header: bytes, key: int) -> bytes:
    buf = ctypes.create_string_buffer(header, 80)
    out = ctypes.create_string_buffer(32)
    _odo.odocrypt_hash_header(buf, key, out)
    return out.raw
