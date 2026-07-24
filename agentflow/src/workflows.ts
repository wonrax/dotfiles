import type {
  AgentDefaults,
  AgentExec,
  Duration,
  Effort,
  JsonSchema,
  NodeExec,
  OutcomeContract,
  SpawnRequest,
  WaitBackoff,
  WorkflowDef,
  WorkflowNode,
} from "./model.ts";
import { isAgentExec, TERMINAL_NODES } from "./model.ts";

const DURATION = /^(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)?$/;
const UNIT_MS: Record<string, number> = {
  ms: 1,
  s: 1000,
  m: 60_000,
  h: 3_600_000,
  d: 86_400_000,
};

/** "30s" / "5m" / "2h" / "1d" -> milliseconds; a bare number is seconds */
export const parseDuration = (d: Duration): number => {
  const m = DURATION.exec(String(d).trim());
  if (!m) throw new Error(`"${d}" is not a duration; use 30s, 5m, 2h, 1d`);
  return Math.round(Number(m[1]) * UNIT_MS[m[2] ?? "s"]);
};

export const formatDuration = (ms: number): string => {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  if (ms < 3_600_000) return `${Math.round(ms / 60_000)}m`;
  if (ms < 86_400_000) return `${+(ms / 3_600_000).toFixed(1)}h`;
  return `${+(ms / 86_400_000).toFixed(1)}d`;
};

/** label a wait node's timer produces when it is the timer that fired */
export const TICK_LABEL = "tick";

/**
 * How long a wait node sleeps on its `attempt`-th consecutive quiet firing.
 * Jittered because the point of backing off is to stop hammering something, and
 * a fleet of pollers that all backed off to the same 8 minutes would arrive
 * together anyway.
 */
export const backoffMs = (b: WaitBackoff, attempt = 0): number => {
  const min = parseDuration(b.min);
  const max = b.max === undefined ? min : Math.max(min, parseDuration(b.max));
  const factor = b.factor ?? 2;
  const grown = Math.min(max, min * Math.pow(factor, Math.max(0, attempt)));
  const jitter = grown * 0.1 * (Math.random() * 2 - 1);
  return Math.max(1000, Math.round(grown + jitter));
};

/**
 * The fields every judgement in this file is made of. The verdict and the
 * reasoning arrive in one object, which is what makes a correction safe —
 * asking again returns a complete answer, not an orphaned verdict. It also
 * replaces two prose conventions with structure: blocking problems are a
 * separate field from non-blocking remarks, instead of a "Remarks:" heading
 * the next prompt had to parse.
 *
 * The field descriptions carry how to use the fields, deliberately. They reach
 * the agent as comments on the type it must satisfy, which is the one place
 * that cannot drift out of sync with what the validator accepts — so the
 * prompts below do not restate any of it.
 */
const JUDGEMENT_FIELDS: Record<string, JsonSchema> = {
  verdict: {
    enum: ["approve", "request_changes"],
    description: "request_changes exactly when `blocking` is non-empty",
  },
  summary: {
    type: "string",
    minLength: 1,
    description:
      "what the change does and your overall judgement, in a paragraph — the next agent reads this first",
  },
  blocking: {
    type: "array",
    items: { type: "string" },
    description:
      "one entry per problem that has to be fixed before this can be approved. Everything here costs the change another full round trip, so it should be worth one. Empty means approve.",
  },
  remarks: {
    type: "array",
    items: { type: "string" },
    description:
      "everything else worth saying — nits, taste, follow-ups. These reach a polish pass after approval and never block, so a borderline call belongs here rather than in `blocking`.",
  },
};

export const VERDICT: OutcomeContract = {
  kind: "schema",
  label: "verdict",
  fallback: "fail",
  retries: 2,
  schema: {
    type: "object",
    required: ["verdict", "summary"],
    properties: { ...JUDGEMENT_FIELDS },
  },
};

/**
 * A verdict that also says what was actually run. `checks` exists so the
 * reviewer downstream does not spend a round re-running a suite that has just
 * been run — it had no way to know, so it re-derived from scratch every time,
 * which was the single largest duplicate in the graph.
 *
 * It carries results and not reasoning on purpose. The reviewer is blind to
 * what the implementer says about its own work; facts about the tree are a
 * different thing from the case for the change, and only the facts cross.
 */
export const VERIFICATION: OutcomeContract = {
  kind: "schema",
  label: "verdict",
  fallback: "fail",
  retries: 2,
  schema: {
    type: "object",
    required: ["verdict", "summary", "checks"],
    properties: {
      ...JUDGEMENT_FIELDS,
      checks: {
        type: "array",
        items: { type: "string" },
        description:
          "one entry per check you ran, each carrying both the command and how it came out. This is the only account anyone downstream gets of what has already been executed against this diff, and they will skip re-running whatever it covers — so an entry that names a command without its result costs a check rather than saving one.",
      },
    },
  },
};

/**
 * What the PR agent hands back, and `url` is the only reason it is a contract
 * at all: the two shell nodes downstream identify the PR by URL, and this agent
 * is the only thing that reliably knows it. Resolving it from the checkout
 * instead — which is what they used to do — needs the push to have gone to the
 * branch that is checked out AND a git remote to resolve against, and a jj
 * workspace has neither by default. It failed as `no git remotes found` on
 * every lap of a loop that otherwise looked perfectly healthy.
 */
export const PUBLICATION: OutcomeContract = {
  kind: "schema",
  label: "status",
  fallback: "fail",
  retries: 2,
  schema: {
    type: "object",
    required: ["status", "url", "summary"],
    properties: {
      status: {
        enum: ["ok", "fail"],
        description:
          "fail when the pull request is not open and reachable at `url` — a rejected push, a rate limit, a network blip. It parks the task and sends it back here to try again, so it is for what a later attempt could fix, not for a PR that exists and has problems.",
      },
      url: {
        type: "string",
        description:
          "the pull request's full URL, restated every turn. Everything downstream identifies the PR by this and has no other way to find it — the workspace has no remote to infer it from.",
      },
      summary: {
        type: "string",
        minLength: 1,
        description:
          "what you did this turn and what you concluded, in prose — this is what the operator reads to know where the PR stands",
      },
    },
  },
};

