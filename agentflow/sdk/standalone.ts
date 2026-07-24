/**
 * # agentflow SDK
 *
 * Orchestrates coding-agent tasks: each task runs Claude Code or Codex inside a
 * docker container on an isolated jujutsu workspace of the target repo, driven
 * by a workflow graph whose nodes pick their own agent and model, with live
 * events and human-in-the-loop steering.
 *
 * This file is self-contained and importable by URL — no repo checkout, no
 * dependencies:
 *
 * ```ts
 * import { connect } from "http://127.0.0.1:4200/sdk.ts";
 *
 * const af = connect();
 * const { id, record } = await af.run({
 *   repo: "/abs/path/to/jj/repo",        // omit for a throwaway scratch dir
 *   title: "export --json flag",         // concise, for the dashboard
 *   task: "add a --json flag to the export command",
 *   gates: "nix develop -c cargo test",  // how the repo is checked, see SpawnRequest.gates
 *   workflow: "implement-review",        // see BundledWorkflowName for what each does
 * }, { onEvent: (e) => console.log(e) });
 * console.log(record.status);            // "succeeded" | "failed" | "stopped"
 * ```
 *
 * ## Running a dispatcher script
 *
 * ```sh
 * deno check --reload=http://127.0.0.1:4200/sdk.ts --allow-import=127.0.0.1:4200 script.ts
 * deno run --reload=http://127.0.0.1:4200/sdk.ts --allow-net --allow-import=127.0.0.1:4200 script.ts
 * ```
 *
 * Always pass that `--reload`: this file is served from a fixed URL and deno
 * caches remote modules forever, so without it a script silently runs against
 * whatever version of the SDK was first downloaded on this machine.
 *
 * ## Prefer the CLI for interactive work
 *
 * If you are an agent with a shell, `af` is on PATH and does everything this SDK
 * does without writing a script, with output sized for reading:
 *
 * ```sh
 * af ls                      # every task, one line each
 * af show <id>               # graph position, per-node status, cost, context%
 * af log <id> <node> --index # one line per transcript event — then fetch only what matters
 * af wait <id>               # block until the task settles (backgroundable)
 * af help                    # full command reference; af help <topic> for concepts
 * ```
 *
 * Reach for the SDK when you need to script a fan-out, drive many tasks from
 * one process, or react to events programmatically.
 *
 * ## Where to look for more
 *
 * The concepts are documented once, in the places that cannot drift from the
 * code: the types below carry their own semantics (start at `WorkflowNode`,
 * `OutcomeContract`, `SpawnRequest`, `RerunOptions`), and `af help
 * workflow|events|monitor|rerun|cache` explains each in depth. This docstring
 * deliberately does not restate either.
 *
 * - `af.workflows()` or `GET /api/workflows`: the full node/edge definitions and
 *   prompt templates of every bundled workflow — the reference graphs to copy.
 * - `GET /api/board`: all known tasks with statuses.
 * - `GET /api/task/<id>`: one task's full record (same as `handle.getState()`).
 * - `GET /api/task/<id>/log?since=<seq>`: the task's event history — what
 *   happened while you were away, without a live connection.
 * - `GET /api/task/<id>/log/<node>/<visit>`: one node run's transcript. Add
 *   `?index`, `?events=A-B`, `?grep=RE&context=N`, or `?render` — see
 *   TaskHandle.transcript. The same file is on disk at
 *   `~/.local/state/agentflow/logs/<task>/<node>-<visit>.log`.
 * - Dashboard for humans: http://127.0.0.1:4200 — live graph, logs, interject box.
 * - If these endpoints refuse connections the daemon isn't running. On a machine
 *   where it is a launchd service, `launchctl kickstart -k
 *   gui/$(id -u)/org.nixos.agentflow` restarts it and /tmp/agentflow.log says
 *   why it stopped; otherwise ask the operator. The daemon repo is
 *   ~/.dotfiles/agentflow and its README.md covers credentials, docker modes,
 *   jj mechanics, and troubleshooting.
 *
 * ## Writing a graph
 *
 * A workflow is nodes plus edges, and a node is three independent choices —
 * `exec` (what runs, and therefore which agent), `session` (which conversation
 * it belongs to), `outcome` (how its result becomes an edge label) — plus an
 * optional `model`/`effort` when one node should run differently from the rest.
 * Each is documented on `WorkflowNode`.
 * Edges route on the label; a backwards edge is a rework loop. The bundled
 * graphs are the worked examples — read one before writing your own.
 *
 * Two things are worth knowing before you start, because they are not visible
 * from the types:
 *
 * - Agent nodes are cheapest to steer through `outcome`, not through prose. A
 *   `kind: "schema"` contract turns a judgement into data that other nodes read
 *   field by field (`{{review.blocking}}`), and the field `description`s are
 *   where usage guidance belongs — the engine renders them into the prompt as
 *   comments on the type, so they cannot drift from what the validator accepts.
 *   Guidance repeated in the prompt on top of that is pure cost.
 * - Nodes execute more than once by design, so a node that touches anything
 *   outside the workspace needs `effects: "external"`. Nothing here can revert
 *   a push or a PR, and `rerun({resetWorkspace: true})` does not pretend to.
 */

/** Base URL of the agentflow daemon (dashboard, this sdk, REST endpoints). */
export const DAEMON = "http://127.0.0.1:4200";

/**
 * Bundled workflows (fetch `af.workflows()` for their exact defs):
 *
 * - "implement-review" — the default. Graph:
 *   `implement(claude) → verify(claude judge) → review(codex judge) →
 *   polish(claude)`, with rework loops: verify or review returning
 *   request_changes goes back to implement. implement and polish share the
 *   "coder" session; review keeps its own and is blind — it accepts operator
 *   events only, so nothing any agent publishes about the work can reach it,
 *   and it judges the task and the diff alone. It runs on codex, so the
 *   judgement does not share the implementer's blind spots; a codex credential
 *   is required (see `af help model`).
 *
 *   Verification is an agent, not the gate command: it inspects the diff, runs
 *   the checks that cover it ({{gates}} is a suggestion), does not block on
 *   pre-existing failures, and reports what it ran so the reviewer does not
 *   run the suite a second time. Nothing re-gates after polish, which is
 *   defined as behaviour-preserving and checks its own work.
 * - "implement-review-smart" — the same workflow. It was the LLM-verification
 *   variant back when a shell-gate one existed too; the name still resolves.
 * - "quick" — single implement node, no verification, no review. Use for
 *   throwaway work or when you'll review manually.
 * - "implement-pr" — implement-review, then out into the world: an approval
 *   gate the operator answers, then one agent that owns the pull request on the
 *   thread that wrote the change — opening it, pushing revisions and answering
 *   reviewers — parked in a watch loop whose polling and re-baselining are
 *   shell. The gate is asked once, before the loop; after it the PR is the
 *   review.
 * - "survey" — a loop that looks at something outside itself and spawns or
 *   updates whatever should exist for what it finds, sleeping longer after each
 *   lap that found nothing. The task prompt says what to survey.
 */
