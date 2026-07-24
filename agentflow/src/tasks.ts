/**
 * Task operations. Each function mutates a TaskRecord in place and tells the
 * store, which broadcasts it and persists it.
 */
import { Effect, Exit } from "effect";
import type {
  DaemonConfig,
  NodeRun,
  SpawnRequest,
  TaskRecord,
  TaskStatus,
  WorkflowDef,
  WorkflowNode,
} from "./model.ts";
import { isAgentExec } from "./model.ts";
import type { Admission } from "./engine.ts";
import {
  killTaskProcesses,
  probeNode,
  restoreWorkspace,
  reviveContainer,
  runSetup,
  runWorkflow,
  scratchFile,
  setupTask,
  stateDir,
  stopContainer,
  teardownContainer,
  teardownTask,
  teardownWorkspace,
  WorkflowError,
} from "./engine.ts";
import {
  bundled,
  bundledWorkflow,
  lintWorkflow,
  normalizeNode,
  normalizeWorkflow,
  parseDuration,
  resolveWorkflow,
  TICK_LABEL,
  validateWorkflow,
} from "./workflows.ts";
import * as store from "./store.ts";

/** live workflows, keyed by task id (ephemeral — a restart clears them) */
const running = new Map<string, { abort: AbortController; done: Promise<void> }>();

/**
 * The daemon's own starts and stops of a task's container, one at a time per
 * task. There are exactly two of them and they crossed: a park hands the
 * container back while a wake — news that arrived in the same second the task
 * went to sleep — is bringing it up for the node it woke for. Whichever landed
 * last decided, and when that was the stop, the woken node failed on "container
 * is not running", which reads as a broken image rather than as two of the
 * daemon's own calls overtaking each other.
 *
 * A queue rather than a flag, because the answer is not "refuse the second one"
 * — both are wanted, in the order they were asked for.
 */
const containerOps = new Map<string, Promise<unknown>>();
const onContainer = <T>(id: string, op: () => Promise<T>): Promise<T> => {
  const next = (containerOps.get(id) ?? Promise.resolve()).then(op, op);
  containerOps.set(id, next.catch(() => {}));
  return next;
};
/** current node's abort controller, for interject({urgent}) */
const nodeAborts = new Map<string, AbortController>();
/**
 * Node currently executing, so workflow edits can refuse to delete it — and the
 * visit it is on, because everything the engine writes for a run is keyed by
 * both and a node id alone names no file.
 */
const activeNode = new Map<string, { node: string; visit: number }>();
/**
 * When each running task last produced a byte of output. In memory because it
 * only describes runs this process started, and mirrored onto the run record so
 * a quiet turn is still diagnosable afterwards.
 */
const lastOutput = new Map<string, number>();

const TERMINAL: TaskStatus[] = ["succeeded", "failed", "stopped"];
export const isTerminal = (s: TaskStatus) => TERMINAL.includes(s);
/** has a fiber behind it right now */
export const isLive = (s: TaskStatus) => s === "running" || s === "starting";

// ---------------------------------------------------------------------------
// host-wide limits

let config: DaemonConfig = {};

export const loadConfig = async () => {
  const path = `${Deno.env.get("HOME")}/.config/agentflow/config.json`;
  try {
    config = JSON.parse(await Deno.readTextFile(path)) as DaemonConfig;
    console.log(`config: ${path}`);
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) console.error(`ignoring bad ${path}:`, e);
  }
};

export const getConfig = () => config;

const WINDOW_MS = { daily: 86_400_000, weekly: 604_800_000, monthly: 2_592_000_000 };

const spentSince = (cutoff: number): number => {
  let total = 0;
  for (const t of store.records()) {
    for (const run of t.runs) {
      if (new Date(run.startedAt).getTime() < cutoff) continue;
      total += run.llm?.costUsd ?? 0;
    }
  }
  return total;
};

const spentByTask = (task: TaskRecord): number =>
  task.runs.reduce((sum, r) => sum + (r.llm?.costUsd ?? 0), 0);

/** a task's spend plus everything its subtree has spent, which is what an ancestor's cap bounds */
const spentByTree = (id: string, seen = new Set<string>()): number => {
  if (seen.has(id)) return 0;
  seen.add(id);
  const task = store.get(id);
  if (!task) return 0;
  return spentByTask(task) +
    store.childrenOf(id).reduce((sum, c) => sum + spentByTree(c.id, seen), 0);
};

/**
 * Whether a node may start. Cost first, because a breach there should park for
 * hours and a slot only until someone finishes; and a claude node only, since a
 * shell node spends nothing and stopping a poll loop over an LLM budget would
 * strand it away from the wait node it needs to reach.
 */
const admit = (task: TaskRecord, node: WorkflowNode): Admission | undefined => {
  if (!isAgentExec(normalizeNode(node).exec)) return undefined;

  for (const [window, ms] of Object.entries(WINDOW_MS) as [keyof typeof WINDOW_MS, number][]) {
    const cap = config.budget?.[window];
    // undefined rather than falsy: an operator who wrote `"daily": 0` meant
    // "spend nothing", and reading that as "no limit" is the one way this check
    // can fail dangerously
    if (cap === undefined) continue;
    const spent = spentSince(Date.now() - ms);
    if (spent < cap) continue;
    return {
      reason: "budget",
      until: new Date(Date.now() + Math.min(ms, 3_600_000)).toISOString(),
      message: `host ${window} budget reached: $${spent.toFixed(2)} of $${cap.toFixed(2)}. ` +
        `This task parked rather than failing and picks up when the window rolls; ` +
        `af poke ${task.id} --force overrides it.`,
    };
  }

  for (
    const [id, label] of [
      [task.id, "this task"],
      ...ancestors(task).map((
        a,
      ) => [a.id, `ancestor ${a.id}`] as const),
    ] as [string, string][]
  ) {
    const owner = store.get(id);
    const cap = owner?.request.maxCostUsd;
    if (cap === undefined) continue;
    const spent = spentByTree(id);
    if (spent < cap) continue;
    return {
      reason: "budget",
      // names the command that actually raises it: this park is the one an
      // operator is most likely to want undone, and a message that says "raise
      // it" without saying how sends them to teardown and respawn, which throws
      // away the session thread that was the point of a long-lived task
      message: `maxCostUsd on ${label} reached: $${spent.toFixed(2)} of $${cap.toFixed(2)}. ` +
        `af budget ${id} --max-cost <usd> raises it and resumes; leave it to stay parked.`,
    };
  }

  const cap = config.maxRunningTasks;
  if (cap && running.size >= cap && !running.has(task.id)) {
    return {
      reason: "slot",
      message: `${running.size} tasks are already running and maxRunningTasks is ${cap}`,
    };
  }
  return undefined;
};

const ancestors = (task: TaskRecord): TaskRecord[] => {
  const chain: TaskRecord[] = [];
  const seen = new Set<string>([task.id]);
  let parent = task.request.parent;
  while (parent && !seen.has(parent)) {
    seen.add(parent);
    const rec = store.get(parent);
    if (!rec) break;
    chain.push(rec);
    parent = rec.request.parent;
  }
  return chain;
};

export class TaskError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

const need = (id: string): TaskRecord => {
  const t = store.get(id);
  if (!t) throw new TaskError(`no task "${id}"`, 404);
  return t;
};

const KEY = /^[\w.:-]+$/;

/**
 * A task id that means something to whoever reads it later. It is not only an
 * internal handle: the jj workspace is named after it, so it shows up in the
 * operator's own `jj workspace list` and as `af-<id>@` in their log, weeks after
 * anyone remembers dispatching it. Derived from the title, then the key, then
 * the task text — a random id is the last resort rather than the default.
 */
export const deriveId = (request: SpawnRequest): string => {
  const slug = (text: string) =>
    text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 28)
      .replace(/-$/, "");
  const stem = slug(request.title ?? "") || slug(request.key ?? "") ||
    slug(request.task?.split(/\s+/).slice(0, 6).join(" ") ?? "");
  if (!stem) return `t${Date.now().toString(36)}${crypto.randomUUID().slice(0, 4)}`;
  if (!store.has(stem)) return stem;
  for (let n = 2; n < 100; n++) {
    if (!store.has(`${stem}-${n}`)) return `${stem}-${n}`;
  }
  return `${stem}-${crypto.randomUUID().slice(0, 4)}`;
};

export interface SpawnResult {
  task: TaskRecord;
  /** an existing task held this key, so nothing new was created */
  joined: boolean;
}

/** an agent picks one of these off a list, so it is as narrow as a node id */
const CHILD_WORKFLOW = /^[\w-]+$/;

/**
 * The graphs a task carries for its children, checked the way its own graph is
 * and at the same moment. Both halves of that matter: a malformed graph first
 * touched at a fan-out is found hours after whoever wrote it stopped watching,
 * and a name that shadows a bundled one would make "survey" mean one thing
 * inside this subtree and another everywhere else — the agent choosing it reads
 * the bundled description either way, since that is what its tool says.
 *
 * Each graph's `name` is set to the key it was declared under. The agent asks
 * by key and `af show` on the child prints the graph's own name, so two names
 * for one graph is a thing to get wrong in two places.
 */
