package highway.mcp_test

import data.highway.mcp

td := "spiffe://highway.lab/ns/migration/sa"

permit(scope) := {"sub": "tester", "scope": scope, "act": {"sub": sprintf("%s/executor-agent", [td]), "act": {"sub": sprintf("%s/planner-agent", [td])}}}

call(tool, args, scope) := {
	"method": "tools/call", "tool": tool, "args": args, "errors": [],
	"permit": permit(scope), "caller": sprintf("%s/executor-agent", [td]),
}

test_copy_allowed if {
	mcp.decision.allow with input as call("copy_bucket", {"source": "customer-data", "destination": "regulated-customer-data"}, "buckets:read buckets:copy")
}

test_delete_needs_scope if {
	d := mcp.decision with input as call("delete_bucket", {"bucket": "billing-exports"}, "buckets:read buckets:copy")
	not d.allow
	"scope buckets:delete not in permit" in d.deny
}

test_retention_lock_beats_scope if {
	d := mcp.decision with input as call("delete_bucket", {"bucket": "prod-archive"}, "buckets:read buckets:copy buckets:delete")
	not d.allow
	d.deny == {"prod-archive is under retention lock"}
}

test_stolen_permit if {
	i := object.union(call("read_inventory", {}, "buckets:read"), {"caller": null, "errors": ["no actor token (JWT-SVID)"]})
	not mcp.decision.allow with input as i
}

test_wrong_presenter if {
	i := object.union(call("read_inventory", {}, "buckets:read"), {"caller": sprintf("%s/planner-agent", [td])})
	d := mcp.decision with input as i
	"caller planner-agent is not the permit's actor executor-agent" in d.deny
}
