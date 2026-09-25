"""All knobs come from environment variables so the same image runs every part."""
import os


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def flag(name: str) -> bool:
    return env(name, "false").lower() in ("1", "true", "yes", "on")


AGENT_NAME = env("AGENT_NAME", "agent")

# LLM: any OpenAI-compatible endpoint (LiteLLM by default). LLM_MODE=mock runs offline.
LLM_MODE = env("LLM_MODE", "live")
LLM_BASE_URL = env("LLM_BASE_URL", "https://litellm.tikalk.dev")
LLM_API_KEY = env("LLM_API_KEY")
LLM_MODEL = env("LLM_MODEL", "gpt-4o-mini")

REDIS_URL = env("REDIS_URL", "redis://redis:6379/0")
TASK_QUEUE = env("TASK_QUEUE", "highway:tasks")
MCP_URL = env("MCP_URL", "http://mcp-tools:8000/mcp")

# Part 2: payload signing with the workload's X.509-SVID.
SIGN_PAYLOADS = flag("SIGN_PAYLOADS")
VERIFY_PAYLOADS = flag("VERIFY_PAYLOADS")
ALLOWED_SIGNERS = [s for s in env("ALLOWED_SIGNERS").split(",") if s]
SPIFFE_ENDPOINT_SOCKET = env("SPIFFE_ENDPOINT_SOCKET", "unix:///run/spire/sockets/agent.sock")

# Part 3: delegation. Agents swap the human's token for short-lived permits at
# the STS and present them, plus a JWT-SVID, at the MCP gateway.
PERMITS = flag("PERMITS")
STS_URL = env("STS_URL", "http://sts:8080")
STS_ISSUER = env("STS_ISSUER", "http://sts.migration.svc.cluster.local:8080")
KEYCLOAK_ISSUER = env("KEYCLOAK_ISSUER", "http://keycloak.idp.svc.cluster.local:8080/realms/highway")
# What the planner asks for. Greedy on purpose: the STS trims it to what the human holds.
PERMIT_SCOPES = env("PERMIT_SCOPES", "buckets:read buckets:copy buckets:delete")
# key = Part 1-2 static LLM_API_KEY; svid = no key, a JWT-SVID to the LLM gateway.
LLM_AUTH = env("LLM_AUTH", "key")