const checkChildWorkflows = (
  declared: Record<string, WorkflowDef>,
): { workflows: Record<string, WorkflowDef>; lints: string[] } => {
  const workflows: Record<string, WorkflowDef> = {};
  const lints: string[] = [];
  for (const [name, def] of Object.entries(declared)) {
    if (!CHILD_WORKFLOW.test(name)) {
      throw new TaskError(
        `childWorkflows name "${name}": letters, digits, dash, underscore only — an agent picks ` +
          `it off a list`,
      );
    }
    if (bundledWorkflow(name)) {
      throw new TaskError(
        `childWorkflows "${name}" is the name of a bundled workflow. Pick another: an agent is ` +
          `told what the bundled one does, and a name that means something else here is a name ` +
          `it picks for the wrong reason.`,
      );
    }
    if (!def || typeof def !== "object" || Array.isArray(def)) {
      throw new TaskError(`childWorkflows "${name}" is not a workflow definition`);
    }
    try {
      validateWorkflow(def);
    } catch (e) {
      throw new TaskError(`childWorkflows "${name}": ${e instanceof Error ? e.message : e}`);
    }
    const graph = normalizeWorkflow({ ...def, name });
    workflows[name] = graph;
    lints.push(...lintWorkflow(graph).map((w) => `childWorkflows.${name}: ${w}`));
  }
  return { workflows, lints };
};

/**
 * `gh` used somewhere, no token asked for. It fails at the first node that
 * reaches for it, as an auth error inside a container, which reads like the
 * container is broken rather than like one missing field on the request — and
 * by then a container has been built and a turn has been paid for.
 *
 * A warning rather than a refusal: a task can perfectly well have `gh` in its
 * prose without running it, and `env: { GH_TOKEN }` is a legitimate way to
 * supply the token that this cannot see.
 */
const GH_COMMAND = /(^|[\s;&|(`$])gh\s+[a-z]/;

const lintRequest = (request: SpawnRequest, workflow: WorkflowDef): string[] => {
  if (request.gh || request.env?.GH_TOKEN) return [];
  const where = [
    ...workflow.nodes.flatMap((n) => [
      ...(GH_COMMAND.test(n.run ?? "") ? [`node "${n.id}"`] : []),
      ...(GH_COMMAND.test(n.followUp ?? "") ? [`node "${n.id}" followUp`] : []),
    ]),
    ...(GH_COMMAND.test(request.task) ? ["the task"] : []),
    ...(GH_COMMAND.test(request.rubric ?? "") ? ["the rubric"] : []),
    ...(GH_COMMAND.test(
        typeof request.setup === "string" ? request.setup : request.setup?.run ?? "",
      )
      ? ["setup"]
      : []),
  ];
  if (!where.length) return [];
  const list = where.length > 1 ? `${where.slice(0, -1).join(", ")} and ${where.at(-1)}` : where[0];
  return [
    `${list} run${where.length > 1 ? "" : "s"} \`gh\`, but this task asked for no token — set ` +
    `gh: true (af spawn --gh) or pass one in env.GH_TOKEN. Without it the first node to reach ` +
    `for it fails on auth, which reads like a broken container rather than a missing field.`,
  ];
};

/**
 * What the task's workspace will be cut from. `jj workspace add` with no
 * `-r` gives the new working copy the same parents as the current one, so the
 * base is `@-` of the repo as it stands right now — which means an operator who
 * left their working copy on a half-finished branch has just handed the agent a
 * tree they never meant to. That is invisible until the first gate fails, half
 * an hour in, so it is worth one line at second zero.
 *
 * Read on the host, synchronously, because `af spawn` prints it before the
 * container the workspace lives in exists. Best effort: a repo jj cannot read
 * is a task with no base line, not a spawn that failed.
 */
const resolveBase = (repo: string): string | undefined => {
  try {
    const r = new Deno.Command("jj", {
      args: [
        "--repository",
        repo,
        "--ignore-working-copy",
        "log",
        "--no-graph",
        "--color",
        "never",
        "-r",
        "@-",
        "-T",
        `separate(" ", commit_id.short(8), bookmarks, description.first_line()) ++ "\n"`,
      ],
      stdout: "piped",
      stderr: "null",
    }).outputSync();
    if (!r.success) return undefined;
    const revs = new TextDecoder().decode(r.stdout).split("\n")
      .map((l) => l.trim().replace(/\s+/g, " ").slice(0, 90)).filter(Boolean);
    return revs.join(" + ") || undefined;
  } catch {
    return undefined;
  }
};

export const spawn = (input: SpawnRequest & { id?: string }): SpawnResult => {
  const { id: given, ...request } = input;
  if (typeof request.task !== "string" || !request.task.trim()) {
    throw new TaskError("task is required and must be a non-empty string");
  }
  if (request.title !== undefined && typeof request.title !== "string") {
    throw new TaskError("title must be a string");
  }
  if (request.key !== undefined) {
    if (typeof request.key !== "string" || !KEY.test(request.key)) {
      throw new TaskError(
        `invalid key "${request.key}": letters, digits and . : _ - only, since a key addresses a ` +
          `task in a URL`,
      );
    }
    /**
     * The point of a key: a poll loop re-asserts what should exist on every lap,
     * and joining rather than duplicating is what makes that safe. What "already
     * exists" means depends on how the last task for this subject ended, and
     * getting that wrong is how a fleet runs away — a rule that only recognised
     * live tasks gave every failed child a fresh sibling on the next lap, so two
     * subjects became six records in three laps and would have kept going.
     */
    const held = store.byKey(request.key);
    if (held && !isTerminal(held.status)) return { task: held, joined: true };
    if (held?.status === "failed") {
      // a retry wants the task that is already there — its container, its
      // workspace and its checkpoint are the state a second attempt starts from
      held.error = undefined;
      held.stoppedBy = undefined;
      store.record(held.id, {
        kind: "control",
        message: `retried: something asked for key "${request.key}" again while this task was ` +
          `failed, so it resumes rather than becoming one of a growing pile of siblings`,
      });
      launch(held);
      return { task: held, joined: true };
    }
    if (held?.status === "stopped") {
      throw new TaskError(
        `key "${request.key}" belongs to ${held.id}, which an operator stopped. Resuming that is ` +
          `their call: af resume ${held.id}, or spawn without the key to start something new.`,
        409,
      );
    }
    // a succeeded task is history. Its subject coming back — a PR reopened, an
    // issue filed again — is new work, and gets a task of its own.
  }
  if (request.parent && !store.has(request.parent)) {
    throw new TaskError(`parent "${request.parent}" is not a task on this daemon`);
  }
  const id = given ?? deriveId(request);
  if (!/^[\w-]+$/.test(id)) {
    throw new TaskError(`invalid task id "${id}": use letters, digits, dash, underscore`);
  }
  const workflow = resolveWorkflow(request.workflow);
  // before the record exists, so a bad graph is a spawn that failed rather than
  // a task sitting there with a fan-out that cannot work
  const children = request.childWorkflows && checkChildWorkflows(request.childWorkflows);
  if (children) request.childWorkflows = children.workflows;
  const task: TaskRecord = {
    id,
    createdAt: new Date().toISOString(),
    status: "starting",
    request,
    workflow,
    runs: [],
    outputs: {},
    data: {},
    meta: {},
    sessions: {},
    cursors: {},
    seq: 0,
  };
  // checked before the record exists, like the graph: a bad bag is a spawn
  // that failed, not a task on the board with half its metadata
  const meta = request.meta === undefined ? undefined : metaChanges(request.meta);
  task.base = request.repo ? resolveBase(request.repo) : undefined;
  store.insert(task);
  store.record(id, { kind: "spawned", message: request.title ?? request.task.slice(0, 120) });
  if (task.base) store.record(id, { kind: "spawned", message: `base ${task.base}` });
  if (meta) applyMeta(task, meta, "operator");
  for (
    const warning of [
      ...lintWorkflow(workflow),
      ...lintRequest(request, workflow),
      ...(children?.lints ?? []),
    ]
  ) {
    store.record(id, { kind: "workflow", message: `lint: ${warning}` });
  }
  launch(task);
  return { task, joined: false };
};

// ---------------------------------------------------------------------------
// what a node inside a container may ask the host to do

/**
 * A container has no route to this API — it writes lines to a spool on its
 * workspace mount and the daemon reads them host-side. That is what keeps a
 * prompt-injected agent from reaching an unauthenticated daemon that can remove
 * every other task on the box, so the policy for what a line may ask for lives
 * here, and every field it names is re-derived rather than trusted.
 */
const str = (v: unknown): string | undefined =>
  typeof v === "string" && v.trim() ? v.trim() : undefined;

const spawnFromNode = (parent: TaskRecord, line: Record<string, unknown>): string => {
  const live = store.childrenOf(parent.id).filter((c) => !isTerminal(c.status));
  const cap = config.maxChildren ?? 50;
  if (live.length >= cap) {
    throw new TaskError(
      `${parent.id} already has ${live.length} live children and maxChildren is ${cap}`,
    );
  }
  const task = str(line.task);
  if (!task) throw new TaskError("spawn needs a task");

  /**
   * A graph is code that runs in the child's container, so what arrives from in
   * there is a name and the host decides what it means. The parent's own
   * declarations come first, then the bundled record; a name in neither is
   * refused rather than falling back to a default nobody asked for, and the
   * refusal is published to the node that asked, because spawning is
   * asynchronous and a silent drop leaves a sweep loop re-requesting the same
   * child every lap with nothing to tell it why.
   *
   * The env var the container reads this list from is not consulted: it lives
   * inside the container, which is the thing being bounded.
   */
  if (line.workflow != null && typeof line.workflow !== "string") {
    throw new TaskError("spawn takes the name of a workflow, not a graph");
  }
  if (line.childWorkflows !== undefined) {
    throw new TaskError(
      "a task cannot hand graphs to its own children from in here; childWorkflows is declared " +
        "host-side, on the request that creates a task",
    );
  }
  const declared = parent.request.childWorkflows ?? {};
  const wanted = str(line.workflow) ?? "implement-review";
  // the declared graph itself rather than its name: the child then carries its
  // own copy and stops depending on a parent record that can be edited or reaped
  const workflow = declared[wanted] ?? (bundledWorkflow(wanted) ? wanted : undefined);
  if (!workflow) {
    const known = [...Object.keys(declared), ...Object.keys(bundled)];
    // the fact that the set is fixed host-side is what stops a sweep loop
    // re-requesting the same child every lap; saying so is enough, and an
    // instruction on top of the list would be one more thing to disagree with
    throw new TaskError(
      `no workflow "${wanted}". This task may spawn children with: ${known.join(", ")} — a set ` +
        `fixed by whoever created the task, which a retry does not change.`,
    );
  }

  // Pointing a task at an arbitrary host path is not a container's decision.
  const repo = line.repo === undefined || line.repo === null
    ? undefined
    : str(line.repo) === parent.request.repo
    ? parent.request.repo
    : (() => {
      throw new TaskError(
        `a child may only use its parent's repo (${
          parent.request.repo ?? "none"
        }); omit repo for ` +
          `a scratch task and clone into it with setup`,
      );
    })();

  const { task: child, joined } = spawn({
    task,
    title: str(line.title),
    key: str(line.key),
    parent: parent.id,
    workflow,
    repo,
    gates: str(line.gates),
    rubric: str(line.rubric),
    setup: str(line.setup),
    // validated in spawn() like every operator-supplied bag; a bad value is a
    // refusal event back to the asker, not a task with half its metadata
    meta: typeof line.meta === "object" && line.meta !== null && !Array.isArray(line.meta)
      ? line.meta as Record<string, string>
      : undefined,
    // inherited rather than offered: a child running on a different model than
    // the task tree it belongs to is a surprise, and the container has no
    // business choosing either. `childWorkflows` is pointedly not in here — the
    // reviewers a survey fans out to have no business fanning out themselves,
    // and passing the set down is what turns one compromised agent's reach into
    // the whole tree's
    model: parent.request.model,
    effort: parent.request.effort,
    gh: parent.request.gh,
    hostAgentConfig: parent.request.hostAgentConfig,
    cache: parent.request.cache,
    maxCostUsd: typeof line.maxCostUsd === "number" ? line.maxCostUsd : undefined,
    idleMin: parent.request.idleMin,
    // machine-spawned work is the case the default retain policy is wrong for:
    // nobody opens the workspace of a reviewer that approved and closed
    retain: { container: "onFailure", record: "90d", ...(line.retain as object ?? {}) },
  });
  store.record(parent.id, {
    kind: "spawn",
    from: str(line.from) ?? "agent",
    message: `${joined ? "joined" : "spawned"} ${child.id}` +
      (child.request.key ? ` (${child.request.key})` : ""),
    refs: [child.id],
  });
  return joined
    ? `${child.id} already exists for that key and is ${child.status}; nothing new was created`
    : `spawned ${child.id}`;
};

/**
 * Cross-task publishing, scoped to the family: a task may talk to itself, to the
 * task that spawned it, and to the ones it spawned. That covers a poller telling
 * one of its watchers that CI went red, and stops one compromised container from
 * addressing every task on the host.
 */
const emitFromNode = (from: TaskRecord, line: Record<string, unknown>): string => {
  const target = str(line.task);
  if (!target || target === from.id) throw new TaskError("no other task named");
  const to = store.resolve(target);
  if (!to) throw new TaskError(`no task or key "${target}"`);
  const related = to.id === from.request.parent || to.request.parent === from.id;
  if (!related) {
    throw new TaskError(
      `${to.id} is neither this task's parent nor one of its children, so it cannot be reached ` +
        `from here`,
    );
  }
  emit(to.id, {
    message: str(line.message) ?? "",
    kind: str(line.kind) ?? "handoff",
    from: `${from.id}/${str(line.from) ?? "agent"}`,
    to: Array.isArray(line.to) ? line.to.filter((x): x is string => typeof x === "string") : "*",
    refs: Array.isArray(line.refs)
      ? line.refs.filter((x): x is string => typeof x === "string")
      : undefined,
    key: str(line.key),
  });
  return `delivered to ${to.id}${
    to.status === "waiting" ? ", which was parked and is now awake" : ""
  }`;
};

// ---------------------------------------------------------------------------
// metadata: facts attached to the task by whoever has them

const META_KEY = /^[A-Za-z][\w.-]{0,63}$/;
const META_VALUE_MAX = 2000;
const META_KEYS_MAX = 64;

/**
 * What a `set` may contain, checked the same whether it came from the
 * operator or a container: a string writes, null or an empty string removes.
 * `pr` is held to being a URL because the board renders it as one — a value
 * that is not would be a dead link in the one place the key exists to be
 * clicked.
 */
const metaChanges = (input: unknown): Record<string, string | null> => {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new TaskError("meta wants an object of key → string, with null to remove a key");
  }
  const out: Record<string, string | null> = {};
  for (const [key, raw] of Object.entries(input)) {
    if (!META_KEY.test(key)) {
      throw new TaskError(
        `meta key "${key}" — a key starts with a letter and is letters, digits, . _ - only`,
      );
    }
    if (raw === null || raw === "") {
      out[key] = null;
      continue;
    }
    if (typeof raw !== "string") {
      throw new TaskError(`meta.${key} must be a string (or null to remove it)`);
    }
    const value = raw.trim();
    if (value.length > META_VALUE_MAX) {
      throw new TaskError(
        `meta.${key} is ${value.length} chars and the limit is ${META_VALUE_MAX}; put the ` +
          `detail in a file under the artifacts directory and point at it`,
      );
    }
    if (key === "pr" && !store.isHttpUrl(value)) {
      throw new TaskError(`meta.pr must be an http(s) URL — the board shows it as a link`);
    }
    out[key] = value;
  }
  return out;
};

