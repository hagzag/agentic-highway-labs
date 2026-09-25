"""Part 3: a human logs in. Stand-in for a CLI on the human's laptop.

    python -m highway.login --user tester            # prints an access token
    python -m highway.login --user tester --claims   # prints what's inside it

Lab-only: the password grant (Direct Access Grants) keeps the lab scriptable.
A real CLI would use the device flow or a browser redirect with PKCE.
"""
import argparse
import json
import sys

import httpx

from . import config
from .permits import claims


def login(user: str, password: str) -> str:
    resp = httpx.post(f"{config.KEYCLOAK_ISSUER}/protocol/openid-connect/token", data={
        "grant_type": "password", "client_id": "highway-cli", "username": user, "password": password,
        "scope": "openid",
    }, timeout=15)
    if resp.status_code != 200:
        sys.exit(f"login failed: {resp.status_code} {resp.text}")
    return resp.json()["access_token"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--user", default="tester")
    p.add_argument("--password", help="defaults to the username (lab realm)")
    p.add_argument("--claims", action="store_true", help="print the decoded claims instead of the token")
    a = p.parse_args()
    tok = login(a.user, a.password or a.user)
    if a.claims:
        c = claims(tok)
        keep = ("iss", "sub", "preferred_username", "azp", "realm_access", "scope", "exp", "iat")
        print(json.dumps({k: c[k] for k in keep if k in c}, indent=2))
    else:
        print(tok)


if __name__ == "__main__":
    main()
