# The fix: the same script, but the only allowed destination is store-gate. Substrate
# injects the actor's JWT (who is asking); the runner's egress() helper attaches the
# permit of the run_script call (on whose behalf). store-gate decides, records, then
# adds the store token.
G = "http://store-gate.migration.svc.cluster.local:8080/mcp-tools.migration.svc.cluster.local:8000/store/v1/buckets"
print("list=%s" % egress("GET", G))
print("delete=%s" % egress("DELETE", G + "/prod-archive"))