/**
 * Write the bag and say so on the stream, one event per key that actually
 * changed: a loop re-asserting the same value every lap records nothing, and
 * `key` collapses a value that keeps moving to where it ended up. Delivered
 * to every agent node, because metadata is shared state and the stream is
 * how the rest of the graph learns it moved.
 */
const applyMeta = (
  task: TaskRecord,
  changes: Record<string, string | null>,
  from: string,
): TaskRecord => {
  task.meta ??= {};
  const adding = Object.entries(changes).filter(([k, v]) => v !== null && !(k in task.meta)).length;
  if (Object.keys(task.meta).length + adding > META_KEYS_MAX) {
    throw new TaskError(
      `${task.id} would hold more than ${META_KEYS_MAX} meta keys; remove some first`,
    );
  }
  let touched = false;
  for (const [key, value] of Object.entries(changes)) {
    if ((task.meta[key] ?? null) === value) continue;
    touched = true;
    if (value === null) delete task.meta[key];
    else task.meta[key] = value;
    store.record(task.id, {
      kind: "meta",
      from,
      to: "*",
      key: `meta:${key}`,
      message: value === null ? `${key} removed` : `${key} = ${value}`,
    });
  }
  if (touched) store.changed(task.id, { immediate: true });
  return task;
};

const metaFromNode = (task: TaskRecord, line: Record<string, unknown>): string => {
  const changes = metaChanges(line.set);
  const before = { ...task.meta };
  applyMeta(task, changes, str(line.from) ?? "agent");
  const moved = Object.keys(changes).filter((k) => (before[k] ?? null) !== (task.meta[k] ?? null));
  return moved.length
    ? `meta set: ${moved.join(", ")}`
    : "meta unchanged; those values were already set";
};

export const meta = (id: string): Record<string, string> => need(id).meta ?? {};

/** the operator's write: `set` is key → string, null removes */
export const setMeta = (id: string, input: { set?: unknown }): TaskRecord =>
  applyMeta(need(id), metaChanges("set" in input ? input.set : input), "operator");

export interface EmitInput {
  /** the event itself; one or two sentences when `refs` carries the detail */
  message: string;
  /** what sort of event this is; nodes filter on it (default "external") */
  kind?: string;
  /** who is publishing — a source name, so a reader knows who is talking */
  from?: string;
  /** node ids this reaches, or "*" for every agent node (default "*") */
  to?: string | string[];
  /** pointers to the detail: paths, URLs, ids. Nothing dereferences them. */
  refs?: string[];
  /** same key = same restated fact; only the newest per key is delivered */
  key?: string;
  /** interrupt the node's current turn and deliver now, not at the next boundary */
  urgent?: boolean;
}

/**
 * Publish an event from outside the workflow: the operator, CI, a webhook, a
 * watcher on a PR. The agents inside the task publish the same events through
 * the same stream via their `emit` tool, and nothing downstream can tell the
 * difference — which is the point, since a node should care what it has been
 * told, not who was holding the pen.
 *
 * `urgent` only means anything from out here. The engine runs one node at a
 * time, so an agent's urgent event could interrupt nothing but itself.
 */