/*
 * These prompts state what the situation is and what the agent is for, and
 * leave the judgement calls to it. Rules enumerating what not to do went away
 * on purpose: they cost tokens, they only ever cover the cases someone thought
 * of, and a model that understands why a constraint exists honors it in the
 * cases nobody listed. Nothing here restates a schema field's meaning either —
 * that lives on the contract, where the validator can't drift from it.
 */

const IMPLEMENT_PROMPT =
  `You are a coding agent in an isolated container. The working directory is a
jujutsu (jj) workspace of the project — this repo is jj, not git. The \`.git\`
beside it holds no history and is not the project's; it exists so nix can tell
source from build output.

Task:
{{task}}
{{rubric}}
The operator reviews your work as this workspace's diff, so keep it there as
one working-copy commit and describe it with \`jj describe -m "..."\` when you
are done. Write that message the way the repository's own log reads — it is the
owner's history, so no AI attribution or Co-Authored-By trailers.`;

const REVIEW_PROMPT =
  `You are a strict, adversarial code reviewer. Another agent changed this workspace for the task below, and you are reviewing it blind: you get the task and the diff (\`jj diff\`), never anything the implementer said about its own work. The code has to speak for itself.

{{task}}
{{rubric}}
Operator notes may be appended below; they are part of the task, not scope
creep.

Judge whether this actually does the task and whether it is correct. Be hard to
convince, and be specific about what is wrong rather than uneasy about it in
general. Weigh both costs honestly: a bug that ships, and a round of rework
spent on a change that was already fine.
{{#verify.checks}}
[already run against this diff by the verification agent — its results, not its
opinion, which you do not get]
{{verify.checks}}
{{/verify.checks}}`;

const REVIEW_FOLLOWUP =
  `The implementer revised the change in response to your last review. Re-read the diff as it stands now (\`jj diff\`) and judge it to the same standard: whether what you marked blocking is genuinely resolved, and whether the revision brought anything new with it.
{{#verify.checks}}
[re-run by the verification agent since your last review]
{{verify.checks}}
{{/verify.checks}}`;

// Shares the coder's session but is new to it: the thread has been writing the
// change, not polishing it, so the terms of this pass have to arrive in full
// once. What they are does not change afterwards, which is all `followUp` has
// left to say.
const POLISH_PROMPT =
  `The review is over and your change is approved — this pass exists only to take the easy wins, so make the ones you agree with and leave the rest, including anything that would change behavior or grow the diff. Changing nothing is a fine outcome. Update your \`jj describe\` message if you touch anything.

You are the last node in this workflow: nothing runs after you and nothing
checks the tree again, so whatever you touch here you also check yourself.
Operator notes, if appended below, outrank these remarks.
{{#review.remarks}}
[reviewer remarks]
{{review.remarks}}
{{/review.remarks}}`;

const POLISH_FOLLOWUP =
  `Still the polish pass, on the same terms — changing nothing is still a fine outcome.
{{#review.remarks}}
[reviewer remarks]
{{review.remarks}}
{{/review.remarks}}`;

// Resumed iterations append only the delta; the session history already
// carries the task, so the cached prompt prefix stays stable. The judge nodes
// return structured objects, so these pull the exact fields that matter
// instead of the whole reply.
// What verification and review concluded arrives on its own in the events
// block, so this pulls only the one field that is a work order rather than
// news — repeating the rest under a heading would be the same text twice.
const IMPLEMENT_FOLLOWUP =
  `New information since your last turn, below — address it and update your \`jj describe\` message. Operator notes take priority and permanently extend the task.
{{#review.blocking}}
[review: what must change before this can be approved]
{{review.blocking}}
{{/review.blocking}}`;

const SMART_VERIFY_PROMPT =
  `You are a verification agent. Another agent changed this workspace for the task below; decide whether the change passes.

{{task}}
{{rubric}}
Operator notes may be appended below; they are part of the requirements.

The operator suggested this command, which may be empty, wrong, or far broader
than the change: {{gates}}

Inspect the diff with \`jj diff\` and run the checks that actually cover what
changed. A failure counts against this change only if this change caused it — a
repo that was already red is not this task's problem, though the next agent
still needs to hear it is red so it doesn't go chasing ghosts.`;

/**
 * The PR half of `implement-pr` is one agent and two shell nodes, and this is
 * the agent. It is the one that wrote the change, so when a comment arrives it
 * already knows why the code looks like this, whether the objection came up in
 * review, and what it said last time — none of which a cold triage node can
 * know, and all of which it would have to rebuild from the PR before it could
 * classify anything. Classifying is the cheap part of that turn and the context
 * is the expensive part, so the split paid for the context twice to save a
 * judgement this thread is better placed to make.
 *
 * Doing nothing is stated as an answer on purpose. Without it the node finds
 * something to do on every wake, which on a busy PR is a push per comment.
 *
 * The task is not restated here: the thread has carried it since `implement`.
 * Neither is any of this, on a wake — see `PR_FOLLOWUP`, which is the whole
 * difference between a watch that costs one delta per wake and one that
 * re-sends its own job description for the life of the pull request.
 */
