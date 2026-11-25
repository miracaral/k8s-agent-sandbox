#!/bin/bash
# What the ops agent can and cannot do, asked from inside its own pod with its own ServiceAccount.
# Section 1 must work (otherwise the "denied" lines below prove nothing), everything after it must not.
# Nothing is changed: write actions are asked with "kubectl auth can-i", never attempted.
# Usage: ops-agent-test.sh      Optional: LAN_TARGETS="host:port ..." adds targets outside the cluster.
K=${KUBECTL:-"kubectl"}
OTHER_NS=${OTHER_NS:-kube-system}   # a namespace that is not on the ops agent's log list
OTHER_POD=$($K -n "$OTHER_NS" get pods -o jsonpath='{.items[0].metadata.name}')
$K -n agents-ops rollout status deploy/ops-agent --timeout=120s >/dev/null 2>&1 || { echo "ops-agent is not running"; exit 1; }

$K -n agents-ops exec -i deploy/ops-agent -- sh -s -- "$OTHER_NS" "$OTHER_POD" "$LAN_TARGETS" <<'EOF'
try() { out=$(kubectl "$@" 2>&1 >/dev/null); rc=$?; if [ $rc = 0 ]; then r="WORKS"; elif echo "$out" | grep -q "Forbidden\|forbidden"; then r="DENIED (403)"; else r="ERROR: $(echo "$out" | head -1 | cut -c1-90)"; fi; printf "%-58s %s\n" "kubectl $(echo "$*" | cut -c1-48)" "$r"; }
can() { printf "%-58s %s\n" "may it: $*" "$(kubectl auth can-i "$@" 2>/dev/null)"; }
t() { if nc -z -w 3 $2 $3 >/dev/null 2>&1; then r="open"; else r="no connection"; fi; printf "%-58s %s\n" "$1 $2:$3" "$r"; }
echo "== 1. Reading the cluster (must work)"
try get nodes; try get pods -A; try get deployments -A; try get events -A
try -n agents-ops logs deploy/ops-agent --tail=1
echo "== 2. Things it must not read"
try get secrets -A; try -n agents-ops get secrets; try get configmaps -A
try -n "$1" logs "$2" --tail=1
echo "== 3. Things it must not do (asked, not attempted)"
can delete pods -A; can create pods -n agents-ops; can create pods/exec -n agents; can patch deployments -n agents-ops
can create secrets -n agents-ops; can get secrets -n agents-ops; can create clusterrolebindings; can impersonate serviceaccounts
echo "== 4. Network: the API server and nothing else"
t "API server (must be open)" "$KUBERNETES_SERVICE_HOST" 443
NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
for n in $NODES; do t "node kubelet" $n 10250; t "node sshd" $n 22; done
t "redis (jobs)" redis.jobs.svc.cluster.local 6379
t "internet" 1.1.1.1 443
for x in $3; do t "outside the cluster" ${x%:*} ${x#*:}; done
EOF