export const emit = (id: string, input: EmitInput): TaskRecord => {
  const task = need(id);
  if (!input.message?.trim()) throw new TaskError("an event needs a message");
  const to = input.to ?? "*";
  for (const target of Array.isArray(to) ? to : [to]) {
    if (target !== "*" && !task.workflow.nodes.some((n) => n.id === target)) {
      throw new TaskError(
        `no node "${target}" in this task's workflow; use "*" to reach every agent node`,
      );
    }
  }
  const kind = input.kind ?? "external";
  store.record(id, {
    kind,
    from: input.from,
    to,
    refs: input.refs?.length ? input.refs : undefined,
    key: input.key,
    urgent: input.urgent || undefined,
    message: input.message,
  });
  store.changed(id, { immediate: true });
  if (input.urgent && isLive(task.status)) nodeAborts.get(id)?.abort();
  // A parked task is the case this whole mechanism exists for: news arriving
  // from outside is what a watch node is waiting for, and the same call that
  // records it is what starts the graph moving again.
  if (task.status === "waiting") offerEvent(task, kind, input.urgent === true);
  return task;
};

/**
 * The operator's own channel, which is `emit` with the operator's name on it.
 * `urgent` interrupts the node's current turn instead of waiting for the next
 * boundary. On a finished task it revives the workflow from its checkpoint.
 */
export const interject = (
  id: string,
  input: { message: string; target?: string; urgent?: boolean },
): TaskRecord => {
  if (!input.message?.trim()) throw new TaskError("interject needs a message");
  const task = emit(id, {
    message: input.message,
    kind: "operator",
    from: "operator",
    to: input.target ?? "*",
    urgent: input.urgent,
  });
  if (isTerminal(task.status)) {
    if (!task.container) {
      throw new TaskError("task was removed; its container is gone, spawn a new task", 409);
    }
    task.error = undefined;
    task.stoppedBy = undefined;
    launch(task);
  }
  return task;
};

// ---------------------------------------------------------------------------
// waiting: parking, waking, and the operator's override

/** the wait node's own view of what it is parked on, or undefined if it is not a wait node */
const waitSpecOf = (task: TaskRecord) => {
  const node = task.workflow.nodes.find((n) => n.id === task.wait?.node);
  return node && normalizeNode(node).exec === "wait" ? node.wait ?? {} : undefined;
};

/**
 * Hand a parked task its answer and let the graph run again. The label is what
 * the wait node's edges route on; for a task parked by a budget or a slot there
 * is no label to give, and resolving simply means running the node it was held
 * in front of.
 */
const wake = (task: TaskRecord, label: string, by: string) => {
  if (!task.wait) return task;
  task.wait.resolved = label;
  task.wait.resolvedBy = by;
  task.wait.settleUntil = undefined;
  task.wait.pending = undefined;
  store.record(task.id, {
    kind: "control",
    node: task.wait.node,
    message: `woke on ${by} → ${label}`,
  });
  task.error = undefined;
  task.stoppedBy = undefined;
  launch(task);
  return task;
};

/**
 * A gate or a park with no label of its own resolves by just running the node.
 * "proceed" is not routed on anywhere — the engine consumes the resolution for
 * a wait node and reads its edges, and for a budget park there is no wait node
 * to read.
 */
const PROCEED = "proceed";

/**
 * The label a wake gets when the event that caused it named none of its own —
 * whatever the node nominated for a poke, else its timer's, else its first
 * trigger's, else the conventions. Shared with `poke`, because "stop waiting,
 * go now" has to mean the same thing whether an operator said it or an urgent
 * event did.
 */
const nudgeLabel = (spec: ReturnType<typeof waitSpecOf>): string =>
  spec?.poke ?? spec?.after?.label ?? (spec?.on?.length ? spec.on[0].label : undefined) ??
    (spec ? TICK_LABEL : PROCEED);

/**
 * An event has landed on a parked task. Waking is not immediate when the node
 * asked to settle: the first match starts a hold, every further match pushes it
 * out, and the sweep wakes it once the hold expires. Eight review comments left
 * in one sitting are one thing that happened.
 *
 * `urgent` means "deliver now, not at the next boundary", and on a parked task
 * the next boundary can be hours away — a watch node's timer, a settle hold, or
 * nothing at all if the event matches no trigger. So urgent wakes it, on
 * whatever label a poke would have used. Where it cannot — a question only a
 * human can answer, a ceiling only the operator can raise — it says so on the
 * stream rather than being quietly filed away, which is what it used to be.
 */
const offerEvent = (task: TaskRecord, kind: string, urgent = false) => {
  const wait = task.wait;
  if (!wait || task.status !== "waiting") return;
  const spec = waitSpecOf(task);
  const undeliverable = (why: string) => {
    if (!urgent) return;
    store.record(task.id, {
      kind: "control",
      node: wait.node,
      message: `an urgent event arrived but could not be delivered now: ${why}`,
    });
    store.changed(task.id, { immediate: true });
  };

  // A park that is not a wait node — budget, slot — has nothing to route on and
  // nothing an event should shortcut. Waking it would spend past the very
  // ceiling that parked it, which is not urgency's to decide.
  if (!spec) {
    return undeliverable(
      `this task is parked on ${wait.reason}, and only ${
        wait.reason === "budget" ? `af budget ${task.id} --max-cost, or af poke --force` : "a slot"
      } clears that`,
    );
  }

  const trigger = (spec.on ?? []).find((t) => t.kind === kind);

  /**
   * A gate is the one park no event may resolve on its own: the answer has to
   * be the one the operator actually gave (see `approve`), and no amount of
   * urgency makes one up. A gate that also declared triggers still routes on
   * those.
   */
  if (spec.ask && !trigger) {
    return undeliverable(
      `it is waiting on you to answer: ${spec.ask} — af approve ${task.id} --label <...>`,
    );
  }

  /**
   * The operator talking to a parked task always wakes it. A graph that
   * declares what an operator note means routes on that, and it matters which:
   * waking a watch loop on its timer label sends it to poll the world, find
   * nothing changed, and park again — with the instruction still unread. So the
   * declared trigger wins, and this fallback exists only so a graph that never
   * thought about it still stirs.
   */
  if (kind === "operator" && !trigger) {
    wake(task, nudgeLabel(spec), "operator");
    return;
  }
  // No trigger takes this kind, so ordinarily it waits for whatever the node
  // was actually parked on. Urgent asked for now, and now is the poke label.
  if (!trigger) {
    if (urgent) wake(task, nudgeLabel(spec), kind);
    return;
  }

  // urgent skips the settle hold for the same reason it skips the timer: the
  // hold exists to batch a burst of ordinary news, and this is not that
  if (!spec.settle || urgent) {
    wake(task, trigger.label, kind);
    return;
  }
  wait.pending = trigger.label;
  wait.settleUntil = new Date(Date.now() + parseDuration(spec.settle)).toISOString();
  store.changed(task.id, { immediate: true });
};

/**
 * "Stop waiting, go now." The label depends on what the task is parked on,
 * because guessing wrong is worse than refusing: a timer wants its own tick, an
 * event wait wants whatever its author nominated, and a question put to a human
 * has no answer that can be inferred from impatience.
 */
export const poke = (id: string, opts: { label?: string; force?: boolean } = {}): TaskRecord => {
  const task = need(id);
  if (task.status !== "waiting" || !task.wait) {
    throw new TaskError(`${id} is ${task.status}, not waiting on anything`, 409);
  }
  const wait = task.wait;
  if (wait.reason === "human") {
    throw new TaskError(
      `${id} is waiting on you to answer: ${wait.ask ?? "(no question recorded)"}\n` +
        `A poke cannot guess which answer you meant — use af approve ${id} ` +
        `--label <${outcomeLabels(task).join("|")}>`,
      409,
    );
  }
  if (wait.reason === "budget" && !opts.force) {
    throw new TaskError(
      `${id} is parked on a budget you set: ${wait.ask ?? ""}\n` +
        `Pass --force to spend past it; the override is recorded on the task.`,
      409,
    );
  }
  const label = opts.label ?? nudgeLabel(waitSpecOf(task));
  if (wait.reason === "budget" && opts.force) {
    store.record(id, {
      kind: "control",
      message: `operator overrode the ${wait.reason} park`,
    });
  }
  return wake(task, label, "operator");
};

/**
 * Everything that could park this task on cost, and what each has spent. The
 * ceiling alone does not answer the only question an operator has at a budget
 * park — what to raise it to — and the three scopes fail differently enough
 * that "which one stopped me" is a real question too.
 */
export interface BudgetView {
  id: string;
  /** this task's own ceiling, if it has one */
  maxCostUsd?: number;
  /** what this task's own runs have cost */
  spentUsd: number;
  /** this task plus everything it spawned, which is what its own ceiling bounds */
  spentTreeUsd: number;
  /** ancestors carrying a ceiling, nearest first — any of them can park this task */
  ancestors: { id: string; maxCostUsd: number; spentTreeUsd: number }[];
  /** host-wide rolling windows from config.json */
  windows: { window: string; capUsd: number; spentUsd: number }[];
}

/**
 * Where this task's files are on the host. The container stops two minutes into
 * a park, so `docker exec` fails exactly when someone most wants to read what a
 * watcher has been keeping — and finding the path meant a `docker inspect` for
 * the mount source.
 */
