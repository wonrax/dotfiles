---
name: agentflow
description: Dispatch coding tasks to background Claude Code agents running in isolated docker containers on jj workspaces, with implement→verify→review loops, live dashboard, and human steering. Use when the user wants to delegate/offload a coding task to a background agent, run several implementation tasks in parallel, run agents against their repos without touching the working copy, or mentions agentflow, "spawn a task/agent", "background agent", or the agent dashboard.
---

# agentflow

Orchestrator daemon on this machine for running coding-agent tasks. Each task
gets a docker container (nix-based image with claude-code, jj, gh, node,
python) working on an isolated jj workspace of the target repo. Workflows are
node graphs (agent / shell / review) with rework loops; the bundled
`implement-review` workflow loops implement → gates → adversarial review until
approved.

Everything below the spawn call is handled for you — do not read agentflow's
source or README to learn the mechanics. In particular, passing `repo`
automatically creates an isolated jj workspace for the agent:

- Base revision: the repo's current working copy parents (a sibling of `@`).
  Uncommitted changes in the user's working copy are NOT included. If the task
  must build on unfinished work, ask the user to commit/describe it first.
- The user's working copy is never touched; parallel tasks on one repo are
  safe (separate workspaces, shared store).
- The agent's commits appear in the repo's regular `jj log` as `af-<id>@`.
- Containers inherit the host's `~/.claude` (CLAUDE.md, skills, agents)
  read-only, plus the repo's own CLAUDE.md/AGENTS.md via the workspace.

The SDK doc comment (`curl -s http://127.0.0.1:4200/sdk.ts`) is the complete
API contract; `~/.dotfiles/agentflow/README.md` is only for operating the
daemon itself (credentials, image, troubleshooting).

## Preflight

```bash
curl -s http://127.0.0.1:4200/api/board
```

If connection refused, start the daemon (background it) and wait for the port:

```bash
cd ~/.dotfiles/agentflow && RIVET_RUN_ENGINE=1 nix develop ~/.dotfiles -c deno task daemon
```

Requirements that may be missing on a fresh machine: `docker build -t
agentflow:latest image/` (once), and a subscription token at
`~/.config/agentflow/token` (user runs `claude setup-token`; agents fail with
auth errors without it).

## Dispatch

Write a deno script importing the SDK by URL — the SDK file's doc comment is
the authoritative API reference, read it first:

```bash
curl -s http://127.0.0.1:4200/sdk.ts
```

```ts
import { connect } from "http://127.0.0.1:4200/sdk.ts";
const af = connect();
const { id, record } = await af.run({
  repo: "/abs/path/to/jj/repo",   // omit for scratch dir
  title: "concise task title",    // always set; dashboards show it
  task: "…",
  gates: "nix develop -c cargo test",
  workflow: "implement-review",   // or "quick"; defs at GET /api/workflows
  model: "<your own model id>",
  effort: "high",                 // optional: low | medium | high
});
```

Model selection: unless the user asks for a specific model, set `model` to the
model YOU are currently running as (your exact model id, stated in your system
prompt) — the container default is sonnet, which silently downgrades tasks
dispatched by a stronger model. Cheap mechanical tasks may justify haiku; say
so when you choose it.

```bash
deno check --allow-import=127.0.0.1:4200 script.ts
deno run --allow-net --allow-env --allow-sys --allow-import=127.0.0.1:4200 script.ts
```

`af.run()` blocks until terminal status; `af.spawn()` returns immediately.
Multiple tasks on the same repo run in parallel safely (separate jj
workspaces, shared store).

## Monitor to completion — never fire-and-forget

Tasks run for minutes to days. Do NOT end your turn right after spawning:
nobody would see the result, a failure would sit unresumed, and finished work
would go unreviewed. After `af.spawn()`, start a watcher script **as a
background shell** (`run_in_background: true`) so you are re-invoked when it
exits:

```ts
// watch.ts — one per task, or loop over several ids
import { connect } from "http://127.0.0.1:4200/sdk.ts";
const rec = await connect().wait(Deno.args[0]);
console.log(rec.status, "| runs:", rec.runs.map((r) => `${r.node}#${r.visit}=${r.status}`).join(" "));
if (rec.error) console.log("error:", rec.error);
Deno.exit(rec.status === "succeeded" ? 0 : 1);
```

When the notification wakes you:

- `succeeded` — verify the work yourself before reporting: `jj log` /
  `jj diff -r af-<id>@` in the target repo, read the final node outputs via
  `GET /api/task/<id>`. Summarize the result to the user.
- `failed` — read `error` and the last node's output. Recoverable failures
  (timeouts, gate flakes, maxVisits) are usually worth one revive:
  `handle.interject({ message: "<what to fix or just: continue>" })` resumes
  from the checkpoint with container + session intact. Then re-watch.
- `stopped` — the operator (or a daemon shutdown) interrupted it; ask the
  user before reviving.

If your environment cannot run background shells, poll
`GET /api/task/<id>` at a sensible interval instead. Either way, your turn
is not done until the task is terminal AND its result has been inspected
and reported.

## Monitor and steer

- Point the user at http://127.0.0.1:4200 (live graph, transcripts, interject box).
- `GET /api/task/<id>` — status, per-node runs, outputs, LLM stats (tokens,
  cache, cost, context %).
- `GET /api/task/<id>/log/<node>/<visit>` — full agent transcript.
- `handle.interject({ message, interrupt? })` — queue feedback (applies at the
  next node boundary), `interrupt: true` kills the current node and re-runs it
  with the feedback. On a finished task this revives it (same container and
  session). Feedback becomes a permanent task amendment the reviewer honors.
- Inspect results from the host: `jj log` / `jj diff -r <workspace>@` in the
  target repo — never run jj inside the workspace dir on the host.

## Cleanup — only when the user asks

Nothing is cleaned up automatically, by design: finished tasks keep their
container, jj workspace, and history so they can be inspected, diffed, and
revived via interject. Do NOT clean up on your own initiative — losing an
agent's workspace loses work. When the user explicitly asks:

- `await af.task(id).cleanup({ container: true })` — remove the container only
  (disables revive; workspace and history stay).
- `await af.task(id).cleanup({ workspace: true })` — jj workspace forget +
  delete the workspace dir.
- `await af.task(id).remove()` — full teardown and drop from the board.

The dashboard has equivalent buttons per task. Cleanup of a running task is
refused; stop it first.
