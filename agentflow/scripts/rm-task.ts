import { connect } from "../sdk/mod.ts";
await connect().task(Deno.args[0]).remove();
console.log("removed");
Deno.exit(0);