export interface TaskPaths {
  id: string;
  /** the mount root: harness, refs, spool */
  workspace: string;
  /** where agents are told to put anything written for another agent to read */
  refs: string;
  /**
   * What agents left for the operator to look at. On the mount while the
   * workspace exists, under logs once it has been torn down — the one
   * directory of a task's that teardown keeps.
   */
  artifacts: string;
  /** node transcripts, one file per node/visit */
  logs: string;
  /** working directory inside the container, which is not the mount root */
  cwd?: string;
}

/**
 * Where the artifacts are right now: written on the workspace mount, moved
 * under logs when the workspace goes, so the answer is whichever exists — and
 * the mount while it does, since that is where a running node is still adding.
 */
export const artifactsDir = (task: TaskRecord): string => {
  const onMount = `${stateDir()}/ws/${task.id}/artifacts`;
  try {
    if (Deno.statSync(onMount).isDirectory) return onMount;
  } catch {
    // torn down, or never set up
  }
  return `${stateDir()}/logs/${task.id}/artifacts`;
};

export const paths = (id: string): TaskPaths => {
  const task = need(id);
  const ws = `${stateDir()}/ws/${task.id}`;
  return {
    id: task.id,
    workspace: ws,
    refs: `${ws}/refs`,
    artifacts: artifactsDir(task),
    logs: `${stateDir()}/logs/${task.id}`,
    cwd: task.cwd,
  };
};

export interface ArtifactEntry {
  /** relative to the artifacts directory; what the serve route takes */
  path: string;
  size: number;
  modifiedAt?: string;
}

export interface ArtifactListing {
  /** host path of the directory the entries are relative to */
  dir: string;
  files: ArtifactEntry[];
  /** more files exist than were listed */
  truncated: boolean;
}

const ARTIFACTS_MAX = 500;
const ARTIFACTS_DEPTH = 8;

/**
 * Every regular file under the artifacts directory. Symlinks are skipped
 * rather than followed: the directory is written from inside a container, and
 * a link out of it is the one way a listing could name a file the serve route
 * must then refuse. Dotfiles are skipped because nothing an agent leaves for a
 * person is hidden on purpose.
 */
export const artifacts = async (id: string): Promise<ArtifactListing> => {
  const dir = artifactsDir(need(id));
  const files: ArtifactEntry[] = [];
  let truncated = false;
  const walk = async (rel: string, depth: number) => {
    if (depth > ARTIFACTS_DEPTH) return;
    const entries: Deno.DirEntry[] = [];
    try {
      for await (const entry of Deno.readDir(rel ? `${dir}/${rel}` : dir)) entries.push(entry);
    } catch {
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const path = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory) {
        await walk(path, depth + 1);
        continue;
      }
      if (!entry.isFile) continue;
      if (files.length >= ARTIFACTS_MAX) {
        truncated = true;
        return;
      }
      const stat = await Deno.stat(`${dir}/${path}`).catch(() => undefined);
      files.push({ path, size: stat?.size ?? 0, modifiedAt: stat?.mtime?.toISOString() });
    }
  };
  await walk("", 0);
  return { dir, files, truncated };
};

export const budget = (id: string): BudgetView => {
  const task = need(id);
  return {
    id: task.id,
    maxCostUsd: task.request.maxCostUsd,
    spentUsd: spentByTask(task),
    spentTreeUsd: spentByTree(task.id),
    ancestors: ancestors(task).flatMap((a) =>
      a.request.maxCostUsd === undefined
        ? []
        : [{ id: a.id, maxCostUsd: a.request.maxCostUsd, spentTreeUsd: spentByTree(a.id) }]
    ),
    windows: (Object.entries(WINDOW_MS) as [keyof typeof WINDOW_MS, number][]).flatMap(
      ([window, ms]) => {
        const cap = config.budget?.[window];
        return cap === undefined
          ? []
          : [{ window, capUsd: cap, spentUsd: spentSince(Date.now() - ms) }];
      },
    ),
  };
};

/**
 * Move a live task's ceiling. `admit` re-reads `request.maxCostUsd` from the
 * store before every node, so the only thing missing was a way to write it —
 * and without one, the only path past a budget park was teardown and respawn,
 * which discards the session thread that is the whole value of a task that has
 * been watching something for a week.
 *
 * A raise resumes the task itself rather than leaving a poke to do. The reverse
 * does not: lowering a ceiling, or putting one on a task that had none, is not
 * an instruction to start running. Whether the raise is actually enough is left
 * to `admit` on the next node — an ancestor's ceiling or a host window can hold
 * it back, and re-parking with that named tells the operator what really has it.
 */
export const setBudget = (
  id: string,
  input: { maxCostUsd?: number | null },
): TaskRecord => {
  const task = need(id);
  const next = input.maxCostUsd === null ? undefined : input.maxCostUsd;
  if (next !== undefined && (typeof next !== "number" || !Number.isFinite(next) || next < 0)) {
    throw new TaskError("maxCostUsd must be a non-negative number, or null to remove the ceiling");
  }
  const prev = task.request.maxCostUsd;
  if (prev === next) throw new TaskError(`${id} already has that ceiling; nothing changed`, 409);
  task.request.maxCostUsd = next;

  const spent = spentByTree(task.id);
  const describe = (v?: number) => v === undefined ? "none" : `$${v.toFixed(2)}`;
  store.record(id, {
    kind: "control",
    from: "operator",
    message: `maxCostUsd ${describe(prev)} → ${describe(next)} (subtree has spent ` +
      `$${spent.toFixed(2)})`,
  });

  const unblocks = next === undefined ? prev !== undefined : prev !== undefined && next > prev;
  if (task.status === "waiting" && task.wait?.reason === "budget" && unblocks) {
    return wake(task, PROCEED, "operator");
  }
  store.changed(id, { immediate: true });
  return task;
};

/** every label a parked gate could be answered with, read off its outgoing edges */
const outcomeLabels = (task: TaskRecord): string[] => {
  const node = task.wait?.node;
  const labels = task.workflow.edges.filter((e) => e.from === node).map((e) => e.when ?? "ok");
  return [...new Set(labels)];
};

/**
 * Answer a gate. The available answers are the wait node's outgoing edge
 * labels, so a graph that offers approve/revise/decline needs nothing added
 * here and nothing added to the dashboard either.
 */
export const approve = (
  id: string,
  input: { label: string; message?: string },
): TaskRecord => {
  const task = need(id);
  if (task.status !== "waiting" || !task.wait) {
    throw new TaskError(`${id} is ${task.status}, not waiting for an answer`, 409);
  }
  const offered = outcomeLabels(task);
  if (offered.length && !offered.includes(input.label)) {
    throw new TaskError(
      `"${input.label}" is not one of the answers node "${task.wait.node}" routes on: ` +
        offered.join(", "),
      400,
    );
  }
  if (input.message?.trim()) {
    // recorded before the wake so the node it lands in front of sees it on its
    // first turn rather than its second
    store.record(id, {
      kind: "operator",
      from: "operator",
      to: "*",
      message: input.message,
    });
  }
  return wake(task, input.label, "operator");
};

/** interrupt the running workflow; container + workspace are kept for inspection */
export const stop = async (id: string): Promise<TaskRecord> => {
  const task = need(id);
  const live = running.get(id);
  if (!live) {
    // A parked task has no fiber to interrupt, but it does have a wake pending,
    // and leaving that armed means a "stopped" task starts itself an hour later.
    if (task.status === "waiting") {
      store.record(id, {
        kind: "control",
        node: task.wait?.node,
        message: `stop requested while parked (${task.wait?.reason}); the wait is cancelled`,
      });
      task.wait = undefined;
      task.stoppedBy = "operator";
      setStatus(task, "stopped");
    }
    return task;
  }
  store.record(id, { kind: "control", message: "stop requested" });
  task.stoppedBy = "operator";
  live.abort.abort();
  await live.done;
  /**
   * The node's own cancel already killed the turn it knew about. This is for
   * the one it did not: anything an agent left running is invisible to the
   * engine, outlives the fiber that started it, and — for an agent — goes on
   * spending the operator's model quota with nobody reading the result.
   */
  if (task.container) await killTaskProcesses(task.container);
  return task;
};

/** continue a stopped task from its checkpoint */
export const resume = (id: string): TaskRecord => {
  const task = need(id);
  if (task.status === "waiting") return poke(id);
  if (!isTerminal(task.status)) {
    throw new TaskError(
      `task is already ${task.status}` +
        (task.status === "starting"
          ? " — its container is still coming up, which can take a while after the docker VM " +
            "has been down. Nothing is lost by waiting; af stop first if it never gets there."
          : ""),
      409,
    );
  }
  if (!task.container) {
    throw new TaskError("task has no container (cleaned up); spawn a new task", 409);
  }
  if (!task.checkpoint) {
    throw new TaskError(
      "task finished its graph, so there is nothing to resume — use rerun --from <node>",
      409,
    );
  }
  task.error = undefined;
  task.stoppedBy = undefined;
  // a park cancelled by a stop must not be re-entered with its old deadline
  task.wait = undefined;
  store.record(id, { kind: "control", node: task.checkpoint.node, message: "resumed" });
  launch(task);
  return task;
};

