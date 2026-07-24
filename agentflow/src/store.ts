/**
 * Task store: in-memory records, one JSON file per task on disk, and the
 * pub/sub the dashboard and SDK consume as SSE.
 *
 * The daemon is a single process on localhost, so there is no distributed
 * anything here: a Map is the source of truth and the JSON files exist so
 * checkpoints survive a restart. Writes are debounced and coalesced; callers
 * that just changed something the operator must not lose (status transitions,
 * node boundaries) ask for an immediate flush.
 */
import type { TaskEventRecord, TaskRecord, TaskSummary } from "./model.ts";
import { contextWindow, stateDir } from "./engine.ts";

const tasksDir = () => `${stateDir()}/tasks`;
const eventsDir = () => `${stateDir()}/events`;

type Listener = (event: string, data: unknown) => void;

const tasks = new Map<string, TaskRecord>();
const taskSubs = new Map<string, Set<Listener>>();
const boardSubs = new Set<Listener>();
/**
 * The event stream, in memory, with the jsonl as its persistence. Reads have
 * to see a write immediately: the engine records an event and then renders the
 * very next prompt from the stream, and the file append is fire-and-forget, so
 * a file-backed read would race it and silently drop the event that mattered.
 */
const eventLog = new Map<string, TaskEventRecord[]>();

const dirty = new Set<string>();
let flushTimer: ReturnType<typeof setTimeout> | undefined;
const FLUSH_MS = 250;

/**
 * The only shape a value is allowed to become a link in: the bag is written
 * from inside containers, and `javascript:` in an href on the dashboard's
 * origin is a container reaching the daemon's unauthenticated API through the
 * operator's browser.
 */
export const isHttpUrl = (v: unknown): v is string =>
  typeof v === "string" && /^https?:\/\/\S+$/.test(v);

const summarize = (t: TaskRecord): TaskSummary => {
  const latestRun = t.runs.at(-1);
  const completedNodes = new Set(
    t.runs.filter((run) => run.status !== "running" && run.status !== "cancelled").map((run) =>
      run.node
    ),
  ).size;
  // A running max rather than a sort of every timestamp the task has ever
  // produced: a poller accumulates thousands of runs and tens of thousands of
  // events, and this runs for every task on the board every time any one of
  // them changes. Events are appended in wall-clock order, so the newest is
  // the last one rather than something to search for.
  let updatedAt = t.createdAt;
  const bump = (at: string | undefined) => {
    if (at && at > updatedAt) updatedAt = at;
  };
  for (const run of t.runs) {
    bump(run.startedAt);
    bump(run.finishedAt);
  }
  bump(eventLog.get(t.id)?.at(-1)?.at);
  // The fullest conversation, not the most recent run: context is a property
  // of a thread and a workflow runs several — the coder's grows across every
  // visit, a cold judge starts empty each time. Take each thread's current
  // size, then the largest, so the board's one number is the thread nearest
  // its limit. Same rule as the dashboard's Context tile; two places
  // disagreeing about what "context" means is worse than either answer.
  const current = new Map<string, number>();
  for (const run of t.runs) {
    if (run.llm?.contextPct === undefined) continue;
    const node = t.workflow.nodes.find((n) => n.id === run.node);
    const thread = node?.session && node.session !== "none" ? node.session : run.node;
    current.set(thread, run.llm.contextPct);
  }
  const contextPct = current.size ? Math.max(...current.values()) : undefined;

  return {
    id: t.id,
    title: t.request.title,
    task: t.request.task,
    repo: t.request.repo,
    status: t.status,
    key: t.request.key,
    parent: t.request.parent,
    waitingOn: t.status === "waiting" ? t.wait?.reason : undefined,
    waitUntil: t.status === "waiting" ? t.wait?.until : undefined,
    ask: t.status === "waiting" ? t.wait?.ask : undefined,
    createdAt: t.createdAt,
    updatedAt,
    activeNode: latestRun?.node ?? t.checkpoint?.node,
    completedNodes,
    totalNodes: t.workflow.nodes.length,
    costUsd: t.runs.reduce((sum, run) => sum + (run.llm?.costUsd ?? 0), 0),
    contextPct,
    pr: isHttpUrl(t.meta?.pr) ? t.meta.pr : undefined,
    // teardown clears these fields, so their presence is the live answer to
    // "is there anything left to clean up here"
    container: t.container ? true : undefined,
    workspace: t.workspace || t.cwd ? true : undefined,
  };
};

