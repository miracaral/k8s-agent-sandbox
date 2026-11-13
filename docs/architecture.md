# Architecture

> Version 1. The Claude runner is planned for version 2; its rows are marked.

## Pieces

| Piece | Namespace | Lives | Credentials it holds |
| --- | --- | --- | --- |
| `labctl` | your machine | while you type | your SSH access to the control-plane node |
| Redis (queue, results, audit log) | `agents` | always | its own password |
| Fetcher pod | `agents` | one per task with `--repo` | its own Redis password; nothing for GitHub |
| Task pod (Gemini) | `agents` | one per task | `take` and `report` containers: the runner's Redis password. `agent` container: the model API key only |
| Ops agent | `agents-ops` | always | a ServiceAccount that may only read |

No task pod has a Kubernetes ServiceAccount token.

## Who may talk to whom

Everything not in this table is dropped by the default-deny policy.

| From | To | Why |
| --- | --- | --- |
| every pod | cluster DNS | names must resolve; also needed for name-based egress rules |
| fetcher pod | `github.com` :443 | clone a public repository |
| fetcher pod, task pod | Redis | take the task, store the repository and the result (the task pod's `agent` container can connect but has no password) |
| Claude task pod (version 2) | `api.anthropic.com` :443 | the model |
| Gemini agent pod | `generativelanguage.googleapis.com` :443 | the model |
| KEDA operator | Redis | read the queue length |
| ops agent | Kubernetes API server | read-only queries |

There is no rule from the agent pod to GitHub, to the Kubernetes API, to other namespaces, to the nodes or to the local network, and no rule that allows `0.0.0.0/0`.

## Why the fetcher is a separate pod

A network policy applies to a whole pod, not to one container in it. If an init container in the agent pod cloned the repository, the pod would need a rule for `github.com`, and the agent container would have it too. A separate pod gets its own policy, so "the agent cannot reach GitHub" becomes something the network enforces and a test can show.

## Nothing is exposed

No Ingress, NodePort, LoadBalancer or port-forward. `labctl` reaches Redis through `kubectl exec`. `tests/exposure-check.sh` counts every way a namespace can be exposed; all counts must be 0.
