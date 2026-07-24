// quick task, then revive; the resumed turn must be the short followUp message
import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, handle, record: _r } = await af.spawn({
  task: "Create hello.txt containing exactly 'hi'. Nothing else.",
  workflow: "quick",
});
const wait = () => new Promise<void>((res) => {
  const conn = handle.connect();
  conn.on("update", (t: { status: string }) => ["succeeded", "failed"].includes(t.status) && res());
});
await wait();
console.log("first run done");
await handle.interject({ message: "Also create bye.txt containing exactly 'bye'." });
await wait();
const rec = await handle.getState();
console.log("revive done:", rec.status, "id:", id);
Deno.exit(0);