/**
 * Writes are serialized per task: two overlapping flushes would otherwise race
 * on the same tmp path and one rename would land on nothing. Chaining also
 * means the last write always serializes the newest in-memory state, since the
 * record is mutated in place.
 */
const writes = new Map<string, Promise<void>>();

const writeRecord = (id: string): Promise<void> => {
  const chained = (writes.get(id) ?? Promise.resolve()).then(async () => {
    const t = tasks.get(id);
    if (!t) return; // removed while queued
    const path = `${tasksDir()}/${id}.json`;
    const tmp = `${path}.tmp`;
    try {
      await Deno.writeTextFile(tmp, JSON.stringify(t, null, 2));
      await Deno.rename(tmp, path);
    } catch (e) {
      console.error(`persist ${id} failed:`, e);
    }
  }).finally(() => {
    if (writes.get(id) === chained) writes.delete(id);
  });
  writes.set(id, chained);
  return chained;
};

/** write every pending record; awaited on shutdown so nothing is lost */
export const flush = async () => {
  if (flushTimer !== undefined) {
    clearTimeout(flushTimer);
    flushTimer = undefined;
  }
  const pending = [...dirty];
  dirty.clear();
  pending.forEach(writeRecord);
  await Promise.all([...writes.values()]);
};

const schedule = (id: string) => {
  dirty.add(id);
  flushTimer ??= setTimeout(() => {
    flushTimer = undefined;
    flush();
  }, FLUSH_MS);
};

export const list = (): TaskSummary[] =>
  [...tasks.values()].map(summarize).sort((a, b) => b.createdAt.localeCompare(a.createdAt));

export const get = (id: string): TaskRecord | undefined => tasks.get(id);

export const has = (id: string): boolean => tasks.has(id);

/** every record, for the sweeps that have to look at all of them */
export const records = (): TaskRecord[] => [...tasks.values()];

/**
 * The task holding a key, if any. Newest wins when history has several — a key
 * identifies a subject, and several tasks may have worked on it over time, but
 * only the latest is the one to join or address.
 */
export const byKey = (key: string): TaskRecord | undefined => {
  let found: TaskRecord | undefined;
  for (const t of tasks.values()) {
    if (t.request.key !== key) continue;
    if (!found || t.createdAt > found.createdAt) found = t;
  }
  return found;
};

/** a task id, or a key naming one; ids win when a string could be either */
export const resolve = (idOrKey: string): TaskRecord | undefined =>
  tasks.get(idOrKey) ?? byKey(idOrKey);

/** children of a task, newest first */
export const childrenOf = (id: string): TaskRecord[] =>
  [...tasks.values()].filter((t) => t.request.parent === id)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));

/** register a brand new task; throws if the id is taken */
export const insert = (t: TaskRecord) => {
  if (tasks.has(t.id)) {
    throw new Error(
      `task id "${t.id}" already exists (created ${tasks.get(t.id)!.createdAt}); ` +
        `pick another id or omit it for a random one`,
    );
  }
  tasks.set(t.id, t);
  changed(t.id, { immediate: true });
};

/**
 * The update frame without the run prompts.
 *
 * They are three quarters of the bytes — sixteen kilobytes per visit, and a
 * poller reaches a thousand visits — so a task that has been running a day
 * ships five megabytes on every status change, to be stringified here and
 * parsed by every subscriber. Nothing on this stream needs them: a prompt
 * never changes after its run starts, the `node` frame that announced the run
 * carried it, and `GET /api/task/:id` still answers with the record whole.
 */
export const updateFrame = (t: TaskRecord): TaskRecord => ({
  ...t,
  runs: t.runs.map((run) => run.prompt === undefined ? run : { ...run, prompt: undefined }),
});

/**
 * A task record was mutated in place: broadcast it, refresh the board, and
 * queue a write. `immediate` forces the write now (status changes, node
 * boundaries — anything a crash must not roll back).
 */
export const changed = (id: string, opts: { immediate?: boolean } = {}) => {
  const t = tasks.get(id);
  if (!t) return;
  if (taskSubs.get(id)?.size) emit(id, "update", updateFrame(t));
  broadcastBoard();
  if (opts.immediate) {
    dirty.add(id);
    flush();
  } else schedule(id);
};