/**
 * Pick up everything a restart interrupted. Only tasks the daemon itself
 * stopped: an `af stop` is a decision, and a startup that overrode it would
 * make stopping a task impossible across a reboot.
 *
 * Started a few at a time, because a host waking from sleep is the common case
 * and twelve simultaneous `docker start`s plus twelve agent turns is a worse
 * first minute than a staggered one.
 */
export const autoResume = async (concurrency = 2) => {
  const orphans = store.records().filter((t) =>
    t.status === "stopped" && t.stoppedBy === "daemon" && t.container && t.checkpoint
  );
  const parked = store.records().filter((t) => t.status === "waiting" && t.wait);
  if (parked.length) {
    console.log(`${parked.length} task(s) parked; the sweep re-arms their timers`);
  }
  if (!orphans.length) return;
  console.log(`auto-resuming ${orphans.length} task(s) interrupted by a restart`);
  for (let i = 0; i < orphans.length; i += concurrency) {
    const batch = orphans.slice(i, i + concurrency);
    for (const task of batch) {
      store.record(task.id, {
        kind: "control",
        node: task.checkpoint?.node,
        message: "auto-resumed after daemon restart",
      });
      task.error = undefined;
      task.stoppedBy = undefined;
      launch(task);
    }
    await Promise.race([
      Promise.all(batch.map((t) => running.get(t.id)?.done ?? Promise.resolve())),
      new Promise((r) => setTimeout(r, 4000)),
    ]);
  }
};

export interface RerunOptions {
  /** node to restart at; defaults to the last node that did not succeed */
  from?: string;
  /**
   * "keep" continues the agent's existing conversation (default). "fresh"
   * mints a new session for the node's session key, so it re-reads the full
   * prompt with no memory of its previous attempts — as do any other nodes
   * sharing that key.
   */
  session?: "keep" | "fresh";
  /**
   * Restore the workspace's tracked files to their state when that node last
   * started. Reverts files in this workspace ONLY: bookmarks, pushed
   * branches, PRs, containers the agent started, and anything else outside
   * the workspace stay exactly as they are.
   */
  resetWorkspace?: boolean;
  /** stop a running task first, and proceed past nodes marked effects: external */
  force?: boolean;
  /**
   * An operator note recorded before the node starts, so it reaches that node on
   * the turn this rerun triggers rather than the one after. Rerouting somewhere
   * and saying why are the same act — done as two calls, the note either lands a
   * turn late or races the launch, and the node redoes exactly what it did
   * before while the reason sits unread on the stream.
   */
  message?: string;
}

export const rerun = async (id: string, opts: RerunOptions = {}): Promise<TaskRecord> => {
  const task = need(id);
  if (isLive(task.status)) {
    if (!opts.force) {
      throw new TaskError(
        `${id} is running "${activeNode.get(id)?.node ?? "a node"}" right now. Passing force ` +
          `stops it first — the turn is killed inside the container and recorded as cancelled, ` +
          `then the graph restarts from the node you named.`,
        409,
      );
    }
    await stop(id);
  }
  /**
   * A parked task has no running node, so rerunning from anywhere is safe and
   * does not need force — but the park has to go, or the graph would arrive back
   * at that wait node holding a deadline that expired while it was away.
   */
  if (task.wait) {
    store.record(id, {
      kind: "control",
      node: task.wait.node,
      message: `wait at "${task.wait.node}" cancelled by a rerun`,
    });
    task.wait = undefined;
  }
  if (!task.container) {
    throw new TaskError("task has no container (cleaned up); spawn a new task", 409);
  }

  const from = opts.from ?? lastUnsuccessfulNode(task);
  if (!from) throw new TaskError("nothing to rerun; pass a node id via from", 400);
  const node = task.workflow.nodes.find((n) => n.id === from);
  if (!node) throw new TaskError(`no node "${from}" in this task's workflow`, 400);

  /**
   * Re-running an external-effects node can duplicate a push, a PR, a deploy —
   * nothing here can undo those, so make the operator say it out loud. But only
   * for the ones that have actually run: a graph where `ship` is merely
   * downstream of `implement` has nothing outside the workspace to duplicate
   * until `ship` has been there, and refusing anyway put the same alarming
   * message and the same `--force` in front of the safe case and the dangerous
   * one. What that teaches is reflexive forcing, which is the opposite of what
   * the guard is for.
   *
   * A run that started counts, finished or not: a node killed mid-turn may
   * already have pushed.
   */
  if (!opts.force) {
    const external = reachableExternalNodes(task.workflow, from)
      .filter((id) => task.runs.some((r) => r.node === id));
    if (external.length) {
      throw new TaskError(
        `node(s) ${external.join(", ")} are marked effects: "external", have already run, and ` +
          `can run again from "${from}". Re-running them may duplicate whatever they created ` +
          `outside the workspace (branches, PRs, deploys) — nothing agentflow does reverts that. ` +
          `Pass force to proceed.`,
        409,
      );
    }
  }

  if (opts.resetWorkspace) {
    const commit = [...task.runs].reverse().find((r) => r.node === from && r.commit)?.commit;
    if (!commit) {
      throw new TaskError(
        `no workspace snapshot recorded for node "${from}" (it may predate snapshots, or the ` +
          `task has no repo)`,
        409,
      );
    }
    await Effect.runPromise(restoreWorkspace(task, commit)).catch((e) => {
      throw new TaskError(String(e?.message ?? e), 409);
    });
    store.record(id, {
      kind: "control",
      node: from,
      message: `workspace files restored to ${commit.slice(0, 12)} (files only — pushes, PRs ` +
        `and other external effects are untouched)`,
    });
  }

  if (opts.session === "fresh") {
    const key = node.session ?? "none";
    if (key !== "none" && task.sessions[key]) {
      delete task.sessions[key];
      store.record(id, { kind: "control", node: from, message: `session "${key}" reset` });
    }
  }

  task.error = undefined;
  task.stoppedBy = undefined;
  task.checkpoint = { node: from };
  // before the control event and before the launch, so the node's very first
  // prompt carries it
  if (opts.message?.trim()) {
    store.record(id, {
      kind: "operator",
      from: "operator",
      to: "*",
      message: opts.message,
    });
  }
  store.record(id, { kind: "control", node: from, message: `rerun from "${from}"` });
  launch(task);
  return task;
};

/** the node of the most recent run that did not produce a success label */
const lastUnsuccessfulNode = (task: TaskRecord): string | undefined => {
  const success = task.workflow.successLabels ?? ["ok", "approve"];
  const bad = [...task.runs].reverse().find((r) => !success.includes(r.status));
  return bad?.node ?? task.checkpoint?.node ?? task.runs.at(-1)?.node;
};

/**
 * Nodes marked effects: "external" reachable from `start` by following edges.
 * Reachability alone is not the question a rerun asks — see `rerun`, which
 * narrows this to the ones that have something out there already.
 */
const reachableExternalNodes = (wf: WorkflowDef, start: string): string[] => {
  const seen = new Set<string>([start]);
  const queue = [start];
  const found: string[] = [];
  while (queue.length) {
    const id = queue.shift()!;
    const node = wf.nodes.find((n) => n.id === id);
    if (node?.effects === "external") found.push(id);
    for (const e of wf.edges) {
      if (e.from === id && !seen.has(e.to) && !e.to.startsWith("@")) {
        seen.add(e.to);
        queue.push(e.to);
      }
    }
  }
  return found;
};

/**
 * Replace the task text — what `{{task}}` renders and every judge is measuring
 * against.
 *
 * An interjection could not do this, and the gap was not cosmetic. An addition
 * composes with the original text; a removal contradicts it, and the original
 * text kept winning: cold-session nodes re-read `{{task}}` on every visit, so a
 * verifier and a reviewer went on reporting a withdrawn requirement as missing
 * round after round while the implementer had been told twice to take it out.
 * Caught between the two, an implementer will eventually decide its workspace
 * is being corrupted and defend the withdrawn code — which is exactly what one
 * did, with a script that restored it before every commit.
 *
 * The amendment is also published, because replacing the text is only half of
 * it: a warm thread was told the old task once and will never re-read anything,
 * so it has to hear that what it was told is void. Keyed, so a second amendment
 * supersedes the first rather than delivering a history of the requirements.
 */
export const setTask = (
  id: string,
  text: string,
  opts: { interrupt?: boolean } = {},
): TaskRecord => {
  const task = need(id);
  if (typeof text !== "string" || !text.trim()) {
    throw new TaskError("the replacement task text must be a non-empty string", 400);
  }
  if (task.request.task.trim() === text.trim()) {
    throw new TaskError("that is the text this task already has", 400);
  }
  task.request.task = text;
  return emit(id, {
    kind: "operator",
    from: "operator",
    key: "task",
    urgent: opts.interrupt,
    message: `THE TASK TEXT YOU WERE GIVEN IS NO LONGER CURRENT. What follows replaces it whole
— it is not an addition. Anything the old text asked for and this one does not is
withdrawn, so work already done for it comes back out, and any verdict published
before now was measured against text that no longer holds.

${text}`,
  });
};

/**
 * Replace the task's workflow. Validated before it lands, so a bad edit is
 * rejected whole rather than half-applied. A running node keeps the prompt it
 * was already handed; the new graph takes effect at the next node boundary —
 * pass interrupt to kill the current node so it re-runs under the new
 * definition immediately.
 */