export type BundledWorkflowName =
  | "implement-review"
  | "implement-review-smart"
  | "implement-pr"
  | "survey"
  | "quick";

/**
 * "wait" runs nothing: it parks the task until something wakes it. "claude" and
 * "codex" each run a turn of that agent — the agent is the exec, so a workflow
 * mixing them names one per node.
 */
export type NodeExec = "shell" | "claude" | "codex" | "wait";
export type NodeType = "agent" | "shell" | "review";
/**
 * "waiting" is idle on purpose and can last weeks — the graph is mid-flight and
 * `TaskRecord.wait` says what has to happen first. Not terminal (there is work
 * left) and not running (no fiber, usually no started container).
 */
export type TaskStatus =
  | "starting"
  | "running"
  | "waiting"
  | "succeeded"
  | "failed"
  | "stopped";

/** a number followed by s/m/h/d ("30s", "5m", "2h", "1d"); bare numbers are seconds */
export type Duration = string;

/** an event kind that wakes a wait node, and the outcome label its edges route on */
export interface WaitTrigger {
  kind: string;
  label: string;
}

/**
 * The timer half of a wait. The delay grows by `factor` on each consecutive
 * firing that found nothing and returns to `min` when real activity arrives, so
 * a quiet subject is polled hourly and a busy one every minute untuned.
 */
export interface WaitBackoff {
  min: Duration;
  /** ceiling (default: min, i.e. a fixed interval) */
  max?: Duration;
  /** multiplier per quiet firing (default 2; 1 for a fixed interval) */
  factor?: number;
  /** outcome label when the timer fired (default "tick") */
  label?: string;
  /** labels on the run that led back here which restart the growth */
  resetOn?: string[];
}

export interface WaitSpec {
  on?: WaitTrigger[];
  after?: WaitBackoff;
  /**
   * After the first matching event, hold this long for more and restart the hold
   * on each one. A review left as eight comments is one thing that happened.
   */
  settle?: Duration;
  /**
   * A question for the operator; its presence makes this an approval gate. The
   * dashboard renders one button per outgoing edge, so the answers are the
   * graph's, not this field's.
   */
  ask?: string;
  /** label produced by `poke()`; defaults to the timer's, then the first trigger's */
  poke?: string;
}

export type WaitReason = "event" | "timer" | "human" | "budget" | "slot";

/** a parked task. Deadlines are absolute, because the host sleeps. */
export interface WaitState {
  node: string;
  reason: WaitReason;
  since: string;
  until?: string;
  attempt?: number;
  settleUntil?: string;
  pending?: string;
  resolved?: string;
  resolvedBy?: string;
  ask?: string;
}

/** JSON Schema subset used for structured output contracts */
export interface JsonSchema {
  type?: "object" | "string" | "number" | "integer" | "boolean" | "array" | "null";
  /** rendered as a comment above the field in the type the agent is shown */
  description?: string;
  enum?: (string | number | boolean | null)[];
  const?: string | number | boolean | null;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  /** false rejects unknown keys; omitted allows them */
  additionalProperties?: boolean;
  items?: JsonSchema;
  /** union — the value must satisfy at least one branch */
  anyOf?: JsonSchema[];
  minItems?: number;
  minLength?: number;
}

/**
 * How a node's result becomes an edge label.
 *
 * `"pattern"` scrapes a regex out of the raw output — right for deterministic
 * producers like a shell script printing `ROUTE: bug`. There is no correction
 * loop, because there is nobody to correct.
 *
 * `"schema"` is for agents. Declare the JSON object the reply must be: the
 * engine renders it into the prompt as a TypeScript type, validates the reply,
 * and on a mismatch quotes the specific errors and asks for the whole object
 * again. Reasoning and label travel together, so a correction swaps one
 * complete answer for another. (An earlier "end with VERDICT: X" convention
 * could not: correcting a bad last line returned a bare verdict and threw away
 * the review it belonged to.)
 */
export type OutcomeContract =
  | {
    kind: "pattern";
    /** regex source, matched case-insensitively; capture group 1 is the key */
    pattern: string;
    /** captured text -> edge label */
    map: Record<string, string>;
    /** label when nothing matches (default "fail") */
    fallback?: string;
    /** match only the last non-empty line (default true) */
    lastLineOnly?: boolean;
  }
  | {
    kind: "schema";
    /** the object the reply must be; shown to the agent as a TypeScript type */
    schema: JsonSchema;
    /** property carrying the routing label; must be required and a string */
    label: string;
    /** label value -> edge label; identity when omitted */
    map?: Record<string, string>;
    /** label used when the reply never validates (default "fail") */
    fallback?: string;
    /** correction attempts before giving up (default 2) */
    retries?: number;
  };

