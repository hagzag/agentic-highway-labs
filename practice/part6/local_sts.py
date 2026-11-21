"""Local stand-in for the Part 3 STS (local.sh only): serves a JWKS and mints permits.
Same claims shape as the real STS (sub, nested act, scope, task_id, jti, 120s TTL)."""
import json
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


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/mint":
            q = parse_qs(u.query)
            body = mint(q["scope"][0], q.get("sub", ["tester"])[0]).encode()
        else:
            body = json.dumps({"keys": [KEY.as_dict(private=False)]}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


HTTPServer(("127.0.0.1", 8099), H).serve_forever()
