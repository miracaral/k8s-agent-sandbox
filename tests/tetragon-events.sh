#!/bin/bash
# Summarise what Tetragon recorded for one task pod, from the Tetragon pod on the task's node.
# Usage: tests/tetragon-events.sh <pod-name> <node> [since, default 10m]
# Prints every process start (binary and arguments, cut to 160 characters), every TCP connection attempt
# (destination) and every read of an environment file. The Secret is never read: anything shaped like a
# Google API key (AQ.… or AIza…) is masked before printing, and the number of masked strings is reported.
HOST=${LABCTL_SSH_HOST:-cp-1}; KC=${LABCTL_KUBECTL:-"sudo -n k3s kubectl"}
ssh -o BatchMode=yes "$HOST" "KC='$KC' bash -s -- '$1' '$2' '${3:-10m}'" <<'EOF'
TP=$($KC -n kube-system get pods -l app.kubernetes.io/name=tetragon --field-selector spec.nodeName=$2 -o name)
$KC -n kube-system logs $TP -c export-stdout --since=$3 2>/dev/null | grep "\"name\":\"$1\"" | python3 -c '
import json, re, sys
KEYLIKE = re.compile(r"(AQ\.[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{30,})")
masked = 0
def clean(text):
    global masked
    text, n = KEYLIKE.subn("[KEY-SHAPED STRING MASKED]", text); masked += n
    return text
for line in sys.stdin:
    e = json.loads(line)
    if "process_exec" in e:
        p = e["process_exec"]["process"]
        print("  exec    %-7s %s" % (p["pod"]["container"]["name"], clean(p["binary"] + " " + p.get("arguments", ""))[:160]))
    elif "process_kprobe" in e:
        k = e["process_kprobe"]; p = k["process"]; a = k.get("args", [])
        if k["function_name"] == "tcp_connect":
            s = a[0].get("sock_arg", {})
            print("  connect %-7s %s -> %s:%s" % (p["pod"]["container"]["name"], p["binary"], s.get("daddr"), s.get("dport")))
        else:
            print("  environ %-7s %s read %s" % (p["pod"]["container"]["name"], p["binary"], a[0].get("file_arg", {}).get("path")))
print("  key-shaped strings masked: %d" % masked)
'
EOF
