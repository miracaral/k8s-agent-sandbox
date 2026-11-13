#!/bin/bash
# The Gemini runner end to end, without the model: the agent container runs a stand-in command
# (AGENT_CMD) instead of the Gemini CLI, so no API key is needed and nothing is paid for.
# Changes while it runs: the runner ScaledJob (test env added, removed at the end), the limits
# (timeout 30 s for one test, restored), agents on/off. Run from the repository root on your machine.
cd "$(dirname "$0")/.." || exit 1
HOST=${LABCTL_SSH_HOST:-cp-1}; KC=${LABCTL_KUBECTL:-"sudo -n k3s kubectl"}
k() { ssh -o BatchMode=yes "$HOST" "$KC $*"; }
set_cmd() { k -n agents patch scaledjob gemini-runner --type json -p "'[{\"op\":\"add\",\"path\":\"/spec/jobTargetRef/template/spec/containers/0/env/-\",\"value\":{\"name\":\"AGENT_CMD\",\"value\":\"$1\"}}]'" >/dev/null; }
reset_runner() { k -n agents delete scaledjob gemini-runner >/dev/null; k apply -f - < manifests/40-runner-gemini.yaml >/dev/null; }
wait_result() { for _ in $(seq 1 40); do out=$(./labctl result "$1"); rc=$?; [ $rc -le 1 ] && { echo "$out"; return; }; sleep 3; done; echo "no result after 120 s: $out"; }
pod() { k -n agents get pods -l agent-sandbox/runner=gemini --field-selector status.phase=Running -o "jsonpath='{.items[*].metadata.name}'" 2>/dev/null | awk '{print $1}'; }
need() { [ -n "$1" ] || { echo "STOP: $2"; ./labctl agents off >/dev/null; reset_runner; exit 1; }; }
id_of() { sed -n 's/^Queued \(t-[^ ]*\).*/\1/p'; }

reset_runner; ./labctl agents off >/dev/null
echo "== 1. Redis users"; k -n agents exec redis-0 -- redis-cli --user admin --no-auth-warning acl users | tr '\n' ' '; echo

echo "== 2. A task end to end (stand-in: cat, echoes the prompt back)"
set_cmd cat; ./labctl agents on >/dev/null
T1=$(./labctl run gemini "dry run: please echo this back" | id_of); need "$T1" "labctl run failed"; echo "queued $T1"
wait_result "$T1" | head -12

echo "== 3. Inside a running task pod (stand-in: sleep 40)"
reset_runner; set_cmd "sleep 40"; ./labctl agents on >/dev/null
T2=$(./labctl run gemini "dry run: sleep" | id_of); need "$T2" "labctl run failed"
for _ in $(seq 1 30); do P=$(pod); [ -n "$P" ] && break; sleep 2; done; need "$P" "no running task pod after 60 s"; sleep 3
echo "pod $P on $(k -n agents get pod "$P" -o "jsonpath='{.spec.nodeName}'")"
echo "-- agent container"
k -n agents exec -i "$P" -c agent -- sh -s -- "$T2" <<'EOF'
echo "env names with PASS/AUTH/KEY: $(env | cut -d= -f1 | grep -iE 'pass|auth|key' | tr '\n' ' ')"
echo "/meta visible: $([ -e /meta ] && echo yes || echo no)   token files: $(ls /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null | wc -l)   uid: $(id -u)"
echo "task id written in task.json is readable: $(grep -c "$1" /workspace/task.json)"
t() { node -e "const s=require('net').connect({host:'$2',port:$3,timeout:3000});s.on('connect',()=>{console.log('$1: open');process.exit()});s.on('timeout',()=>{console.log('$1: no connection');process.exit()});s.on('error',e=>{console.log('$1: no connection ('+e.code+')');process.exit()})"; }
t "redis :6379 (expected open, but no password here)" redis.agents.svc.cluster.local 6379
node -e "const s=require('net').connect(6379,'redis.agents.svc.cluster.local');s.on('data',d=>{console.log('redis answers a PING without login: '+String(d).trim());process.exit()});s.write('PING\r\n')"
t "gemini API :443 (expected open)" generativelanguage.googleapis.com 443
t "other Google host :443" www.google.com 443
t "internet 1.1.1.1:443" 1.1.1.1 443
t "API server" kubernetes.default.svc 443
t "redis in jobs" redis.jobs.svc.cluster.local 6379
EOF
echo "-- report container (Redis user gemini)"
k -n agents exec -i "$P" -c report -- sh -s <<'EOF'
q() { printf "%-40s %s\n" "$*" "$(redis-cli -h redis.agents.svc.cluster.local --user gemini --no-auth-warning "$@" 2>&1 | head -1 | cut -c1-60)"; }
q RPUSH queue:gemini injected; q LPOP queue:claude; q GET task:claude:t-x; q HSET result:claude:t-x status succeeded
q GET result:gemini:t-x; q SET platform:state on; q XADD audit '*' e x; q KEYS '*'
EOF
wait_result "$T2" | head -3

echo "== 4. Timeout (limit 30 s, stand-in: sleep 100)"
reset_runner; set_cmd "sleep 100"
k -n agents patch configmap agent-limits --type merge -p "'{\"data\":{\"taskTimeoutSeconds\":\"30\"}}'" >/dev/null
./labctl agents on >/dev/null
T3=$(./labctl run gemini "dry run: too slow" | id_of); need "$T3" "labctl run failed"; sleep 45; wait_result "$T3" | head -4

echo "== cleanup"
k -n agents patch configmap agent-limits --type merge -p "'{\"data\":{\"taskTimeoutSeconds\":\"900\"}}'" >/dev/null
./labctl agents off >/dev/null; reset_runner
./labctl budget | sed -n '1,4p'