const PR_PROMPT =
  `The change in this workspace is yours, and so is the pull request carrying it — from opening it to whatever comes back at it. The operator approved sending it out; after that you are woken whenever something moves on the PR.

You have \`gh\` and a token. If the PR is not open yet, push the branch and open
it against trunk. Its body is read by people deciding whether to spend time on
this, and by you on a later turn once the details have gone — the commit
history and the diff are already there, so write what they do not carry. A
later push is a force-push or another commit, whichever suits how this
repository's history reads, and the description comes with it when what the
change does has shifted.

When you are woken, \`$AF_REFS/pr-seen.json\` is the PR as it stood the last time
you acted on it and \`pr-latest.json\` is what the most recent poll saw, so the
difference between them is what arrived while you were not looking. Neither is
live — \`gh pr view --json …\`, \`gh pr diff\` and \`gh api\` are.

Work out what the activity means and deal with it here in the workspace, the
same way you would have if it had arrived before you pushed. A review asking
for something is a work order; a CI failure may or may not be this change's,
and is worth reading yourself rather than believing a comment about it; plenty
of activity is nobody asking for anything at all. Changing nothing is a complete
answer, and it is a silent one only where nobody asked: when a person asked for
something and you are not acting on it, the answer is a reply on the PR saying
so, because from their side an unanswered request and an unread one look the
same. Say what you concluded either way and the task goes back to watching. An
operator note outranks all of it: it amends the task rather than commenting on
it. Where you disagree with a request, the answer is a reply on the PR rather
than a change you did not believe in, and what you push next gets read by the
same people again.`;

/**
 * Every wake after the first. This node is woken more often than any other in
 * the bundled graphs — once per burst of activity, for as long as the PR is
 * open — so what it costs per wake is what watching a PR costs. The charter is
 * in the thread from the turn that opened the PR; all that is new is that
 * something moved, and the events block says what.
 */
const PR_FOLLOWUP =
  `Something moved on the pull request, or the operator sent word. Same job as before: changing nothing is still a complete answer, leaving a person who asked for something without a reply is not.`;

/**
 * The PR as both shell nodes look at it. One list, because a snapshot built
 * from different fields than the baseline it is compared against differs on
 * every lap.
 */
const PR_FIELDS = "state,mergeStateStatus,statusCheckRollup,latestReviews,comments,commits";

/**
 * Which PR both shell nodes are talking about, taken from the agent that opened
 * it rather than rediscovered. `{{ship.url}}` holds its last answer for as long
 * as the PR is watched, so a lap that runs hours after the push resolves the
 * same way the first one did — and a full URL carries the repo with it, which
 * is what makes it work in a checkout that has no remote at all.
 *
 * The guard is here because the alternative is worse than a failed lap: an
 * empty URL makes `gh` fall back to inferring the repo from the checkout, and
 * what comes back then is a complaint about git remotes, which is nobody's
 * first guess at "the ship node did not report where it put the PR".
 */
const PR_URL = `url='{{ship.url}}'
[ -n "$url" ] || { echo "no PR url from the ship node, so there is nothing to look at"; exit 1; }`;

/**
 * Two seconds of shell that delete an agent turn from every lap, and the one
 * node here that is worth adding rather than removing.
 *
 * It records the baseline after the agent has finished, so what a poll compares
 * against is the last time this task *acted* rather than the last time it
 * *looked*. A poll that advanced its own baseline shows no delta on precisely
 * the wake where something was missed — and on the first publish there was no
 * baseline at all, so opening a PR always cost one agent turn spent reading the
 * commits and body this same task had just written.
 *
 * The same pass records the URL as the task's `pr` metadata, which is what
 * puts the link on the board row. Here rather than in the agent's prompt
 * because the URL is already structured output the engine validated; asking
 * the agent to also call a tool with it is a second copy that can disagree.
 */
const BASELINE_PR = `set -eu
refs="\${AF_REFS:-/tmp}"
${PR_URL}
snapshot=$(gh pr view "$url" --json ${PR_FIELDS})
printf '%s' "$snapshot" > "$refs/pr-seen.json"
printf '{"op":"meta","from":"%s","set":{"pr":"%s"}}\\n' "\${AF_NODE:-baseline}" "$url" >> "\${AF_OUTBOX:-/dev/null}"`;

/**
 * The cheap half of watching: one API call, a comparison against what the agent
 * last acted on, and a route. It runs on every quiet lap, which is why nothing
 * here spends a token. It reads `pr-seen.json` and never writes it — that file
 * is the baseline node's to move, and a poll that moved it would be answering
 * "has anything happened since I last looked?", which nobody asked.
 *
 * The fingerprint lives in the refs directory beside the checkout rather than
 * inside it, so a poll never shows up in the diff under review.
 */
const POLL_PR = `set -eu
refs="\${AF_REFS:-/tmp}"
${PR_URL}
snapshot=$(gh pr view "$url" --json ${PR_FIELDS})
printf '%s' "$snapshot" > "$refs/pr-latest.json"
case "$snapshot" in *'"state":"MERGED"'*|*'"state":"CLOSED"'*) echo "ROUTE: merged"; exit 0;; esac
if [ "$snapshot" = "$(cat "$refs/pr-seen.json")" ]; then
  echo "ROUTE: idle"
else
  echo "ROUTE: changed"
fi`;

const SWEEP_PROMPT = `{{task}}
{{rubric}}
You are one lap of a loop that runs until it is stopped: look at whatever the
task describes, and make the world match what it says should be true. Then say
whether you changed anything, because that decides how long the loop sleeps
before asking you again.

Read enough to tell what should exist and to say what each task is for, and stop
there. A task you spawn reads for itself and comes at the work without your view
of it, which is most of the reason it is a task and not more turns of this one.
A lap that arrived at an opinion of the work did the work.

Tasks you spawn are keyed, so spawning one that already exists joins it instead
of making a second — which is what lets you re-assert the whole picture on
every lap rather than tracking what you did on the last one.

You have no memory of previous laps beyond what is on this task's event stream,
and that is deliberate: the world in front of you is the state, so read it rather
than reasoning about what you did last time.`;

