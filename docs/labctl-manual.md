# labctl manual

`labctl` is the only tool you need for the agent sandbox. This manual is updated in the same step as every feature; a command is listed as *ready* only after it ran on a real cluster.

## Cheat sheet

| I want to | Command | Status |
| --- | --- | --- |
| see all commands | `labctl --help` | ready |
| check the cluster | `labctl ops health` | ready |
| see who did what | `labctl audit [-n N]` | ready |
| allow agents to run | `labctl agents on` | ready |
| stop new tasks | `labctl agents off` | ready |
| stop everything now | `labctl agents kill` | ready |
| see what is running | `labctl agents status` | ready |
| see today's usage | `labctl budget` | ready |
| give an agent a task | `labctl run gemini "<instruction>" [--repo https://github.com/<owner>/<name>]` | ready (`claude`: version 2) |
| read a result | `labctl result <task-id>` | ready |
| ask about the cluster | `labctl ops ask "<question>"` | version 2 |

## Setup

`labctl` is one Python file with no dependencies. It runs on your machine and sends `kubectl` commands to the cluster over SSH.

| Setting | Default | Meaning |
| --- | --- | --- |
| `LABCTL_SSH_HOST` | `cp-1` | SSH host that has `kubectl`. Set to `local` if `kubectl` works on this machine |
| `LABCTL_KUBECTL` | `sudo -n k3s kubectl` | the `kubectl` command on that host |

## Daily use

```bash
labctl agents on
labctl run gemini "Explain in three sentences what a Kubernetes ServiceAccount is."
#   Queued t-20261113-012215-2fac for gemini (1 of 10 today). Result: labctl result t-20261113-012215-2fac
labctl result t-20261113-012215-2fac
labctl agents off        # when you are done for the day
```

- `labctl run` refuses when agents are off, when the daily limit is used up (and then switches agents off), and when the instruction is empty or longer than 8000 characters.
- `labctl result` prints the status (`succeeded`, `failed`, `timeout`, `killed`), the model that answered, start and end time and the agent's output (the API key is replaced by `[REDACTED]` if it ever appears). While the task waits or runs it says so and exits with code 2. Output above 64 KiB is cut and marked.
- Tasks and results are kept 30 days in Redis.
- One task runs at a time; more wait in the queue.
- `--repo` takes a public `https://github.com/<owner>/<name>` URL. A separate fetcher pod clones the newest commit (no history, no credentials, at most 20 MB compressed) and hands it to the agent, which finds it in `/workspace/repo`. The agent itself cannot reach GitHub. A fetched repository waits at most one hour; if agents stay off longer, queue the task again. A failed clone shows as `failed` with `fetch failed: ...`.
- What a task can reach: the Gemini API and Redis (where it has no password). Not the internet, not other Google hosts, not the cluster API, not the local network. It has no Kubernetes token.

## Emergency

**Something looks wrong and you want it to stop: `labctl agents kill`.**

| Command | New task pods | A task that is running | Tasks waiting in the queue |
| --- | --- | --- | --- |
| `labctl agents off` | none start | finishes normally | stay in the queue |
| `labctl agents kill` | none start | stopped (about a second of grace), its pod deleted | stay in the queue |
| `labctl agents on` | start again, one at a time | | are processed in order |

- The platform is **off by default**: after a fresh install, after Redis loses its data, or when the state cannot be read, it counts as off. A new runner also arrives paused and starts only after `agents on`.
- `off` and `kill` work even if the audit log or Redis cannot be reached (they print a warning). `on` refuses to run without an audit entry.
- A task that `kill` stops is gone: it was already taken from the queue and is not put back. Queue it again if you still want it.
- `kill` deletes the finished task pods too (their logs go with them). Results already stored in Redis are not touched.
- Measured on the test cluster: `kill` returned after 14 seconds with a pod in the middle of its work; `off` takes effect at once, and no new pod started in the 80 seconds watched.

Check afterwards:

```bash
labctl agents status     # Platform: OFF, every runner "paused", Task pods: none
```

**If `labctl` itself cannot reach the cluster** (SSH down), the same brake by hand on the control-plane node:

