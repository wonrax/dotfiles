import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, handle } = await af.spawn({
  repo: Deno.args[0],
  task: "Write test_convert.py: unittest tests for convert.py covering c→f, f→c, kelvin input, --to, --precision, and invalid-input error handling. Must pass with `python3 -m unittest`.",
  gates: "python3 -m unittest discover -v 2>&1 | tail -3; exit ${PIPESTATUS:-$?}",
  workflow: "implement-review",
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
