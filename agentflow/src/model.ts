import type { JsonSchema } from "./schema.ts";
export type { JsonSchema } from "./schema.ts";

/**
 * What actually runs when a node executes. "wait" runs nothing: it parks the
 * task until something wakes it, which is what lets a workflow outlive the work
 * — watching a PR, waiting on the operator, sitting out a rate limit.
 *
 * The coding agent is the exec rather than a `provider` field beside it, so a
 * node cannot name a model its agent has never heard of: every default resolves
 * under the key it applies to. A workflow may mix them — implement on claude,
 * review on codex.
 */
export type NodeExec = "shell" | "claude" | "codex" | "wait";

/** the execs that run a coding agent, as opposed to a command or nothing */
export type AgentExec = "claude" | "codex";

export const isAgentExec = (exec?: NodeExec): exec is AgentExec =>
  exec === "claude" || exec === "codex";

/**
 * Reasoning budget. The three both agents agree on — codex also takes "minimal"
 * and "xhigh", and naming those here would make a workflow that used one fail
 * only once it was pointed at claude.
 */
export type Effort = "low" | "medium" | "high";

/** what to run a provider's turns as, when a node does not say */
export interface AgentDefaults {
  model?: string;
  effort?: Effort;
}

/** legacy sugar, desugared into exec/session/outcome at load time */
export type NodeType = "agent" | "shell" | "review";

/**
 * A duration, as a number followed by s/m/h/d ("30s", "5m", "2h", "1d"). Bare
 * numbers are seconds. Parsed by `parseDuration` in workflows.ts.
 */
export type Duration = string;

/** an event kind that wakes a wait node, and the outcome label it produces */
export interface WaitTrigger {
  kind: string;
  /** edges route on this, exactly as they route on a shell node's exit */
  label: string;
}

/**
 * The timer half of a wait: fires when nothing else did. The delay grows by
 * `factor` on each consecutive firing that found nothing new and drops back to
 * `min` the moment a real event arrives, so a quiet PR is polled hourly and an
 * active one every minute without anyone tuning it.
 */
export interface WaitBackoff {
  /** first delay, and the one it returns to after any real activity */
  min: Duration;
  /** ceiling on the grown delay (default: min, i.e. a fixed interval) */
  max?: Duration;
  /** multiplier per consecutive quiet firing (default 2; 1 for a fixed interval) */
  factor?: number;
  /** outcome label when the timer is what fired (default "tick") */
  label?: string;
  /**
   * Labels which, on the run that led back here, mean the growth should start
   * over. The counter otherwise only resets when a real event wakes the node,
   * which is right for a node that waits on news and wrong for a poll loop: a
   * sweep that found work and looped back is evidence the world is busy, and
   * without naming its label here the next sleep would be as long as if it had
   * found nothing.
   */
  resetOn?: string[];
}

/**
 * What a wait node is waiting for. Any combination: `on` alone parks until
 * something happens, `after` alone is a poll loop, both together is a poll loop
 * that reacts sooner if it hears something first.
 */
export interface WaitSpec {
  on?: WaitTrigger[];
  after?: WaitBackoff;
  /**
   * After the first matching event, hold this long for more before waking, and
   * restart the hold on each one. A review left as eight comments is one thing
   * that happened, and without this it is eight rounds of rework.
   */
  settle?: Duration;
  /**
   * A question for the operator. Its presence makes this an approval gate: the
   * task parks, the dashboard shows the question with one button per outgoing
   * edge, and nothing proceeds until a human answers.
   */
  ask?: string;
  /**
   * Label produced by `af poke`, which means "stop waiting, go now". Defaults
   * to the timer's label, then the first trigger's. A gate with `ask` is never
   * poked — there is no way to guess which answer the operator meant.
   */
  poke?: string;
}

/** why a task is parked; the dashboard groups on it and `af poke` behaves per case */
export type WaitReason = "event" | "timer" | "human" | "budget" | "slot";

