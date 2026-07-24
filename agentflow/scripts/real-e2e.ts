// The real thing: claude code with subscription auth, implement-review loop, jj repo.
import { connect } from "../sdk/mod.ts";

const repo = Deno.args[0];
const af = connect();
const { id, record } = await af.run({
  repo,
  task:
    "Create convert.py: a python script that converts celsius to fahrenheit and back. " +
    "CLI: convert.py <value><unit> e.g. `convert.py 100c` prints `212.0f`, `convert.py 32f` prints `0.0c`. " +
    "Invalid input exits nonzero with an error on stderr. Keep it to a single file, stdlib only.",
  gates: "python3 -c \"import subprocess as s; assert s.run(['python3','convert.py','100c'],capture_output=True,text=True).stdout.strip()=='212.0f'; assert s.run(['python3','convert.py','32f'],capture_output=True,text=True).stdout.strip()=='0.0c'; assert s.run(['python3','convert.py','abc']).returncode!=0; print('gates pass')\"",
  workflow: "implement-review",
}, {
  onEvent: (e) => {
    if (e.kind === "node") console.log(`[${new Date().toISOString().slice(11, 19)}] node ${e.run.node} v${e.run.visit}: ${e.run.status}`);
    if (e.kind === "update") console.log(`[${new Date().toISOString().slice(11, 19)}] task: ${e.task.status}`);
  },
});
console.log("\nfinal:", record.status);
for (const r of record.runs) console.log(`  ${r.node}#${r.visit} ${r.status} exit=${r.exitCode}`);
console.log("id:", id);
Deno.exit(record.status === "succeeded" ? 0 : 1);
