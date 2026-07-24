// Interject on a FINISHED task must revive the workflow with feedback applied.
import { connect } from "../sdk/mod.ts";
const af = connect();

// terminal-status task with a shell workflow that records what feedback it saw
const { id, handle, record: r0 } = await af.spawn({
  task: "revive test",
  workflow: {
    name: "revive",
    nodes: [{ id: "work", type: "shell", run: "echo \"feedback was: [{{feedback}}]\" >> runs.log; cat runs.log" }],
    edges: [],
  },
});
await new Promise<void>((res) => {
  const conn = handle.connect();
  conn.on("update", (t: { status: string }) =>
    ["succeeded", "failed"].includes(t.status) && res());
});
console.log("first run done");

// now interject on the finished task
const revived = await handle.interject({ message: "try again with more effort" });
console.log("after interject status:", revived.status);
const conn2 = handle.connect();
const final = await new Promise<{ status: string; runs: { output: string }[] }>((res) => {
  conn2.on("update", (t: { status: string; runs: { output: string }[] }) =>
    ["succeeded", "failed"].includes(t.status) && res(t));
});
console.log("revived run:", final.status);
console.log("node saw:", final.runs.at(-1)?.output.trim().split("\n").at(-1));
await handle.remove();
Deno.exit(0);