/**
 * A parked task, persisted on the record. Deadlines are absolute because the
 * host sleeps: a laptop that shut its lid over a 30-minute timer should wake up
 * already due, not start the 30 minutes again.
 */
export interface WaitState {
  /** node that runs when this resolves — a wait node, or one a gate held back */
  node: string;
  reason: WaitReason;
  since: string;
  /** when the timer fires, if there is one */
  until?: string;
  /** consecutive quiet firings, driving the backoff */
  attempt?: number;
  /** matching events arrived; wake once this passes with no further ones */
  settleUntil?: string;
  /** label the settling events will produce */
  pending?: string;
  /** set when something has woken this; the engine consumes it and routes */
  resolved?: string;
  /** who resolved it: an event kind, "timer", "operator" */
  resolvedBy?: string;
  /** the operator's question, copied off the node so the UI need not walk the graph */
  ask?: string;
}

/**
 * How a node's result becomes an edge label.
 *
 * "pattern" scrapes a regex out of the raw output. It suits deterministic
 * producers — a shell script that prints `ROUTE: bug` — and has no correction
 * loop, because there is nobody to ask.
 *
 * "schema" is for agents. The node declares the JSON object it must return;
 * the engine puts that contract in the prompt, validates the reply, and on a
 * mismatch asks for the whole object again with the specific errors quoted.
 * The reply carries the reasoning AND the label together, so a correction
 * replaces a complete answer with another complete answer. The older
 * last-line convention could not do that: correcting a malformed verdict got
 * back a bare verdict, and the review it was attached to was lost.
 */
