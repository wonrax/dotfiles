# agentflow

Orchestrator for coding-agent tasks. Each task runs Claude Code or Codex inside a docker container
on a jujutsu workspace of the target repo, driven through a workflow graph (implement, verify,
review, loop until approved) whose nodes pick their agent and model individually. A dispatcher LLM
spawns and monitors tasks through a typed Deno SDK; a web dashboard shows the live node graph per
task.

One deno process, no external services: task records live in memory and are mirrored to
`~/.local/state/agentflow/tasks/<id>.json`, so checkpoints survive a restart. The workflow engine is
effect-ts; the dashboard and SDK both talk plain REST + SSE to `:4200`.

## Run

```sh
# once: build the task container image
docker build -t agentflow:latest image/

# daemon (dashboard, sdk, and api on :4200)
deno task daemon

# typecheck, and the regression suite
deno task check
deno task test
```

`deno task test` runs `scripts/sandbox-e2e.ts`, which boots a daemon of its own on :4297 with a
throwaway `HOME` and tears it down after. It covers the parts where a regression is silent rather
than loud — what a container may make the host run, the working directory a repo-less task gets, and
the ceilings that park a task — so it has to spawn deliberately broken tasks and park one on a $0
budget, and it does that on a board that is not yours. Shell graphs throughout, so it needs docker
and the image but no claude credential. The rest of `scripts/` are one-off probes that talk to
whatever daemon you already have running.

### As a service (nix-darwin)

`darwin.nix` runs the daemon as a launchd **user** agent and puts `af` on PATH, both from
`package.nix`. A user agent rather than a system daemon because everything it touches belongs to the
user: their docker, their `gh` and `jj` credentials, the `~/.claude` it mounts read-only into task
containers, and the `~/.local/state/agentflow` it checkpoints into. None of that exists for root.

```sh
darwin-rebuild switch --flake ~/.dotfiles       # deploys the current source
launchctl kickstart -k gui/$(id -u)/org.nixos.agentflow
tail -f /tmp/agentflow.log
```

**Editing this directory is not deploying it.** The service runs from a nix store path, so a change
here reaches it on the next `switch` — which is the point: the store path changes, the plist changes
with it, and nix-darwin boots the agent out and back in on the new code. To test a change without
switching, run a second daemon on another port (`AGENTFLOW_PORT=4211 deno task daemon`) and point the
CLI at it with `AGENTFLOW_URL`; starting one on 4200 just fails to bind while the service holds it.

Two details worth knowing. `node_modules` is filtered out of the store copy — 288M, and deno rebuilds
it from the lockfile — so the daemon runs with `--node-modules-dir=none` and resolves npm
dependencies from `DENO_DIR` under the user's cache instead, which means the first start after a
dependency change needs the network. And `ExitTimeOut` is raised to 60s because stopping the daemon
checkpoints every running task and kills the agent turns inside their containers; launchd's default
20s can cut that short and leave orphans contending with a later revive on the same claude session.

### Per-machine setup: Claude credential

Agents inside containers authenticate with a long-lived OAuth token from your Claude subscription.
Containers can't reach the host keychain, so on every new machine, once:

```sh
claude setup-token          # opens browser oauth, prints a token
mkdir -p ~/.config/agentflow
pbpaste > ~/.config/agentflow/token   # or paste into the file with an editor
chmod 600 ~/.config/agentflow/token
```

The daemon injects it into task containers as `CLAUDE_CODE_OAUTH_TOKEN` (setting that env var on the
daemon works too and takes precedence). Without a token only shell-node workflows run. If agents
start failing with auth errors months later, the token has expired: rerun `claude setup-token`.

### Per-machine setup: Codex credential

Only needed if a workflow has `codex` nodes. The two agents authenticate nothing alike, and it is
worth knowing why this section exists at all. Claude's credential is one opaque bearer token
(`sk-ant-oat01…`, not a JWT, no decodable expiry) handed to the container as an environment
variable — nothing in there ever writes it, so any number of containers can share one safely.
Codex's is a JWT plus a refresh token in a *file*, and the CLI rewrites that file whenever it
refreshes. A file with N writers is the thing openai's own CI guidance warns about — one
`auth.json` per serialized stream, and a fan-out of six reviewers is not one.

So each task gets its own copy, seeded fresh on every run (a parked watcher re-seeds each time it
wakes). Measured on this account, the access token's lifetime is 10 days, which means a container
holding a copy for the length of one task essentially never reaches a refresh — the seed just has
to be newer than that.

Do not mount `~/.codex/auth.json` into the containers instead. Read-write puts every task's codex
on one file; read-only forbids the refresh outright. The copy costs nothing and avoids both.

Seed it from a login that exists for this. `~/.codex/auth.json` works and is the same format, but
it is your desktop app's live session — on the rare occasion a container does refresh, a rotated
token is better spent on something disposable:

```sh
CODEX_HOME=~/.config/agentflow/codex-home codex login
cp ~/.config/agentflow/codex-home/auth.json ~/.config/agentflow/codex-auth.json
chmod 600 ~/.config/agentflow/codex-auth.json
```

