/**
 * # agentflow SDK
 *
 * Orchestrates coding-agent tasks: each task runs Claude Code inside a docker
 * container on an isolated jujutsu workspace of the target repo, driven by a
 * workflow graph, with live events and human-in-the-loop steering.
 *
 * This file is self-contained and importable by URL — no repo checkout needed:
 *
 * ```ts
 * import { connect } from "http://127.0.0.1:4200/sdk.ts";
 *
 * const af = connect();
 * const { id, record } = await af.run({
 *   repo: "/abs/path/to/jj/repo",        // omit for a throwaway scratch dir
 *   title: "export --json flag",         // concise, for the dashboard
 *   task: "add a --json flag to the export command",
 *   gates: "nix develop -c cargo test",  // verification command, see SpawnRequest.gates
 *   workflow: "implement-review",        // see BundledWorkflowName for what each does
 * }, { onEvent: (e) => console.log(e) });
 * console.log(record.status);            // "succeeded" | "failed" | "stopped"
 * ```
 *
 * ## Running a dispatcher script
 *
 * Verify first: `deno check --allow-import=127.0.0.1:4200 script.ts`
 * Run: `deno run --allow-net --allow-env --allow-sys --allow-import=127.0.0.1:4200 script.ts`
 * (--allow-env/--allow-sys satisfy a transitive logger dependency, not agentflow)
 *
 * ## Where to look for more
 *
 * - `af.workflows()` or `GET http://127.0.0.1:4200/api/workflows`: the full
 *   node/edge definitions and prompt templates of every bundled workflow —
 *   the reference implementations for custom graphs.
 * - `GET http://127.0.0.1:4200/api/board`: all known tasks with statuses.
 * - `GET http://127.0.0.1:4200/api/task/<id>`: one task's full record — per-node
 *   runs, outputs, exit codes (same data as `handle.getState()`).
 * - `GET http://127.0.0.1:4200/api/task/<id>/log/<node>/<visit>`: the complete
 *   agent transcript of one node run (stream-json: messages, tool calls).
 * - Dashboard for humans: http://127.0.0.1:4200 — live graph, logs, interject box.
 * - If these endpoints refuse connections the daemon isn't running; ask the
 *   operator to start it. The daemon repo is ~/.dotfiles/agentflow and its
 *   README.md covers credentials, docker modes, jj mechanics, troubleshooting.
 *
 * ## Custom workflow graphs
 *
 * Pass a WorkflowDef instead of a bundled name. Node types: `agent` (a Claude
 * Code turn in the workspace), `shell` (any command; exit code 0 = ok, else
 * fail), `review` (fresh-session Claude turn whose reply must end with
 * "VERDICT: APPROVE" or "VERDICT: REQUEST_CHANGES"; a missing verdict counts
 * as fail). Edges fire on the source node's outcome (`when`, default "ok");
 * an edge pointing at an earlier node forms a rework loop, bounded by
 * `maxVisits`. When no edge matches the outcome, the task ends: succeeded on
 * ok/approve, failed otherwise. Execution starts at `start` ?? nodes[0].
 *
 * Template variables available in node `run` / `followUp` strings:
 * `{{task}}` the task text · `{{gates}}` SpawnRequest.gates
 * · `{{feedback}}` fresh operator feedback (see
 * interject) · `{{amendments}}` all operator feedback so far · `{{<nodeId>}}`
 * the latest output of that node (e.g. `{{verify}}`, `{{review}}`) ·
 * `{{notes}}` path of a shared scratch file agents use to leave each other
 * context between nodes (outside the repo, never committed).
 *
 * Large `{{<nodeId>}}` outputs are not injected verbatim: beyond ~4KB the
 * full text is saved to a file inside the task mount and the variable
 * carries head/tail excerpts plus the file path, with instructions to
 * inspect it via rg/sed/tail. Keeps prompts small and costs flat.
 */
import { createClient } from "npm:rivetkit@2.3.9/client";

/** Base URL of the agentflow daemon (dashboard, this sdk, REST endpoints). */
export const DAEMON = "http://127.0.0.1:4200";

