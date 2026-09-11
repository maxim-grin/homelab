#!/usr/bin/env python3
"""Generate the Harbor credential block for ansible/secret.yaml.

The chart validates several of these at runtime: secretKey, the core secret,
the jobservice secret and the registry secret must be exactly 16 characters,
and the XSRF key exactly 32. The registry htpasswd must carry a $2a$ or $2b$
hash -- Docker's registry uses Go's bcrypt, which rejects the $2y$ that
htpasswd(1) emits.

Run it, paste the output into `ansible-vault edit ansible/secret.yaml`, and
keep harbor_admin_password in a password manager. Nothing is written to disk.
"""
import secrets
import string
import sys

try:
    import bcrypt
except ImportError:
    sys.exit("error: python3 bcrypt module required -- pip3 install bcrypt")

ALPHABET = string.ascii_letters + string.digits
REGISTRY_USER = "harbor_registry_user"


def rand(n):
    return "".join(secrets.choice(ALPHABET) for _ in range(n))


registry_password = rand(24)
htpasswd = "{}:{}".format(
    REGISTRY_USER,
    bcrypt.hashpw(registry_password.encode(), bcrypt.gensalt(10)).decode(),
)

print(f'harbor_admin_password: "{rand(24)}"')
print(f'harbor_secret_key: "{rand(16)}"')
print(f'harbor_core_secret: "{rand(16)}"')
print(f'harbor_xsrf_key: "{rand(32)}"')
print(f'harbor_jobservice_secret: "{rand(16)}"')
print(f'harbor_registry_http_secret: "{rand(16)}"')
print(f'harbor_registry_password: "{registry_password}"')
print(f'harbor_registry_htpasswd: "{htpasswd}"')
