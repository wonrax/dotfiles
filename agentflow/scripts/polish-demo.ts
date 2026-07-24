import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, handle } = await af.spawn({
  repo: Deno.args[0],
  task: "Add a .gitignore that excludes __pycache__/ and *.pyc, and remove any tracked __pycache__ files from the working copy.",
  gates: "python3 -m unittest discover 2>&1 | tail -2; exit ${PIPESTATUS}",
  workflow: "implement-review",
  effort: "medium",
});
console.log("spawned", id);
const conn = handle.connect();
conn.on("node", (r: { node: string; visit: number; status: string }) =>
  console.log(`node ${r.node} v${r.visit}: ${r.status}`));
const rec = await new Promise<{ status: string }>((res) => {
  conn.on("update", (t: { status: string }) =>
    ["succeeded", "failed", "stopped"].includes(t.status) && res(t));
});
console.log("final:", rec.status, id);
Deno.exit(0);
