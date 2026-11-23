"""Lab stand-in for the Part 3 STS: serves a JWKS and mints permits on GET /mint.
Used where Keycloak + SPIRE aren't installed (Part 6 local.sh, Part 7 on kind, Part 8).
Same claims shape as the real STS (sub, nested act, scope, task_id, jti, 120s TTL).
NEVER a real STS: anyone who can reach /mint gets a permit."""
import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from joserfc import jwt
from joserfc.jwk import ECKey

ISS = "http://sts.migration.svc.cluster.local:8080"
TD = "spiffe://highway.lab/ns/migration/sa"
KEY = ECKey.generate_key("P-256", parameters={"kid": "local-sts"})


def mint(scope: str, sub: str) -> str:
    now = int(time.time())
    return jwt.encode({"alg": "ES256", "kid": "local-sts"}, {
        "iss": ISS, "aud": "mcp-gateway", "sub": sub, "scope": scope, "task_id": 72,
        "jti": uuid.uuid4().hex[:12], "iat": now, "exp": now + 120,
        "act": {"sub": f"{TD}/executor-agent", "act": {"sub": f"{TD}/planner-agent"}}}, KEY)


def mint_actor(sub: str, aud: str) -> str:
    """Stand-in for an Agent Substrate actor JWT (Part 7 local test)."""
    now = int(time.time())
    return jwt.encode({"alg": "ES256", "kid": "local-sts"},
                      {"iss": "local-ate-idp", "aud": aud, "sub": sub, "iat": now, "exp": now + 300}, KEY)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/mint-actor":
            q = parse_qs(u.query)
            body = mint_actor(q["sub"][0], q.get("aud", ["store-gate"])[0]).encode()
        elif u.path == "/mint":
            q = parse_qs(u.query)
            body = mint(q["scope"][0], q.get("sub", ["tester"])[0]).encode()
        else:
            body = json.dumps({"keys": [KEY.as_dict(private=False)]}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


HTTPServer((os.environ.get("HOST", "127.0.0.1"), int(os.environ.get("PORT", "8099"))), H).serve_forever()
