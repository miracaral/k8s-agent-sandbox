#!/bin/bash
# Show that nothing in the platform's namespaces is reachable from outside the cluster:
# no NodePort/LoadBalancer Service, no externalIPs, no Ingress, no hostNetwork pod, no hostPort.
# Every count should be 0.   Usage: exposure-check.sh [namespace ...]
K=${KUBECTL:-"kubectl"}
count() { wc -w | tr -d ' '; }

[ $# -eq 0 ] && set -- agents agents-ops
for NS in "$@"; do
  echo "== Exposure check (namespace $NS)"
  printf "%-40s %s\n" "services that are not ClusterIP" "$($K -n "$NS" get svc -o jsonpath='{range .items[?(@.spec.type!="ClusterIP")]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "services with externalIPs"       "$($K -n "$NS" get svc -o jsonpath='{range .items[?(@.spec.externalIPs)]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "Ingress objects"                 "$($K -n "$NS" get ingress --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf "%-40s %s\n" "pods with hostNetwork"           "$($K -n "$NS" get pods -o jsonpath='{range .items[?(@.spec.hostNetwork==true)]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "containers with a hostPort"      "$($K -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{range .ports[*]}{.hostPort}{" "}{end}{end}{end}' | count)"
  echo
done