export const setWorkflow = (
  id: string,
  def: WorkflowDef,
  opts: { interrupt?: boolean } = {},
): TaskRecord => {
  const task = need(id);
  const live = running.has(id);
  try {
    validateWorkflow(def, {
      runningNode: live ? activeNode.get(id)?.node : undefined,
      checkpointNode: task.checkpoint?.node,
    });
  } catch (e) {
    throw new TaskError(e instanceof Error ? e.message : String(e), 400);
  }
  task.workflow = normalizeWorkflow(def);
  store.record(id, {
    kind: "workflow",
    message: `workflow replaced (${def.nodes.length} nodes, ${def.edges?.length ?? 0} edges)`,
  });
  store.changed(id, { immediate: true });
  if (opts.interrupt && live) nodeAborts.get(id)?.abort();
  return task;
};

/**
 * Replace the graphs this task hands its children, checked exactly as spawn
 * checks them so a hot swap cannot put something in that spawn would have
 * refused.
 *
 * Only children spawned after this see it. The ones already running hold their
 * own copy of the graph they were created with, which is the right shape for
 * what this is for — moving a fleet's reviewers onto a different agent without
 * disturbing the reviews already in flight — but it does mean a swap is not
 * retroactive, and the event says so where an operator will read it.
 */
export const setChildWorkflows = (
  id: string,
  declared: Record<string, WorkflowDef>,
): TaskRecord => {
  const task = need(id);
  let checked;
  try {
    checked = checkChildWorkflows(declared);
  } catch (e) {
    throw e instanceof TaskError ? e : new TaskError(String(e), 400);
  }
  task.request.childWorkflows = checked.workflows;
  const names = Object.keys(checked.workflows);
  store.record(id, {
    kind: "workflow",
    message: `child workflows replaced (${names.length ? names.join(", ") : "none"}) — ` +
      `children spawned from here on get these; the ones already running keep the graph ` +
      `they were created with`,
  });
  for (const lint of checked.lints) {
    store.record(id, { kind: "workflow", message: `lint: ${lint}` });
  }
  store.changed(id, { immediate: true });
  return task;
};

/**
 * Granular cleanup, keeping the task record and history. container: docker rm
 * (disables revive). workspace: jj workspace forget + delete the workspace
 * dir. Refused while the task is running.
 */
export const cleanup = async (
  id: string,
  opts: { container?: boolean; workspace?: boolean },
): Promise<TaskRecord> => {
  const task = need(id);
  if (!isTerminal(task.status)) {
    throw new TaskError("task is running; stop it before cleaning up", 409);
  }
  if (opts.container) await Effect.runPromise(teardownContainer(task));
  if (opts.workspace) await Effect.runPromise(teardownWorkspace(task));
  store.record(id, {
    kind: "control",
    message: `cleaned up ${
      [opts.container && "container", opts.workspace && "workspace"].filter(Boolean).join(" + ")
    }`,
  });
  store.changed(id, { immediate: true });
  return task;
};

/** stop + tear down container, jj workspace, and workspace dir, then forget the task */
export const remove = async (id: string): Promise<void> => {
  const task = need(id);
  await stop(id).catch(() => {});
  await Effect.runPromise(teardownTask(task));
  await store.drop(id);
};

// ---------------------------------------------------------------------------

/** run (or re-run) a task's workflow; an existing container is revived rather than rebuilt */
const launch = (task: TaskRecord) => {
  const id = task.id;
  /**
   * The only place a fiber is created, so the only place that can refuse a
   * second one — and it has to ask `running` rather than the status, because
   * the status is what every caller's own guard reads and it is not accurate
   * yet. `setStatus` below closes that gap going forward; this stays as the
   * backstop for the paths that reach here without a guard of their own.
   *
   * It is not theoretical. A crashed docker VM left `reviveContainer` blocked
   * on a socket for an hour and 48 minutes, during which the task still read
   * "stopped" — so an auto-resume, three resumes and a rerun all passed their
   * checks and stacked five fibers on one container, one workspace and one
   * claude session, each walking the graph on its own.
   *
   * Recorded rather than thrown: the sweep wakes parked tasks from a timer with
   * no try around it, and a task that is merely already awake must not take the
   * timer down with it.
   */
  if (running.has(id)) {
    store.record(id, {
      kind: "control",
      node: task.checkpoint?.node,
      message: `already ${task.status}, so this start was dropped rather than run alongside the ` +
        `one in flight (af stop ${id} first if that one is stuck)`,
    });
    return;
  }
  const abort = new AbortController();
  /**
   * Before the fiber, not inside it. Setting it where the container comes up
   * left the whole revive looking like a task that had stopped — which is what
   * an operator answers by pressing resume again.
   */
  setStatus(task, "starting");

  const emitNode = (run: NodeRun) => {
    const i = task.runs.findIndex((r) => r.node === run.node && r.visit === run.visit);
    if (i >= 0) task.runs[i] = run;
    else task.runs.push(run);
    if (run.status === "running") activeNode.set(id, { node: run.node, visit: run.visit });
    else {
      activeNode.delete(id);
      store.record(id, {
        kind: "node",
        node: run.node,
        visit: run.visit,
        status: run.status,
        message: `${run.node}#${run.visit} ${run.status}`,
      });
    }
    store.emit(id, "node", run);
    // node boundaries carry the checkpoint the operator would resume from
    store.changed(id, { immediate: run.status !== "running" });
  };
  const emitLog = (node: string, chunk: string) => {
    lastOutput.set(id, Date.now());
    const run = [...task.runs].reverse().find((r) => r.status === "running");
    // mutated in place rather than re-emitted: this fires per chunk, and the
    // debounced write picks it up
    if (run) run.lastOutputAt = new Date().toISOString();
    store.emit(id, "log", { node, chunk });
  };
  const onNodeStart = (nodeAbort: AbortController) => nodeAborts.set(id, nodeAbort);
  const publish = (event: Parameters<typeof store.record>[1]) => void store.record(id, event);
  const deliverable = (node: Parameters<typeof store.deliverable>[1], since: number) =>
    store.deliverable(id, node, since);
  const request = (op: string, line: Record<string, unknown>): string => {
    if (op === "spawn") return spawnFromNode(task, line);
    if (op === "emit") return emitFromNode(task, line);
    if (op === "meta") return metaFromNode(task, line);
    throw new TaskError(
      `"${op}" is not something a node can ask for; this container can spawn tasks, emit ` +
        `events and set metadata`,
    );
  };

  const program = Effect.gen(function* () {
    /**
     * Admission before setup, not only before each node. The per-node check
     * inside the graph cannot help here: building a container and a workspace is
     * the expensive part, so a fan-out over fifty PRs would create fifty of them
     * and then park all fifty — which is the opposite of what a slot limit is
     * for. Nothing is created until the task is allowed to run.
     */
    const first = task.workflow.nodes.find((n) =>
      n.id === (task.checkpoint?.node ?? task.workflow.start ?? task.workflow.nodes[0]?.id)
    );
    const denied = first && admit(task, first);
    if (denied) {
      task.wait = {
        node: first!.id,
        reason: denied.reason,
        since: new Date().toISOString(),
        until: denied.until,
        ask: denied.message,
      };
      return "waiting" as const;
    }
    if (!task.container) {
      yield* setupTask(task);
      const code = yield* runSetup(task, (chunk) => emitLog("setup", chunk));
      if (code !== undefined) {
        task.setupExit = code;
        store.record(id, {
          kind: "control",
          message: `setup exited ${code}` +
            (code === 0 ? "" : " (task continues; see af log <id> setup 0)"),
        });
        /**
         * A failed prewarm also goes to the agents. They are the ones who meet
         * it — as a missing toolchain, an empty cache, a build that has to
         * happen from scratch — and an agent that knows the prewarm failed
         * stops improvising workarounds for a machine it thinks is broken.
         */
        if (code !== 0) {
          store.record(id, {
            kind: "setup",
            from: "agentflow",
            to: "*",
            key: "setup",
            message: `this task's setup command exited ${code}. Whatever it was meant to ` +
              `prepare may not be there, so a missing toolchain or a cold cache is that, ` +
              `rather than a container that needs working around.`,
          });
        }
      }
    } else {
      // queued, so a park still handing this container back finishes first and
      // the start lands after it rather than under it
      yield* Effect.tryPromise({
        try: () => onContainer(id, () => Effect.runPromise(reviveContainer(task))),
        catch: (e) => new WorkflowError({ message: String((e as Error)?.message ?? e) }),
      });
    }
    setStatus(task, "running");
    return yield* runWorkflow(task, {
      emitNode,
      emitLog,
      onNodeStart,
      publish,
      deliverable,
      request,
      admit: (node) => admit(task, node),
    });
  });

  const done = Effect.runPromiseExit(program, { signal: abort.signal }).then(async (exit) => {
    running.delete(id);
    nodeAborts.delete(id);
    lastOutput.delete(id);
    if (Exit.isSuccess(exit) && exit.value === "waiting") {
      await parked(task);
      return;
    }
    finalizeInterruptedRun(task);
    if (Exit.isSuccess(exit)) {
      setStatus(task, exit.value);
      await reap(task);
    } else if (Exit.isInterrupted(exit)) {
      task.stoppedBy ??= "daemon";
      setStatus(task, "stopped");
    } else {
      task.error = String(Exit.isFailure(exit) ? exit.cause : exit);
      store.record(id, { kind: "error", message: task.error.slice(0, 500) });
      task.stoppedBy = "error";
      setStatus(task, "failed");
      await reap(task);
    }
  });

  running.set(id, { abort, done });
};

