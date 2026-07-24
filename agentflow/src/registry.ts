import { actor, setup } from "rivetkit";
import { createClient } from "rivetkit/client";
import { Effect, Exit } from "effect";
import type { NodeRun, SpawnRequest, TaskRecord, TaskStatus, TaskSummary } from "./model.ts";
import {
  runWorkflow,
  setupTask,
  teardownContainer,
  teardownTask,
  teardownWorkspace,
} from "./engine.ts";
import { resolveWorkflow } from "./workflows.ts";

const ENDPOINT = Deno.env.get("RIVET_ENDPOINT") ?? "http://127.0.0.1:6420";

// Actor-to-actor: the task actor reports status changes to the board through a
// plain client against our own endpoint.
// deno-lint-ignore no-explicit-any
let boardHandle: any;
const board_ = () => {
  boardHandle ??= createClient<Registry>({ endpoint: ENDPOINT }).board.getOrCreate(["main"]);
  return boardHandle;
};
// board updates are best-effort; a failed one must never take the daemon down
// deno-lint-ignore no-explicit-any
const tellBoard = (p: Promise<any>) => p.catch((e) => console.error("board call failed:", e));

const emptyTask = (): TaskRecord => ({
  id: "",
  createdAt: "",
  status: "starting",
  request: { task: "" },
  workflow: { name: "empty", nodes: [], edges: [] },
  runs: [],
  pendingFeedback: [],
});

// live workflow abort controllers, keyed by task id (ephemeral, daemon-local)
const aborts = new Map<string, AbortController>();
// current node abort controllers, for interject({interrupt: true})
const nodeAborts = new Map<string, AbortController>();

export const task = actor({
  state: emptyTask(),
  // A daemon restart kills in-flight workflow fibers; the persisted status
  // would stay "running" forever with no live fiber behind it. On wake,
  // detect the orphan and mark it stopped so interject can revive it.
  onWake: (c) => {
    if (["running", "starting"].includes(c.state.status) && !aborts.has(c.state.id)) {
      c.state.status = "stopped";
      c.state.error = "daemon restarted mid-run; interject to revive from the last state";
      tellBoard(board_().update({ id: c.state.id, status: "stopped" }));
    }
  },
  actions: {
    getState: (c): TaskRecord => c.state,

    spawn: (c, input: SpawnRequest & { id: string }): TaskRecord => {
      if (c.state.id) return c.state; // idempotent: already spawned
      const workflow = resolveWorkflow(input.workflow);
      const { id, ...request } = input;
      Object.assign(c.state, {
        id,
        createdAt: new Date().toISOString(),
        status: "starting" satisfies TaskStatus,
        request,
        workflow,
      });
      broadcastUpdate(c);
      tellBoard(board_().register({
        id,
        title: request.title,
        task: request.task,
        repo: request.repo,
        status: "starting",
        createdAt: c.state.createdAt,
      } satisfies TaskSummary));

      launch(c);
      return c.state;
    },

    /**
     * queue operator feedback for the next node boundary; with interrupt, the
     * current node is killed and re-run with the feedback injected. On a
     * finished task this revives the workflow on the same container and
     * claude session, feedback applied from the start node.
     */
    interject: (c, input: { message: string; interrupt?: boolean }): TaskRecord => {
      c.state.pendingFeedback.push(input.message);
      broadcastUpdate(c);
      const terminal = ["succeeded", "failed", "stopped"].includes(c.state.status);
      if (terminal) {
        if (!c.state.container) {
          throw new Error("task was removed; its container is gone, spawn a new task");
        }
        c.state.error = undefined;
        launch(c);
      } else if (input.interrupt) {
        nodeAborts.get(c.state.id)?.abort();
      }
      return c.state;
    },

    /** interrupt the running workflow; container + workspace are kept for inspection */
    stop: async (c): Promise<TaskRecord> => {
      aborts.get(c.state.id)?.abort();
      await new Promise((r) => setTimeout(r, 100));
      return c.state;
    },

    /**
     * granular cleanup, keeping the task record and history on the board.
     * container: docker rm (disables revive). workspace: jj workspace forget
     * + delete the workspace dir. Refused while the task is running.
     */
    cleanup: async (c, opts: { container?: boolean; workspace?: boolean }): Promise<TaskRecord> => {
      if (["running", "starting"].includes(c.state.status)) {
        throw new Error("task is running; stop it before cleaning up");
      }
      if (opts.container) await Effect.runPromise(teardownContainer(c.state));
      if (opts.workspace) await Effect.runPromise(teardownWorkspace(c.state));
      broadcastUpdate(c);
      return c.state;
    },

    /** stop + tear down container, jj workspace, and workspace dir */
    remove: async (c): Promise<void> => {
      aborts.get(c.state.id)?.abort();
      await Effect.runPromise(teardownTask(c.state));
      if (c.state.status === "running" || c.state.status === "starting") {
        setStatus(c, "stopped");
      }
      await board_().remove(c.state.id);
    },
  },
});

