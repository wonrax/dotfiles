import { connect } from "../sdk/mod.ts";
const af = connect();
const t = await af.task(Deno.args[0]).getState();
console.log(t.runs.map((r) => `${r.node}#${r.visit} exit=${r.exitCode}\n${r.output}`).join("\n---\n"));
console.log("error:", t.error);
Deno.exit(0);
