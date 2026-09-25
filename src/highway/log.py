"""logfmt-ish lines, so `kubectl logs | grep` works in the post."""
import sys
import time


def log(event: str, **fields) -> None:
    parts = [f"{time.strftime('%H:%M:%S')}", event]
    for k, v in fields.items():
        s = str(v)
        parts.append(f"{k}={s!r}" if " " in s else f"{k}={s}")
    print(" ".join(parts), file=sys.stdout, flush=True)
