"""Part 2: sign task payloads with the workload's X.509-SVID, verify on the far side.

Why not GPG? A GPG key is long-lived, human-managed and knows nothing about
where the workload runs. An X.509-SVID is issued by SPIRE only after the
agent attests the pod (namespace, ServiceAccount, node), and it rotates on
its own. Same idea as signing a commit; a much better key.

The signature survives the queue, where TLS does not.
"""
import base64
import json
import time

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from joserfc import jws
from joserfc.jwk import ECKey, RSAKey
from spiffe import WorkloadApiClient

from . import config

TYP = "highway-task+jws"
MAX_AGE_S = 300

# joserfc caps the protected header at 512 bytes by default. An x5c header
# carrying a real SVID chain is ~1-3 KB, so raise the cap (and keep a cap).
REGISTRY = jws.JWSRegistry(algorithms=["ES256", "RS256"])
REGISTRY.max_header_length = 8192


class Rejected(Exception):
    """Payload failed verification. The message says why."""


def _client() -> WorkloadApiClient:
    return WorkloadApiClient(config.SPIFFE_ENDPOINT_SOCKET)


def _spiffe_id(cert: x509.Certificate) -> str:
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    uris = san.get_values_for_type(x509.UniformResourceIdentifier)
    return next((u for u in uris if u.startswith("spiffe://")), "")


def sign(task: dict) -> tuple[str, str]:
    """Return (compact JWS, signer SPIFFE ID)."""
    with _client() as c:
        svid = c.fetch_x509_svid()
    key = svid.private_key
    if isinstance(key, ec.EllipticCurvePrivateKey):
        alg, jwk = "ES256", ECKey.import_key(key)
    elif isinstance(key, rsa.RSAPrivateKey):
        alg, jwk = "RS256", RSAKey.import_key(key)
    else:  # pragma: no cover
        raise RuntimeError(f"unsupported SVID key type {type(key)}")
    header = {
        "alg": alg,
        "typ": TYP,
        "x5c": [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in svid.cert_chain],
    }
    now = int(time.time())
    body = {**task, "iat": now, "exp": now + MAX_AGE_S}
    return jws.serialize_compact(header, json.dumps(body), jwk, algorithms=[alg], registry=REGISTRY), str(svid.spiffe_id)


def verify(token: str) -> tuple[dict, str]:
    """Return (task, signer SPIFFE ID) or raise Rejected."""
    if token.count(".") != 2:
        raise Rejected("unsigned payload")
    try:
        header = jws.extract_compact(token.encode(), registry=REGISTRY).headers()
    except Exception as e:  # noqa: BLE001
        raise Rejected(f"malformed JWS: {e}") from e
    if header.get("typ") != TYP or not header.get("x5c"):
        raise Rejected("missing typ/x5c header")

    chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in header["x5c"]]
    leaf = chain[0]

    # 1. Chain of trust: leaf -> intermediates -> an authority in the SPIRE bundle.
    with _client() as c:
        bundles = c.fetch_x509_bundles()
    signer = _spiffe_id(leaf)
    td = signer.removeprefix("spiffe://").split("/", 1)[0]
    bundle = next((b for b in bundles.bundles if str(b.trust_domain) == td), None)
    if bundle is None:
        raise Rejected(f"no trust bundle for trust domain {td!r}")
    try:
        for child, parent in zip(chain, chain[1:]):
            child.verify_directly_issued_by(parent)
        roots = bundle.x509_authorities
        if not any(_issued_by(chain[-1], r) for r in roots):
            raise Rejected(f"chain does not lead to the {td} trust bundle (claimed {signer})")
    except Rejected:
        raise
    except Exception as e:  # noqa: BLE001
        raise Rejected(f"bad chain: {e}") from e

    now = time.time()
    if not (leaf.not_valid_before_utc.timestamp() <= now <= leaf.not_valid_after_utc.timestamp()):
        raise Rejected("signing SVID expired or not yet valid")

    # 2. Who is allowed to put work on this queue.
    if config.ALLOWED_SIGNERS and signer not in config.ALLOWED_SIGNERS:
        raise Rejected(f"signer {signer} not in ALLOWED_SIGNERS")

    # 3. The signature itself, with the leaf's public key.
    pub = leaf.public_key()
    jwk = ECKey.import_key(pub) if isinstance(pub, ec.EllipticCurvePublicKey) else RSAKey.import_key(pub)
    try:
        body = json.loads(jws.deserialize_compact(token, jwk, algorithms=[header["alg"]], registry=REGISTRY).payload)
    except Exception as e:  # noqa: BLE001
        raise Rejected(f"bad signature: {e}") from e
    if body.get("exp", 0) < now:
        raise Rejected("payload expired (replay?)")
    return body, signer


def _issued_by(cert: x509.Certificate, authority: x509.Certificate) -> bool:
    try:
        cert.verify_directly_issued_by(authority)
        return True
    except Exception:  # noqa: BLE001
        return cert == authority  # a root in the chain itself
