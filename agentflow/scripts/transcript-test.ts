// real claude, quick workflow — verifies stream-json summary + transcript file
import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, record } = await af.run({
  repo: Deno.args[0],
  task: "Add a short USAGE section to README.md documenting convert.py (read convert.py first). Keep it under 15 lines.",
  workflow: "quick",
});
console.log("status:", record.status);
console.log("summary output (first 200):", record.runs[0]?.output.slice(0, 200));
console.log("id:", id);
Deno.exit(record.status === "succeeded" ? 0 : 1);
