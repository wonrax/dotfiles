export type NodeType = "agent" | "shell" | "review";

export interface WorkflowNode {
  id: string;
  type: NodeType;
  label?: string;
  /** shell: command run in the workspace. agent/review: prompt template. */
  run: string;
  /**
   * agent nodes: template for revisits on the resumed session. Should carry
   * only new information ({{feedback}}, gate/review outputs) — the session
   * history already has the task, keeping the cached prefix stable.
   * Defaults to `run`.
   */
  followUp?: string;
  /** agent nodes: continue the same claude session on revisits (default true) */
  resume?: boolean;
  /** max times this node may execute before the task is failed (default 10) */
  maxVisits?: number;
  /** per-execution timeout in minutes (default: SpawnRequest.nodeTimeoutMin, else none) */
  timeoutMin?: number;
}

export type EdgeCondition = "ok" | "fail" | "approve" | "request_changes";

export interface WorkflowEdge {
  from: string;
  to: string;
  /** which outcome of `from` activates this edge (default "ok") */
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
  /** absolute path to a jj repo on the host; omit for throwaway scratch tasks */
  repo?: string;
  /** concise human-readable title for dashboards and listings */
  title?: string;
  /** the task prompt, available to node templates as {{task}} */
  task: string;
  /** bundled workflow name or inline definition (default "implement-review") */
  workflow?: string | WorkflowDef;
  /** verification command run by gate nodes, available as {{gates}} (default no-op) */
  gates?: string;
  /** model for agent/review nodes (ANTHROPIC_MODEL); default is claude's own */
  model?: string;
  /** reasoning effort for agent/review nodes (CLAUDE_CODE_EFFORT_LEVEL) */
  effort?: "low" | "medium" | "high";
  /** per-node execution timeout in minutes (default: none — tasks may run for days) */
  nodeTimeoutMin?: number;
  /**
   * mount the host's ~/.claude/{CLAUDE.md,skills,agents} read-only into the
   * container so agents inherit them (default true; false disables)
   */
  hostAgentConfig?: boolean;
  /** inject GH_TOKEN so the agent can push branches / open PRs */
  gh?: boolean;
  /**
   * give the task access to docker: "socket" mounts the host docker socket
   * (fast, zero isolation — containers the agent starts are siblings on the
   * host daemon), "dind" runs a private dockerd in a --privileged container.
   */
  docker?: "socket" | "dind";
  /** extra env vars for the container */
  env?: Record<string, string>;
}

export type TaskStatus = "starting" | "running" | "succeeded" | "failed" | "stopped";

/** per-run LLM telemetry, parsed from claude's stream-json events */
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
  /** tail of combined stdout/stderr, capped */
  output: string;
  /** the rendered prompt (agent/review) or command (shell) this run received */
  prompt?: string;
  llm?: LlmStats;
}

/** graph position persisted at every node boundary, for resume after a
 * daemon stop; cleared when the workflow reaches a terminal state */
export interface WorkflowCheckpoint {
  /** node about to execute (or executing when the daemon stopped) */
  node: string;
  outputs: Record<string, string>;
  amendments: string[];
  feedback: string;
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
  /** working directory inside the container */
  cwd?: string;
  /** the coding agent's claude session id, stable across revives */
  session?: string;
  runs: NodeRun[];
  /** operator feedback queued for the next node boundary */
  pendingFeedback: string[];
  checkpoint?: WorkflowCheckpoint;
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
  | { kind: "task"; task: TaskRecord }
  | { kind: "node"; taskId: string; run: NodeRun }
  | { kind: "log"; taskId: string; node: string; chunk: string };
