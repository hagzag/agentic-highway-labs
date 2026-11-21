# Part 6: the traffic law at the egress gateway. The sandbox's credential is
# spent only inside the delegation that started the script.
# The gateway (PEP) has verified the permit; `input` carries the result:
#   input.permit   verified permit claims (sub, act, scope, exp, task_id) or null
#   input.caller   the mesh identity of the pod asking (l5d-client-id)
#   input.errors   why the permit failed verification
#   input.method, input.host, input.path   the outbound request
package highway.egress

scopes := split(input.permit.scope, " ")

decision := {"allow": count(deny) == 0, "deny": deny}

# 1. No valid permit: the credential is not spent on behalf of nobody.
deny contains msg if some msg in input.errors

# 2. Only the sandbox may use this road, and only while running a delegated script.
deny contains msg if {
	not input.caller in data.lab.egress_callers
	msg := sprintf("caller %s may not use the egress gateway", [input.caller])
}

deny contains "permit does not delegate scripts:run" if {
	input.permit
	not "scripts:run" in scopes
}

# 3. The outbound request needs the same scope the MCP tool would.
need := "buckets:read" if {
	input.method == "GET"
	startswith(input.path, "/store/v1/buckets")
}

need := "buckets:delete" if {
	input.method == "DELETE"
	startswith(input.path, "/store/v1/buckets/")
}

deny contains msg if {
	not need
	msg := sprintf("no rule for %s %s", [input.method, input.path])
}

deny contains msg if {
	input.permit
	need
	not need in scopes
	msg := sprintf("scope %s not in permit", [need])
}

# 4. Resource rules that no scope overrides (same retention lock as Part 3).
deny contains msg if {
	input.method == "DELETE"
	bucket := trim_prefix(input.path, "/store/v1/buckets/")
	bucket in data.lab.retention_locked
	msg := sprintf("%s is under retention lock", [bucket])
}
