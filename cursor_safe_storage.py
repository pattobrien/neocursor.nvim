#!/usr/bin/env python3
"""Unseal auth tokens Cursor stores with Electron safeStorage.

Cursor 3.x writes cursorAuth/accessToken as

    cursor-safe-storage:v1:<base64 of safeStorage.encryptString(token)>

when `cursor.storage.authTokenEncryptionAtRest` is on. Values without the
prefix are plaintext and pass through untouched.

On macOS safeStorage is Chromium's OSCrypt: a "v10" header, then AES-128-CBC
keyed by PBKDF2-SHA1 over the "<App> Safe Storage" Keychain password.
"""
import base64
import hashlib
import subprocess
import sys

PREFIX = "cursor-safe-storage:v1:"
_V10 = b"v10"


def is_sealed(value: str) -> bool:
    return value.startswith(PREFIX)


def keychain_password(app: str) -> str:
    service = f"{app} Safe Storage"
    r = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", service, "-a", f"{app} Key"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"cannot read the '{service}' Keychain item ({r.stderr.strip() or r.returncode}); "
            "allow access when macOS asks, or sign into Cursor again"
        )
    return r.stdout.rstrip("\n")


def decrypt_v10(blob: bytes, password: str) -> str:
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    if not blob.startswith(_V10):
        raise RuntimeError(f"unsupported safeStorage header {blob[:3]!r}")
    key = hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)
    dec = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
    padded = dec.update(blob[len(_V10):]) + dec.finalize()
    unpad = padding.PKCS7(128).unpadder()
    return (unpad.update(padded) + unpad.finalize()).decode()


def unseal(value: str, app: str) -> str:
    if not is_sealed(value):
        return value
    if sys.platform != "darwin":
        raise RuntimeError(
            f"Cursor encrypted its auth token ({PREFIX}…); decrypting it is only "
            f"supported on macOS so far (this is {sys.platform})"
        )
    blob = base64.b64decode(value[len(PREFIX):])
    return decrypt_v10(blob, keychain_password(app))