The copy is retaken on every run, so reseeding the same way is also the fix if codex nodes start
failing to authenticate.

## Dispatch a task

Scripts import the SDK by URL; no checkout of this repo needed:

```ts
import { connect } from "http://127.0.0.1:4200/sdk.ts";

const af = connect();
const { id, record } = await af.run({
  repo: "/abs/path/to/jj/repo", // omit for a throwaway scratch dir
  task: "add a --json flag to the export command",
  gates: "nix develop -c cargo test", // how this repo is checked; a hint to the verifier
  rubric: "match the flag handling in src/cli/args.rs", // standards, see below
  workflow: "implement-review", // or "quick", or an inline graph
  gh: false, // true injects GH_TOKEN (push, PRs)
});
```

```sh
RELOAD=--reload=http://127.0.0.1:4200/sdk.ts
deno check $RELOAD --allow-import=127.0.0.1:4200 dispatch.ts   # verify before executing
deno run $RELOAD --allow-net --allow-import=127.0.0.1:4200 dispatch.ts
```

`--reload` matters: `/sdk.ts` is a stable URL whose contents change with the daemon, and deno caches
remote modules indefinitely. Without it a script runs against whichever SDK version this machine
downloaded first.

## The `af` CLI

`af` does everything the SDK does without writing a script, and is the right tool for both a human
checking in and an agent deciding what to do next. It is on PATH via nix (see above); `./af` in this
directory is the same thing against the checkout rather than the store.

```sh
af ls                          # every task, one line each
af show <id>                   # per-node status, visits, duration, ctx%, cost
af log <id>                    # the task's event history, in order
af log <id> <node> --index     # one line per transcript event
af log <id> <node> --events 40-55
af wait <id>                   # block until it settles; exit 1 failed, 2 timeout
af rerun <id> --from review --session fresh
af task <id> [--set new.md]    # read, or rewrite, the task text it works from
af artifacts <id>              # what its agents left for you to look at, as host paths
af meta <id> [pr=https://…]    # facts on the task: the PR it opened, whatever else was recorded
af help                        # full reference
af help workflow|model|prompt|monitor|rerun|cache|artifacts
```

## Workflows

A workflow is nodes plus edges, and a node is three independent choices:

