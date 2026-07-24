// Force a malformed review reply; the engine must request a correction.
import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, record } = await af.run({
  task: "contract test",
  model: "claude-haiku-4-5",
  workflow: { name: "contract", nodes: [
    { id: "judge", type: "review", run: "Reply with exactly the word: hello. Output nothing else whatsoever, no verdicts, no explanations." },
  ], edges: [] },
});
const r = record.runs[0];
console.log("status:", record.status, "| judge outcome:", r?.status);
console.log("output tail:", r?.output.slice(-80).replaceAll("\n", " "));
console.log("id:", id);
Deno.exit(0);