export const drop = async (id: string) => {
  tasks.delete(id);
  dirty.delete(id);
  taskSubs.delete(id);
  eventLog.delete(id);
  broadcastBoard();
  // let any queued write drain first — it no-ops on the missing record, but
  // deleting the file underneath an in-flight rename would resurrect it
  await writes.get(id)?.catch(() => {});
  await Deno.remove(`${tasksDir()}/${id}.json`).catch(() => {});
  await Deno.remove(`${eventsDir()}/${id}.jsonl`).catch(() => {});
};

// ---------------------------------------------------------------------------
// event log: an append-only history a dispatcher can catch up on after being
// away, without holding a live connection or re-reading the whole record

/**
 * Publish an event: stamp it with the task's next seq, keep it, persist it,
 * broadcast it. Deliberately excludes log chunks — those are high-frequency
 * and belong in the transcript files, not in a stream meant to be read
 * start-to-finish and partly injected into prompts.
 */
export const record = (
  id: string,
  event: Omit<TaskEventRecord, "seq" | "at">,
): TaskEventRecord | undefined => {
  const t = tasks.get(id);
  if (!t) return undefined;
  const full: TaskEventRecord = {
    seq: t.seq = (t.seq ?? 0) + 1,
    at: new Date().toISOString(),
    ...event,
  };
  let log = eventLog.get(id);
  if (!log) eventLog.set(id, log = []);
  log.push(full);
  const line = JSON.stringify(full) + "\n";
  Deno.writeTextFile(`${eventsDir()}/${id}.jsonl`, line, { append: true, create: true })
    .catch((e) => console.error(`event log ${id} failed:`, e));
  emit(id, "event", full);
  return full;
};

/** the event stream from a sequence number the caller has already seen */
export const events = (id: string, since = 0): TaskEventRecord[] =>
  (eventLog.get(id) ?? []).filter((ev) => ev.seq > since);

/**
 * The events a node should be shown on this turn.
 *
 * `since` is that node's cursor: the last seq its conversation was told about,
 * or 0 for a cold session, which has been told nothing. Nothing is dropped for
 * length — a delivered event omitted to save tokens is the one piece of
 * context the run needed — but restated facts collapse to their latest value,
 * because six rounds of "gates failed" is five stale claims and one true one.
 */
export const deliverable = (
  id: string,
  node: { id: string; accepts?: string[]; ignores?: string[] },
  since: number,
): TaskEventRecord[] => {
  const addressed = events(id, since).filter((ev) => {
    if (ev.to === undefined) return false;
    // nobody needs to be told what they themselves said, and handing a cold
    // judge its own last verdict back is how you anchor it to a position
    // instead of letting it look again
    if (ev.from === node.id) return false;
    const to = Array.isArray(ev.to) ? ev.to : [ev.to];
    if (!to.includes("*") && !to.includes(node.id)) return false;
    if (node.accepts && !node.accepts.includes(ev.kind)) return false;
    return !(node.ignores ?? []).includes(ev.kind);
  });
  const superseded = new Set<number>();
  const latest = new Map<string, number>();
  for (const ev of addressed) {
    if (ev.key === undefined) continue;
    const prev = latest.get(ev.key);
    if (prev !== undefined) superseded.add(prev);
    latest.set(ev.key, ev.seq);
  }
  return addressed.filter((ev) => !superseded.has(ev.seq));
};

// ---------------------------------------------------------------------------
// pub/sub

/** fan out to this task's subscribers; log events deliberately skip persistence */
export const emit = (id: string, event: string, data: unknown) => {
  for (const fn of taskSubs.get(id) ?? []) {
    try {
      fn(event, data);
    } catch (e) {
      console.error("task listener failed:", e);
    }
  }
};

const broadcastBoard = () => {
  if (!boardSubs.size) return;
  const snapshot = list();
  for (const fn of boardSubs) {
    try {
      fn("board", snapshot);
    } catch (e) {
      console.error("board listener failed:", e);
    }
  }
};

export const subscribeTask = (id: string, fn: Listener): () => void => {
  let set = taskSubs.get(id);
  if (!set) taskSubs.set(id, set = new Set());
  set.add(fn);
  return () => {
    const s = taskSubs.get(id);
    s?.delete(fn);
    if (s && !s.size) taskSubs.delete(id);
  };
};