```bash
kubectl -n agents annotate scaledjob --all autoscaling.keda.sh/paused=true --overwrite
kubectl -n agents delete jobs --all
```

## Cluster health

```bash
labctl ops health
```

Asks the ops agent pod to look at the cluster and prints a short report. No AI is involved and nothing is changed: the pod runs a few `kubectl get` commands with a ServiceAccount that may only read.

| Section | What it shows | Counts as a problem |
| --- | --- | --- |
| Nodes | how many are Ready | any node not Ready |
| Node usage | CPU and memory in percent | memory at 85% or more |
| Pods | how many are healthy | a pod that is not Running with all containers ready, and not Completed |
| Most restarted pods | the five highest restart counts, with the time of the last restart | never (information only: the count is a total since the pod was created) |
| Warning events | warnings the cluster still remembers (about one hour), grouped by namespace and reason | never (information only) |
| Agent platform | number of pods in `agents` and `agents-ops` | never |

The exit code is 0 when nothing counts as a problem and 1 otherwise, so it can be used in a script.

If it says `could not run the health check in the ops agent pod`, the ops agent itself is down or unreachable. Look at it directly from the control-plane node: `kubectl -n agents-ops get pods`.

What the ops agent cannot see, by design: Secrets, ConfigMaps, and logs of namespaces that are not on its list. `tests/ops-agent-test.sh` shows each of these being refused.

## Budget and limits

```bash
labctl budget
```

```text
Today (2026-11-12 UTC):  3 of 10 tasks used, 7 left
Per-task timeout:        900 s
Parallel per runner:     1
Platform:                ON
Runners:
  gemini-runner        in sync
Last 7 days:             11-11: 8   11-10: 0   ...
```

Three limits, all in the ConfigMap `agent-limits`:

| Limit | Default | What happens at the limit |
| --- | --- | --- |
| `dailyTaskLimit` | 10 | the next `labctl run` is refused **and the platform is switched off** (see below) |
| `taskTimeoutSeconds` | 900 | Kubernetes stops the task pod; the task ends as failed |
| `maxParallelPerRunner` | 1 | further tasks wait in the queue |

- **The day is a UTC day, by the cluster's clock.** The counter starts again at 00:00 UTC.
- **A task counts when it is queued,** not when it finishes. A task that fails, times out or is killed still counts.
- **The tripwire.** Tasks 1 to 10 are accepted and run. An attempt to queue an 11th is refused and switches the platform off, because a request beyond the limit may be something calling `labctl` in a loop. Tasks already waiting stay in the queue. The platform stays off, also on the next day, until you run `labctl agents on`.
- **The parallel limit is per runner.** With the value 1, one Gemini task and one fetcher can run at the same time; once a second runner exists (version 2), one task of each.
- **Changing a limit:** `kubectl -n agents edit configmap agent-limits`. The daily limit counts from the next `labctl run`. The timeout and the parallel limit reach the runners at the next `labctl agents on`; until then `labctl budget` shows the runner as `NOT in sync`.
- **A broken value stops everything.** If a limit is missing, not a number or outside its allowed range, `labctl` refuses to queue tasks and refuses `agents on`. A broken setting never means "no limit".

## Audit log

```bash
labctl audit          # the newest 20 entries
labctl audit -n 100
```

Every `labctl` action writes one line: time, who, action, detail. The time is stamped by Redis in the cluster, not by your machine's clock. `labctl audit` itself and `--help` are not logged.

- A command that only reads (like `ops health`) still runs if the log cannot be written, and prints a warning.
- A command that changes something will refuse to run if the log cannot be written.
- The log keeps about the newest 10000 entries and lives on Redis's volume, so it survives a restart of the Redis pod.
- It is a record for you, not tamper-proof evidence: anyone with the Redis admin password or `kubectl exec` rights in `agents` can change it. The independent record of what agent pods really did is Tetragon's process log.

## Where every setting lives

