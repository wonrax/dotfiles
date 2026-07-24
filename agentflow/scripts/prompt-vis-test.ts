import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, record } = await af.run({
  task: "prompt visibility test",
  workflow: { name: "pv", nodes: [
    { id: "a", type: "shell", run: "echo task was: {{task}}" },
  ], edges: [] },
});
console.log("status:", record.status);
console.log("recorded prompt:", record.runs[0]?.prompt);
await af.task(id).remove();
Deno.exit(0);