const SWEEP: OutcomeContract = {
  kind: "schema",
  label: "verdict",
  fallback: "idle",
  retries: 2,
  schema: {
    type: "object",
    required: ["verdict", "summary"],
    properties: {
      verdict: {
        enum: ["acted", "idle", "done"],
        description:
          "acted when this lap changed something — spawned, updated, published; idle when the world already matched and there was nothing to do, which stretches the delay before the next lap and is what stops a quiet watch from costing anything; done when the thing being watched has ended and there will never be anything to do again — the PR merged, the issue closed — which finishes the task instead of watching an empty room forever.",
      },
      summary: {
        type: "string",
        minLength: 1,
        description:
          "what you found and what you did about it, in a few sentences — the operator reads these as the history of the watch",
      },
      spawned: {
        type: "array",
        items: { type: "string" },
        description: "keys of the tasks this lap created or joined",
      },
    },
  },
};

/**
 * implement -> verify -> blind adversarial review -> polish, looping back to
 * the implementer whenever either judge is unhappy.
 *
 * Verification is an agent rather than the operator's gate command, because a
 * command has no way to tell a failure this change caused from one the repo
 * arrived with, and answers a question nobody asked ("is the whole tree
 * green?") at the cost of the whole suite, twice a round. `gates` survives as
 * a suggestion to it.
 *
 * There is no second gate node after polish either. Polish is defined as
 * behaviour-preserving and allowed to do nothing at all, so re-running the
 * suite to guard it was the purest duplicate work in the graph; it now checks
 * what it touched, and its prompt says why that is on it.
 */