export type OutcomeContract =
  | {
    kind: "pattern";
    /** regex source, matched case-insensitively; group 1 is the key */
    pattern: string;
    /** captured text (exact, or uppercased) -> edge label */
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
    /** property carrying the routing label (must be a string field) */
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
   * Legacy shorthand kept for compatibility; `normalizeWorkflow` expands it.
   * "shell" = exec shell. "agent" = exec claude on the shared "task" session.
   * "review" = exec claude, cold session, VERDICT contract.
   */
  type?: NodeType;
  /**
   * shell: the command. claude/codex: the prompt template. wait: unused.
   *
   * Variables: {{task}} · {{gates}} · {{rubric}} (pre-wrapped in its own
   * section, empty when unset) · {{<nodeId>}} that node's latest output ·
   * {{<nodeId>.<field>}} one field of a schema node's validated object.
   * Delivered events and the output contract are appended by the engine.
   * Every node's output is written to the task's refs directory; over ~4KB the
   * variable carries excerpts plus that path rather than the whole thing.
   */
  run?: string;
  exec?: NodeExec;
  /** required for exec "wait", meaningless otherwise: what it parks for */
  wait?: WaitSpec;
  /**
   * Conversation this node's turns belong to. "none" starts a cold session
   * every visit — the node has no memory of its own past runs. Any other
   * string is a session key, and nodes sharing a key share one thread, so a
   * revisit continues where it left off. Ignored by shell execs.
   * Default: "none".
   */
  session?: string;
  /**
   * Template used when the node's session already exists. Should carry only
   * what is new ({{<nodeId>}} outputs) — the thread already holds the task,
   * which keeps the cached prompt prefix stable. Defaults to `run`.
   */
  followUp?: string;
  /**
   * Model for this node's turns, overriding the workflow's and the request's.
   * Named in whatever form the node's exec understands — "opus" for claude,
   * "gpt-5.6-sol" for codex. Ignored by shell and wait.
   */
  model?: string;
  /** reasoning budget for this node's turns; same precedence as `model` */
  effort?: Effort;
  /** absent: exit code decides ("ok" / "fail"). present: parse the output. */
  outcome?: OutcomeContract;
  /** receive delivered events at all (default true for agent execs) */
  events?: boolean;
  /**
   * Put this node's result on the event stream when it finishes (default true).
   *
   * The default is right whenever another node might care what happened here,
   * which is most of them — it is what stops a node's work going nowhere
   * because the graph's author forgot to wire a template var for it. Delivery
   * is already keyed per node, so a loop that has run four hundred laps
   * delivers the *latest* result, not four hundred of them; the cost of leaving
   * this on is one line in a downstream prompt, not the whole history.
   *
   * Turn it off for a node whose result is purely how the graph routes — a poll
   * that prints `ROUTE: idle`, a bookkeeping step nobody reads. That line is
   * noise in every downstream prompt, and suppressing it also stops the output
   * being written to the refs directory, which for a node inside a watch loop
   * is one small file per lap for as long as the task lives.
   *
   * It does not affect routing, `{{thisNode}}` template vars, or the task's own
   * run history — only whether the rest of the workflow is told.
   */
  announce?: boolean;
  /** what `events` was called when operator notes were the only thing delivered */
  notes?: boolean;
  /**
   * Event kinds this node is willing to see; omitted means all of them.
   * Narrower than `ignores` and worth reaching for when a node's whole job
   * depends on NOT knowing something.
   */
  accepts?: string[];
  /**
   * Event kinds withheld from this node. Use `accepts` instead where the
   * invariant matters: the bundled reviewer takes `["operator"]`, because a
   * denylist only holds until an agent publishes under a kind nobody thought
   * to name — and that blindness used to rest on nothing but the reviewer's
   * prompt not mentioning the scratch file the implementer wrote.
   */
  ignores?: string[];
  /**
   * Max times this node may execute per run before the task fails (default 10).
   * 0 lifts the ceiling, which is what a node inside a watch loop needs — such
   * a loop is meant to run for weeks, so a visit count is the wrong guard for
   * it and `maxCostUsd` is the right one.
   */
  maxVisits?: number;
  /** per-execution timeout in minutes (default: SpawnRequest.nodeTimeoutMin, else none) */
  timeoutMin?: number;
  /**
   * Marks the node as touching the world outside the workspace — pushing a
   * branch, opening a PR, deploying, calling an API. Rerunning at or before
   * such a node needs `force`, because nothing agentflow reverts can undo it,
   * and the node's prompt gains an idempotence clause.
   */
  effects?: "workspace" | "external";
}

export interface WorkflowEdge {
  from: string;
  /** a node id, or the reserved terminals "@succeeded" / "@failed" */
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
  /**
   * Labels that mean the task succeeded when a node produces one and no edge
   * matches. Default ["ok", "approve"].
   */
  successLabels?: string[];
  /**
   * What this workflow's agent nodes run as when they do not say themselves,
   * keyed by exec. Sits between the node and `SpawnRequest.agents`, so a
   * workflow that only makes sense on a big model carries that itself instead
   * of relying on every dispatcher to remember.
   */
  defaults?: Partial<Record<AgentExec, AgentDefaults>>;
}

export const TERMINAL_NODES = ["@succeeded", "@failed"] as const;

/** a docker volume shared between task containers */
export interface CacheVolume {
  /** docker volume name; the same name in two tasks means a shared cache */
  name: string;
  /** absolute mount path inside the container */
  at: string;
}

export interface CacheConfig {
  /**
   * Share one nix store across every task container built from the same
   * image (default true). Without it each container re-downloads its own
   * /nix — tens of GB per task.
   */
  nix?: boolean;
  /** extra volumes to mount; same name across tasks = shared cache */
  volumes?: CacheVolume[];
  /** env vars pointing toolchains at those mounts (CARGO_HOME, GOCACHE, …) */
  env?: Record<string, string>;
}

/**
 * What to keep once a task is finished with. Containers and workspaces are the
 * expensive part (gigabytes each); the record and its event log are a JSON file
 * and a JSONL. Nothing here applies while a task can still run — a parked task
 * keeps everything, because it is going to need it.
 */