export const subscribeBoard = (fn: Listener): () => void => {
  boardSubs.add(fn);
  return () => void boardSubs.delete(fn);
};

// ---------------------------------------------------------------------------
// boot

const readEventFile = async (id: string): Promise<TaskEventRecord[]> => {
  let text: string;
  try {
    text = await Deno.readTextFile(`${eventsDir()}/${id}.jsonl`);
  } catch {
    return [];
  }
  const out: TaskEventRecord[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as TaskEventRecord);
    } catch {
      // partially written trailing line
    }
  }
  return out;
};

/**
 * Fold pre-event-stream operator notes into the stream. A note that had
 * already reached a session thread is replayed as history only: it is in that
 * conversation's transcript, and re-delivering it would tell the agent a
 * second time as if it were new. Undelivered ones keep their audience and go
 * out on the next turn, which is what the operator asked for.
 */
const migrateNotes = (t: TaskRecord) => {
  if (!t.notes?.length) return;
  for (const n of t.notes) {
    record(t.id, {
      kind: "operator",
      from: "operator",
      to: n.deliveredTo?.length ? undefined : n.target ?? "*",
      node: n.target,
      message: n.message,
    });
  }
  t.notes = undefined;
  dirty.add(t.id);
};

/**
 * Load persisted tasks. A record still marked running/starting has no fiber
 * behind it after a restart, so it is demoted to stopped — its checkpoint is
 * intact and `resume` picks it back up.
 */
export const load = async () => {
  await Deno.mkdir(tasksDir(), { recursive: true });
  await Deno.mkdir(eventsDir(), { recursive: true });
  let orphans = 0;
  for await (const entry of Deno.readDir(tasksDir())) {
    if (!entry.isFile || !entry.name.endsWith(".json")) continue;
    try {
      const t = JSON.parse(await Deno.readTextFile(`${tasksDir()}/${entry.name}`)) as TaskRecord;
      t.seq ??= 0;
      t.sessions ??= {};
      t.cursors ??= {};
      // outputs used to live inside the checkpoint, which made them unreachable
      // once the checkpoint cleared — and rerun needs them from any node
      const legacy = (t.checkpoint as { outputs?: Record<string, string> } | undefined)?.outputs;
      t.outputs ??= legacy ?? {};
      t.data ??= {};
      t.meta ??= {};
      tasks.set(t.id, t);
      eventLog.set(t.id, await readEventFile(t.id));
      // the record and the jsonl are written independently, so a crash between
      // them can leave the counter behind the log; the log wins or the next
      // event reuses a seq that is already taken
      const highest = eventLog.get(t.id)!.at(-1)?.seq ?? 0;
      if (highest > t.seq) t.seq = highest;
      migrateNotes(t);
      // percentages recorded before the window was read off the model were all
      // computed against a hardcoded 200k, so every run on a 1M model is stored
      // at 5x. The inputs are still on the record, so recompute rather than
      // leaving the board showing 300%.
      for (const run of t.runs) {
        if (!run.llm?.contextTokens) continue;
        const window = contextWindow(run.llm.model);
        run.llm.contextWindow = window;
        run.llm.contextPct = window
          ? Math.round((run.llm.contextTokens / window) * 100)
          : undefined;
      }
      if (t.status === "running" || t.status === "starting") {
        /**
         * No fiber survived, so the record is describing a run that is not
         * happening. It is demoted to stopped and marked as the daemon's doing
         * rather than the operator's — that distinction is the whole basis for
         * picking it back up automatically, since a task a human stopped must
         * stay stopped and one a restart interrupted never asked to.
         */
        t.status = "stopped";
        t.stoppedBy = "daemon";
        t.error = "daemon restarted mid-run; resume to continue from the last checkpoint";
        orphans++;
        dirty.add(t.id);
        record(t.id, {
          kind: "status",
          status: "stopped",
          message: "daemon restarted mid-run; task demoted to stopped",
        });
      }
    } catch (e) {
      console.error(`skipping unreadable task file ${entry.name}:`, e);
    }
  }
  if (orphans) await flush();
  console.log(`loaded ${tasks.size} task(s)${orphans ? `, ${orphans} orphaned -> stopped` : ""}`);
};