export interface WorkflowNode {
  id: string;
  /** short name for the dashboard and CLI; `description` is what reaches agents */
  label: string;
  /**
   * One line on what this node is for. It goes in the graph map every agent
   * node receives on a full turn, so write it for someone who has never seen
   * this workflow: `verify · shell` tells them nothing about what verify
   * covers, and a node that cannot tell what its neighbours already did is a
   * node that redoes their work.
   */
  description: string;
  /**
   * shell: the command. claude/codex: the prompt template.
   *
   * Variables: `{{task}}` · `{{gates}}` · `{{rubric}}` (already wrapped in its
   * own section, empty when unset) · `{{<nodeId>}}` that node's latest output ·
   * `{{<nodeId>.<field>}}` one field of a schema node's validated object, which
   * is how you hand the next agent exactly what it needs instead of a whole
   * review. Delivered events and the output contract are appended by the engine
   * — no variable involved.
   *
   * Outputs over ~4KB are not injected verbatim: the full text is written to a
   * file inside the task mount and the variable carries head/tail excerpts plus
   * the path, so a chatty node cannot inflate every prompt downstream of it.
   */
  run?: string;
  exec?: NodeExec;
  /** required for exec "wait", meaningless otherwise: what it parks for */
  wait?: WaitSpec;
  /** legacy shorthand for exec+session+outcome; see the module docs */
  type?: NodeType;
  /**
   * Conversation this node's turns belong to. "none" (default) is a cold
   * session every visit. Any other string is a key shared with other nodes
   * using the same key.
   */
  session?: string;
  /** template used once the session exists; carries only what is new */
  followUp?: string;
  /**
   * Model for this node's turns, named in whatever form its exec understands —
   * "claude-opus-5" for claude, "gpt-5.6-sol" for codex. Overrides the
   * workflow's `defaults` and the request's `agents`.
   */
  model?: string;
  /** reasoning budget for this node's turns; same precedence as `model` */
  effort?: "low" | "medium" | "high";
  /** absent: exit code decides. present: parse the reply into a label. */
  outcome?: OutcomeContract;
  /** receive delivered events at all (default true for agent execs) */
  events?: boolean;
  /**
   * Put this node's result on the event stream when it finishes (default true).
   *
   * Leave it on for anything another node might care about — it is what stops a
   * node's work going nowhere because you forgot to wire a template var for it.
   * Delivery is keyed per node, so a loop on its four hundredth lap delivers the
   * latest result rather than four hundred of them: the standing cost is one
   * line in a downstream prompt, not the history.
   *
   * Turn it off for a node whose result is only how the graph routes — a poll
   * printing `ROUTE: idle`, a bookkeeping step nobody reads. The bundled
   * `implement-pr` does this on its poll node. Suppressing also stops the output
   * being written to the refs directory, which inside a watch loop is one small
   * file per lap for the life of the task.
   *
   * Routing, `{{thisNode}}` template vars and the run history are unaffected;
   * this is only whether the rest of the workflow is told.
   */
  announce?: boolean;
  /** what `events` was called when operator notes were the only thing delivered */
  notes?: boolean;
  /**
   * Event kinds this node will see; omitted means all of them. The allowlist
   * is the one to reach for when a node's value depends on what it has NOT
   * been told — the bundled reviewer takes `["operator"]` so that no kind an
   * agent invents can brief it.
   */
  accepts?: string[];
  /** event kinds withheld from this node */
  ignores?: string[];
  /** max executions per run before the task fails (default 10) */
  /** 0 lifts the ceiling, for a node inside a loop meant to run indefinitely */
  maxVisits?: number;
  /** per-execution timeout in minutes (default: SpawnRequest.nodeTimeoutMin, else none) */
  timeoutMin?: number;
  /** "external" marks a node that touches the world outside the workspace */
  effects?: "workspace" | "external";
}

export interface WorkflowEdge {
  from: string;
  /** a node id, or the reserved "@succeeded" / "@failed" */
  to: string;
  /** which outcome label of `from` activates this edge (default "ok") */
  when?: string;
}

export interface WorkflowDef {
  name: string;
  /** node executed first; defaults to nodes[0] */
  start?: string;
  nodes: WorkflowNode[];
  edges: WorkflowEdge[];
  /** labels that mean success when no edge matches (default ["ok","approve"]) */
  successLabels?: string[];
  /**
   * What this workflow's agent nodes run as when they do not say themselves,
   * keyed by exec. Sits between the node and `SpawnRequest.agents`.
   */
  defaults?: {
    claude?: { model?: string; effort?: "low" | "medium" | "high" };
    codex?: { model?: string; effort?: "low" | "medium" | "high" };
  };
}

/** a docker volume shared between task containers; same name = shared cache */
export interface CacheVolume {
  name: string;
  /** absolute mount path inside the container */
  at: string;
}

export interface CacheConfig {
  /** share one nix store across containers built from the same image (default true) */
  nix?: boolean;
  volumes?: CacheVolume[];
  /** env pointing toolchains at those mounts (CARGO_HOME, GOCACHE, …) */
  env?: Record<string, string>;
}

