// spawn a long-running mock so the dashboard has something juicy to show
import { connect } from "../sdk/mod.ts";
const af = connect();
const { id } = await af.spawn({
  task: "demo: exercise the review loop with mock agents",
  workflow: {
    name: "mock-implement-review",
    nodes: [
      { id: "implement", type: "shell", label: "Implement", run: "echo 'pretending to implement...'; sleep 6; echo 'done implementing'" },
      { id: "verify", type: "shell", label: "Verify gates", run: "sleep 3; test -f pass.flag || { touch pass.flag; echo 'gates: FAIL first time'; exit 1; }; echo 'gates: PASS'" },
      { id: "review", type: "shell", label: "Review", run: "sleep 4; echo 'looks good to me'" },
    ],
    edges: [
      { from: "implement", to: "verify" },
      { from: "verify", to: "review", when: "ok" },
      { from: "verify", to: "implement", when: "fail" },
    ],
  },
});
console.log("spawned", id);
Deno.exit(0);
