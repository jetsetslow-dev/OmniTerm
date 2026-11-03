"""Prints the current one-time code for the OS lab's two-step account (RFC 6238, as
pam_google_authenticator checks it): python3 scripts/os-lab/totp.py <secret file>."""
import base64
import hashlib
import hmac
import struct
import sys
import time

secret = base64.b32decode(open(sys.argv[1]).read().strip().upper())
counter = struct.pack(">Q", int(time.time()) // 30)
digest = hmac.new(secret, counter, hashlib.sha1).digest()
offset = digest[-1] & 0x0F
code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
print(f"{code:06d}")
