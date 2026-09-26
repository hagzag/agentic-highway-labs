"""Part 4: blast-radius probe. Run inside a pod; report what it is and what it can reach.

    python -m highway.probe            # human-readable lines
    python -m highway.probe --targets host:port,host:port

For each target it opens a TCP connection with a short timeout and classifies:
    REACH    connected (or refused: host reachable, port closed)
    BLOCKED  timed out — a NetworkPolicy dropped the packets
    NODNS    name did not resolve
It also prints the pod's own identity: SPIFFE ID, runtime (runc/gVisor), and
whether a ServiceAccount token is mounted. run.sh runs this from several pods,
before and after the fence, and assembles the matrix in captured/.
"""
import argparse
import os
import socket
import sys

TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

# host:port ; the label is what shows up in the matrix.
DEFAULT_TARGETS = [
    "redis:6379",
    "mcp-tools:8000",
    "mcp-gateway:8080",
    "sandbox-runner:8000",
    "llm-gateway:8080",
    "sts:8080",
    "kubernetes.default:443",
    "sink.internet:9000",
]


def reach(target: str, timeout: float = 3.0) -> str:
    """REACH only if the real destination answers. A bare TCP connect is not enough:
    a meshed pod's own Linkerd proxy accepts the local connect even when the upstream
    is dropped by a NetworkPolicy, so we send a request and require bytes back."""
    host, _, port = target.partition(":")
    try:
        infos = socket.getaddrinfo(host, int(port or 80), proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return "NODNS"
    af, kind, proto, _, addr = infos[0]
    s = socket.socket(af, kind, proto)
    s.settimeout(timeout)
    try:
        s.connect(addr)
    except (socket.timeout, TimeoutError):
        return "BLOCKED"
    except ConnectionRefusedError:
        return "CLOSED"   # host up, port closed (no proxy in the way)
    except OSError as e:
        return f"ERR({e.errno})"
    try:
        s.sendall(b"GET /healthz HTTP/1.0\r\n\r\n")
        return "REACH" if s.recv(1) else "BLOCKED"
    except (socket.timeout, TimeoutError):
        return "BLOCKED"   # connected to the proxy, but the upstream never answered
    except OSError:
        return "REACH"     # the destination spoke (e.g. TLS/redis reset our HTTP)
    finally:
        s.close()


def runtime() -> str:
    try:
        v = open("/proc/version").read()
    except OSError:
        return "unknown"
    return "gVisor" if "gvisor" in v.lower() else "runc"


def identity() -> str:
    try:
        from . import svid
        with __import__("contextlib").suppress(Exception):
            return svid.short(str(__import__("spiffe").WorkloadApiClient(
                os.environ.get("SPIFFE_ENDPOINT_SOCKET", "unix:///run/spire/sockets/agent.sock")
            ).fetch_x509_svid().spiffe_id))
    except Exception:  # noqa: BLE001
        pass
    return "-"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--targets", default="")
    a = p.parse_args()
    targets = a.targets.split(",") if a.targets else DEFAULT_TARGETS
    me = os.environ.get("AGENT_NAME", os.environ.get("HOSTNAME", "pod"))
    token = "yes" if os.path.exists(TOKEN_PATH) else "no"
    print(f"probe pod={me} spiffe={identity()} runtime={runtime()} sa_token={token}")
    for t in targets:
        print(f"probe target={t} result={reach(t)}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