- **`exec`** — `shell` runs a command in the workspace; `claude` and `codex` run a turn of that
  coding agent there. The agent is the exec rather than a `provider` field beside it, so a node
  cannot name a model its agent has never heard of, and one graph can implement on claude and
  review on codex. See [Models and providers](#models-and-providers).
- **`model` / `effort`** — what this node's turns run as, both optional. Named in whatever form
  the node's exec understands (`claude-opus-5`, `gpt-5.6-sol`); effort is `low | medium | high`.
  Unset, they resolve through the workflow's `defaults[exec]`, then the task's `agents[exec]`,
  then the built-in floor. This is how one graph thinks hard about its review and cheaply about
  its formatting. See [Models and providers](#models-and-providers).
- **`session`** — which conversation the turn joins. `"none"` (default) is a cold session every
  visit. Any other string is a key: nodes sharing a key share one thread, and revisits continue it,
  sending `followUp` instead of `run` so only the delta goes over the wire and the cached prefix
  stays put. A revisit is per *node*, not per thread — a node joining a conversation some other
  node opened gets its full `run` template once, however warm that conversation already is, and
  the workflow map, the idempotence clause and its output contract come with it.
- **`outcome`** — how the result becomes an edge label. Omitted, the exit code decides (`ok` /
  `fail`). `kind: "pattern"` scrapes a regex out of the output, for deterministic producers.
  `kind: "schema"` makes an agent answer with a validated JSON object — see below.

Edges fire on the source's label (`when`, default `ok`); a backwards edge is a rework loop bounded
by `maxVisits`; edges may target `@succeeded` / `@failed`. With no matching edge the task ends —
succeeded if the label is in `successLabels` (default `["ok","approve"]`). The older
`type: agent | shell | review` shorthand still works and expands to the above.

Templates in `run` / `followUp`: `{{task}}`, `{{gates}}`, `{{rubric}}`, `{{<nodeId>}}` for another
node's latest output, and `{{<nodeId>.<field>}}` for one field of a schema node's object. The full
types live in the served `sdk.ts`.

Templates are the pull side of context sharing — deterministic, and the only thing edges route on.
What a node wants to *say* rather than return goes on the event stream instead.

`exec: "wait"` is the third kind, and it runs nothing at all — see
[Waiting](#waiting-and-tasks-that-outlive-the-work).

The bundled `implement-review` is `implement → verify → review → polish`, looping back to the
implementer whenever either judge asks for changes. `implement-pr` continues past it: an approval
gate, then one agent that owns the pull request — the thread that wrote the change opens it, pushes
revisions and answers reviewers — parked in a watch loop whose polling and re-baselining are shell,
so a quiet PR costs one API call a lap and no tokens. One actor with one memory is the point: the
cold triage node that used to classify activity for a separate publisher spent its turn rebuilding
what the implementer's thread already held. `survey` is a loop that looks at something outside
itself and spawns whatever should exist for what it finds. Verification is an agent rather than the
gate command, because a command cannot tell a failure this change caused from one the repo already
had, and answers a question nobody asked — is the whole tree green? — at the cost of the whole suite.
`gates` survives as a suggestion to it. Nothing re-gates after polish either: polish is
behaviour-preserving by definition and allowed to do nothing, so a second full suite run to guard it
was pure duplicate work; it checks what it touched instead. `implement-review-smart` still resolves
to the same graph, from when the shell-gate variant existed alongside it.

## Models and providers

Which agent runs a node is its `exec`. Model and effort resolve through four levels, nearest wins:
`node.model` / `node.effort`, then the workflow's `defaults[exec]`, then the request's
`agents[exec]`, then a built-in floor — `claude-opus-5` and `gpt-5.6-sol`, both at effort `high`.

That floor is stated rather than left to each CLI, because "the CLI's default" is not one thing:
claude follows whatever the operator's subscription settles on, and codex reads `model` from a
config.toml which for these tasks is the one the engine generates into a private `CODEX_HOME` — so
the operator's own choice never reached it and the container ran on whatever the binary shipped
with. A task is worth more than the cheapest model that could have run it; anything above the floor
overrides it.

Every level is keyed by exec, which is what keeps a model name away from an agent that never heard
of it:

```jsonc
{ "agents": { "claude": { "model": "claude-opus-5", "effort": "high" },
              "codex":  { "model": "gpt-5.6-sol" } } }
```

`model` / `effort` at the top of a request still work and mean claude. Effort is
`low | medium | high` for both — codex accepts more names than that, and naming one here would make
the workflow fail the day it was pointed at claude.

Both agents get the task's MCP emit tool and the host's skills, and both are held to the same
house style. The mechanics differ: claude takes it on `--append-system-prompt`, and codex, which
has no such flag, gets it in the `AGENTS.md` of the private `CODEX_HOME` each task runs out of —
that directory also holds the credential copy and the session rollouts `codex exec resume` reads,
which is why it lives on the workspace mount and outlives the container.

Three things are thinner on codex. There is no cost telemetry, because a ChatGPT subscription has no
per-token price to total — a graph that moved its expensive step to codex reads as cheap in
`af show` and in budget ceilings, and the limit it actually hits is the subscription's. The model id
is whatever was resolved for the node rather than what codex reports, because `codex exec` does not
say what it ran as — accurate while nothing overrides it inside the container, and the only handle
there is. And the context percentage is absent either way: `contextWindow()` only knows claude's windows, and a
figure the operator uses to judge whether a task is about to run out of room is worse guessed than
omitted. Tokens and turns are reported for both.

Their `turns` differ in meaning. Claude's is assistant turns within the run; codex's is the number
of `codex exec` invocations, which is one plus any contract corrections.

`codex exec` is the integration, not the Codex SDK: the SDK shells out to `codex exec` itself, so it
would add a dependency and a node runtime inside the image for nothing. The app-server interface
(JSON-RPC over stdio) is the real escalation path if richer telemetry is ever worth a long-lived
process per container — it is what openai points at for metrics beyond what `exec` emits.

## Waiting, and tasks that outlive the work

A node with `exec: "wait"` runs no process. It parks the task — status `waiting`,
no fiber, container stopped once the wait passes two minutes — until something wakes it, and
whatever wakes it becomes the outcome label the edges route on. That is the difference between a
workflow that is a batch job and one that can watch a PR for a fortnight: the resting state costs
what a stopped container costs.

```ts
{
  id: "watch", exec: "wait", label: "Watch PR",
  description: "parks until the PR moves, and otherwise polls on a stretching delay",
  wait: {
    on: [{ kind: "review", label: "activity" }, { kind: "merged", label: "merged" }],
    settle: "45s",
    after: { min: "2m", max: "1h", factor: 2, resetOn: ["changed"] },
  },
}
```

`on` wakes on an event kind, from anywhere — `af emit`, another task, an agent's own tool. `after`
is a timer whose delay grows by `factor` on each firing that found nothing and returns to `min` when
real activity arrives, so a quiet PR is polled hourly and a busy one every minute with nothing
tuned. `resetOn` names labels on the run that led back here which also reset it, which is how a
sweep that found work goes back to a short delay.

`settle` is the one that is easy to miss: after the first matching event it holds for that long and
restarts the hold on each further one. Eight review comments left in one sitting are one thing that
happened, and without it they are eight rounds of rework. The event stream already coalesced
*delivery* through `key`; this coalesces *waking*.

`ask` makes the node an approval gate. The task parks, `af ls` shows it as **NEEDS YOU** in the same
group as the failures, and the dashboard renders the question with one button per outgoing edge —
so a graph offering `approve` / `revise` / `decline` needs nothing added to the dashboard, and one
that renames them cannot leave stale buttons behind. Answer with `af approve <id> --label L
["message"]`; the message is recorded as an operator note before the wake, so the node it lands in
front of reads it on its first turn rather than its second.

Deadlines are absolute, so a laptop that slept through one wakes up already due.

`af poke <id>` means "stop waiting, go now". It is refused at a gate — impatience does not say which
answer you meant — and on a budget park without `--force`, because that is a limit you set. An `af
interject` on a parked task wakes it too: a graph that declares what an operator note means routes
on that, which matters, because waking a watch loop on its *timer* label would send it to poll
GitHub, find nothing changed, and park again with the instruction still unread.

`af emit --urgent` wakes a parked task as well, even when its kind matches no trigger the wait node
declared — that is the difference between news that arrives now and news that arrives whenever the
poll timer next comes round, which on a backed-off watch can be hours. The two parks it cannot
clear, a gate and a budget ceiling, say so on the stream and in the CLI rather than accepting the
flag and doing nothing with it.

The failure mode this introduces is worth stating: a node the loop returns to will meet a rate limit
or a dropped connection eventually, and with no edge for `fail` that one moment ends a task meant to
run for weeks. Give those nodes a fail edge, usually back to the wait node so the backoff absorbs
the retry. `spawn` lints the graph for exactly this and records what it finds on the task.

## Keys, budgets, and tasks that spawn tasks

`key` is a stable name for what a task is *about* — a PR, an issue, a nightly job. Spawning again
with a key a live task already holds joins that task and creates nothing, which is what makes a poll
loop safe to run every ten minutes: each pass re-asserts what should exist and changes nothing when
it already does. It is also an address, so `af emit pr:owner-repo-42 "CI went red"` reaches the task
that owns that PR without anyone tracking its id.

An agent node inside a container can ask for a task of its own through the same spool the `emit`
tool writes to — no port, no token, no route to the daemon's API. The host applies the policy: a
workflow by name (a graph assembled inside a container is not something to execute), the parent's
repo or none at all, `model` and `cache` inherited rather than chosen, and a cap on live children.
Spawning is asynchronous — the spool is read when the turn ends — so the tool promises a request and
the child's id arrives as an event, which is also how the caller learns a key was already taken.

By default the names it may use are the bundled four, and `childWorkflows` on the parent's own
`SpawnRequest` adds to them:

```sh
af spawn --workflow survey --child-workflow pr-babysit=./babysit.json --task '...spawn one keyed
pr:<number> with workflow pr-babysit for every PR asking for review...'
```

That is what a survey fanning out to watchers of its *own* shape needs, since no bundled graph is a
six-node poller carrying your digest comparison and your cost ceiling. The agent's argument stays a
string throughout — a lookup key resolved against the parent's declarations first and the bundled
record second — because a graph runs shell nodes, and taking a definition over that tool would put
arbitrary commands downstream of whatever text the agent last read. The invariant is worth stating
plainly: **every workflow graph that ever executes entered through a host-side `SpawnRequest`,
written by a person.**

Each carried graph is validated and linted at `af spawn`, so a malformed one fails the parent
outright rather than the fan-out six hours later, and a name colliding with a bundled one is refused
— the agent is told what `survey` does by its own tool, so a `survey` meaning something else in one
subtree is a name it picks for the wrong reason. A name in neither set is refused with the list of
what it *may* use, published to the node that asked; a sweep loop that got nothing back would
re-request the same child every lap forever. Children do not inherit the set: a spawned watcher
spawns nothing, and passing graphs down is what turns one compromised agent's reach into the whole
tree's.

Children hang off their parent on the board as one row that opens, not forty rows burying
everything else. `retain` decides what survives them: the default keeps the container and workspace,
because a human who dispatched a task usually wants the diff afterwards, and `{container:
"onFailure", record: "90d"}` — the default for machine-spawned children — keeps the record long
after the container is gone. That record *is* the history: which PRs were reviewed, what each
concluded.

Cost has three scopes because they fail differently. `maxCostUsd` bounds one task; an ancestor's
bounds everything it spawned, which is the only scope that helps when a poller fans out; and
`~/.config/agentflow/config.json` bounds the host:

```json
{"budget": {"daily": 20, "weekly": 100}, "maxRunningTasks": 4, "maxChildren": 50}
```

**A breach parks the task, it does not fail it.** A week-old watcher killed over a cost cap loses
more than the cap saved, so it waits with `waitingOn: "budget"` and picks up when the window rolls.
The check runs before the container is built, which is also what makes `maxRunningTasks` a queue
rather than fifty containers all parked at once. `af budget <id>` says which of the three ceilings
did it and what each has spent; `af budget <id> --max-cost 80` raises this task's own and resumes it
on the spot, keeping the container and the session thread that a respawn would throw away.

**A ceiling is a stop-after line, not a cap.** It is checked before a node starts, never during one,
and nothing interrupts a turn in flight — so it decides whether the *next* node begins, not what the
current one may spend. A single turn can cross it by a multiple, and the usual reason is subagents:
an agent that fans out spends all of their budget inside one turn, and none of it lands until the
turn ends. `af show` puts a `sub` count beside the cost for exactly that, because otherwise four
agents' spend reads as one implausibly expensive one. Size the ceiling for a turn you are willing to
pay for rather than for the total you want.

### Worked example: reviewing every open PR, and keeping up with them

Two `survey` tasks, one nested inside the other, and no custom graph. The outer one owns "there should
be a reviewer per open PR"; the inner ones each own one PR. Both are the same template, because both
are the same shape of job — look at something, make the world match, sleep longer when there was
nothing to do.

```sh
af spawn --workflow survey --key prs:acme-web --title "acme/web pr reviewers" \
  --gh --max-cost 40 --model claude-opus-5 --task '
Every open pull request on acme/web that is not a draft should have a reviewer task watching it.

  gh pr list --repo acme/web --state open --json number,title,isDraft,headRefName

For each one, spawn a task keyed pr:acme-web-<number> — spawning a key that already
has a live task joins it, so run this list every lap and let the keys do the
bookkeeping. Give each child:

  workflow: survey
  title:    the PR number and a few words of its title
  setup:    gh repo clone acme/web . && gh pr checkout <number>
  task:     it owns that one PR — the prompt below

You are not reviewing anything yourself. If every open PR already has a task,
that lap is idle.'
```

The child prompt is the other half, and it is the one that does the work:

```
You own pull request acme/web#<number>, from now until it is merged or closed.

Read it with `gh pr diff` and `gh pr view --json comments,reviews,statusCheckRollup,commits`.
On your first lap, review it and post what you find with `gh pr review`. On later
laps, the question is what has changed since: a new commit to re-read, a reply to
one of your comments to answer, a check that went red. Reply where a reply is what
is wanted, and amend your review when the code moved under it.

You have already posted whatever is on the PR under your own name — read it before
adding to it, so you do not say the same thing twice to the same person.
```

Nothing else is needed. The keys make the outer lap idempotent, `idle` laps stretch the delay so a
quiet repository costs almost nothing, `acted` laps pull it back in, and `done` — the PR merged —
finishes that child, which under the default `retain` for machine-spawned tasks releases its
container and keeps the record. Those records are the review history.

`--max-cost 40` on the parent bounds the whole fleet, because an ancestor's ceiling covers its
subtree. Watch it with `af ls` (children nest under the parent in the dashboard) and steer any one of
them with `af interject pr:acme-web-42 "..."`, addressing it by key.

## Surviving restarts and a host that sleeps

Two different problems, and the second is the harder one.

**The daemon died** — a shutdown, a crash, a `kill -9`. Records still marked running have no fiber
behind them, so they are demoted to stopped and marked `stoppedBy: "daemon"`, and those resume
automatically a few at a time on the next start. `stoppedBy: "operator"` is an `af stop` and stays
stopped: without that distinction, stopping a task across a reboot would be impossible.

One error message mattered enough to change here. A `docker inspect` that fails has two very
different causes — the container is gone, or docker itself is not up yet — and the second happens
routinely when a host wakes and the daemon comes back before the docker VM does. Reading it as the
first told the operator to delete a workspace that was perfectly intact. It now waits for docker and
only calls a container missing once docker is answering.

**The daemon survived, the host did not.** Sleeping a laptop freezes the process; it comes back
holding a dead `docker exec` and an HTTP request that timed out hours ago, and the socket under it
may never produce an error. Nothing is "stopped" — the task is silently wedged.

Elapsed time cannot detect this, because an agent may legitimately work for days. Output silence
can: every agent node streams events continuously, so a turn that has produced nothing for
`idleMin` minutes (default 25) is suspicious. But a single long tool call is *also* silent, so
silence only triggers a **probe** rather than a kill — the node's process tree is sampled twice for
CPU time, and an agent blocked on a dead socket is alive burning nothing while a 40-minute build is
alive burning plenty. Only a confirmed wedge is killed, and killing it re-runs the node, which for a
persistent session means re-entering its own conversation.

The sweep also watches its own clock: a tick that arrives far later than scheduled means the process
was suspended, so every running task is probed immediately rather than waiting out an interval that
assumes the clock ran.

## Structured output

An agent node with a `kind: "schema"` contract must answer with one JSON object. You write the
schema; the engine renders it into the prompt as a TypeScript type, validates the reply, and on a
mismatch quotes the exact errors back and asks for the object again:

```
verdict: must be one of "approve" | "request_changes", got "BAD"
```

The format instruction is generated from the same schema the validator uses, so the two cannot drift
— which is how the previous convention failed. That convention asked for a final `VERDICT: X` line,
and a correction for a malformed line came back as a bare verdict that then replaced the entire
reply: the review it belonged to was silently discarded, and the rework loop received a verdict with
no reasons. Because a schema reply carries the reasoning and the label together, a correction swaps
one complete answer for another, and `{{review.blocking}}` can hand the next agent exactly the part
it needs.

Put a `description` on every non-obvious field — it becomes a comment in the type the agent reads.
Unions come from `enum` or `anyOf`. `label` names the property that decides routing and must be
required and a string. Shell nodes may carry a schema too, but get no correction attempt: there is
nobody to ask.

## Prompts and rubrics

The bundled prompts state the situation and what the node is for, then stop. They do not enumerate
what not to do: those lists cost tokens on every visit, only cover the cases somebody thought of,
and are redundant next to the reason the constraint exists. "The operator reviews your work as this
workspace's diff, so keep it there as one commit" does more than four prohibitions about jj
subcommands.

They also never restate a schema field's meaning. Field `description`s are rendered into the prompt
as comments on the type the agent must satisfy, which is the one place that cannot drift from what
the validator accepts — so the reviewer prompt says nothing about when to use `blocking`, and the
`blocking` description says all of it.

`rubric` is the standards the work is held to, injected as `{{rubric}}` into every bundled prompt.
The implementer, the verifier and the reviewer all see the same copy, which matters because the
reviewer is otherwise blind: without a rubric there is nothing holding the two sides to one
definition of done. Use it for what the task states but cannot enforce, and prefer a pointer into
the repo over prose about it — "match the error handling in `src/net/retry.rs`" is higher fidelity
than a paragraph on error handling, and it stays current. The variable renders empty when unset, so
the section costs nothing.

## Rerouting: answering the graph, or overriding it

Two ways to put a task at a node and start it, and the difference is who decided:

```sh
af approve <id> --label revise "use argparse"   # follows the graph's own edge
af rerun <id> "the plan was wrong" --from plan  # overrides it, edges ignored
```

`approve` takes the edge the wait node declares, so a graph that later routes `revise` through a
replanning step keeps working and the answer does not change. `rerun --from` goes where you said. It
works from any state — running (with `force`, which stops the turn first), finished, or parked — and
a parked task's wait is cancelled rather than re-entered with a deadline that expired while it was
away.

Both carry a message, recorded **before** the node starts so it lands on the turn they trigger rather
than the one after. That ordering is the whole point: a node sent back with no reason attached redoes
exactly what it did the first time.

Answering is normal operation; rerouting is the escape hatch, for when the destination is not one the
graph offers — a gate with only `approve` and `decline` and a change you want reworked. Prefer the
answer where one fits, because it stays correct as the workflow changes.

## Rerunning, and what cannot be undone

`af stop` kills the running node's process tree inside the container and keeps the checkpoint;
`af resume` continues from it; `af rerun --from <node>` restarts anywhere in the graph. Visit
numbers keep climbing, so history is never overwritten.

`--session fresh` mints a new conversation for that node's session key, so it retries with no memory
of earlier attempts. `--reset-workspace` restores the workspace's tracked files to their state when
that node last started.

That reset reverts **files in this workspace and nothing else**. It does not move bookmarks, un-push
a branch, close a PR, or undo an API call — and if the agent pushed a bookmark, the files roll back
while the bookmark and the remote do not, leaving them disagreeing. The defense against re-running
impure work is idempotence, not rollback: mark such a node `effects: "external"` and `rerun` refuses
without `--force` while the node's prompt gains a clause telling it to update what it already
created instead of duplicating it. The refusal asks whether such a node has actually *run*, not
whether one is reachable — a `ship` node sitting downstream of the rerun with no PR behind it has
nothing to duplicate, and a guard that cried wolf there would only teach you to force past it.

## Shared caches

The nix store is shared automatically — one docker volume per image build, mounted at `/nix` in
every task container. Without it each container downloads its own store; measured here, three task
containers had accumulated 113 GB of writable layer between them, versus 475 kB each once shared.
The volume is keyed by image id on purpose: docker only populates a named volume from the image on
first mount, so a volume from an older image would shadow the new image's `/nix` and leave the
container's profile symlinks dangling. Rebuilding the image starts a fresh volume and strands the
previous one at full size; `af volumes` marks which are leftovers and `af volumes --prune` removes
them, worth doing before a rebuild rather than after.

Setup also runs `git init` and `git add -A` in each workspace, which is why that volume no longer
grows without bound. A `nix develop` gate copies the workspace into the store to evaluate the flake,
and nix filters a directory only when there is a git index to filter against — a jj workspace has
none, so nix took the tree as it found it, `.venv` and `node_modules` and all, and again after every
edit. One store here reached 179 GB that way; the index took a 101 MB workspace to an 8 KB snapshot
that moves only when source does.

It inherits the repo's `.gitignore`, so a repo that does not ignore its build output still snapshots
it — put those directories on a volume instead. And nix reads modified tracked files from the
worktree but never sees an unstaged *new* file, so an agent that creates one and runs `nix build` on
it in the same turn has to stage it; between nodes, agentflow does.

Everything else is declared per task, because only the caller knows what the repo builds with:

```ts
cache: {
  volumes: [{ name: "cargo-global", at: "/cache/cargo" },
            { name: "myrepo-target", at: "/cache/target" }],
  env: { CARGO_HOME: "/cache/cargo", CARGO_TARGET_DIR: "/cache/target" },
}
```

Same volume name in two tasks means one shared cache — that is the whole sharing model, so a name
derived from the repo shares across tasks on it and a name with the task id isolates.
`setup: "nix develop -c true"` runs once before the first node so agent turns aren't paying tokens
to watch a cold build. `af help cache` has per-ecosystem recipes; `af volumes` lists what exists.

A setup that fails without `--setup-required` lets the task run on, which is usually right and
occasionally means every gate downstream is already doomed. So the exit code stays on the record:
`af show` prints `SETUP FAILED (exit N)` for as long as the task exists, and the agents are told
too, since they are the ones who meet it as a missing toolchain and would otherwise spend twenty
minutes working around a machine they think is broken.

## Inspecting a node

Above the graph, the metric row carries the revision the workspace was cut from under the repo path,
and a task whose prewarm failed keeps an amber notice there with the setup output one click away —
both because a task that was doomed from second zero otherwise looks perfectly healthy for half an
hour, until the first gate fails.

Click a node in the graph. The output pane has three tabs: summary (each visit's final result text),
full (the complete stream-json transcript — assistant messages, tool calls, tool results — stored
under `~/.local/state/agentflow/logs/<task>/`), and config, which shows the node's definition and
edges and lets you **edit its template in place**. Saving validates and replaces the task's graph;
it applies at the next node boundary, or immediately with "save + interrupt". The selected node also
gets "rerun from here" buttons. Running nodes stream live in both output modes.

Claude nodes run with `--output-format stream-json`; the engine parses the final result event for
summaries, outcome contracts, and `{{node}}` template variables. Agents querying transcripts should
not fetch them whole — see `af help monitor` for the index/slice/grep path.

## Events

Everything that happens to a task is one event on one append-only, seq-ordered stream — node
boundaries, status flips, operator interjections, whatever an agent publishes about its own work,
whatever an outside source reports. `af log <id>` is that stream.

Being on the stream does not put an event in front of an agent; most of it is bookkeeping that would
be noise in a prompt. **Delivery is opt-in**: an event reaches prompts only if it names an audience
in `to` (`"*"`, or node ids). Alongside it: `kind`, which nodes filter on; `refs`, pointers to the
detail that nothing dereferences, so a summary can stay a summary; `key`, marking an event that
restates a fact rather than adding one, of which only the newest is delivered; and `urgent`, which
interrupts the node's current turn and delivers the event now rather than at the next boundary.

Every node announces its own output on the stream when it finishes: a brief message (a schema
node's `summary`, otherwise the head of its output) with the full text one ref away. That is what a
node used to learn only if the graph's author remembered to wire a `{{var}}` for it. Template vars
keep the complementary job — news is pushed, but a node acting on one specific field still pulls it,
because `{{review.blocking}}` is a work order rather than an announcement. A node is never sent its
own output back.

Files an event points at belong in `/ws/<id>/refs`, which the engine creates and every agent is
pointed at — the write side in the `emit` tool's schema, the read side in the delivered-events
block. It sits beside the jj checkout rather than inside it, so a note one agent leaves for another
never shows up in the diff the reviewer is judging, and a cold session that has never run before
knows where to look instead of inventing a path of its own.

Three publishers, one stream, and nothing downstream can tell them apart — a node should care what
it has been told, not who held the pen.

Two things a task leaves for a person rather than for the next node, both on the dashboard and both
kept after the workspace is gone. **Artifacts** are files: `/ws/<id>/artifacts` (`$AF_ARTIFACTS`)
is the directory every agent turn is told about, for the screenshot of the feature working or the
log of the run that failed — the task's page lists it with images inline, `af artifacts <id>` prints
host paths, and teardown moves it under the task's logs directory instead of deleting it. Files are
served as text or image only, never as a page, since the directory is written from inside a
container. **Metadata** is a flat bag of key → string on the record: agents have a `meta` tool, a
shell node appends `{"op":"meta","set":{…}}` to `$AF_OUTBOX`, you run `af meta <id> k=v`; the
bundled `implement-pr` graph records the PR it opened as `pr`, which the board row shows as a link,
and prompts read any key as `{{meta.<key>}}`. `af help artifacts` has the details.

```ts
await af.task(id).interject({ message: "use argparse, not manual parsing" });
await af.task(id).interject({ message: "stop, wrong file", urgent: true });

// a note adds to the task; withdrawing something needs the text itself rewritten,
// because the judges are cold-session and re-read {{task}} on every visit
await af.task(id).setTask("...the whole task, minus section six...", { interrupt: true });

// from outside: CI, a webhook, a PR watcher
await af.task(id).emit({
  kind: "ci",
  key: "ci:pr-42", // supersedes the last ci:pr-42, however many there were
  from: "github",
  message: "CI on the PR went red: 2 failures in the auth suite",
  refs: ["https://github.com/o/r/actions/runs/123"],
});
```

Agents publish through an `emit` MCP tool present in every agent node. It writes to a spool on the
workspace mount that the daemon reads host-side, so a task container needs no port, no token and no
route to the daemon's API — which is unauthenticated and can stop and remove every other task on the
box. It cannot set `urgent`: the engine runs one node at a time, so the only node an agent could
interrupt is itself.

A node with a persistent session is shown each event once, and a revisit gets only what arrived
since; a cold-session node is shown everything addressed to it on every visit, because every visit
is a thread that has been told nothing. Nothing is dropped for length — an event omitted to save
tokens is the one piece of context that run needed.

Receiving is filtered per node: `accepts` (kinds it will see), `ignores` (kinds withheld), `events:
false` (off the stream entirely). The allowlist is the one to reach for when a node's value is in
what it has *not* been told — the bundled reviewer takes `accepts: ["operator"]`, so no kind an
agent invents can brief it. Operator events reach every node including that one, because without
them the adversarial reviewer rejects operator-requested work as scope creep (observed in practice).

A rerun delivers what is known **now**, never a replay of what the node saw the first time: you
rerun to get a better result, and withholding what has been learned since is how a node repeats its
mistake. What it did see is recorded as a seq range on the run, so "what did it know?" stays
answerable without re-enacting it.

## Docker inside tasks

`docker: "socket"` mounts the host docker socket into the task container: fast, but containers the
agent starts are siblings on your daemon with no isolation. `docker: "dind"` runs a private dockerd
in a privileged container with `/var/lib/docker` on an anonymous volume (overlayfs cannot nest);
isolated, slower to start, pulls its own images. Both verified on orbstack.

## How the jj side works

The container mounts the repo at `/repo` and an empty task dir at `/ws/<id>`, then runs
`jj workspace add` from inside, so the workspace's pointer file holds container paths. All commits
and the op log live in the shared repo store, which means plain `jj log` / `jj diff -r <workspace>@`
in the repo on the host shows the agent's work live. Never run jj inside the workspace directory on
the host; it only resolves inside the container. `remove` tears down the container and runs
`jj workspace forget`.

## Notes and sharp edges

- The task image is `nixos/nix` based. Two fixes baked into the Dockerfile: `/etc/passwd` and
  `/etc/group` are materialized from their nix-store symlinks because runc refuses them during
  `docker exec`, and claude-code and codex come from nixpkgs because their npm builds expect
  `/lib64/ld-linux`.
- State lives in `~/.local/state/agentflow/tasks/<id>.json`, written atomically (tmp + rename) and
  serialized per task. Writes are debounced ~250ms and forced at node boundaries and status changes,
  so a `kill -9` loses at most a few log chunks, never a checkpoint. Deleting a task file by hand is
  a supported way to forget a task, but tear down its container first.
- Claude session transcripts from every task land in `~/.local/state/agentflow/claude/projects/`
  (bind-mounted as the container's `/root/.claude/projects`), so they survive `af rm` and the host
  can count them. `CLAUDE_CONFIG_DIR=$HOME/.claude,$HOME/.local/state/agentflow/claude` makes
  `ccusage claude daily` report the operator's own sessions and agentflow's together. Codex
  rollouts are per task, under `ws/<id>/codex/sessions/`.
- Stopping the daemon: SIGINT/SIGTERM the deno process. It stops running workflows (checkpoints
  already persisted), kills in-container agent turns so a later revive doesn't contend with orphans
  on the same claude session, and flushes pending writes. Nothing else survives it — there is no
  second process, no port besides 4200, and no state store to wipe.
- A reply that misses its schema is malformed, not failed: the engine asks the same session to fix
  it (`retries`, default 2) and only then falls back to the contract's `fallback` label. Replies are
  parsed leniently — code fences and a preamble are tolerated, and the last balanced object wins —
  while the prompt still demands a bare object.
- Cancelling a node kills its process tree inside the container by walking `/proc` from a recorded
  pidfile. It does not use `ps`/`pkill`, which the image did not have — killing only the local
  `docker exec` client leaves the agent running, and a later resume would then have two writers on
  one claude session.
- The reviewer is blind by design: the task and the diff, and `accepts: ["operator"]` so nothing an
  agent publishes can reach it. That blindness used to rest on the reviewer's prompt simply not
  mentioning the scratch file the implementer wrote into — a rule enforced by omission, against an
  agent holding a shell, in a container where the file was sitting in plain sight. It is a
  subscription now. It does receive the verifier's `checks`, which is results and not reasoning:
  facts about the tree are a different thing from the case for the change, and only the facts cross,
  which is what stops it spending a round re-running a suite that just ran. It keeps its own session
  (`"reviewer"`), separate from the coder's, so a second pass can ask whether what it marked
  blocking actually landed rather than re-deriving the whole change. The tradeoff is anchoring — a
  reviewer that has already taken a position is a reviewer with a position to defend — which is the
  price of it not forgetting its own demands between rounds.
- Nothing is cleaned up automatically: finished tasks keep container + workspace so they can be
  inspected and revived. Cleanup is explicit — `cleanup({container, workspace})` (granular, keeps
  the board record) or `remove()` (full teardown + board removal), both also available as buttons in
  the dashboard task header. Cleanup while running is refused.
