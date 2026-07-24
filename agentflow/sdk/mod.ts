/**
 * agentflow SDK — what dispatcher scripts import.
 *
 * Example:
 * ```ts
 * import { connect } from "../sdk/mod.ts";
 * const af = connect();
 * const { id, handle } = await af.spawn({
 *   repo: "/Users/wonrax/dev/some-repo",
 *   task: "add a --json flag to the export command",
 *   gates: "nix develop -c cargo test",
 *   gh: false,
 * });
 * const conn = handle.connect();
 * conn.on("update", (t) => console.log(t.status));
 * ```
 */
import { createClient } from "rivetkit/client";
import type { Registry } from "../src/registry.ts";
import type { SpawnRequest, TaskRecord, TaskSummary } from "../src/model.ts";

export type { SpawnRequest, TaskRecord, TaskSummary, WorkflowDef } from "../src/model.ts";
export { bundled as bundledWorkflows } from "../src/workflows.ts";

export function connect(endpoint = "http://127.0.0.1:6420") {
  const client = createClient<Registry>({ endpoint });
  const board = client.board.getOrCreate(["main"]);
  return {
    client,
    board,

    /** list all known tasks (newest first) */
    list: (): Promise<TaskSummary[]> => board.list(),

    /** handle for an existing task */
    task: (id: string) => client.task.getOrCreate([id]),

    /** spawn a new task; returns its id, handle, and initial record */
    async spawn(req: SpawnRequest & { id?: string }) {
      const id = req.id ?? `t${Date.now().toString(36)}${crypto.randomUUID().slice(0, 4)}`;
      const handle = client.task.getOrCreate([id]);
      const record: TaskRecord = await handle.spawn({ ...req, id });
      return { id, handle, record };
    },

    /** spawn and block until the task reaches a terminal status */
    async run(req: SpawnRequest & { id?: string }, opts?: { onEvent?: (e: unknown) => void }) {
      const { id, handle } = await this.spawn(req);
      const conn = handle.connect();
      const done = new Promise<TaskRecord>((resolve) => {
        conn.on("update", (t: TaskRecord) => {
          opts?.onEvent?.({ kind: "update", task: t });
          if (["succeeded", "failed", "stopped"].includes(t.status)) resolve(t);
        });
        conn.on("node", (run: unknown) => opts?.onEvent?.({ kind: "node", run }));
        conn.on("log", (log: unknown) => opts?.onEvent?.({ kind: "log", log }));
      });
      const record = await done;
      await conn.dispose();
      return { id, record };
    },
  };
}
