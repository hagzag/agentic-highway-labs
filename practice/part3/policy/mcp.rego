# Part 3: the traffic law. OPA decides every MCP call the gateway forwards.
# The gateway (PEP) has already verified both tokens; `input` carries the result:
#   input.permit  verified permit claims (sub, act, scope, exp, task_id) or null
#   input.caller  SPIFFE ID proven by the caller's JWT-SVID, or null
#   input.errors  why a token failed verification
#   input.method, input.tool, input.args   the JSON-RPC call
package highway.mcp

tool_scope := {
	"list_buckets": "buckets:read",
	"read_inventory": "buckets:read",
	"copy_bucket": "buckets:copy",
	"delete_bucket": "buckets:delete",
}

scopes := split(input.permit.scope, " ")

actor := input.permit.act.sub

decision := {"allow": count(deny) == 0, "deny": deny}

# 1. No valid permit or no proven caller: nothing else matters.
deny contains msg if some msg in input.errors

# 2. Sender constraint: a permit only works for the agent it was issued to.
#    A permit lifted from the queue is useless without that agent's SVID.
deny contains msg if {
	input.permit
	input.caller
	input.caller != actor
	msg := sprintf("caller %s is not the permit's actor %s", [short(input.caller), short(actor)])
}

# 3. Delegated scope: the human must hold it, and the permit must carry it.
deny contains msg if {
	input.method == "tools/call"
	need := tool_scope[input.tool]
	not need in scopes
	msg := sprintf("scope %s not in permit", [need])
}

deny contains msg if {
	input.method == "tools/call"
	not tool_scope[input.tool]
	msg := sprintf("unknown tool %s", [input.tool])
}

# 4. Agent least privilege: which tools each agent may touch at all.
deny contains msg if {
	input.method == "tools/call"
	input.permit
	not input.tool in object.get(data.lab.actor_tools, actor, [])
	msg := sprintf("%s may not call %s", [short(actor), input.tool])
}

# 5. Resource rules that no scope overrides.
deny contains "copy destination must be regulated-*" if {
	input.tool == "copy_bucket"
	not startswith(input.args.destination, "regulated-")
}

deny contains msg if {
	input.tool == "delete_bucket"
	input.args.bucket in data.lab.retention_locked
	msg := sprintf("%s is under retention lock", [input.args.bucket])
}

short(id) := s if {
	parts := split(id, "/")
	s := parts[count(parts) - 1]
}