export interface SpawnRequest {
  /**
   * Absolute path to a jj repo on the host; omit for throwaway scratch tasks.
   * An isolated jj workspace is created for the agent automatically — no
   * setup on your side. Base revision: the repo's current working-copy
   * parents (a sibling of `@`), so uncommitted changes in the user's working
   * copy are NOT included. The agent's work appears in the repo's normal
   * `jj log` as `af-<taskId>@`; the user's working copy is never touched, and
   * parallel tasks on the same repo are safe.
   */
  repo?: string;
  /**
   * Concise human-readable title (a few words) shown in the dashboard task
   * list and header. Always set it — without one the UI falls back to the
   * full task prompt, which can be paragraphs long.
   */
  title?: string;
  task: string;
  /**
   * A bundled workflow name (see BundledWorkflowName) or an inline
   * WorkflowDef. Default: "implement-review".
   */
  workflow?: BundledWorkflowName | WorkflowDef;
  /**
   * Graphs this task's agents may spawn children with, by the name they ask for
   * them by. Without it a child can only be one of the bundled four, which is
   * what rules out a survey that fans out to watchers of its own shape — a
   * six-node poller with its own digest comparison and cost ceiling is nothing
   * bundled.
   *
   * The `spawn` tool an agent uses takes a workflow **name**, always: a lookup
   * key resolved against this record first and the bundled one second, refused
   * if neither has it. A graph carries shell nodes, so accepting a definition
   * over that tool would put arbitrary command execution downstream of whatever
   * text the agent last read. The invariant behind the whole mechanism is that
   * every WorkflowDef that ever executes entered through a SpawnRequest like
   * this one, on the host, written by a person.
   *
   * Every entry is validated and linted here, when the task is spawned: a
   * malformed graph fails this call rather than the fan-out six hours from now,
   * and lint warnings land on the task's event stream. A name that collides
   * with a bundled one is refused — the agent is told what "survey" does by its
   * own tool, so a "survey" that means something else in one subtree is a name
   * it picks for the wrong reason.
   *
   * Not inherited: the children spawned this way carry nothing for children of
   * their own. Depth is what turns one compromised agent's reach into the whole
   * tree's, and a task that genuinely needs it gets its own declaration from
   * out here.
   *
   * This does not affect the task's own graph — that is `workflow`.
   *
   * ```ts
   * await af.spawn({
   *   workflow: "survey",
   *   task: "every PR asking for review should have a watcher: spawn one keyed " +
   *         "pr:<number> with workflow pr-babysit",
   *   childWorkflows: { "pr-babysit": JSON.parse(await Deno.readTextFile("./babysit.json")) },
   * });
   * ```
   */
  childWorkflows?: Record<string, WorkflowDef>;
  /**
   * How this repo is checked (e.g. `nix develop -c cargo test`), available as
   * `{{gates}}`. "implement-review"'s verifier is an agent, so this is a
   * suggestion to it rather than the thing that decides: it inspects the diff
   * and runs what actually covers it, which may be narrower than this or
   * wider. A shell node with `run: "{{gates}}"` in a custom graph still runs it
   * verbatim and routes on the exit code. Default: no-op.
   */
  gates?: string;
  /**
   * The standards this work is judged against, injected as `{{rubric}}` into
   * every bundled prompt — the implementer, the verifier and the reviewer all
   * see the same one. This is for what `task` states but cannot enforce: what
   * "done" means on this codebase, what a reviewer here always catches, which
   * checks actually matter.
   *
   * Highest fidelity is the codebase's own. "Match the error handling in
   * src/net/retry.rs and the table-test shape in tests/parse_test.go" beats a
   * paragraph describing either, because the agent can go read them. The
   * variable renders empty when unset, so the section costs nothing.
   */
  rubric?: string;
  /** inject GH_TOKEN so the agent can push branches / open PRs */
  gh?: boolean;
  /**
   * Initial metadata, for what the spawner already knows — the PR a babysit
   * task is for, the ticket a fix is against. The same bag the task's nodes
   * write afterwards; see `TaskRecord.meta`.
   */
  meta?: Record<string, string>;
  /**
   * What this task's agent nodes run as, keyed by the exec they apply to. The
   * weakest of three levels: a node's own `model`/`effort` wins, then the
   * workflow's `defaults`, then this, then a built-in floor: claude-opus-5
   * and gpt-5.6-sol, both at effort "high".
   *
   * Keyed rather than flat because the key is what keeps a model name away from
   * an agent that never heard of it — `{ claude: { model: "claude-opus-5" } }`
   * says nothing about what a codex node in the same graph runs as.
   *
   * Effort is "low" | "medium" | "high" for both. Prefer "high" for gnarly
   * work, "low" for mechanical edits; for a raw thinking-token budget instead,
   * pass env: { MAX_THINKING_TOKENS: "..." }.
   *
   * Dispatcher LLMs should pass their own model id for claude unless told
   * otherwise.
   */
  agents?: {
    /** e.g. "claude-fable-5", "claude-opus-5", "claude-sonnet-5" */
    claude?: { model?: string; effort?: "low" | "medium" | "high" };
    /** e.g. "gpt-5.6-sol"; needs a codex credential on the daemon */
    codex?: { model?: string; effort?: "low" | "medium" | "high" };
  };
  /** what `agents.claude.model` was called when claude was the only exec */
  model?: string;
  /** what `agents.claude.effort` was called when claude was the only exec */
  effort?: "low" | "medium" | "high";
  /**
   * Per-node execution timeout in minutes. Default: none — tasks may run for
   * hours, and stop/interject are the levers for stuck runs. A timed-out node
   * fails the task; the checkpoint is kept, so resume retries it.
   */
  nodeTimeoutMin?: number;
  /**
   * Mount the host's agent config read-only into the container so agents
   * inherit the operator's global instructions and skills — ~/.claude/{CLAUDE.md,
   * skills,agents} for claude, ~/.agents/skills plus a copy of ~/.codex/AGENTS.md
   * for codex. Default true; set false for a vanilla agent. (settings.json is
   * never mounted: host hooks/permissions don't translate into containers.)
   */
  hostAgentConfig?: boolean;
  /**
   * docker access for the task: "socket" mounts the host docker socket
   * (fast, agent shares your daemon), "dind" runs a private dockerd in a
   * privileged container (isolated, slower start, pulls its own images).
   */
  docker?: "socket" | "dind";
  /** shared build caches; see the module docs for how to choose volume names */
  cache?: CacheConfig;
  /**
   * Shell command run once in the working directory before the first node:
   * warming a cache, or putting the code there at all when the task has no
   * `repo`.
   *
   * ```
   * setup: { run: "gh repo clone acme/web . && gh pr checkout 42", required: true }
   * ```
   *
   * That clone works because the working directory is empty and is not the
   * mount root — the task's harness (the `af` MCP server, the refs directory,
   * the spool) sits one level above it, where `git clone .` cannot object to it
   * and no agent trips over it. Set `gh: true` or the clone fails on auth.
   *
   * A bare string may fail without failing the task, since a cold cache is a
   * slow task rather than a wrong one. `required: true` inverts that, which is
   * what setup the first node depends on needs: six agents flailing in an empty
   * directory is a worse outcome than one clear failure.
   */
  setup?: string | { run: string; required?: boolean };
  /**
   * Stable name for the subject this task is about. Spawning again with a key a
   * live task already holds joins that task instead of creating a second, which
   * is what makes a poll loop safe to run every ten minutes. Also an address:
   * `af.task("pr:owner-repo-42").emit(...)` reaches it without knowing its id.
   */
  key?: string;
  /** the task that spawned this one; set by the daemon, not by callers */
  parent?: string;
  /**
   * Ceiling on this task's LLM spend in USD. On breach it parks with
   * `waitingOn: "budget"` rather than failing, and an ancestor's ceiling bounds
   * its whole subtree. `TaskHandle.setBudget` moves it while the task runs, and
   * a raise resumes one parked on it.
   *
   * **A stop-after line, not a cap.** It is checked before a node starts and
   * never during one, and nothing interrupts a turn in flight — so it decides
   * whether the next node begins, not what the current one may spend. A single
   * turn can cross it by a multiple: an agent that fans out to subagents spends
   * all of their budget inside one turn, and none of it is visible until that
   * turn ends. Size this for a turn you are willing to pay for rather than for
   * the total you want.
   */
  maxCostUsd?: number;
  /**
   * Minutes of total output silence before a running turn is probed and, if it
   * is provably doing nothing, re-run (default 25; 0 disables). Silence rather
   * than elapsed time, so a turn that legitimately runs for days is untouched.
   */
  idleMin?: number;
  /** what survives the task settling; containers are gigabytes, records are not */
  retain?: {
    container?: "always" | "onFailure" | "never";
    record?: Duration;
  };
  env?: Record<string, string>;
}

