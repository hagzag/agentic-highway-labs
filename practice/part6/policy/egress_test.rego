package highway.egress_test

import data.highway.egress

td := "spiffe://highway.lab/ns/migration/sa"

runner := "sandbox-runner.migration.serviceaccount.identity.linkerd.cluster.local"

permit(scope) := {"sub": "tester", "scope": scope, "act": {"sub": sprintf("%s/executor-agent", [td])}}

req(method, path, p) := {"method": method, "host": "mcp-tools:8000", "path": path, "caller": runner, "permit": p, "errors": []}

test_list_allowed if {
	egress.decision.allow with input as req("GET", "/store/v1/buckets", permit("buckets:read scripts:run"))
}

test_delete_without_scope_denied if {
	d := egress.decision with input as req("DELETE", "/store/v1/buckets/customer-data", permit("buckets:read scripts:run"))
	not d.allow
	"scope buckets:delete not in permit" in d.deny
}

test_retention_lock_beats_scope if {
	d := egress.decision with input as req("DELETE", "/store/v1/buckets/prod-archive", permit("buckets:delete scripts:run"))
	not d.allow
	"prod-archive is under retention lock" in d.deny
}

test_no_permit_denied if {
	d := egress.decision with input as {"method": "GET", "host": "mcp-tools:8000", "path": "/store/v1/buckets", "caller": runner, "permit": null, "errors": ["no permit (x-highway-permit)"]}
	not d.allow
}

test_other_caller_denied if {
	d := egress.decision with input as object.union(req("GET", "/store/v1/buckets", permit("buckets:read scripts:run")), {"caller": "rogue.migration.serviceaccount.identity.linkerd.cluster.local"})
	not d.allow
}

test_permit_without_scripts_run_denied if {
	d := egress.decision with input as req("GET", "/store/v1/buckets", permit("buckets:read"))
	not d.allow
	"permit does not delegate scripts:run" in d.deny
}
