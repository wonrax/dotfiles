import { connect } from "../sdk/mod.ts";
const af = connect();
for (const t of await af.list()) await af.task(t.id).remove();
console.log("board size now:", (await af.list()).length);
Deno.exit(0);