/** per-run LLM telemetry (agent nodes), parsed from the agent's event stream */
export interface LlmStats {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  cacheRead?: number;
  cacheWrite?: number;
  costUsd?: number;
  turns?: number;
  apiMs?: number;
  /**
   * Subagents this run started, counted from its `Task` tool calls. Their spend
   * is already inside `costUsd` — claude reports one total per turn — so a run
   * that fanned out to four of them otherwise reads as one very expensive
   * agent. Absent when it started none.
   */
  subagents?: number;
  /** context size after the final turn, and % of the 200k window */
  contextTokens?: number;
  /** the model's window, resolved from its id; absent if the model is unknown */
  contextWindow?: number;
  /** contextTokens as a % of contextWindow; absent when the window is unknown */
  contextPct?: number;
}

export interface NodeRun {
  node: string;
  visit: number;
  /** "running" while in flight, "cancelled" if killed, else the outcome label */
  status: string;
  startedAt: string;
  finishedAt?: string;
  exitCode?: number;
  /** readable text: the agent's reply, or a rendering of `data` */
  output: string;
  /** the validated object, for schema-contract nodes */
  data?: unknown;
  /** the rendered prompt (claude) or command (shell) this run received */
  prompt?: string;
  /** last time this run produced output; how a wedged turn is told from a slow one */
  lastOutputAt?: string;
  /** workspace commit when the run started, for rerun({resetWorkspace}) */
  commit?: string;
  llm?: LlmStats;
}

/**
 * One entry of a task's stream: node boundaries, status flips, operator
 * interjections, whatever an agent publishes through its `emit` tool, and
 * whatever an outside source reports. History and delivery share a substrate.
 *
 * Being on the stream does not put an event in front of an agent — most of it
 * is machine bookkeeping. Delivery is opt-in: an event reaches prompts only if
 * it names an audience in `to`.
 */
export interface TaskEventRecord {
  seq: number;
  at: string;
  /**
   * "spawned" | "status" | "node" | "workflow" are the engine's bookkeeping and
   * are never delivered; "control" / "error" are too, except when they answer
   * something a node asked for (a spawn request granted or refused), which they
   * address back to that node; "output" / "verdict" announce a finished node;
   * "operator" is an interjection; anything else was named by whoever published
   * it. Nodes filter on this via `accepts` / `ignores`.
   */
  kind: string;
  /** the event entire: one or two sentences with `refs`, a paragraph without */
  message: string;
  /**
   * Node ids this reaches, or "*" for every agent node. Absent means history
   * only — no prompt ever sees it.
   */
  to?: string | string[];
  /** pointers to the detail (paths, URLs, ids). Nothing dereferences them. */
  refs?: string[];
  /** same key = the same restated fact; only the newest per key is delivered */
  key?: string;
  /** interrupt the node's current turn and deliver now, not at the next boundary */
  urgent?: boolean;
  /** publisher: a node id, "operator", or an outside source's name */
  from?: string;
  node?: string;
  visit?: number;
  status?: string;
}

/** one row of a transcript index — see TaskHandle.transcript */
export interface TranscriptEvent {
  i: number;
  type: string;
  tool?: string;
  preview: string;
  chars: number;
  line: number;
}

export interface TaskRecord {
  id: string;
  createdAt: string;
  status: TaskStatus;
  request: SpawnRequest;
  workflow: WorkflowDef;
  container?: string;
  workspace?: string;
  cwd?: string;
  /**
   * The revision the workspace was cut from: the repo's working-copy parents at
   * spawn time, which is what `jj workspace add` uses. Worth reading before
   * anything else when a task fails in ways the change cannot explain.
   */
  base?: string;
  /**
   * Exit code of the prewarm command, if the task had one. Non-zero on a setup
   * that was not marked required means the task ran anyway with whatever setup
   * was meant to prepare possibly missing.
   */
  setupExit?: number;
  /**
   * Claude conversations by session key. `nodes` is who has already taken a
   * turn on the thread, which is what decides `run` vs `followUp`.
   */
  sessions: Record<string, { id: string; started: boolean; nodes?: string[] }>;
  runs: NodeRun[];
  /** latest readable output of each node */
  outputs: Record<string, string>;
  /** latest validated object of each schema-contract node */
  data: Record<string, unknown>;
  /**
   * Facts attached to the task by its agents (`meta` tool), its shell nodes
   * (`{"op":"meta","set":{…}}` on the outbox), or the operator (`setMeta`).
   * Flat strings; the dashboard lists them, `pr` is promoted onto the board
   * row as a link, and prompts read them as `{{meta.<key>}}`.
   */
  meta: Record<string, string>;
  /** highest event seq each session thread has already been shown */
  cursors: Record<string, number>;
  /** node this task would resume at; absent once the graph finished */
  checkpoint?: { node: string };
  /** set while status is "waiting": what this task is parked on */
  wait?: WaitState;
  /** consecutive timer firings per wait node, which its backoff grows on */
  waitAttempts?: Record<string, number>;
  /**
   * Why it stopped, which decides whether a restart may resume it unasked.
   * "daemon" is a shutdown, a crash or a host that slept — those resume on their
   * own; "operator" is an `af stop` and stays stopped.
   */
  stoppedBy?: "operator" | "daemon" | "error";
  seq: number;
  error?: string;
}

export interface TaskSummary {
  id: string;
  title?: string;
  task: string;
  repo?: string;
  status: TaskStatus;
  key?: string;
  /** the task that spawned this one, so a board can nest a fleet under its poller */
  parent?: string;
  /** while waiting: why, when the timer is due, and the question if a human owes an answer */
  waitingOn?: WaitReason;
  waitUntil?: string;
  ask?: string;
  createdAt: string;
  /** `meta.pr`, when it is an http(s) URL — the one key the board shows */
  pr?: string;
}

export type TaskEvent =
  | { kind: "update"; task: TaskRecord }
  | { kind: "node"; run: NodeRun }
  | { kind: "log"; log: { node: string; chunk: string } }
  | { kind: "event"; event: TaskEventRecord };