export interface RetainPolicy {
  /**
   * "always" (default) is the rule a human-dispatched task wants: the container
   * and workspace outlive the run so the work can be inspected and revived.
   * "onFailure" keeps them only when there is something to debug, which is what
   * a fleet of machine-spawned tasks wants — a reviewer that posted its review
   * on a merged PR has nothing anyone will open again. "never" reaps either way.
   */
  container?: "always" | "onFailure" | "never";
  /**
   * How long the record and event log survive after the task settles, as a
   * duration ("90d"). Omitted means forever. This is the history — which PRs
   * were reviewed, what each concluded — so it should outlive the container by
   * a long way.
   */
  record?: Duration;
}

export interface SpawnRequest {
  /** absolute path to a jj repo on the host; omit for throwaway scratch tasks */
  repo?: string;
  /** concise human-readable title for dashboards and listings */
  title?: string;
  /**
   * Stable name for the thing this task is about — a PR, an issue, a nightly
   * job. Spawning again with a key that a task already holds joins that task
   * instead of creating a second one, which is what makes a poll loop safe to
   * run every ten minutes: each pass re-asserts what should exist and changes
   * nothing when it already does. Also an address, so an outside watcher can
   * emit into "the task for PR 42" without tracking its id.
   * `[A-Za-z0-9_.:-]+` — it appears in URLs.
   */
  key?: string;
  /**
   * Task that spawned this one. Set by the daemon, not by callers: it decides
   * what the child may emit to and whose budget bounds it.
   */
  parent?: string;
  /**
   * Ceiling on this task's own LLM spend, in USD. On breach the task parks with
   * `waitingOn: "budget"` rather than failing — a week-old watcher killed over
   * a cost cap loses more than it saves. An ancestor's ceiling bounds its whole
   * subtree, so a limit on a poller is a limit on everything it spawns.
   */
  maxCostUsd?: number;
  /**
   * Minutes of total silence from a running agent before its turn is treated as
   * wedged rather than slow (default 25; 0 disables). The check is silence on
   * the output stream, not elapsed time, so a turn that legitimately runs for
   * days is never touched — but a claude blocked on a socket the network
   * dropped produces nothing at all, and would otherwise sit there until
   * someone noticed. A confirmed wedge is probed before anything is killed.
   */
  idleMin?: number;
  /** what survives this task settling; see RetainPolicy */
  retain?: RetainPolicy;
  /** the task prompt, available to node templates as {{task}} */
  task: string;
  /** bundled workflow name or inline definition (default "implement-review") */
  workflow?: string | WorkflowDef;
  /**
   * Graphs this task's agents may spawn children with, by the name they name
   * them with. Resolution is these first, then the bundled record, and a name
   * in neither is refused.
   *
   * The `spawn` tool's `workflow` argument stays a string either way — a lookup
   * key, never a definition — because a graph carries shell nodes, and taking
   * one over that tool would make arbitrary command execution a function of
   * whatever text the agent last read. The invariant is that every WorkflowDef
   * that ever executes entered through a host-side SpawnRequest like this one,
   * written by a person.
   *
   * Every entry is validated and linted when this task is spawned, so a
   * malformed graph is a spawn that fails now rather than a fan-out that fails
   * in six hours, and a name that collides with a bundled one is refused rather
   * than quietly meaning something else inside this subtree.
   *
   * Children do not inherit it. The reviewers a survey fans out to have no
   * business fanning out themselves, and inheriting is what turns one
   * compromised agent's reach into the whole tree's; a child that needs its own
   * set gets one from the host-side request that creates it.
   *
   * This says nothing about the task's own graph — that is `workflow`, which
   * still takes a bundled name or an inline definition.
   */
  childWorkflows?: Record<string, WorkflowDef>;
  /**
   * How this repo is checked, available as {{gates}}. The bundled verifier is
   * an agent and treats it as a suggestion — it runs what actually covers the
   * diff, which may be narrower or wider. A shell node given `run: "{{gates}}"`
   * still executes it verbatim and routes on its exit code. Default: no-op.
   */
  gates?: string;
  /**
   * The standards this work is judged against, available as {{rubric}} and
   * seen by the implementer, the verifier and the reviewer alike. For what the
   * task text states but cannot enforce: what "done" means here, what a
   * reviewer on this codebase always catches. Highest fidelity is the
   * codebase's own — point at the file that already gets it right rather than
   * describing it. The variable is empty when unset, so the section vanishes.
   */
  rubric?: string;
  /**
   * Model and effort for this task's agent nodes, keyed by exec. The weakest
   * of the three levels — a node's own setting wins, then the workflow's
   * `defaults`, then this, then a built-in floor of opus 5 / gpt-5.6-sol at
   * effort high (`AGENT_DEFAULTS` in workflows.ts).
   *
   * Keyed rather than flat because the key is what stops a model name reaching
   * an agent that has never heard of it: `{ claude: { model: "opus" } }` says
   * nothing about what the codex reviewer in the same graph runs as.
   */
  agents?: Partial<Record<AgentExec, AgentDefaults>>;
  /** what `agents.claude` was called when claude was the only exec */
  model?: string;
  /** what `agents.claude.effort` was called when claude was the only exec */
  effort?: Effort;
  /** per-node execution timeout in minutes (default: none — tasks may run for days) */
  nodeTimeoutMin?: number;
  /**
   * mount the host's agent config read-only into the container so agents
   * inherit it — ~/.claude/{CLAUDE.md,skills,agents} for claude nodes,
   * ~/.agents/skills plus ~/.codex/AGENTS.md for codex (default true)
   */
  hostAgentConfig?: boolean;
  /** inject GH_TOKEN so the agent can push branches / open PRs */
  gh?: boolean;
  /**
   * Initial metadata, for what the spawner already knows — the PR a babysit
   * task is for, the ticket a fix is against. Same bag the task's own nodes
   * write to afterwards; see `TaskRecord.meta`.
   */
  meta?: Record<string, string>;
  /**
   * give the task access to docker: "socket" mounts the host docker socket
   * (fast, zero isolation — containers the agent starts are siblings on the
   * host daemon), "dind" runs a private dockerd in a --privileged container.
   */
  docker?: "socket" | "dind";
  /** shared build caches; see CacheConfig */
  cache?: CacheConfig;
  /**
   * Shell command run once in the working directory after the container is
   * created, before the first node. For warming caches (`nix develop -c true`,
   * `cargo fetch`) so agent turns don't burn tokens waiting on a cold build,
   * and for putting the code there at all when the task has no `repo` —
   * `gh repo clone … && gh pr checkout 42` is how a PR gets reviewed without a
   * jj workspace of the operator's own checkout.
   *
   * That clone works because the working directory is empty and is not the
   * mount root: the task's harness — the MCP server, the refs directory, the
   * spool — sits one level above it, out of the way of a `clone .` that would
   * otherwise refuse to write into a directory with files already in it.
   *
   * A bare string may fail without failing the task: a cold cache is a slow
   * task, not a wrong one. `required: true` inverts that, which is what setup
   * the first node depends on needs — six agents flailing in an empty directory
   * is a worse outcome than one clear failure.
   */
  setup?: string | { run: string; required?: boolean };
  /** extra env vars for the container */
  env?: Record<string, string>;
}

