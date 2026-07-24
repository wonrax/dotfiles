import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, record } = await af.run({
  task: "Create stats.txt containing the single word 'telemetry'.",
  workflow: "quick",
});
const l = record.runs[0]?.llm;
console.log("status:", record.status, "id:", id);
console.log("llm:", JSON.stringify(l, null, 1));
Deno.exit(record.status === "succeeded" ? 0 : 1);
