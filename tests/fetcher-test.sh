#!/bin/bash
# The fetcher, without a model: what a fetcher pod and an agent pod can reach, what the fetcher's Redis user
# may do, and a task with --repo end to end (the agent runs a stand-in that lists the repository).
# Changes while it runs: agents on/off, a stand-in env on the runner (removed at the end). Run from the repo root.
cd "$(dirname "$0")/.." || exit 1
HOST=${LABCTL_SSH_HOST:-cp-1}; KC=${LABCTL_KUBECTL:-"sudo -n k3s kubectl"}
NODE=${NODE:?"set NODE to the worker that runs the agents, e.g. NODE=<your worker>"}
on_node() { sed -e "s/values: \[worker-1\]/values: [$NODE]/" -e "s/hostname: worker-1}/hostname: $NODE}/"; }
k() { ssh -o BatchMode=yes "$HOST" "$KC $*"; }
REPO=${REPO:-https://github.com/miracaral/fastapi-todo-api}
id_of() { sed -n 's/^Queued \(t-[^ ]*\).*/\1/p'; }
wait_result() { for _ in $(seq 1 60); do out=$(./labctl result "$1"); [ $? -le 1 ] && { echo "$out"; return; }; sleep 3; done; echo "no result after 180 s: $out"; }
reset_runner() { k -n agents delete scaledjob gemini-runner >/dev/null; on_node < manifests/40-runner-gemini.yaml | k apply -f - >/dev/null; }

echo "== 1. Redis users"; k -n agents exec redis-0 -- redis-cli --user admin --no-auth-warning acl users | tr '\n' ' '; echo
echo "== 2. Network and Redis from a fetcher-labelled and an agent-labelled pod"
on_node < tests/fetcher-netcheck.yaml | k apply -f - >/dev/null
k -n agents wait --for=condition=Ready pod/netcheck-fetcher pod/netcheck-agent --timeout=90s >/dev/null
for p in netcheck-fetcher netcheck-agent; do
  echo "-- $p"
  k -n agents exec -i $p -- sh -s <<'EOF'
t() { if timeout 4 nc -z $1 $2 >/dev/null 2>&1; then r="open"; else r="no connection"; fi; printf "  %-40s %s\n" "$1:$2" "$r"; }
t github.com 443; t api.github.com 443; t codeload.github.com 443; t generativelanguage.googleapis.com 443
t 1.1.1.1 443; t "$KUBERNETES_SERVICE_HOST" 443; t redis.agents.svc.cluster.local 6379
EOF
done
echo "-- fetcher's Redis user"
k -n agents exec -i netcheck-fetcher -- sh -s <<'EOF'
q() { printf "  %-40s %s\n" "$*" "$(redis-cli -h redis.agents.svc.cluster.local --user fetcher --no-auth-warning "$@" 2>&1 | head -1 | cut -c1-55)"; }
q PING; q GET task:gemini:t-x; q GET repo:gemini:t-x; q HGET result:gemini:t-x status; q LPOP queue:gemini
q RPUSH queue:claude t-x; q SET repo:claude:t-x v; q SET platform:state on; q KEYS '*'
EOF
k -n agents delete pod netcheck-fetcher netcheck-agent --now --wait=true >/dev/null

echo "== 3. A task with --repo end to end (stand-in lists the repository)"
reset_runner
k -n agents patch scaledjob gemini-runner --type json -p "'[{\"op\":\"add\",\"path\":\"/spec/jobTargetRef/template/spec/containers/0/env/-\",\"value\":{\"name\":\"AGENT_CMD\",\"value\":\"find /workspace/repo -maxdepth 1\"}}]'" >/dev/null
./labctl agents on >/dev/null
T1=$(./labctl run gemini "dry run: list the repository" --repo "$REPO" | id_of); echo "queued $T1"
wait_result "$T1" | head -20
echo "-- fetcher log"; k -n agents logs -l agent-sandbox/role=fetcher --tail=2

echo "== 4. A repository that does not exist"
T2=$(./labctl run gemini "dry run" --repo https://github.com/miracaral/this-repository-does-not-exist-123 | id_of)
wait_result "$T2" | head -5

./labctl agents off >/dev/null; reset_runner
echo "$T1 $T2"