export interface TaskConnection {
  on(event: "update", cb: (task: TaskRecord) => void): void;
  on(event: "node", cb: (run: NodeRun) => void): void;
  on(event: "log", cb: (log: { node: string; chunk: string }) => void): void;
  on(event: "event", cb: (e: TaskEventRecord) => void): void;
  dispose(): Promise<void>;
}

export interface RerunOptions {
  /** node to restart at; defaults to the last node that did not succeed */
  from?: string;
  /**
   * "keep" continues the agent's conversation (default). "fresh" mints a new
   * session for that node's session key, so it re-reads the full prompt with
   * no memory of its earlier attempts — as do nodes sharing the key.
   */
  session?: "keep" | "fresh";
  /**
   * Restore the workspace's tracked files to their state when that node last
   * started. Files in this workspace ONLY — pushed branches, PRs, and every
   * other external effect stay as they are.
   */
  resetWorkspace?: boolean;
  /** stop a running task first, and proceed past effects: "external" nodes */
  force?: boolean;
  /**
   * An operator note recorded before the node starts, so it reaches that node on
   * the turn this rerun triggers rather than the one after. Rerouting somewhere
   * and saying why are the same act — as two calls the note either lands a turn
   * late or races the launch, and the node redoes exactly what it did before
   * while the reason sits unread on the stream.
   */
  message?: string;
}

export interface TranscriptQuery {
  /** one row per transcript event instead of the raw stream — start here */
  index?: boolean;
  /** only events [from, to] from the index, 1-based inclusive */
  events?: [number, number];
  /** only index rows matching this regex */
  grep?: string;
  /** rows of context around each grep match (default 1) */
  context?: number;
  /** readable plain text instead of raw json */
  render?: boolean;
}

/**
 * Every ceiling that could park a task on cost, with what each has spent
 * against it. Three scopes, because they fail differently: a task's own, an
 * ancestor's (which bounds its whole subtree, and is what actually stops a
 * runaway fan-out), and the host's rolling windows.
 */
export interface BudgetView {
  id: string;
  /** this task's own ceiling, if it has one */
  maxCostUsd?: number;
  /** what this task's own runs have cost */
  spentUsd: number;
  /** this task plus everything it spawned — what its own ceiling bounds */
  spentTreeUsd: number;
  /** ancestors carrying a ceiling, nearest first */
  ancestors: { id: string; maxCostUsd: number; spentTreeUsd: number }[];
  /** host-wide rolling windows from ~/.config/agentflow/config.json */
  windows: { window: string; capUsd: number; spentUsd: number }[];
}

/** where a task's files live on the host; see TaskHandle.paths */
export interface TaskPaths {
  id: string;
  /** the mount root: harness, refs, spool */
  workspace: string;
  /** where agents put anything written for another agent to read */
  refs: string;
  /**
   * What agents left for the operator to look at — screenshots, proof of a
   * run. On the mount while the workspace exists, under logs once it is torn
   * down: the one directory of a task's that teardown keeps.
   */
  artifacts: string;
  /** node transcripts, one file per node/visit */
  logs: string;
  /** working directory inside the container, which is not the mount root */
  cwd?: string;
}

export interface ArtifactListing {
  /** host path the entries are relative to */
  dir: string;
  files: { path: string; size: number; modifiedAt?: string }[];
  /** more files exist than were listed (the listing stops at 500) */
  truncated: boolean;
}

export interface EmitInput {
  /** the event itself; one or two sentences when `refs` carries the detail */
  message: string;
  /** what sort of event this is; nodes filter on it (default "external") */
  kind?: string;
  /** who is publishing, so a reader knows who is talking */
  from?: string;
  /** node ids this reaches, or "*" for every agent node (default "*") */
  to?: string | string[];
  /** pointers to the detail: paths, URLs, ids. Nothing dereferences them. */
  refs?: string[];
  /** same key = the same restated fact; only the newest per key is delivered */
  key?: string;
  /** interrupt the node's current turn and deliver now, not at the next boundary */
  urgent?: boolean;
}