/**
 * "waiting" is idle on purpose and can last weeks: the graph is mid-flight, the
 * checkpoint is the node it will run next, and `TaskRecord.wait` says what has
 * to happen first. It is not terminal — a waiting task has work left — and it is
 * not running, so it holds no fiber and usually no started container either.
 */
export type TaskStatus = "starting" | "running" | "waiting" | "succeeded" | "failed" | "stopped";

/** per-run LLM telemetry, parsed from the agent's own event stream */
export interface LlmStats {
  model?: string;
  /** cumulative for the run */
  inputTokens?: number;
  outputTokens?: number;
  cacheRead?: number;
  cacheWrite?: number;
  costUsd?: number;
  turns?: number;
  apiMs?: number;
  /**
   * Subagents the node's agent started during this run, counted from its `Task`
   * tool calls. Their spend is inside `costUsd` — claude reports one total for
   * the turn — so without this a run that fanned out to four of them looks like
   * one very expensive agent, and the dominant cost driver is visible only by
   * reading the transcript. Absent when the run started none.
   */
  subagents?: number;
  /** context size after the final turn */
  contextTokens?: number;
  /** the model's window, resolved from its id; absent if the model is unknown */
  contextWindow?: number;
  /** contextTokens as a % of contextWindow; absent when the window is unknown */
  contextPct?: number;
}