/** how long a park has to be before releasing the container is worth the restart */
const PARK_STOP_AFTER_MS = 120_000;

/**
 * Settle a task into its park: announce it, and give back the container if the
 * wait is long enough to be worth a `docker start` later. A waiting task is the
 * normal resting state of anything that watches something, so it should cost
 * about what a stopped task costs.
 */
const parked = async (task: TaskRecord) => {
  const wait = task.wait;
  if (!wait) return;
  const due = wait.until ? new Date(wait.until).getTime() - Date.now() : Infinity;
  store.record(task.id, {
    kind: "status",
    status: "waiting",
    node: wait.node,
    message: wait.reason === "human"
      ? `waiting on you: ${wait.ask ?? "an answer"}`
      : wait.reason === "budget" || wait.reason === "slot"
      ? `parked before ${wait.node}: ${wait.ask ?? wait.reason}`
      : `parked at ${wait.node}` +
        (wait.until ? `, next due ${new Date(wait.until).toLocaleString()}` : "") +
        (wait.reason === "event" ? " or when something arrives" : ""),
  });
  setStatus(task, "waiting");
  if (due > PARK_STOP_AFTER_MS && task.container) {
    await onContainer(task.id, async () => {
      /**
       * The park became observable at the line above, so news can arrive while
       * this is still queued — and an event that was already on its way when
       * the poll parked the task lands in exactly that window. A task with a
       * fiber again needs the container it is about to run in, so the stop is
       * dropped rather than deferred: it will be offered again at the next
       * park, which is where it belongs.
       */
      if (running.has(task.id)) return;
      await Effect.runPromise(stopContainer(task)).catch(() => {});
    });
  }
};

/**
 * Give back what a finished task will not need again, per its `retain` policy.
 * The default keeps everything, because a human who dispatched a task usually
 * wants the diff afterwards — but a fleet of machine-spawned tasks is the
 * opposite case, and a container per reviewed PR is how a disk fills.
 */
const reap = async (task: TaskRecord) => {
  const policy = task.request.retain?.container ?? "always";
  const keep = policy === "always" || (policy === "onFailure" && task.status !== "succeeded");
  if (keep || !task.container) return;
  await Effect.runPromise(teardownContainer(task)).catch(() => {});
  await Effect.runPromise(teardownWorkspace(task)).catch(() => {});
  store.record(task.id, {
    kind: "control",
    message: `container and workspace released (retain.container: "${policy}"); the record and ` +
      `its event log stay`,
  });
  store.changed(task.id, { immediate: true });
};

/**
 * A workflow aborted between node boundaries leaves its in-flight run marked
 * "running" forever, which reads as a live node that no longer exists.
 */
const finalizeInterruptedRun = (task: TaskRecord) => {
  const active = activeNode.get(task.id);
  if (!active) return;
  activeNode.delete(task.id);
  const run = task.runs.find((r) =>
    r.node === active.node && r.visit === active.visit && r.status === "running"
  );
  if (!run) return;
  run.status = "cancelled";
  run.finishedAt = new Date().toISOString();
  store.emit(task.id, "node", run);
  store.record(task.id, {
    kind: "node",
    node: run.node,
    visit: run.visit,
    status: "cancelled",
    message: `${run.node}#${run.visit} cancelled`,
  });
};

const setStatus = (task: TaskRecord, status: TaskStatus) => {
  if (task.status === status) return;
  task.status = status;
  store.record(task.id, { kind: "status", status, message: `task ${status}` });
  store.changed(task.id, { immediate: true });
};

// ---------------------------------------------------------------------------
// the sweep: due timers, settled bursts, wedged turns, and a host that slept

const SWEEP_MS = 5000;
const DEFAULT_IDLE_MIN = 25;
/** a tick this late means the process was not running: the host suspended */
const SLEEP_SKEW_MS = SWEEP_MS * 4;

let sweepTimer: ReturnType<typeof setInterval> | undefined;
let lastTick = Date.now();
/** tasks already probed for this stretch of silence, so one wedge is diagnosed once */
const probing = new Set<string>();

const dueTimers = () => {
  const now = Date.now();
  for (const task of store.records()) {
    if (task.status !== "waiting" || !task.wait) continue;
    const wait = task.wait;
    if (wait.settleUntil && new Date(wait.settleUntil).getTime() <= now) {
      wake(task, wait.pending ?? TICK_LABEL, "activity");
      continue;
    }
    if (!wait.until || new Date(wait.until).getTime() > now) continue;
    if (wait.reason === "human") continue; // a deadline does not answer a question
    const spec = waitSpecOf(task);
    if (spec) {
      // a firing that found nothing is what the backoff grows on
      task.waitAttempts ??= {};
      task.waitAttempts[wait.node] = (task.waitAttempts[wait.node] ?? 0) + 1;
      wake(task, spec.after?.label ?? TICK_LABEL, "timer");
    } else {
      // a budget or slot park: the window rolled, so simply try the node again
      wake(task, PROCEED, "timer");
    }
  }
};

/**
 * A running turn that has produced nothing for a long time is either working
 * hard inside one tool call or wedged on a socket that will never answer.
 * Duration cannot tell those apart — an agent may legitimately work for days —
 * so this asks the process itself, and only kills what is provably doing
 * nothing. A killed node re-runs, which for a persistent session means it
 * re-enters its own conversation and carries on.
 */
const checkWedged = async (task: TaskRecord) => {
  const idleMin = task.request.idleMin ?? DEFAULT_IDLE_MIN;
  if (!idleMin || !task.container || probing.has(task.id)) return;
  const since = lastOutput.get(task.id);
  if (since === undefined || Date.now() - since < idleMin * 60_000) return;
  const active = activeNode.get(task.id);
  if (!active) return;
  const { node, visit } = active;

  probing.add(task.id);
  try {
    const state = await Effect.runPromise(
      probeNode(task.container, `/ws/${task.id}/${scratchFile("pid", node, visit)}`),
    );
    if (state === "busy" || state === "unknown") {
      // still working, or docker could not tell us — either way, not ours to
      // interrupt. Reset the clock so the next check is another full interval.
      lastOutput.set(task.id, Date.now());
      return;
    }
    store.record(task.id, {
      kind: "control",
      node,
      visit,
      message: `node "${node}#${visit}" produced nothing for ${idleMin}m and its process is ` +
        `${state === "gone" ? "gone" : "burning no cpu"}; treating the turn as wedged and ` +
        `running it again. A host that slept or a connection that dropped mid-request is the ` +
        `usual cause.`,
    });
    store.changed(task.id, { immediate: true });
    nodeAborts.get(task.id)?.abort();
  } finally {
    probing.delete(task.id);
  }
};

/**
 * The host was suspended: every in-flight HTTP request died without anyone
 * being told, and the sockets under them may never produce an error. Rather
 * than wait out an idle threshold that assumes the clock ran, look now.
 */
const hostWoke = async (asleepMs: number) => {
  const live = store.records().filter((t) => isLive(t.status));
  console.log(
    `host was suspended for ~${
      Math.round(asleepMs / 1000)
    }s; probing ${live.length} running task(s)`,
  );
  for (const task of live) {
    store.record(task.id, {
      kind: "control",
      message: `the host slept for ~${Math.round(asleepMs / 60_000)}m; checking whether this ` +
        `turn survived it`,
    });
    // the silence happened while nothing could have been produced, so judge it
    // from now rather than from before the sleep
    lastOutput.set(task.id, Date.now() - 60_000);
    await checkWedged(task);
  }
};

/** records past their retain.record age; the container is long gone by then */
const expiredRecords = () => {
  const now = Date.now();
  return store.records().filter((t) => {
    const ttl = t.request.retain?.record;
    if (!ttl || !isTerminal(t.status)) return false;
    const settled = t.runs.at(-1)?.finishedAt ?? t.createdAt;
    try {
      return now - new Date(settled).getTime() > parseDuration(ttl);
    } catch {
      return false;
    }
  });
};

let sweeps = 0;

export const startSweep = () => {
  sweepTimer ??= setInterval(() => {
    const now = Date.now();
    const skew = now - lastTick - SWEEP_MS;
    lastTick = now;
    if (skew > SLEEP_SKEW_MS) void hostWoke(skew);

    dueTimers();
    for (const task of store.records()) {
      if (isLive(task.status)) void checkWedged(task);
    }
    // record expiry is housekeeping, not something to do twelve times a minute
    if (++sweeps % 120 === 0) {
      for (const task of expiredRecords()) {
        console.log(
          `dropping expired record ${task.id} (retain.record ${task.request.retain?.record})`,
        );
        void remove(task.id).catch(() => {});
      }
    }
  }, SWEEP_MS);
};

/**
 * Shutdown sweep: stop every live workflow so its checkpoint is the last word,
 * and kill the in-container agent turn — a later revive resumes the same claude
 * session and must not contend with an orphaned process still writing to it.
 */
export const stopAllForShutdown = async () => {
  for (const [id, live] of running) {
    const task = store.get(id);
    live.abort.abort();
    await live.done.catch(() => {});
    if (task?.container) await killTaskProcesses(task.container);
    console.log(`stopped ${id} (resume after restart)`);
  }
};
