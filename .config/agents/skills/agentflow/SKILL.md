---
name: agentflow
description: Dispatch coding tasks to background Claude Code agents running in isolated docker containers on jj workspaces, with implement→verify→review loops, live dashboard, and human steering. Use when the user wants to delegate/offload a coding task to a background agent, run several implementation tasks in parallel, run agents against their repos without touching the working copy, or mentions agentflow, "spawn a task/agent", "background agent", or the agent dashboard.
---

# agentflow

Orchestrator daemon on this machine (dashboard and API at http://127.0.0.1:4200)
running coding-agent tasks in docker containers on isolated jj workspaces.
The user's working copy is never touched, parallel tasks on one repo are safe,
and the agent's commits appear in the repo's normal `jj log` as `af-<id>@`.
Containers mount the host's `~/.claude` read-only, so task agents carry the
same global instructions and skills you do.

`af` is on PATH and its help is the manual — it ships with the daemon, so it is
current in a way this file cannot be, and this file does not restate it.
`af help` lists the commands; `af help
workflow|model|events|artifacts|prompt|monitor|rerun|cache|wait|budget` are the
concepts. Everything takes `--json`. Read the topic before anything non-obvious.

Never start a daemon by hand: it is a launchd user agent, already running and
back on its own after reboots — a second one just fails to bind the port. If it
is not answering, or you are changing agentflow's own code (editing the
checkout deploys nothing), `~/.dotfiles/agentflow/README.md` covers restart,
logs, and the deploy loop.

## What only you know at dispatch time

- **The id becomes the workspace name** — `af-<id>` in the user's
  `jj workspace list`, sometimes weeks later. Two to four words naming the
  change (`json-export-flag`), not a ticket number or a verb phrase. Omitted,
  it is slugified from `title`, which is a floor rather than a good name.
- **The base revision is the repo's current working-copy parents (`@-`)**, so
  the user's uncommitted changes are not included. If the task builds on
  unfinished work, ask them to commit it first.
- **Pass `--model <your exact model id>`** unless the user says otherwise.
  Omitted, the task runs at the engine's built-in floor (`af help model`), not
  the model you were dispatched as, and nothing in the output says so. Cheap
  mechanical work can justify haiku; say so when you pick it.
- **`--gates` is prompt material for the verifier agent, not a gate command** —
  verification is an agent's judgement, and gates are a suggestion to it.
- **`--max-cost` is checked between nodes, never mid-turn**, so one fan-out
  turn can cross it several times over. Size it for a turn you would pay for,
  not the total (`af help budget`). On breach the task parks rather than fails.
- Write the task and rubric by pointing at real things in the repo, not prose
  about them (`af help prompt`). When proof matters — a screenshot, the output
  of the run — ask for it in the task or rubric (`af help artifacts`).
- Scripted fan-out over many tasks: the SDK is at
  `http://127.0.0.1:4200/sdk.ts`, its types are the contract, and it must be
  imported with `--reload=http://127.0.0.1:4200/sdk.ts` or deno serves a stale
  cached copy forever.

## Monitor to completion — never fire-and-forget

Tasks run minutes to hours. Do not end your turn after spawning: run
`af wait <id>` as a background shell (`run_in_background: true`) so its exit
re-invokes you. Exit 0 succeeded, 1 failed, 2 timeout — and **3 parked on a
human**: a gate question or a budget park, which `af show <id>` explains.

When it wakes you, read in layers (`af help monitor`) instead of pulling a
transcript into context. Then:

- **succeeded** — verify before reporting:
  `jj diff -r "af-<id>@" --ignore-working-copy` in the target repo
  (`--ignore-working-copy` skips the snapshot, which fails under this
  machine's 1Password commit signing). An approving review is one agent's
  opinion, not your check.
- **failed** — read the failing node's output; a timeout or flake usually
  earns one `af resume` or `af rerun --from <node>` (`af help rerun`), then
  re-watch.
- **stopped** — check `stoppedBy`. `"operator"` is a human's decision, so ask
  before resuming. `"daemon"` restarts resume themselves, so one still sitting
  there has the reason on its event stream.
- **waiting** — working correctly, not stuck (`af help wait`).

Three calls belong to the user, not you: answering a gate they haven't weighed
in on (the gate exists to ask them), raising a budget ceiling they set, and
cleanup. Nothing is cleaned up automatically by design — finished tasks keep
container, workspace and history, and losing one loses work — so
`af cleanup`/`af rm` only when the user asks.

## Steering

A running task can be told things, not just watched: `af interject` puts a
note in front of the agents, `af emit` delivers outside news (CI went red,
review comments landed), and `af task --set` rewrites the requirements — a
note adds but cannot take away, so the cold-session judges keep failing
dropped requirements until the task text itself changes. `af help events` has
the delivery rules. Reruns are not undo: `--reset-workspace` restores
workspace files, never a push, a PR, or a deploy (`af help rerun`). Point the
user at http://127.0.0.1:4200 for the live graph, event stream, and interject
box.