/**
 * Bundled workflows (fetch `af.workflows()` for their exact defs):
 *
 * - "implement-review" — the default. Graph:
 *   `implement(agent) → verify(shell, runs {{gates}}) → review(review) →
 *   polish(agent) → finalverify(shell)`, with rework loops: verify-fail →
 *   implement, review-request_changes → implement. On approval the reviewer's
 *   non-blocking remarks flow to a polish pass (same agent session, trivial
 *   fixes only), re-gated by finalverify. Use for real changes to repos you
 *   care about.
 * - "implement-review-smart" — same loop, but verification is an LLM judge
 *   instead of a shell command: it inspects the diff, runs only the checks
 *   relevant to the change ({{gates}} is a suggestion, not a mandate), and
 *   does not block on pre-existing failures unrelated to the change. Use for
 *   repos with flaky/failing baselines or where the right checks depend on
 *   what changed. Costs an extra agent turn per iteration vs plain gates.
 * - "quick" — single implement(agent) node, no gates, no review. Use for
 *   throwaway work or when you'll review manually.
 */
export type BundledWorkflowName = "implement-review" | "implement-review-smart" | "quick";

export type NodeType = "agent" | "shell" | "review";
export type EdgeCondition = "ok" | "fail" | "approve" | "request_changes";
export type TaskStatus = "starting" | "running" | "succeeded" | "failed" | "stopped";

export interface WorkflowNode {
  id: string;
  type: NodeType;
  label?: string;
  /** shell: command. agent/review: prompt template. */
  run: string;
  /**
   * agent nodes: template for revisits on the resumed session; carry only new
   * info ({{feedback}}, {{<nodeId>}} outputs) to keep the cached session
   * prefix stable. Defaults to `run`.
   */
  followUp?: string;
  /** agent nodes: continue the same claude session on revisits (default true) */
  resume?: boolean;
  /** max executions of this node before the task fails (default 10) */
  maxVisits?: number;
  /** per-execution timeout in minutes (default: SpawnRequest.nodeTimeoutMin, else none) */
  timeoutMin?: number;
}

export interface WorkflowEdge {
  from: string;
  to: string;
  /** outcome of `from` that activates this edge (default "ok") */
  when?: EdgeCondition;
}

export interface WorkflowDef {
  name: string;
  /** node executed first; defaults to nodes[0] */
  start?: string;
  nodes: WorkflowNode[];
  edges: WorkflowEdge[];
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
   * A bundled workflow name (see BundledWorkflowName for what each does, or
   * `af.workflows()` for the exact graphs) or an inline WorkflowDef.
   * Default: "implement-review".
   */
  workflow?: BundledWorkflowName | WorkflowDef;
  /**
   * Verification command run by "implement-review"'s verify node in the
   * workspace (e.g. `nix develop -c cargo test`). Nonzero exit sends the
   * workflow back to implement with the output attached. Default: no-op
   * (verify always passes). Irrelevant for "quick".
   */
  gates?: string;
  /** inject GH_TOKEN so the agent can push branches / open PRs */
  gh?: boolean;
  /**
   * Model id for the agent and review turns (sets ANTHROPIC_MODEL in the
   * container, e.g. "claude-fable-5", "claude-opus-4-8", "claude-sonnet-5",
   * "claude-haiku-4-5"). Omitted = claude code's own default (sonnet).
   * Dispatcher LLMs should pass their own model id unless told otherwise.
   */
  model?: string;
  /**
   * Reasoning effort for agent/review turns (CLAUDE_CODE_EFFORT_LEVEL).
   * Omitted = claude's default. Prefer "high" for gnarly work, "low" for
   * mechanical edits. For a raw thinking-token budget instead, pass
   * env: { MAX_THINKING_TOKENS: "..." }.
   */
  effort?: "low" | "medium" | "high";
  /**
   * Per-node execution timeout in minutes. Default: none — tasks may run for
   * hours or days, and stop/interject are the levers for stuck runs. Set it
   * only when you know a node finishing slowly means something is wrong
   * (a timed-out node fails the task; checkpoint kept, revive retries it).
   * Nodes can override individually via WorkflowNode.timeoutMin.
   */
  nodeTimeoutMin?: number;
  /**
   * Mount the host's ~/.claude/{CLAUDE.md,skills,agents} read-only into the
   * container so agents inherit the operator's global instructions and
   * skills. Default true; set false for a vanilla claude. (settings.json is
   * never mounted: host hooks/permissions don't translate into containers.)
   */
  hostAgentConfig?: boolean;
  /**
   * docker access for the task: "socket" mounts the host docker socket
   * (fast, agent shares your daemon), "dind" runs a private dockerd in a
   * privileged container (isolated, slower start, pulls its own images).
   */
  docker?: "socket" | "dind";
  env?: Record<string, string>;
}

/** per-run LLM telemetry (agent/review nodes), parsed from stream-json */
export interface LlmStats {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  cacheRead?: number;
  cacheWrite?: number;
  costUsd?: number;
  turns?: number;
  apiMs?: number;
  /** context size after the final turn, and % of the 200k window */
  contextTokens?: number;
  contextPct?: number;
}

