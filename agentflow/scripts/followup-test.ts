// Revive the finished README task with feedback; the resumed turn must use the
// short followUp template, not the full scaffold.
import { connect } from "../sdk/mod.ts";
const af = connect();
const id = "tmryjey7b7ef1";
const handle = af.task(id);
await handle.interject({ message: "Also mention the --precision default value in the USAGE section." });
const conn = handle.connect();
const rec = await new Promise<{ status: string; runs: unknown[] }>((res) => {
  conn.on("update", (t: { status: string; runs: unknown[] }) =>
    ["succeeded", "failed"].includes(t.status) && res(t));
});
console.log("revived:", rec.status, "runs:", rec.runs.length);
Deno.exit(0);
