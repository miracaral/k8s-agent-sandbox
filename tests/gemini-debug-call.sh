#!/bin/bash
# One real Gemini call with the CLI's --debug output, a 120 s limit, and the model named explicitly.
# This costs one request. Debug is switched on only for this run (an env var added to the runner and
# removed again); the timeout goes back to the value it had. Run from the repository root.
cd "$(dirname "$0")/.." || exit 1
HOST=${LABCTL_SSH_HOST:-cp-1}; KC=${LABCTL_KUBECTL:-"sudo -n k3s kubectl"}
k() { ssh -o BatchMode=yes "$HOST" "$KC $*"; }
OLD=$(k -n agents get configmap agent-limits -o "jsonpath='{.data.taskTimeoutSeconds}'")
k -n agents delete scaledjob gemini-runner --ignore-not-found >/dev/null; k apply -f - < manifests/40-runner-gemini.yaml >/dev/null
k -n agents patch scaledjob gemini-runner --type json -p "'[{\"op\":\"add\",\"path\":\"/spec/jobTargetRef/template/spec/containers/0/env/-\",\"value\":{\"name\":\"GEMINI_DEBUG\",\"value\":\"true\"}}]'" >/dev/null
k -n agents patch configmap agent-limits --type merge -p "'{\"data\":{\"taskTimeoutSeconds\":\"120\"}}'" >/dev/null
./labctl agents on >/dev/null
ID=$(./labctl run gemini "${1:-Reply with one short sentence: what is Kubernetes?}" | sed -n 's/^Queued \(t-[^ ]*\).*/\1/p')
echo "task $ID"
for _ in $(seq 1 60); do ./labctl result "$ID" >/dev/null; [ $? -le 1 ] && break; sleep 3; done
./labctl agents off >/dev/null
k -n agents patch configmap agent-limits --type merge -p "'{\"data\":{\"taskTimeoutSeconds\":\"$OLD\"}}'" >/dev/null
k -n agents delete scaledjob gemini-runner >/dev/null; k apply -f - < manifests/40-runner-gemini.yaml >/dev/null
echo "$ID"