| Setting | Where | Change it with |
| --- | --- | --- |
| SSH host, kubectl command | environment variables on your machine | `export LABCTL_SSH_HOST=...` |
| Pod Security level of the namespaces | labels in `manifests/00-namespaces.yaml` | edit, `kubectl apply` |
| Who may talk to whom | `manifests/50-network-policies.yaml` | edit, `kubectl apply` |
| What the ops agent may read cluster-wide | `ClusterRole ops-agent-read` in `manifests/20-ops-agent.yaml` | edit the resource list, `kubectl apply` |
| Namespaces whose logs the ops agent may read | every namespace that contains the `Role` and `RoleBinding` named `ops-agent-logs` (today: `agents`, `agents-ops`) | copy the two objects into another namespace, or delete them from one |
| What `ops health` checks and its thresholds | `HEALTH_SCRIPT` at the top of `labctl` | edit the file; no image rebuild needed |
| Ops agent image and its base versions | `images/ops/Dockerfile` (base images pinned by digest) | rebuild, load onto the nodes, change the tag in the Deployment |
| Redis passwords | Secret `redis-auth` in `agents` (keys `admin`, `keda`; `runner` is no longer used) | recreate the Secret as in `manifests/examples/redis-auth.md`, then delete the pod `redis-0` so it restarts |
| What each Redis user may do | the `user ...` lines in `manifests/10-redis.yaml` | edit, `kubectl apply`, pod restarts |
| Redis persistence | `appendonly no`, `save 60 1` in `manifests/10-redis.yaml`: a snapshot at most every 60 s and on clean shutdown | do not switch the append-only file back on while the `default` user is off (it drops the counter on restart) |
| Redis memory limit, volume size | `maxmemory` and `volumeClaimTemplates` in `manifests/10-redis.yaml` | edit, `kubectl apply` (volume size cannot be changed in place) |
| How many audit entries are kept | `MAXLEN` in the `audit()` function of `labctl` | edit the file |
| Platform on/off | key `platform:state` in Redis, plus the annotation `autoscaling.keda.sh/paused` on every ScaledJob in `agents` | `labctl agents on` / `off` / `kill` |
| How KEDA logs in to Redis | `manifests/11-keda-auth.yaml` and the `username` in each ScaledJob trigger | edit, `kubectl apply` |
| Who may connect to Redis | `redis-ingress` and `redis-clients-egress` in `manifests/50-network-policies.yaml`; a pod needs the label `agent-sandbox/redis-client: "true"` | edit, `kubectl apply` |
| Daily task limit, per-task timeout, parallel tasks per runner | ConfigMap `agent-limits` in `agents` (`manifests/30-limits.yaml`) | `kubectl -n agents edit configmap agent-limits`, then `labctl agents on` for the timeout and parallel limit |
| Allowed range of each limit | `LIMITS` at the top of `labctl` | edit the file |
| Today's counter | key `count:<day number>` in Redis, kept 8 days | not meant to be changed; `labctl budget` shows it |
| Gemini API key | Secret `gemini-api` in `agents`, key `api-key` (see `manifests/examples/`) | recreate the Secret; the next task pod uses it |
| Redis passwords of the runners | Secret `redis-runners` (`gemini`; `claude` prepared for version 2) | recreate, then delete pod `redis-0` |
| Which nodes run Gemini tasks | `affinity` in `manifests/40-runner-gemini.yaml` (today worker-1 only: the image is loaded only there) | edit, load the image onto the new node, `kubectl apply` |
| Gemini model | `GEMINI_MODEL` in `manifests/40-runner-gemini.yaml`, twice (agent and report); today `gemini-4-hydrogen` | edit both, `kubectl apply`. Check first with `tests/gemini-models-check.yaml` (free) that the key lists it; a listed model can still be refused (`gemini-2.5-flash` was: "no longer available to new users") |
| Gemini CLI version, telemetry settings | `images/runner-gemini/` | rebuild, load onto the nodes, change the tag |
| Fetcher: Redis password, node, limits | Secret `redis-fetcher`; `manifests/45-fetcher.yaml` (clone timeout 120 s, size limit 20 MB, repository kept 1 hour) | edit, `kubectl apply` |
| Where Gemini tasks may connect | `gemini-egress` in `manifests/50-network-policies.yaml` | adding a host widens the sandbox: see the threat model first |
| What Tetragon records in `agents` | `manifests/60-tetragon.yaml` (connection attempts, environment-file reads; process starts are always recorded) | edit, `kubectl apply`; read with `tests/tetragon-events.sh <pod> <node>` |
