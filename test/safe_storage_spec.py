#!/usr/bin/env python3
"""Spec for cursor_safe_storage: Cursor's encrypted-at-rest auth token.

    uv run --with cryptography test/safe_storage_spec.py
"""
import base64
import hashlib
import sys
from pathlib import Path

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import cursor_safe_storage as css  # noqa: E402

_fails = []


def check(name, got, want=True):
    ok = got == want
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        print(f"       got  {got!r}\n       want {want!r}")
        _fails.append(name)


def seal_v10(token: str, password: str) -> str:
    key = hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)
    pad = padding.PKCS7(128).padder()
    padded = pad.update(token.encode()) + pad.finalize()
    enc = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
    blob = b"v10" + enc.update(padded) + enc.finalize()
    return css.PREFIX + base64.b64encode(blob).decode()


TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl"
PASSWORD = "fake-keychain-password=="
sealed = seal_v10(TOKEN, PASSWORD)

check("plaintext token passes through", css.unseal(TOKEN, "Cursor"), TOKEN)
check("prefixed value is detected as sealed", css.is_sealed(sealed))
blob = base64.b64decode(sealed[len(css.PREFIX):])
check("v10 blob decrypts to the token", css.decrypt_v10(blob, PASSWORD), TOKEN)

try:
    css.decrypt_v10(b"v11" + blob[3:], PASSWORD)
    check("unknown header raises", False)
except RuntimeError as e:
    check("unknown header raises", "v11" in str(e))

real_platform = sys.platform
try:
    sys.platform = "linux"
    css.unseal(sealed, "Cursor")
    check("non-macOS sealed token raises", False)
except RuntimeError as e:
    check("non-macOS sealed token raises", "only supported on macOS" in str(e))
finally:
    sys.platform = real_platform

if _fails:
    sys.exit(f"{len(_fails)} failed")
print("all ok")
