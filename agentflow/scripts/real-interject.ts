// Real LLM run with a mid-flight operator interrupt.
import { connect } from "../sdk/mod.ts";

const af = connect();
const { id, handle } = await af.spawn({
  repo: Deno.args[0],
  task: "In convert.py, add a --precision N flag controlling output decimal places (default 1). Keep existing behavior otherwise.",
  gates: "python3 -c \"import subprocess as s; assert s.run(['python3','convert.py','100c'],capture_output=True,text=True).stdout.strip()=='212.0f'; print('gates pass')\"",
  workflow: "implement-review",
});
console.log("spawned", id);

const conn = handle.connect();
conn.on("node", (r: { node: string; visit: number; status: string }) =>
  console.log(`node ${r.node} v${r.visit}: ${r.status}`));

// let claude get ~20s into implementing, then interrupt with new requirements
setTimeout(async () => {
  console.log(">>> interjecting with interrupt");
  await handle.interject({
    message: "Change of plans from the operator: ALSO add kelvin support (unit 'k', e.g. `convert.py 273.15k` prints `0.0c`, celsius converts to kelvin with `--to k`). Do this in the same change.",
    interrupt: true,
  });
}, 20_000);

const done = await new Promise<{ status: string; runs: unknown[] }>((resolve) => {
  conn.on("update", (t: { status: string; runs: unknown[] }) => {
    if (["succeeded", "failed", "stopped"].includes(t.status)) resolve(t);
  });
});
console.log("final:", done.status);
for (const r of done.runs as { node: string; visit: number; status: string; exitCode?: number }[]) {
  console.log(`  ${r.node}#${r.visit} ${r.status} exit=${r.exitCode}`);
}
Deno.exit(done.status === "succeeded" ? 0 : 1);