export const bundled: Record<string, WorkflowDef> = {
  "implement-review": {
    name: "implement-review",
    nodes: [
      {
        id: "implement",
        exec: "claude",
        session: "coder",
        label: "Implement",
        description:
          "writes the change in the workspace, and is sent back here to revise it whenever verification or review comes back unhappy",
        run: IMPLEMENT_PROMPT,
        followUp: IMPLEMENT_FOLLOWUP,
        maxVisits: 6,
      },
      {
        id: "verify",
        exec: "claude",
        session: "none",
        label: "Verify",
        description:
          "picks and runs the checks that actually cover the diff, decides whether a failure belongs to this change or was already there, and reports what it ran so nothing downstream runs it twice",
        run: SMART_VERIFY_PROMPT,
        outcome: VERIFICATION,
        maxVisits: 6,
      },
      {
        id: "review",
        // A different agent from the one that wrote the change — the same
        // argument as the blindness below, carried one step further: an
        // independent judgement is worth most when it does not share the
        // implementer's blind spots, and two models of one family share most of
        // them. Needs a codex credential; see `af help model`.
        exec: "codex",
        // its own thread, separate from the coder's: still blind to anything
        // the implementer says about its own work, but able to see whether the
        // changes it demanded last round actually landed
        session: "reviewer",
        label: "Review",
        // the blindness is worth stating here rather than only in the code:
        // this description is in the graph map every agent node receives, so
        // it is where the implementer learns that briefing the reviewer is not
        // a thing it can do
        description:
          "judges the finished diff against the task and returns a verdict, blind on purpose — it is shown the verifier's results but nothing any node published about the work, so the diff has to stand on its own",
        run: REVIEW_PROMPT,
        followUp: REVIEW_FOLLOWUP,
        outcome: VERDICT,
        // an allowlist rather than a denylist: blindness cannot depend on
        // having named every kind an agent might publish under, and this is
        // the one node whose whole value is in what it has not been told.
        // Enforced here rather than by leaving the events out of the prompt —
        // the reviewer is an agent with a shell, and a rule it is never told
        // about is a rule that holds only while it does not go looking
        accepts: ["operator"],
        maxVisits: 6,
      },
      {
        id: "polish",
        exec: "claude",
        session: "coder",
        label: "Polish",
        description:
          "a last pass over the approved change for the reviewer's non-blocking remarks — no behaviour changes, doing nothing is allowed, and nothing runs after it",
        run: POLISH_PROMPT,
        followUp: POLISH_FOLLOWUP,
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

  /**
   * implement-review, then out into the world: ask the operator before anything
   * is pushed, open the PR, and stay alive watching it — reacting to review
   * comments, CI and new commits until it merges.
   *
   * The approval gate sits before the loop rather than inside it, so the
   * operator is asked once. After that the PR itself is the review, and the
   * blind local reviewer does not run again, because a human on the PR has
   * taken over the job it was doing.
   *
   * The loop is one agent, because a person looking after their own pull
   * request is one actor with one memory. `ship` opens the PR, pushes
   * revisions and answers what comes back, all on the thread that wrote the
   * change; everything around it — noticing that something moved, recording
   * what has been dealt with — is shell that spends nothing. It used to be
   * three agents, two of them cold, rebuilding on every wake the context the
   * third already had.
   */
  "implement-pr": {
    name: "implement-pr",
    nodes: [
      {
        id: "implement",
        exec: "claude",
        session: "coder",
        label: "Implement",
        description:
          "writes the change in the workspace, and is sent back here to revise it whenever verification or review comes back unhappy",
        run: IMPLEMENT_PROMPT,
        followUp: IMPLEMENT_FOLLOWUP,
        maxVisits: 6,
      },
      {
        id: "verify",
        exec: "claude",
        session: "none",
        label: "Verify",
        description:
          "picks and runs the checks that actually cover the diff, decides whether a failure belongs to this change or was already there, and reports what it ran so nothing downstream runs it twice",
        run: SMART_VERIFY_PROMPT,
        outcome: VERIFICATION,
        maxVisits: 6,
      },
      {
        id: "review",
        // A different agent from the one that wrote the change — the same
        // argument as the blindness below, carried one step further: an
        // independent judgement is worth most when it does not share the
        // implementer's blind spots, and two models of one family share most of
        // them. Needs a codex credential; see `af help model`.
        exec: "codex",
        session: "reviewer",
        label: "Review",
        description:
          "judges the finished diff against the task and returns a verdict, blind on purpose — it is shown the verifier's results but nothing any node published about the work, so the diff has to stand on its own. It runs before the PR exists and not again after: once humans are reviewing on GitHub, this node's job is theirs",
        run: REVIEW_PROMPT,
        followUp: REVIEW_FOLLOWUP,
        outcome: VERDICT,
        accepts: ["operator"],
        maxVisits: 6,
      },
      {
        id: "polish",
        exec: "claude",
        session: "coder",
        label: "Polish",
        description:
          "a last pass over the approved change for the reviewer's non-blocking remarks — no behaviour changes, doing nothing is allowed",
        run: POLISH_PROMPT,
        followUp: POLISH_FOLLOWUP,
        maxVisits: 3,
      },
      {
        id: "approve",
        exec: "wait",
        label: "Approval",
        description:
          "parks until the operator decides whether this goes out; nothing has left the workspace before this point and nothing does without an answer here",
        wait: {
          ask:
            "The change is reviewed and polished. Push it to a branch and open a PR against trunk?",
        },
      },
      {
        id: "ship",
        exec: "claude",
        session: "coder",
        label: "Push + PR",
        description:
          "owns the pull request end to end on the thread that wrote the change: opens it, pushes revisions, replies to reviewers, and decides when activity needs nothing from us. The only node that touches anything outside this workspace",
        run: PR_PROMPT,
        followUp: PR_FOLLOWUP,
        outcome: PUBLICATION,
        // `af rerun` refuses to re-enter this without --force, which is what
        // stops a re-run of the loop posting a second copy of a review reply
        effects: "external",
      },
      {
        id: "cooloff",
        exec: "wait",
        label: "Cool off",
        description:
          "sits out a failed push — a rejected non-fast-forward, a rate limit, a network blip — and sends it back to try again",
        wait: { after: { min: "2m", max: "1h", factor: 2, label: "retry" } },
      },
      {
        id: "baseline",
        exec: "shell",
        label: "Re-baseline",
        description:
          "records the PR as it stands once the agent is done with it, and pins its URL on the first pass, so the next poll compares against the last time this task acted rather than the last time it looked",
        run: BASELINE_PR,
        // same reason as the poll: bookkeeping nobody reads, and one file per
        // lap in the refs directory for as long as the PR is open
        announce: false,
      },
      {
        id: "watch",
        exec: "wait",
        label: "Watch PR",
        description:
          "the task's resting state once the PR is open: costs nothing, wakes when something happens on the PR, and otherwise polls on a delay that stretches while the PR is quiet",
        wait: {
          on: [
            { kind: "review", label: "activity" },
            { kind: "ci", label: "activity" },
            { kind: "commit", label: "activity" },
            { kind: "merged", label: "merged" },
            // the operator changing their mind about the change is the same
            // shape of news as a reviewer asking for something, and goes to the
            // same node — waking on the timer's label instead would send this
            // to poll GitHub, find nothing, and park with the note unread
            { kind: "operator", label: "activity" },
          ],
          // eight comments left in one sitting are one thing that happened
          settle: "45s",
          // "ok" is what the re-baseline routes back with, and it is the only
          // node that routes here on it: arriving that way means the agent just
          // dealt with something, so a PR that is being worked is polled
          // quickly again rather than at whatever the quiet delay had grown to
          after: { min: "2m", max: "1h", factor: 2, resetOn: ["ok"] },
        },
      },
      {
        id: "poll",
        exec: "shell",
        label: "Poll PR",
        description:
          "asks GitHub whether anything moved since the last look, so a quiet PR costs one API call per lap and no tokens at all",
        run: POLL_PR,
        // its output is the word it routes on and nothing else, and this node
        // runs once a lap for as long as the PR is open. Announcing would put
        // "poll — ROUTE: idle" in front of every agent downstream, for ever,
        // to tell them what the edge they arrived down already told them.
        announce: false,
        outcome: {
          kind: "pattern",
          pattern: "^ROUTE:\\s*(\\w+)",
          map: { changed: "changed", idle: "idle", merged: "merged" },
          fallback: "idle",
        },
      },
    ],
    edges: [
      { from: "implement", to: "verify" },
      { from: "verify", to: "review", when: "approve" },
      { from: "verify", to: "implement", when: "request_changes" },
      { from: "review", to: "implement", when: "request_changes" },
      { from: "review", to: "polish", when: "approve" },
      { from: "polish", to: "approve" },
      { from: "approve", to: "ship", when: "approve" },
      { from: "approve", to: "implement", when: "revise" },
      // the work is done and sitting in the workspace; not pushing it is an
      // outcome the operator chose, not a failure
      { from: "approve", to: "@succeeded", when: "decline" },
      { from: "ship", to: "baseline" },
      // a push rejected as non-fast-forward, or a rate limit, must not end a
      // task meant to live as long as the PR — the backoff absorbs the retry
      { from: "ship", to: "cooloff", when: "fail" },
      { from: "cooloff", to: "ship", when: "retry" },
      { from: "baseline", to: "watch" },
      // a baseline that did not record leaves the poll seeing the same activity
      // again, which costs one more turn and loses nothing
      { from: "baseline", to: "watch", when: "fail" },
      { from: "watch", to: "ship", when: "activity" },
      { from: "watch", to: "poll", when: "tick" },
      { from: "watch", to: "@succeeded", when: "merged" },
      { from: "poll", to: "ship", when: "changed" },
      { from: "poll", to: "watch", when: "idle" },
      { from: "poll", to: "@succeeded", when: "merged" },
      // a failed poll is GitHub having a bad minute, not the end of the task
      { from: "poll", to: "watch", when: "fail" },
    ],
  },

  /**
   * A loop that surveys something outside itself and acts on what it finds,
   * usually by spawning tasks. Two wait nodes rather than one so the delay
   * tracks how busy the world is: a lap that found work sleeps briefly, a lap
   * that found none sleeps longer each time.
   *
   * Deliberately says nothing about what to survey — that is the task prompt's
   * job, and the node has `gh`, a shell, and the tools to spawn and publish.
   */
  survey: {
    name: "survey",
    nodes: [
      {
        id: "sweep",
        exec: "claude",
        session: "none",
        label: "Sweep",
        description:
          "looks at the world the task describes, spawns or updates whatever should exist for what it finds, and reports whether it did anything",
        run: SWEEP_PROMPT,
        outcome: SWEEP,
      },
      {
        id: "soon",
        exec: "wait",
        label: "Soon",
        description: "short fixed delay taken after a lap that found work",
        wait: { after: { min: "1m", factor: 1, label: "due" } },
      },
      {
        id: "later",
        exec: "wait",
        label: "Later",
        description:
          "the delay after a quiet lap, doubling each time nothing is found so an idle watch costs almost nothing",
        wait: {
          after: { min: "5m", max: "2h", factor: 2, label: "due", resetOn: ["acted"] },
          on: [{ kind: "operator", label: "due" }],
        },
      },
    ],
    edges: [
      { from: "sweep", to: "soon", when: "acted" },
      { from: "sweep", to: "later", when: "idle" },
      // a watch whose subject has ended is finished, not idle. Without this a
      // loop over something merged three weeks ago is still holding a record and
      // waking every two hours to confirm there is nothing to do
      { from: "sweep", to: "@succeeded", when: "done" },
      // a failed sweep waits with the quiet path, so a broken token or a rate
      // limit backs off instead of hammering
      { from: "sweep", to: "later", when: "fail" },
      { from: "soon", to: "sweep", when: "due" },
      { from: "later", to: "sweep", when: "due" },
    ],
  },

  // single-shot agent, no review loop
  quick: {
    name: "quick",
    nodes: [{
      id: "implement",
      exec: "claude",
      session: "coder",
      label: "Implement",
      description: "writes the change in the workspace; nothing verifies or reviews it after",
      run: IMPLEMENT_PROMPT,
      followUp: IMPLEMENT_FOLLOWUP,
    }],
    edges: [],
  },
};

/**
 * The graph as the agent standing in it needs to see it: which node it is,
 * what ran before it, and what happens to its answer.
 *
 * Generated from the graph rather than written into each prompt, so a workflow
 * someone edits mid-task cannot describe itself wrongly. It exists mostly to
 * stop nodes redoing each other's work — a reviewer that can see a gate node
 * already ran the suite has no reason to run it again, and one that can see
 * its `request_changes` goes back to an implementer knows what its verdict is
 * actually for.
 */
export const describeWorkflow = (wf: WorkflowDef, current: string): string => {
  const width = Math.max(...wf.nodes.map((n) => n.id.length)) + 2;
  const rows = wf.nodes.flatMap((n) => {
    const edges = (wf.edges ?? []).filter((e) => e.from === n.id)
      .map((e) => `${e.when ?? "ok"}→${e.to}`).join("  ");
    const exec = normalizeNode(n).exec;
    const kind = exec === "shell" ? "shell" : exec === "wait" ? "wait" : "agent";
    const id = n.id + " ".repeat(Math.max(0, width - n.id.length));
    const head = `${n.id === current ? "*" : " "} ${id}${kind.padEnd(7)}${edges}`;
    return n.description ? [head, `${" ".repeat(width + 2)}${n.description}`] : [head];
  });
  return `\n\n[workflow] ${wf.name} — you are "${current}", marked *. ` +
    `Edges are labelled with the outcome that takes them.\n${rows.join("\n")}`;
};

/**
 * Expand the legacy `type` shorthand and fill defaults, so the engine only
 * ever sees explicit exec/session/outcome. Old workflows — including ones
 * already persisted inside task records — keep working unchanged.
 */
export const normalizeNode = (node: WorkflowNode): WorkflowNode => {
  const n = { ...node };
  // outcome contracts predate the kind discriminator; infer it for workflows
  // written (or persisted) before it existed
  if (n.outcome && !("kind" in n.outcome)) {
    const legacy = n.outcome as Record<string, unknown>;
    n.outcome = { ...legacy, kind: legacy.schema ? "schema" : "pattern" } as OutcomeContract;
  }
  // a wait node runs no process, so it has no session to join and no output to
  // scrape a label from: its label is whichever trigger fired
  if (n.exec === "wait") {
    n.session = "none";
    n.outcome = undefined;
    return n;
  }
  if (!n.exec) {
    switch (n.type) {
      case "shell":
        n.exec = "shell";
        break;
      case "review":
        n.exec = "claude";
        n.session ??= "none";
        n.outcome ??= VERDICT;
        break;
      case "agent":
      default:
        n.exec = "claude";
        // legacy `resume: false` meant a cold session every visit
        n.session ??= (node as { resume?: boolean }).resume === false ? "none" : "coder";
    }
  }
  n.session ??= "none";
  return n;
};

export const normalizeWorkflow = (wf: WorkflowDef): WorkflowDef => ({
  ...wf,
  nodes: wf.nodes.map(normalizeNode),
});

/**
 * What this node's turns run as: the node's own setting, else the workflow's
 * default for its exec, else the task's.
 *
 * Resolved per node rather than baked into the container's environment, which
 * is where `ANTHROPIC_MODEL` used to live — one value fixed at creation, so a
 * graph could never have run its reviewer on a different model than its
 * implementer even before there were two agents to choose between.
 *
 * Every level is keyed by exec, so a claude default cannot reach a codex node.
 * The unkeyed `model`/`effort` on the request predate the second agent and mean
 * claude.
 */
/**
 * The floor under every other level: what an agent node runs as when nothing
 * anywhere names a model.
 *
 * Stated rather than left to each CLI's own default, because "the default" is
 * not one thing. Claude Code follows whatever the operator's subscription
 * settles on, and codex reads `model` from a config.toml — which for these
 * tasks is the one the engine generates into a private CODEX_HOME, so the
 * operator's own choice never reached it and the container quietly ran on
 * whatever the binary shipped with. A task is worth more than the cheapest
 * model that could have run it, so the floor is the good one and a caller that
 * wants otherwise says so.
 */
export const AGENT_DEFAULTS: Record<AgentExec, Required<AgentDefaults>> = {
  claude: { model: "claude-opus-5", effort: "high" },
  codex: { model: "gpt-5.6-sol", effort: "high" },
};

export const resolveAgent = (
  node: WorkflowNode,
  wf: WorkflowDef,
  request: { agents?: SpawnRequest["agents"]; model?: string; effort?: Effort },
): AgentDefaults => {
  const exec = normalizeNode(node).exec;
  if (!isAgentExec(exec)) return {};
  const fromRequest = request.agents?.[exec] ??
    (exec === "claude" ? { model: request.model, effort: request.effort } : undefined);
  const fromWorkflow = wf.defaults?.[exec];
  const floor = AGENT_DEFAULTS[exec];
  return {
    model: node.model ?? fromWorkflow?.model ?? fromRequest?.model ?? floor.model,
    effort: node.effort ?? fromWorkflow?.effort ?? fromRequest?.effort ?? floor.effort,
  };
};

/** node type shown in the UI and CLI, derived from the real axes */
export const nodeKind = (n: WorkflowNode): string =>
  n.exec === "wait"
    ? n.wait?.ask ? "gate" : "wait"
    : n.exec === "shell"
    ? "shell"
    : n.outcome
    ? "judge"
    : n.session === "none"
    ? "oneshot"
    : "agent";

/**
 * Structural validation. `runningNode` is the node currently executing, which
 * may not be removed out from under the engine.
 */
export const validateWorkflow = (
  wf: WorkflowDef,
  opts: { runningNode?: string; checkpointNode?: string } = {},
): void => {
  const fail = (m: string): never => {
    throw new Error(`invalid workflow: ${m}`);
  };
  if (!wf.nodes?.length) fail("no nodes");
  const ids = new Set<string>();
  for (const n of wf.nodes) {
    if (!n.id) fail("a node has no id");
    if (!/^[\w-]+$/.test(n.id)) fail(`node id "${n.id}" must be [A-Za-z0-9_-]+`);
    if (ids.has(n.id)) fail(`duplicate node id "${n.id}"`);
    ids.add(n.id);
    // Enforced here rather than left to the type, because a graph can arrive as
    // JSON over the API where no compiler ever saw it. An agent node reads the
    // description of every node in its workflow, so one missing description
    // degrades the map for the whole graph, not just its own node.
    if (!n.label?.trim()) fail(`node "${n.id}" has no label`);
    if (!n.description?.trim()) {
      fail(
        `node "${n.id}" has no description — one line on what it is for, written for an agent ` +
          `that has never seen this workflow and has to know what the other nodes already covered`,
      );
    }
    const exec = normalizeNode(n).exec;
    if (exec === "wait") {
      const w = n.wait;
      if (!w || (!w.on?.length && !w.after && !w.ask)) {
        fail(
          `wait node "${n.id}" needs something to wait for: event kinds in \`on\`, a timer in ` +
            `\`after\`, or a question in \`ask\`. With none of them it would park forever`,
        );
        continue; // unreachable: fail throws
      }
      for (const t of w.on ?? []) {
        if (!t.kind?.trim()) fail(`wait node "${n.id}" has a trigger with no kind`);
        if (!t.label?.trim()) {
          fail(
            `wait node "${n.id}" trigger "${t.kind}" has no label, so nothing could route on it`,
          );
        }
      }
      for (
        const [field, value] of [
          ["after.min", w.after?.min],
          ["after.max", w.after?.max],
          ["settle", w.settle],
        ] as const
      ) {
        if (value === undefined) continue;
        try {
          parseDuration(value);
        } catch (e) {
          fail(`wait node "${n.id}" ${field}: ${e instanceof Error ? e.message : e}`);
        }
      }
      continue;
    }
    if (typeof n.run !== "string") fail(`node "${n.id}" has no run template`);
    if (exec !== "shell" && !isAgentExec(exec)) {
      fail(`node "${n.id}" has unknown exec "${exec}"`);
    }
    // Nothing downstream can tell a model meant for the other agent from a
    // typo, so this catches only the one case it can — a setting on a node that
    // has no turn to apply it to, which would otherwise be silently ignored.
    if ((n.model || n.effort) && exec === "shell") {
      fail(`node "${n.id}" runs a command, so it has no model or effort to set`);
    }
    if (n.outcome) {
      const o = normalizeNode(n).outcome!;
      if (o.kind === "pattern") {
        try {
          new RegExp(o.pattern, "i");
        } catch (e) {
          fail(`node "${n.id}" has an invalid outcome pattern: ${e}`);
        }
        if (!Object.keys(o.map ?? {}).length) fail(`node "${n.id}" outcome has an empty map`);
      } else if (o.kind === "schema") {
        if (!o.schema || typeof o.schema !== "object") fail(`node "${n.id}" outcome has no schema`);
        if (!o.label) fail(`node "${n.id}" outcome must name the label field`);
        // the label has to be reachable, or every run falls back
        const root = o.label.split(".")[0];
        if (o.schema?.properties && !(root in o.schema.properties)) {
          fail(`node "${n.id}" outcome label "${o.label}" is not a property of its schema`);
        }
        if (!(o.schema?.required ?? []).includes(root)) {
          fail(`node "${n.id}" outcome label "${root}" must be listed in the schema's required`);
        }
      } else {
        fail(`node "${n.id}" has an outcome with unknown kind`);
      }
    }
  }
  /**
   * A session key is one conversation with one agent holding it. Two execs on
   * the same key share a single thread id and a single "has it started" flag,
   * so whichever ran second would hand its agent the other's thread — claude
   * resuming a codex thread id it has never issued, or codex resuming a uuid
   * with no rollout behind it. Both fail per visit and neither says why, which
   * is a strange way to find out the graph was never coherent.
   */
  const execBySession = new Map<string, { exec: NodeExec; node: string }>();
  for (const n of wf.nodes ?? []) {
    const norm = normalizeNode(n);
    if (!isAgentExec(norm.exec) || (norm.session ?? "none") === "none") continue;
    const key = norm.session!;
    const first = execBySession.get(key);
    if (!first) execBySession.set(key, { exec: norm.exec, node: n.id });
    else if (first.exec !== norm.exec) {
      fail(
        `nodes "${first.node}" (${first.exec}) and "${n.id}" (${norm.exec}) share session ` +
          `"${key}", but a session is one conversation with one agent. Give them a key each, ` +
          `or put them on the same exec`,
      );
    }
  }

  const known = (id: string) => ids.has(id) || (TERMINAL_NODES as readonly string[]).includes(id);
  for (const e of wf.edges ?? []) {
    if (!ids.has(e.from)) fail(`edge from unknown node "${e.from}"`);
    if (!known(e.to)) fail(`edge to unknown node "${e.to}"`);
  }
  if (wf.start && !ids.has(wf.start)) fail(`start node "${wf.start}" does not exist`);
  if (opts.runningNode && !ids.has(opts.runningNode)) {
    fail(`node "${opts.runningNode}" is executing right now and cannot be removed`);
  }
  if (opts.checkpointNode && !ids.has(opts.checkpointNode)) {
    fail(
      `node "${opts.checkpointNode}" is where this task would resume; ` +
        `remove it only together with a rerun that picks a different node`,
    );
  }
};

/**
 * Problems a graph can have that are not errors. They are reported as events on
 * the task rather than refusing the graph, because each one is legitimate
 * somewhere — but all three are silent, and all three bite hardest in exactly
 * the graphs that are supposed to run for weeks.
 */
export const lintWorkflow = (wf: WorkflowDef): string[] => {
  const warnings: string[] = [];
  const nodes = wf.nodes.map(normalizeNode);
  const edgeFor = (from: string, label: string) =>
    (wf.edges ?? []).some((e) => e.from === from && (e.when ?? "ok") === label);
  const success = wf.successLabels ?? ["ok", "approve"];
  const waits = nodes.filter((n) => n.exec === "wait");
  /**
   * Only recurring waits make a node part of a long-lived loop. A gate is
   * traversed once — an operator answers it and the graph moves on — so a cycle
   * that exists only because a gate can send work back for revision is the
   * ordinary rework loop of a one-shot task, where a failure ending the task is
   * exactly right.
   */
  const recurring = waits.filter((n) => !n.wait?.ask);

  // reachability both ways, to find the nodes that sit on a loop through a wait
  const forward = (start: string) => {
    const seen = new Set<string>();
    const queue = [start];
    while (queue.length) {
      const id = queue.shift()!;
      for (const e of wf.edges ?? []) {
        if (e.from !== id || e.to.startsWith("@") || seen.has(e.to)) continue;
        seen.add(e.to);
        queue.push(e.to);
      }
    }
    return seen;
  };
  const looping = new Set<string>();
  for (const w of recurring) {
    const downstream = forward(w.id);
    for (const id of downstream) if (forward(id).has(w.id)) looping.add(id);
    if (downstream.has(w.id)) looping.add(w.id);
  }

  for (const n of nodes) {
    if (n.exec === "wait") {
      for (const t of n.wait?.on ?? []) {
        if (!edgeFor(n.id, t.label) && !success.includes(t.label)) {
          warnings.push(
            `wait node "${n.id}" wakes on ${t.kind} with label "${t.label}", but no edge takes ` +
              `it — that wake would end the task instead of acting on what it heard`,
          );
        }
      }
      const tick = n.wait?.after ? n.wait.after.label ?? TICK_LABEL : undefined;
      if (tick && !edgeFor(n.id, tick) && !success.includes(tick)) {
        warnings.push(
          `wait node "${n.id}" has a timer producing "${tick}" with no edge taking it, so the ` +
            `first time it fires the task ends`,
        );
      }
    } else if (looping.has(n.id) && !edgeFor(n.id, "fail")) {
      // only on the loop: a node in the one-shot phase of a graph is allowed to
      // end the task by failing, which is the normal meaning of a failed run.
      // A node the loop comes back to is different — it will meet a rate limit
      // or a dropped connection eventually, and one of those should not be what
      // stops a watch that was meant to run for weeks.
      warnings.push(
        `node "${n.id}" sits on a loop through a wait node but has no edge for "fail", so a ` +
          `single transient failure ends a task that was meant to keep running`,
      );
    }
  }
  return warnings;
};

/**
 * The gate-command and smart-verify variants were two workflows until smart
 * verification became the only one. Anything still naming the old id — a
 * script, a saved dispatcher prompt — resolves to it instead of failing, but
 * it is deliberately absent from `bundled`: there is one implement-review now,
 * and listing two would say otherwise.
 */
const ALIASES: Record<string, string> = { "implement-review-smart": "implement-review" };

/** the canonical bundled name behind `w`, following aliases; undefined if it is not one */
export const bundledWorkflow = (w: string): string | undefined => {
  const name = ALIASES[w] ?? w;
  return bundled[name] ? name : undefined;
};

export const resolveWorkflow = (w: string | WorkflowDef | undefined): WorkflowDef => {
  if (!w) return normalizeWorkflow(bundled["implement-review"]);
  if (typeof w === "string") {
    const name = bundledWorkflow(w);
    if (!name) {
      throw new Error(
        `unknown bundled workflow "${w}"; known: ${Object.keys(bundled).join(", ")}`,
      );
    }
    return normalizeWorkflow(bundled[name]);
  }
  validateWorkflow(w);
  return normalizeWorkflow(w);
};