export type RunStatus = "running" | "cancelled" | string;

export interface NodeRun {
  node: string;
  visit: number;
  /** "running" while in flight, "cancelled" if killed, else the outcome label */
  status: RunStatus;
  startedAt: string;
  finishedAt?: string;
  exitCode?: number;
  /** readable text: the agent's reply, or a rendering of `data` */
  output: string;
  /** the validated object, for schema-contract nodes */
  data?: unknown;
  /** the rendered prompt (claude) or command (shell) this run received */
  prompt?: string;
  /**
   * Last time this run produced a byte of output. Silence is the only signal
   * that separates a wedged turn from a slow one, since duration cannot: an
   * agent may legitimately work for days, but never silently.
   */
  lastOutputAt?: string;
  /**
   * Inclusive seq range of the events delivered into this run's prompt. A
   * rerun deliberately does not replay it — you rerun to get a better result,
   * and withholding what has been learned since is how a node repeats its
   * mistake — so this exists to answer "what did it know?" after the fact
   * rather than to reconstruct it.
   */
  events?: [number, number];
  /** workspace commit id when this run started, for rerun --reset-workspace */
  commit?: string;
  llm?: LlmStats;
}

/** graph position persisted at every node boundary, for resume after a stop */
export interface WorkflowCheckpoint {
  /** node about to execute (or executing when the daemon stopped) */
  node: string;
}

/** one agent conversation, shared by every node using the same session key */
export interface SessionState {
  /**
   * Absent until the thread exists, which only happens for codex: claude is
   * handed an id it will use, codex names its own and reports it on the stream
   * after the first turn. A turn that dies before naming one leaves this absent,
   * so the retry opens a fresh thread instead of resuming a thread that was
   * never created.
   */
  id?: string;
  /** whether the session exists in the container yet (--resume vs --session-id) */
  started: boolean;
  /**
   * Thread-cumulative token usage as of the end of the last run on this thread,
   * for codex only.
   *
   * Codex reports usage for the whole conversation on every `turn.completed`,
   * not for the turn — measured across three turns of one thread: output
   * 5 → 10 → 15, input 16477 → 32980 → 49500. A per-run figure is therefore the
   * difference from this watermark, and reading the number as it arrives would
   * bill the fourth visit of a rework loop for everything the first three did.
   * Claude reports per turn and never sets this.
   */
  usage?: { input: number; output: number; cacheRead: number; cacheWrite: number };
  /**
   * Nodes that have already taken a turn on this thread. `followUp` means "you
   * have been here before", which is a fact about the node rather than about
   * the session: a node joining a thread some other node opened is meeting its
   * own job for the first time however warm that thread is, and owes it the
   * whole brief. Absent on records written before this was tracked; the engine
   * seeds it from the run history on the next turn.
   */
  nodes?: string[];
}

/**
 * Superseded by TaskEventRecord; kept so records written before the event
 * stream existed still parse. `store.load` converts these into operator events
 * and clears the field.
 */
