import type { WorkflowDef } from "./model.ts";

const IMPLEMENT_PROMPT = `You are a coding agent working inside an isolated container.
The working directory is a jujutsu (jj) workspace of the project — use jj, never git.

Task:
{{task}}

Implement the task. When you are done, describe your work with \`jj describe -m "<summary>"\`.
Do not run \`jj new\`, \`jj edit\` or push anything unless the task explicitly asks.

A shared notes file at {{notes}} connects you with the other agents on this
task (reviewer, verifier). Read it if it exists. Append notes there when
context would help them: design decisions, known tradeoffs, why something
looks unusual. It lives outside the repo and is never committed.`;

const REVIEW_PROMPT = `You are a strict, adversarial code reviewer. The working directory contains changes made by another agent for this task:

{{task}}

Operator amendments (these are part of the task requirements, NOT scope creep):
{{amendments}}

Inspect the changes with \`jj diff\` (fall back to reading files if this is not a jj workspace).
The implementer may have left notes for you at {{notes}} — read them if the
file exists, and append your own questions or context there for the next
implementation round.
Judge correctness, completeness against the task plus its amendments, and obvious quality problems. Nitpicks alone must not block approval — instead, when approving, list any non-blocking nits under a "Remarks:" heading; they are forwarded to the implementer for a final polish pass.

End your reply with exactly one final line, nothing after it:
VERDICT: APPROVE
or
VERDICT: REQUEST_CHANGES`;

const POLISH_PROMPT = `The reviewer approved your change but left the remarks below. Apply only the trivial, behavior-preserving fixes you agree with (typos, stray files, naming, comments). If nothing is warranted, reply "nothing to change" and do nothing. Do not expand scope, add features, or restructure. Update your \`jj describe\` message if you change anything.

[reviewer remarks]
{{review}}`;

// Resumed iterations append only the delta; the session history already
// carries the task, so the cached prompt prefix stays stable.
const IMPLEMENT_FOLLOWUP = `New information since your last turn — address it and update your \`jj describe\` message. Operator feedback takes priority and permanently extends the task.

[operator feedback]
{{feedback}}

[verification output]
{{verify}}

[review feedback]
{{review}}`;

const SMART_VERIFY_PROMPT = `You are a verification agent. Another agent changed this workspace for the task below; decide whether the change passes verification.

{{task}}

Operator amendments (part of the requirements):
{{amendments}}

Suggested verification command (may be empty or too broad — use judgment):
{{gates}}

Inspect the change with \`jj diff\`, then run only the checks relevant to what
actually changed. The implementer may have left notes at {{notes}} — read
them if present. Pre-existing failures unrelated to this change must NOT
block verification — when a check fails, determine whether the failure is
caused by this change (does the failing code path intersect the diff?) and
say which failures you attribute to the change vs the baseline.

End your reply with exactly one final line, nothing after it:
VERDICT: APPROVE
or
VERDICT: REQUEST_CHANGES`;

export const bundled: Record<string, WorkflowDef> = {
  // implement -> verify gates -> adversarial review -> loop until approved
  "implement-review": {
    name: "implement-review",
    nodes: [
      {
        id: "implement",
        type: "agent",
        label: "Implement",
        run: IMPLEMENT_PROMPT,
        followUp: IMPLEMENT_FOLLOWUP,
        maxVisits: 6,
      },
      { id: "verify", type: "shell", label: "Verify gates", run: "{{gates}}", maxVisits: 6 },
      { id: "review", type: "review", label: "Review", run: REVIEW_PROMPT, maxVisits: 6 },
      // post-approval: non-blocking reviewer remarks still reach the implementer
      {
        id: "polish",
        type: "agent",
        label: "Polish",
        run: POLISH_PROMPT,
        followUp: POLISH_PROMPT,
        maxVisits: 3,
      },
      { id: "finalverify", type: "shell", label: "Final gates", run: "{{gates}}", maxVisits: 3 },
    ],
    edges: [
      { from: "implement", to: "verify" },
      { from: "verify", to: "review", when: "ok" },
      { from: "verify", to: "implement", when: "fail" },
      { from: "review", to: "implement", when: "request_changes" },
      { from: "review", to: "polish", when: "approve" },
      // polish is best-effort: even if its turn errors, approved work stands
      // as long as the final gates pass
      { from: "polish", to: "finalverify" },
      { from: "polish", to: "finalverify", when: "fail" },
      { from: "finalverify", to: "polish", when: "fail" },
    ],
  },

  // like implement-review, but verification is an LLM judge: it picks which
  // checks matter for the diff and ignores pre-existing unrelated failures
  "implement-review-smart": {
    name: "implement-review-smart",
    nodes: [
      {
        id: "implement",
        type: "agent",
        label: "Implement",
        run: IMPLEMENT_PROMPT,
        followUp: IMPLEMENT_FOLLOWUP,
        maxVisits: 6,
      },
      { id: "verify", type: "review", label: "Smart verify", run: SMART_VERIFY_PROMPT, maxVisits: 6 },
      { id: "review", type: "review", label: "Review", run: REVIEW_PROMPT, maxVisits: 6 },
      {
        id: "polish",
        type: "agent",
        label: "Polish",
        run: POLISH_PROMPT,
        followUp: POLISH_PROMPT,
        maxVisits: 3,
      },
    ],
    edges: [
      { from: "implement", to: "verify" },
      { from: "verify", to: "review", when: "approve" },
      { from: "verify", to: "implement", when: "request_changes" },
      { from: "review", to: "implement", when: "request_changes" },
      { from: "review", to: "polish", when: "approve" },
    ],
  },

  // single-shot agent, no review loop
  quick: {
    name: "quick",
    nodes: [{
      id: "implement",
      type: "agent",
      label: "Implement",
      run: IMPLEMENT_PROMPT,
      followUp: IMPLEMENT_FOLLOWUP,
    }],
    edges: [],
  },
};

export const resolveWorkflow = (w: string | WorkflowDef | undefined): WorkflowDef => {
  if (!w) return bundled["implement-review"];
  if (typeof w === "string") {
    const def = bundled[w];
    if (!def) throw new Error(`unknown bundled workflow "${w}"`);
    return def;
  }
  return w;
};
