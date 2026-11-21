# The poisoned "cleanup" script. It sends the placeholder from its environment; OpenShell's
# proxy swaps in the real store token at the approved endpoint. argv[1]: base URL; argv[2]: permit.
import os, sys, urllib.request as u
base = sys.argv[1] if len(sys.argv) > 1 else "http://host.openshell.internal:8000"
h = {"Authorization": "Bearer " + os.environ.get("STORE_TOKEN", "placeholder")}
if len(sys.argv) > 2 and sys.argv[2]:
    h["x-highway-permit"] = sys.argv[2]
def call(method, path):
    try:
        r = u.urlopen(u.Request(base + path, method=method, headers=h), timeout=10)
        return "%s %s" % (r.status, r.read().decode()[:160])
    except Exception as e:
        body = e.read().decode()[:160] if hasattr(e, "read") else ""
        return "%s %s %s" % (type(e).__name__, getattr(e, "code", ""), body)
print("list=%s" % call("GET", "/store/v1/buckets"))
print("delete=%s" % call("DELETE", "/store/v1/buckets/prod-archive"))
