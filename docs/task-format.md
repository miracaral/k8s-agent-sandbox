# Task format

> Design document, version 1. Fields marked *reserved* are stored and validated but not acted on yet.

A task is one JSON object. `labctl run` creates it; nothing else may.

## Task

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | number | format version, `1` |
| `id` | string | made by `labctl`, for example `t-20261112-093015-a3f9` |
| `created_at` | string | UTC time, ISO 8601 |
| `runner` | string | `claude` or `gemini`: which agent runs it |
| `role` | string | what the agent is in this task. Today only `worker`. *Reserved:* `author`, `critic`, `fixer`, `tester` |
| `instruction` | string | what to do. Always typed by a person at `labctl run`, never produced by an agent |
| `repo` | string or null | public Git URL to fetch into `/workspace/repo` |
| `parent_task_id` | string or null | *reserved:* the task this one follows |
| `inputs` | list | *reserved:* results of earlier tasks to hand over, as `{"from_task": "<id>", "what": "summary" or "patch"}` |
| `pipeline_id` | string or null | *reserved:* groups the tasks of one multi-agent run |
| `timeout_seconds` | number | copied from the limits ConfigMap when the task is queued |

## Result

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | the task's id |
| `status` | string | `succeeded`, `failed`, `timeout` or `killed` |
| `started_at`, `finished_at` | string | UTC times |
| `exit_code` | number | of the agent process |
| `summary` | string | the agent's answer as text |
| `patch` | string or null | changes to the repository as a unified diff. The agent cannot push; a person applies the patch |
| `truncated` | boolean | true if the output was cut at the size limit |

## The rule for multi-agent work: output is data, never instruction

The reserved fields exist so that one task can later use another task's result (one agent writes, another criticises, the first fixes, a third tests). The format is built around one rule:

- `instruction` comes from a person, for every task in a pipeline. An agent's output is never copied into another task's `instruction`.
- An earlier result reaches the next agent only as **files**, under `/workspace/inputs/<task-id>/`, named by `inputs`.
- The runner tells the agent that everything under `/workspace/inputs` and `/workspace/repo` is material to work on, not orders to follow.
- A task may only name inputs from its own `pipeline_id`.

This keeps the two apart in the platform. It does not make a language model immune to text it reads; see [threat-model.md](threat-model.md).