export interface OperatorNote {
  id: string;
  message: string;
  target?: string;
  createdAt: string;
  deliveredTo: string[];
}

/**
 * Everything that happens to a task is one of these, in one append-only,
 * seq-ordered stream: node boundaries, status flips, operator interjections,
 * whatever an agent publishes about its own work, and whatever an outside
 * source reports. History and delivery share a substrate because they were
 * already the same thing — the log, the `fresh()` output filter and the old
 * per-note `deliveredTo` cursor were three implementations of "what is new
 * since I last ran".
 *
 * Being in the stream does not put an event in front of an agent. Most of it
 * is machine bookkeeping that would be pure noise in a prompt, so **delivery
 * is opt-in**: an event reaches prompts only if it names an audience in `to`.
 */
export interface TaskEventRecord {
  seq: number;
  at: string;
  /**
   * What happened. "spawned" | "status" | "node" | "workflow" are the engine's
   * own bookkeeping and are never delivered; "control" and "error" are too,
   * except when they answer something a node asked for, which they address back
   * to that node; "output" and "verdict" are how it announces a finished node
   * (the latter when the node had a schema contract); "operator" is an
   * interjection; "meta" is a change to the task's metadata, delivered so the
   * rest of the graph learns what one node recorded.
   * Anything else was named by whoever published it. Nodes filter on this via
   * `accepts` / `ignores`.
   */
  kind: string;
  /**
   * The event, entire, as far as a reader is concerned — one line when `refs`
   * carries the detail, a paragraph when it does not.
   */
  message: string;
  /**
   * Who this reaches: a node id, several, or "*" for every agent node in the
   * graph. Absent means the event is history only and no prompt ever sees it.
   */
  to?: string | string[];
  /**
   * Where the detail lives, for a reader that wants more than the summary —
   * a workspace path, a URL, a `node#visit`. Nothing dereferences these; the
   * point is that a reader who cares can go look, so the summary stays a
   * summary.
   */
  refs?: string[];
  /**
   * Identifies a fact that gets restated rather than added to — CI status, PR
   * state, a gate result. Only the newest event per key is delivered, so a
   * node arriving after six rounds of a flapping check sees where it landed
   * instead of all six rounds, five of which are now lies.
   */
  key?: string;
  /**
   * Interrupt the node's current turn and deliver this now, instead of waiting
   * for the next node boundary. Ignored by shell execs.
   */
  urgent?: boolean;
  /** who published it: a node id, "operator", or an outside source's name */
  from?: string;
  node?: string;
  visit?: number;
  status?: string;
}