export interface TaskHandle {
  getState(): Promise<TaskRecord>;
  /**
   * Leave a note for the agents — `emit` with the operator's name on it.
   * `target` scopes it to one node id (e.g. "review" to instruct only the
   * reviewer); omitted = every agent node. `urgent: true` kills the running
   * node so its re-run sees the note rather than finishing work the note has
   * already invalidated. On a finished task this revives the workflow from its
   * checkpoint. Notes never alter routing.
   */
  interject(input: { message: string; target?: string; urgent?: boolean }): Promise<TaskRecord>;
  /**
   * Publish an event onto the task's stream from outside the workflow: CI, a
   * webhook, a watcher on a PR. Agents inside the task publish through the
   * same stream with their `emit` tool and nothing downstream tells the
   * difference — a node should care what it has been told, not who held the
   * pen.
   *
   * Delivery: a node whose conversation persists is shown each event once, on
   * its next turn; a cold-session node is shown everything addressed to it,
   * every visit. Nothing is dropped for length, but events sharing a `key`
   * collapse to the newest, so a fact that keeps being restated arrives as
   * where it ended up rather than every step it took.
   */
  emit(input: EmitInput): Promise<TaskRecord>;
  /** interrupt the workflow; container + workspace kept for inspection */
  stop(): Promise<TaskRecord>;
  /** continue a stopped task from its checkpoint; on a parked task this pokes it */
  resume(): Promise<TaskRecord>;
  /**
   * "Stop waiting, go now" for a parked task. The label follows what it is
   * parked on: a timer gets its own tick, an event wait gets whatever its author
   * nominated. Refused on a gate — impatience does not say which answer you
   * meant, so use `approve` — and on a budget park without `force`, since that
   * is a limit you set.
   */
  poke(opts?: { label?: string; force?: boolean }): Promise<TaskRecord>;
  /**
   * Answer a gate. The available labels are the wait node's outgoing edge
   * labels, so a graph offering approve/revise/decline needs nothing added here.
   * `message` is recorded as an operator note before the wake, so the node it
   * lands in front of reads it on its first turn.
   */
  approve(input: { label: string; message?: string }): Promise<TaskRecord>;
  /** restart from a node; see RerunOptions */
  rerun(opts?: RerunOptions): Promise<TaskRecord>;
  /**
   * Every ceiling that could park this task on cost — its own, each ancestor's,
   * and the host's rolling windows — with what each has spent against it. What
   * a budget park does not tell you is which of the three stopped you and what
   * to raise it to; this does.
   */
  budget(): Promise<BudgetView>;
  /**
   * Move this task's own ceiling while it runs. `null` removes it.
   *
   * A raise resumes a task parked on budget, which is the case this exists for:
   * before it, the only way past that park was teardown and respawn, and a
   * week-old watcher's session thread is the thing that respawn throws away.
   * Whether the raise is enough is decided at the next node — an ancestor's
   * ceiling or a host window can still hold it, and it re-parks naming whichever
   * one does. Lowering a ceiling, or adding one to a task that had none, does
   * not resume anything.
   */
  setBudget(input: { maxCostUsd: number | null }): Promise<TaskRecord>;
  /**
   * Where this task's files are on the host. Containers stop two minutes into a
   * park, so `docker exec` is unavailable exactly when a parked watcher's refs
   * are what you want to read; these paths stay valid either way.
   */
  paths(): Promise<TaskPaths>;
  /**
   * What the task's agents left for a person to look at. Each file is served
   * at `/api/task/<id>/artifacts/<path>`, images inline on the dashboard.
   */
  artifacts(): Promise<ArtifactListing>;
  /** the task's metadata bag; see TaskRecord.meta */
  meta(): Promise<Record<string, string>>;
  /**
   * Write metadata: a string per key, null to remove one. Every change is an
   * event on the stream, delivered to the agents, so a node finds out the PR
   * moved without being told twice.
   */
  setMeta(set: Record<string, string | null>): Promise<TaskRecord>;
  /** the task's current graph */
  workflow(): Promise<WorkflowDef>;
  /**
   * Replace the graph. Validated whole — a bad edit is rejected, not
   * half-applied. Takes effect at the next node boundary (a running node
   * keeps the prompt it was handed); pass interrupt to kill the current node
   * so it re-runs under the new definition immediately. Editing a finished
   * task's workflow and then calling rerun is the normal iterate loop.
   */
  setWorkflow(def: WorkflowDef, opts?: { interrupt?: boolean }): Promise<TaskRecord>;
  /** the graphs this task hands its children */
  childWorkflows(): Promise<Record<string, WorkflowDef>>;
  /**
   * Replace them, checked exactly as spawn checks them. Only children spawned
   * after this see it — the ones already running hold the graph they were
   * created with, so a swap moves the fleet's next reviewers without disturbing
   * the reviews in flight. Pass {} to withdraw all of them.
   */
  setChildWorkflows(defs: Record<string, WorkflowDef>): Promise<TaskRecord>;
  /**
   * Replace the task text — what `{{task}}` renders and what every judge is
   * measuring against. A note adds to the task and cannot withdraw from it: a
   * cold-session judge re-reads the original text every visit, so it goes on
   * failing the work for a requirement you removed. The replacement is
   * published to every agent node as well, since a warm thread re-reads
   * nothing. `interrupt` stops the running turn rather than letting it finish
   * against text that is now void.
   */
  setTask(text: string, opts?: { interrupt?: boolean }): Promise<TaskRecord>;
  /** the task's event history, optionally only what is newer than `since` */
  events(since?: number): Promise<TaskEventRecord[]>;
  /**
   * One node run's transcript. Called bare it returns the whole raw stream,
   * which is routinely hundreds of KB — do not read that into a context
   * window. Start with `{index: true}` for one row per event, then pull what
   * you need with `{events: [40, 55], render: true}` or `{grep: "..."}`.
   */
  transcript(node: string, visit: number, q?: TranscriptQuery): Promise<string | TranscriptEvent[]>;
  /**
   * granular cleanup keeping the task record on the board. container: docker
   * rm (disables revive). workspace: jj workspace forget + delete its dir.
   * Refused (throws) while the task is running.
   */
  cleanup(opts: { container?: boolean; workspace?: boolean }): Promise<TaskRecord>;
  /** stop + full teardown + drop the task from the board */
  remove(): Promise<void>;
  connect(opts?: { since?: number }): TaskConnection;
}

export interface SpawnResult {
  id: string;
  handle: TaskHandle;
  record: TaskRecord;
  /**
   * A live task already held `req.key`, so this call joined it and created
   * nothing. That is the point of a key — a loop can re-assert what should
   * exist on every lap — but a caller that meant to start fresh work needs to
   * know it did not.
   */
  joined: boolean;
}

/** what `connect()` hands back: the board, and a handle onto any one task */
export interface AgentflowClient {
  /** all known tasks, newest first */
  list(): Promise<TaskSummary[]>;
  /** bundled workflow definitions, keyed by name — the reference graphs */
  workflows(): Promise<Record<string, WorkflowDef>>;
  /**
   * Block until an already-spawned task settles, and return its record. Safe on
   * a task that already finished. For watcher scripts run after a spawn.
   */
  wait(id: string): Promise<TaskRecord>;
  /** a handle onto one task, by id or by key */
  task(id: string): TaskHandle;
  /**
   * Spawn a task. Prefer a readable kebab-case `id` ("fix-auth-tests") — it
   * names the container (`af-<id>`) and the jj workspace too, both of which the
   * operator reads in their own repo weeks later. Omitted = random. Reusing an
   * existing id throws rather than silently attaching to the old task.
   */
  spawn(req: SpawnRequest & { id?: string }): Promise<SpawnResult>;
  /** spawn and block until the task settles */
  run(
    req: SpawnRequest & { id?: string },
    opts?: { onEvent?: (e: TaskEvent) => void },
  ): Promise<{ id: string; record: TaskRecord }>;
}

// ---------------------------------------------------------------------------
// transport: plain fetch + SSE against the daemon

const api = async (base: string, path: string, init?: RequestInit) => {
  const resp = await fetch(`${base}${path}`, init);
  const raw = await resp.text();
  const ct = resp.headers.get("content-type") ?? "";
  const body = ct.includes("json") && raw ? JSON.parse(raw) : raw;
  if (!resp.ok) throw new Error(body?.error ?? raw ?? `${resp.status} ${resp.statusText}`);
  return body;
};

const post = (base: string, path: string, body?: unknown) =>
  api(base, path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });

