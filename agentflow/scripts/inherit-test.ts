// Agent task; then verify the host agent config is mounted ro in its container.
import { connect } from "../sdk/mod.ts";
const af = connect();
const { id, record } = await af.run({
  task: "Reply with the first heading of /root/.claude/skills/agentflow/SKILL.md and the first line of /root/.claude/CLAUDE.md. Do not write any files.",
  workflow: "quick",
  model: "claude-haiku-4-5",
});
console.log("status:", record.status);
console.log("agent saw:", record.runs[0]?.output.slice(0, 220).replaceAll("\n", " | "));
console.log("id:", id);
Deno.exit(0);