/** run (or re-run) the task's workflow; container setup is skipped when it already exists */
// deno-lint-ignore no-explicit-any
const launch = (c: any) => {
  const id: string = c.state.id;
  const abort = new AbortController();
  aborts.set(id, abort);

  const emitNode = (run: NodeRun) => {
    const i = c.state.runs.findIndex((r: NodeRun) => r.node === run.node && r.visit === run.visit);
    if (i >= 0) c.state.runs[i] = run;
    else c.state.runs.push(run);
    c.broadcast("node", run);
  };
  const emitLog = (node: string, chunk: string) => c.broadcast("log", { node, chunk });
  const takeFeedback = () => {
    const drained = c.state.pendingFeedback.splice(0);
    if (drained.length) broadcastUpdate(c);
    return drained;
  };
  const onNodeStart = (nodeAbort: AbortController) => nodeAborts.set(id, nodeAbort);

  const program = Effect.gen(function* () {
    if (!c.state.container) yield* setupTask(c.state);
    setStatus(c, "running");
    return yield* runWorkflow(c.state, { emitNode, emitLog, takeFeedback, onNodeStart });
  });

  const work = Effect.runPromiseExit(program, { signal: abort.signal }).then((exit) => {
    aborts.delete(id);
    nodeAborts.delete(id);
    if (Exit.isSuccess(exit)) {
      setStatus(c, exit.value);
    } else if (Exit.isInterrupted(exit)) {
      setStatus(c, "stopped");
    } else {
      c.state.error = String(Exit.isFailure(exit) ? exit.cause : exit);
      setStatus(c, "failed");
    }
  });
  c.keepAwake(work);
};

// deno-lint-ignore no-explicit-any
const setStatus = (c: any, status: TaskStatus) => {
  c.state.status = status;
  broadcastUpdate(c);
  tellBoard(board_().update({ id: c.state.id, status }));
};

// deno-lint-ignore no-explicit-any
const broadcastUpdate = (c: any) => c.broadcast("update", c.state);

export const board = actor({
  state: { tasks: {} as Record<string, TaskSummary> },
  actions: {
    list: (c): TaskSummary[] =>
      Object.values(c.state.tasks).sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    register: (c, summary: TaskSummary) => {
      c.state.tasks[summary.id] = summary;
      c.broadcast("board", Object.values(c.state.tasks));
    },
    update: (c, patch: { id: string; status: TaskStatus }) => {
      const t = c.state.tasks[patch.id];
      if (t) {
        t.status = patch.status;
        c.broadcast("board", Object.values(c.state.tasks));
      }
    },
    remove: (c, id: string) => {
      delete c.state.tasks[id];
      c.broadcast("board", Object.values(c.state.tasks));
    },
  },
});

export const registry = setup({ use: { task, board } });
export type Registry = typeof registry;