/** minimal SSE client: named events, JSON payloads, abortable */
const eventStream = (url: string): TaskConnection => {
  const ctrl = new AbortController();
  // deno-lint-ignore no-explicit-any
  const handlers = new Map<string, ((data: any) => void)[]>();

  const pump = async () => {
    const resp = await fetch(url, {
      signal: ctrl.signal,
      headers: { accept: "text/event-stream" },
    });
    if (!resp.ok || !resp.body) throw new Error(`event stream failed: ${resp.status}`);
    const reader = resp.body.pipeThrough(new TextDecoderStream()).getReader();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) return;
      buf += value;
      let sep: number;
      while ((sep = buf.indexOf("\n\n")) >= 0) {
        const frame = buf.slice(0, sep);
        buf = buf.slice(sep + 2);
        let name = "message";
        let data = "";
        for (const line of frame.split("\n")) {
          if (line.startsWith("event:")) name = line.slice(6).trim();
          else if (line.startsWith("data:")) data += line.slice(5).trim();
        }
        const fns = handlers.get(name);
        if (!fns?.length || !data) continue;
        const parsed = JSON.parse(data);
        for (const fn of fns) fn(parsed);
      }
    }
  };

  pump().catch((e) => {
    if (!ctrl.signal.aborted) console.error("event stream dropped:", e);
  });

  return {
    // deno-lint-ignore no-explicit-any
    on(event: string, cb: (data: any) => void) {
      const fns = handlers.get(event) ?? [];
      fns.push(cb);
      handlers.set(event, fns);
    },
    dispose: () => {
      ctrl.abort();
      return Promise.resolve();
    },
  } as TaskConnection;
};

export const TERMINAL_STATUSES = ["succeeded", "failed", "stopped"];

/**
 * What `run()` stops on. "waiting" is included even though it is not terminal:
 * a parked task may sit for hours or weeks, and a caller that blocks on one
 * would hang rather than finish. Check `record.wait` to see what it is parked
 * on, and `poke()` / `approve()` to move it.
 */
export const SETTLED_STATUSES = [...TERMINAL_STATUSES, "waiting"];

export function connect(endpoint = DAEMON): AgentflowClient {
  const task = (id: string): TaskHandle => ({
    getState: () => api(endpoint, `/api/task/${id}`),
    interject: (input) => post(endpoint, `/api/task/${id}/interject`, input),
    emit: (input) => post(endpoint, `/api/task/${id}/emit`, input),
    stop: () => post(endpoint, `/api/task/${id}/stop`),
    resume: () => post(endpoint, `/api/task/${id}/resume`),
    poke: (opts) => post(endpoint, `/api/task/${id}/poke`, opts ?? {}),
    approve: (input) => post(endpoint, `/api/task/${id}/approve`, input),
    rerun: (opts) => post(endpoint, `/api/task/${id}/rerun`, opts ?? {}),
    budget: () => api(endpoint, `/api/task/${id}/budget`),
    setBudget: (input) => post(endpoint, `/api/task/${id}/budget`, input),
    paths: () => api(endpoint, `/api/task/${id}/paths`),
    artifacts: () => api(endpoint, `/api/task/${id}/artifacts`),
    meta: () => api(endpoint, `/api/task/${id}/meta`),
    setMeta: (set) => post(endpoint, `/api/task/${id}/meta`, { set }),
    workflow: () => api(endpoint, `/api/task/${id}/workflow`),
    setWorkflow: (def, opts) =>
      post(endpoint, `/api/task/${id}/workflow`, { workflow: def, ...opts }),
    childWorkflows: () => api(endpoint, `/api/task/${id}/child-workflows`),
    setChildWorkflows: (defs) =>
      post(endpoint, `/api/task/${id}/child-workflows`, { childWorkflows: defs }),
    setTask: (text, opts) => post(endpoint, `/api/task/${id}/task`, { task: text, ...opts }),
    events: (since = 0) => api(endpoint, `/api/task/${id}/log?since=${since}`),
    transcript: (node, visit, q = {}) => {
      const p = new URLSearchParams();
      if (q.index) p.set("index", "1");
      if (q.events) p.set("events", `${q.events[0]}-${q.events[1]}`);
      if (q.grep) p.set("grep", q.grep);
      if (q.context !== undefined) p.set("context", String(q.context));
      if (q.render) p.set("render", "1");
      const qs = p.toString();
      return api(endpoint, `/api/task/${id}/log/${node}/${visit}${qs ? `?${qs}` : ""}`);
    },
    cleanup: (opts) => post(endpoint, `/api/task/${id}/cleanup`, opts),
    remove: () => post(endpoint, `/api/task/${id}/remove`).then(() => undefined),
    connect: (opts) =>
      eventStream(
        `${endpoint}/api/task/${id}/events${
          opts?.since !== undefined ? `?since=${opts.since}` : ""
        }`,
      ),
  });

  // the semantics live on AgentflowClient, which is what a caller reads
  return {
    list: () => api(endpoint, "/api/board"),

    workflows: () => api(endpoint, "/api/workflows"),

    async wait(id: string): Promise<TaskRecord> {
      const handle = task(id);
      const conn = handle.connect();
      const viaEvents = new Promise<TaskRecord>((resolve) => {
        conn.on("update", (t) => SETTLED_STATUSES.includes(t.status) && resolve(t));
      });
      const current = await handle.getState();
      const record = SETTLED_STATUSES.includes(current.status) ? current : await viaEvents;
      await conn.dispose();
      return record;
    },

    task,

    async spawn(req: SpawnRequest & { id?: string }): Promise<SpawnResult> {
      const { id, record, joined } = await post(endpoint, "/api/spawn", req);
      return {
        id: id as string,
        handle: task(id),
        record: record as TaskRecord,
        joined: joined === true,
      };
    },

    async run(req: SpawnRequest & { id?: string }, opts?: { onEvent?: (e: TaskEvent) => void }) {
      const { id, handle } = await this.spawn(req);
      const conn = handle.connect();
      const record = await new Promise<TaskRecord>((resolve) => {
        conn.on("update", (t) => {
          opts?.onEvent?.({ kind: "update", task: t });
          if (SETTLED_STATUSES.includes(t.status)) resolve(t);
        });
        conn.on("node", (run) => opts?.onEvent?.({ kind: "node", run }));
        conn.on("log", (log) => opts?.onEvent?.({ kind: "log", log }));
      });
      await conn.dispose();
      return { id, record };
    },
  };
}
