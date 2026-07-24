// Mock e2e: shell-only workflow with a deliberate fail->retry edge, throwaway dir.
import { connect } from "../sdk/mod.ts";

const af = connect();
const { id, record } = await af.run({
  task: "mock",
  workflow: {
    name: "mock-loop",
    nodes: [
      // fails on first visit, succeeds on second — proves the loop edge works
      { id: "work", type: "shell", run: "test -f done.flag || { touch done.flag; echo 'first visit: failing'; exit 1; }; echo 'second visit: ok'" },
      { id: "final", type: "shell", run: "echo all done" },
    ],
    edges: [
      { from: "work", to: "work", when: "fail" },
      { from: "work", to: "final", when: "ok" },
    ],
  },
}, { onEvent: (e) => {
  const ev = e as { kind: string; run?: { node: string; visit: number; status: string }; task?: { status: string } };
  if (ev.kind === "node") console.log(`node ${ev.run!.node} v${ev.run!.visit}: ${ev.run!.status}`);
  if (ev.kind === "update") console.log(`task: ${ev.task!.status}`);
}});

console.log(`\nfinal status: ${record.status}`);
console.log(`runs: ${record.runs.map((r) => `${r.node}#${r.visit}=${r.status}`).join(", ")}`);
const list = await af.list();
console.log(`board: ${list.map((t) => `${t.id}:${t.status}`).join(", ")}`);

// cleanup
await af.task(id).remove();
console.log("removed:", id);
Deno.exit(record.status === "succeeded" ? 0 : 1);
