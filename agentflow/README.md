# agentflow

Orchestrator for coding-agent tasks. Each task runs Claude Code inside a docker
container on a jujutsu workspace of the target repo, driven through a workflow
graph (implement, verify, review, loop until approved). A dispatcher LLM spawns
and monitors tasks through a typed Deno SDK; a web dashboard shows the live
node graph per task.

Built on RivetKit actors: one durable `task` actor per task (state, events,
websocket realtime) plus a `board` actor indexing all tasks. The workflow
engine itself is effect-ts. State survives daemon restarts in the rivet
engine's RocksDB store.

## Run

```sh
# once: build the task container image
docker build -t agentflow:latest image/

# daemon (rivet engine on :6420, dashboard + sdk on :4200)
RIVET_RUN_ENGINE=1 deno task daemon
```

### Per-machine setup: Claude credential

Agents inside containers authenticate with a long-lived OAuth token from your
Claude subscription. Containers can't reach the host keychain, so on every new
machine, once:

```sh
claude setup-token          # opens browser oauth, prints a token
mkdir -p ~/.config/agentflow
pbpaste > ~/.config/agentflow/token   # or paste into the file with an editor
chmod 600 ~/.config/agentflow/token
```

The daemon injects it into task containers as `CLAUDE_CODE_OAUTH_TOKEN`
(setting that env var on the daemon works too and takes precedence). Without a
token only shell-node workflows run. If agents start failing with auth errors
months later, the token has expired: rerun `claude setup-token`.

## Dispatch a task

Scripts import the SDK by URL; no checkout of this repo needed:

```ts
import { connect } from "http://127.0.0.1:4200/sdk.ts";

const af = connect();
const { id, record } = await af.run({
  repo: "/abs/path/to/jj/repo",       // omit for a throwaway scratch dir
  task: "add a --json flag to the export command",
  gates: "nix develop -c cargo test", // verify node runs this
  workflow: "implement-review",       // or "quick", or an inline graph
  gh: false,                          // true injects GH_TOKEN (push, PRs)
});
```

```sh
deno check --allow-import=127.0.0.1:4200 dispatch.ts   # verify before executing
deno run --allow-net --allow-env --allow-sys --allow-import=127.0.0.1:4200 dispatch.ts
```

Workflows are data: nodes of type `agent | shell | review` and edges with
`when` conditions (`ok | fail | approve | request_changes`). A loop is an edge
pointing backwards; `maxVisits` per node bounds it. Node `run` templates can
reference `{{task}}`, `{{gates}}`, `{{iteration}}`, and `{{<nodeId>}}` for
another node's last output. The full types are documented in the served
`sdk.ts` itself.

## Inspecting a node

Click a node in the graph. The output pane has three tabs: summary (each
visit's final result text), full (the complete stream-json transcript —
assistant messages, tool calls, tool results — stored under
`~/.local/state/agentflow/logs/<task>/`), and config (the node's definition,
edges, and prompt/command template). Running nodes stream live in both output
modes. Agent nodes run with `--output-format stream-json`; the engine parses
the final result event for summaries, verdict parsing, and `{{node}}`
template variables.

## Human in the loop

Queue feedback for a running task from the dashboard (input under the log
pane) or the SDK:

```ts
await af.task(id).interject({ message: "use argparse, not manual parsing" });
await af.task(id).interject({ message: "stop, wrong file", interrupt: true });
```

Plain interject applies at the next node boundary. With `interrupt` the
current node's process is killed and the node re-runs immediately with the
feedback injected; agent sessions resume, so the agent keeps its context.
Every piece of feedback also becomes a permanent amendment to the task that
the review node sees as requirements — otherwise the adversarial reviewer
rejects operator-requested work as scope creep (observed in practice).

## Docker inside tasks

`docker: "socket"` mounts the host docker socket into the task container:
fast, but containers the agent starts are siblings on your daemon with no
isolation. `docker: "dind"` runs a private dockerd in a privileged container
with `/var/lib/docker` on an anonymous volume (overlayfs cannot nest);
isolated, slower to start, pulls its own images. Both verified on orbstack.

## How the jj side works

The container mounts the repo at `/repo` and an empty task dir at `/ws/<id>`,
then runs `jj workspace add` from inside, so the workspace's pointer file
holds container paths. All commits and the op log live in the shared repo
store, which means plain `jj log` / `jj diff -r <workspace>@` in the repo on
the host shows the agent's work live. Never run jj inside the workspace
directory on the host; it only resolves inside the container. `remove` tears
down the container and runs `jj workspace forget`.

## Notes and sharp edges

- The task image is `nixos/nix` based. Two fixes baked into the Dockerfile:
  `/etc/passwd` and `/etc/group` are materialized from their nix-store
  symlinks because runc refuses them during `docker exec`, and claude-code
  comes from nixpkgs because the npm build expects `/lib64/ld-linux`.
- The dashboard never talks to the rivet engine. It uses plain fetch + SSE
  against `:4200/api/*`, which the daemon bridges to actors with the
  in-process client. The browser rivetkit client was tried first and is
  unusable over plain HTTP/1.1: it sends streaming request bodies, which
  Chrome rejects with `ERR_ALPN_NEGOTIATION_FAILED`. A `/rivet/*` passthrough
  proxy remains for experiments but nothing depends on it.
- Stopping the daemon: kill the deno process and `rivet-engine` — the engine
  is a child process that survives `pkill -f "deno task daemon"` and keeps
  port 6420. If actors return 503/`no_envoys` after unclean restarts, stop
  everything and wipe the engine state
  (`~/Library/Application Support/rivet-engine/db` on macOS,
  `~/.local/share/rivet-engine/db` on Linux); task history is lost, repos and
  workspaces are untouched.
- Review nodes must end with `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES`;
  the bundled review prompt already does. A missing verdict counts as `fail`.
- Nothing is cleaned up automatically: finished tasks keep container +
  workspace so they can be inspected and revived. Cleanup is explicit —
  `cleanup({container, workspace})` (granular, keeps the board record) or
  `remove()` (full teardown + board removal), both also available as buttons
  in the dashboard task header. Cleanup while running is refused.
