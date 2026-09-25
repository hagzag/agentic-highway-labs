"""The queue between planner and executor. mTLS protects the hop; it ends here."""
import json

import redis

from . import config
from .log import log


_client: redis.Redis | None = None


def _redis() -> redis.Redis:
    global _client
    if _client is None:
        # socket_timeout must outlive the BLPOP timeout below
        _client = redis.Redis.from_url(config.REDIS_URL, decode_responses=True, socket_timeout=30)
    return _client


def put(task: dict) -> None:
    if config.SIGN_PAYLOADS:
        from .signing import sign
        msg, signer = sign(task)
        log("broker=put", task_id=task["task_id"], step=task["step"], signed_by=signer)
    else:
        msg = json.dumps(task)
        log("broker=put", task_id=task["task_id"], step=task["step"], signed_by="-")
    _redis().rpush(config.TASK_QUEUE, msg)


def get(timeout: int = 5) -> tuple[dict, str] | None:
    """Return (task, signer) or None. Raises signing.Rejected when verification fails."""
    item = _redis().blpop([config.TASK_QUEUE], timeout=timeout)
    if item is None:
        return None
    raw = item[1]
    if config.VERIFY_PAYLOADS:
        from .signing import verify
        return verify(raw)
    # Part 1 behaviour: trust whatever is on the queue.
    if raw.count(".") == 2 and not raw.lstrip().startswith("{"):
        import base64
        body = raw.split(".")[1]
        raw = base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode()
    return json.loads(raw), "-"
