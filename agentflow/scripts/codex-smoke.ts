/**
 * End-to-end probe for codex nodes. Needs a codex credential on the daemon —
 * see `af help model`.
 *
 * Two nodes on one session rather than one, because everything specific to this
 * exec is on the second turn: claude is handed a thread id, codex names its own
 * and reports it on the stream, so a workflow that only ever runs one turn per
 * thread would pass with the id capture broken.
 */
import { connect } from "../sdk/mod.ts";

const af = connect();
const { id, record } = await af.run({
  task: "Write a file called codex.txt whose only contents are the word 'pong'.",
  workflow: {
    name: "codex-smoke",
    nodes: [
      {
        id: "write",
        exec: "codex",
        session: "coder",
        label: "Write",
        description: "creates the file the second node is asked about",
        run: "{{task}}",
      },
      {
        id: "recall",
        exec: "codex",
        session: "coder",
        label: "Recall",
        description: "answers from the thread, so a lost thread id shows up as a wrong answer",
        run: "What filename did you just create? Reply with the bare filename and nothing else.",
      },
    ],
    edges: [{ from: "write", to: "recall" }],
  },
});

const runs = Object.fromEntries(record.runs.map((r) => [r.node, r]));
const recall = runs.recall;
const problems = [
  record.status !== "succeeded" && `task ${record.status}`,
  !recall && "recall never ran",
  recall && !recall.output.includes("codex.txt") &&
  `recall answered ${JSON.stringify(recall.output.slice(0, 80))}, so the thread was not resumed`,
  !runs.write?.llm?.turns && "no telemetry parsed from the event stream",
].filter(Boolean);

console.log("id:", id, "| status:", record.status);
console.log("thread:", record.sessions?.coder?.id ?? "(never captured)");
for (const node of ["write", "recall"]) {
  console.log(`${node}:`, JSON.stringify(runs[node]?.llm ?? null));
}
for (const p of problems) console.log("FAIL:", p);
Deno.exit(problems.length ? 1 : 0);
