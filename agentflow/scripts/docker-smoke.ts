import { connect } from "../sdk/mod.ts";
const af = connect();
const mode = Deno.args[0] as "socket" | "dind";
const { id, record } = await af.run({
  task: `docker ${mode} smoke`,
  docker: mode,
  workflow: {
    name: `docker-${mode}`,
    nodes: [{ id: "d", type: "shell", run: "docker version --format '{{.Server.Version}}' && docker run --rm alpine echo container-in-container-works" }],
    edges: [],
  },
});
console.log(mode, record.status, "|", (record.runs[0]?.output ?? "").trim().split("\n").slice(-2).join(" / "));
await af.task(id).remove();
Deno.exit(record.status === "succeeded" ? 0 : 1);