export interface TaskRecord {
  id: string;
  createdAt: string;
  status: TaskStatus;
  request: SpawnRequest;
  workflow: WorkflowDef;
  container?: string;
  /** jj workspace name, when repo-backed */
  workspace?: string;
  /**
   * The revision this task's workspace was cut from — the working-copy parents
   * of the repo at spawn time, which is what `jj workspace add` uses. Recorded
   * and echoed because the base is invisible until something built on it fails:
   * a task cut from a broken working copy looks perfectly healthy right up to
   * the first gate.
   */
  base?: string;
  /**
   * Exit code of the prewarm command, when the task had one. Kept on the record
   * rather than left to the log, because a non-required setup that failed is a
   * task whose gates are already doomed, and one line on an event stream that
   * ends in the hundreds is a thing nobody sees until they go looking for
   * something else.
   */
  setupExit?: number;
  /** working directory inside the container */
  cwd?: string;
  /** claude conversations by session key, stable across revives */
  sessions: Record<string, SessionState>;
  /** legacy single-session field, migrated into sessions.task on load */
  session?: string;
  runs: NodeRun[];
  /** latest output of each node, for {{<nodeId>}} template vars */
  outputs: Record<string, string>;
  /** latest validated object of each schema-contract node, for {{<nodeId>.field}} */
  data: Record<string, unknown>;
  /**
   * Facts attached to the task by whoever has them — an agent through its
   * `meta` tool, a shell node through the outbox, the operator through the
   * API. Flat strings, because every reader is a dashboard chip, a template
   * var (`{{meta.<key>}}`) or a person. Not `data`: that is keyed by node id
   * and owned by the engine, and a key that is also a node's name would
   * silently answer for it. `pr` is promoted onto the board row as a link.
   */
  meta: Record<string, string>;
  /**
   * Highest event seq each session thread has been shown. A thread is told a
   * thing once and it stays in its history, so a revisit only needs what
   * arrived since. Cold-session nodes keep no cursor — every visit is a new
   * thread that has been told nothing.
   */
  cursors: Record<string, number>;
  /** bytes of the container's outbox.jsonl already ingested into the stream */
  outboxOffset?: number;
  /** pre-event-stream operator notes; migrated and cleared at load */
  notes?: OperatorNote[];
  checkpoint?: WorkflowCheckpoint;
  /** set while status is "waiting": what this task is parked on */
  wait?: WaitState;
  /**
   * Consecutive timer firings per wait node, which is what its backoff grows
   * on. Kept on the record rather than in the WaitState so it survives the park
   * being torn down and rebuilt on every lap of the loop.
   */
  waitAttempts?: Record<string, number>;
  /**
   * Why the task stopped, which decides whether a restart may pick it back up
   * on its own. "daemon" is a shutdown, a crash or a host that slept, and the
   * task did not ask for it — those resume automatically. "operator" is a human
   * `af stop` and stays stopped until that human says otherwise.
   */
  stoppedBy?: "operator" | "daemon" | "error";
  /** monotonic counter behind TaskEventRecord.seq */
  seq: number;
  error?: string;
}

export interface TaskSummary {
  id: string;
  title?: string;
  task: string;
  repo?: string;
  status: TaskStatus;
  /** stable name for what this task is about, when it has one */
  key?: string;
  /** the task that spawned this one, so a board can nest a fleet under its poller */
  parent?: string;
  /** while waiting: why, when the timer is due, and the question if a human owes an answer */
  waitingOn?: WaitReason;
  waitUntil?: string;
  ask?: string;
  createdAt: string;
  /** latest task or node activity, used to order and age work on the board */
  updatedAt: string;
  /** node currently executing, or the most recently visited node */
  activeNode?: string;
  completedNodes: number;
  totalNodes: number;
  costUsd: number;
  contextPct?: number;
  /**
   * `meta.pr`, when set and an http(s) URL: the one piece of metadata the
   * board shows, because "which PR is this" is the question a row is scanned
   * for. The rest of the bag stays on the record — this frame is stringified
   * for every subscriber whenever any task changes.
   */
  pr?: string;
  /**
   * What the task is still holding. Neither is released when a task ends — a
   * finished task's container is a daemon still running and its workspace is a
   * checkout still on disk — so the board says which are there to be reclaimed
   * rather than making someone open each task to find out.
   */
  container?: boolean;
  workspace?: boolean;
}

/**
 * Host-wide limits, read from `~/.config/agentflow/config.json`. These bound
 * the box rather than any one task, which is the only scope that helps once
 * tasks spawn tasks: a per-task ceiling does nothing about four hundred
 * children each staying politely under it.
 */
export interface DaemonConfig {
  /**
   * Rolling spend ceilings in USD across every task. A task that would cross
   * one parks with `waitingOn: "budget"` until the window rolls, so the work
   * resumes on its own rather than needing to be found and restarted.
   */
  budget?: { daily?: number; weekly?: number; monthly?: number };
  /**
   * Tasks allowed to execute a node at once. Others park with
   * `waitingOn: "slot"` and start as slots free up, which is what keeps a
   * fan-out over fifty PRs from starting fifty containers at once.
   */
  maxRunningTasks?: number;
  /** ceiling on live children per parent task (default 50) */
  maxChildren?: number;
}