export interface NodeRun {
  node: string;
  visit: number;
  status: "running" | "ok" | "fail" | "approve" | "request_changes";
  startedAt: string;
  finishedAt?: string;
  exitCode?: number;
  output: string;
  /** the rendered prompt (agent/review) or command (shell) this run received */
  prompt?: string;
  llm?: LlmStats;
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
  runs: NodeRun[];
  error?: string;
}

export interface TaskSummary {
  id: string;
  title?: string;
  task: string;
  repo?: string;
  status: TaskStatus;
  createdAt: string;
}

export type TaskEvent =
  | { kind: "update"; task: TaskRecord }
  | { kind: "node"; run: NodeRun }
  | { kind: "log"; log: { node: string; chunk: string } };

export interface TaskConnection {
  on(event: "update", cb: (task: TaskRecord) => void): void;
  on(event: "node", cb: (run: NodeRun) => void): void;
  on(event: "log", cb: (log: { node: string; chunk: string }) => void): void;
  dispose(): Promise<void>;
}

export interface TaskHandle {
  spawn(input: SpawnRequest & { id: string }): Promise<TaskRecord>;
  getState(): Promise<TaskRecord>;
  /**
   * queue feedback for the running agent; it is injected as {{feedback}} at
   * the next node boundary. interrupt: true kills the current node and
   * re-runs it with the feedback applied immediately. On a finished task this
   * revives the workflow (same container, same claude session) with the
   * feedback applied from the start node.
   */
  interject(input: { message: string; interrupt?: boolean }): Promise<TaskRecord>;
  /** interrupt the workflow; container + workspace kept for inspection */
  stop(): Promise<TaskRecord>;
  /**
   * granular cleanup keeping the task record on the board. container: docker
   * rm (disables revive). workspace: jj workspace forget + delete its dir.
   * Refused (throws) while the task is running.
   */
  cleanup(opts: { container?: boolean; workspace?: boolean }): Promise<TaskRecord>;
  /** stop + full teardown + drop the task from the board */
  remove(): Promise<void>;
  connect(): TaskConnection;
}

export function connect(endpoint = "http://127.0.0.1:6420") {
  // deno-lint-ignore no-explicit-any
  // deno-lint-ignore no-explicit-any
  const client = createClient({ endpoint }) as any;
  const board = client.board.getOrCreate(["main"]);
  const task = (id: string): TaskHandle => client.task.getOrCreate([id]) as unknown as TaskHandle;

  return {
    /** all known tasks, newest first */
    list: (): Promise<TaskSummary[]> => board.list() as Promise<TaskSummary[]>,

    /** bundled workflow definitions, keyed by name — the reference graphs */
    workflows: async (): Promise<Record<string, WorkflowDef>> =>
      (await fetch(`${DAEMON}/api/workflows`)).json(),

    /**
     * Block until an already-spawned task reaches a terminal status and
     * return its record. Safe to call on a task that already finished.
     * Intended for watcher scripts run in the background after spawn().
     */
    async wait(id: string): Promise<TaskRecord> {
      const handle = task(id);
      const conn = handle.connect();
      const terminal = ["succeeded", "failed", "stopped"];
      const viaEvents = new Promise<TaskRecord>((resolve) => {
        conn.on("update", (t) => terminal.includes(t.status) && resolve(t));
      });
      const current = await handle.getState();
      const record = terminal.includes(current.status) ? current : await viaEvents;
      await conn.dispose();
      return record;
    },

    task,

    async spawn(req: SpawnRequest & { id?: string }) {
      const id = req.id ?? `t${Date.now().toString(36)}${crypto.randomUUID().slice(0, 4)}`;
      const handle = task(id);
      const record = await handle.spawn({ ...req, id });
      return { id, handle, record };
    },

    /** spawn and block until the task reaches a terminal status */
    async run(req: SpawnRequest & { id?: string }, opts?: { onEvent?: (e: TaskEvent) => void }) {
      const { id, handle } = await this.spawn(req);
      const conn = handle.connect();
      const record = await new Promise<TaskRecord>((resolve) => {
        conn.on("update", (t) => {
          opts?.onEvent?.({ kind: "update", task: t });
          if (["succeeded", "failed", "stopped"].includes(t.status)) resolve(t);
        });
        conn.on("node", (run) => opts?.onEvent?.({ kind: "node", run }));
        conn.on("log", (log) => opts?.onEvent?.({ kind: "log", log }));
      });
      await conn.dispose();
      return { id, record };
    },
  };
}
