/**
 * Regression suite for the boundaries that are expensive to get wrong quietly:
 * what an agent inside a container may make the host run, and the affordances an
 * operator reaches for when a long-lived task is stuck.
 *
 * Unlike its neighbours this does not talk to the daemon you have running. It
 * boots one of its own on a spare port with a throwaway HOME, so the state dir,
 * the containers and the board all belong to the run and go away with it —
 * these assertions need to spawn deliberately broken tasks and park one on a
 * $0 ceiling, and doing that on the real board would be rude at best.
 *
 * Nothing here reaches a model: the graphs are shell, and the one that needs
 * claude *nodes* — to assert what goes into their prompts — writes a stub over
 * the binary first. Needs docker and the agentflow:latest image.
 *
 *   deno task test
 */
const PORT = 4297;
const URL_ = `http://127.0.0.1:${PORT}`;
const MAIN = new URL("../src/main.ts", import.meta.url).pathname;

const api = async (path: string, body?: unknown) => {
  const res = await fetch(`${URL_}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
};

let failures = 0;
const check = (name: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "  ok  " : "FAIL  "}${name}${ok || !detail ? "" : `\n        ${detail}`}`);
  if (!ok) failures++;
};

/** a task settles or we stop waiting on it; "waiting" counts, it can last weeks */
const settle = async (id: string, tries = 90) => {
  for (let i = 0; i < tries; i++) {
    const { body } = await api(`/api/task/${id}`);
    if (body.error) return body;
    if (["succeeded", "failed", "stopped", "waiting"].includes(body.status)) return body;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return (await api(`/api/task/${id}`)).body;
};

/** poll the record until it looks the way the next step needs it to */
const until = async (id: string, want: (t: Record<string, string>) => boolean, tries = 120) => {
  for (let i = 0; i < tries; i++) {
    const { body } = await api(`/api/task/${id}`);
    if (want(body)) return body;
    await new Promise((r) => setTimeout(r, 500));
  }
  return (await api(`/api/task/${id}`)).body;
};

const shell = (name: string, run: string) => ({
  name,
  nodes: [{ id: "go", exec: "shell", label: "Go", description: "does the thing", run }],
  edges: [],
});

// ---------------------------------------------------------------------------

if ((await fetch(`${URL_}/api/board`).then(() => true, () => false))) {
  console.error(`something is already listening on ${PORT}; stop it and re-run`);
  Deno.exit(2);
}

const home = await Deno.makeTempDir({ prefix: "agentflow-sandbox-" });
await Deno.mkdir(`${home}/.config/agentflow`, { recursive: true });
// a host window with room in it, so the budget view has all three scopes to show
await Deno.writeTextFile(`${home}/.config/agentflow/config.json`, '{"budget":{"daily":500}}');
/**
 * Never used to talk to anything. One assertion below needs claude *nodes* —
 * what goes into their prompts, which the engine records before it runs
 * anything — and the daemon refuses to build a container for one without a
 * credential to put in it. The binary those nodes reach is a stub the task
 * writes over the real one, so this token is never sent anywhere.
 */
await Deno.writeTextFile(`${home}/.config/agentflow/token`, "sandbox-not-a-real-token\n");

const daemon = new Deno.Command(Deno.execPath(), {
  args: ["run", "--allow-all", MAIN],
  env: { HOME: home, AGENTFLOW_PORT: String(PORT) },
  stdout: "piped",
  stderr: "piped",
}).spawn();

const teardown = async () => {
  // the board first: the ids are the container names, and the daemon has to be
  // gone before they are removed or its own teardown races this one
  const ids = await api("/api/board").then((r) => (r.body as { id: string }[]).map((t) => t.id))
    .catch(() => [] as string[]);
  try {
    daemon.kill("SIGTERM");
  } catch { /* already gone */ }
  await daemon.status;
  for (const id of ids) {
    await new Deno.Command("docker", { args: ["rm", "-f", `af-${id}`] }).output().catch(() => {});
  }
  await Deno.remove(home, { recursive: true }).catch(() => {});
};

const ready = async () => {
  for (let i = 0; i < 40; i++) {
    if (await fetch(`${URL_}/api/board`).then((r) => r.ok, () => false)) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
};

try {
  if (!await ready()) {
    // its own stderr is the only thing that says why — a port already taken and
    // a broken import look identical from out here. Cleaned up by hand rather
    // than by the `finally`, which Deno.exit does not run.
    daemon.kill("SIGTERM");
    const { stderr } = await daemon.output();
    console.error(`sandbox daemon never answered on ${PORT}\n${new TextDecoder().decode(stderr)}`);
    await Deno.remove(home, { recursive: true }).catch(() => {});
    Deno.exit(2);
  }

  // -------------------------------------------------------------------------
  console.log("\nchildWorkflows — what a container may make the host run\n");

  const BABYSIT = shell("whatever-the-file-called-it", "echo 'babysitter alive'");

  const malformed = await api("/api/spawn", {
    task: "x",
    workflow: shell("p", "true"),
    childWorkflows: { broken: { name: "broken", nodes: [{ id: "n", exec: "shell" }], edges: [] } },
  });
  check(
    "a malformed carried graph fails the parent's spawn, not its first fan-out",
    malformed.status === 400 && /childWorkflows "broken"/.test(malformed.body.error ?? ""),
    `${malformed.status} ${malformed.body.error ?? ""}`,
  );

  const collide = await api("/api/spawn", {
    task: "x",
    workflow: shell("p", "true"),
    childWorkflows: { survey: BABYSIT },
  });
  check(
    "a name that shadows a bundled workflow is refused",
    collide.status === 400 && /bundled workflow/.test(collide.body.error ?? ""),
    `${collide.status} ${collide.body.error ?? ""}`,
  );

  const badName = await api("/api/spawn", {
    task: "x",
    workflow: shell("p", "true"),
    childWorkflows: { "not a name": BABYSIT },
  });
  check(
    "a name an agent could not pick off a list is refused",
    badName.status === 400 && /letters, digits/.test(badName.body.error ?? ""),
    `${badName.status} ${badName.body.error ?? ""}`,
  );

  // a loop through a wait with no fail edge — the lint the task's own graph
  // already gets, now for a graph it carries for someone else
  const lintable = {
    name: "lintable",
    nodes: [
      { id: "work", exec: "shell", label: "Work", description: "the lap", run: "true" },
      {
        id: "nap",
        exec: "wait",
        label: "Nap",
        description: "waits between laps",
        wait: { after: { min: "1m", label: "due" } },
      },
    ],
    edges: [{ from: "work", to: "nap" }, { from: "nap", to: "work", when: "due" }],
  };

  const line = (o: unknown) => JSON.stringify(JSON.stringify(o));
  const asks = [
    {
      op: "spawn",
      from: "go",
      task: "watch it",
      key: "ok",
      title: "declared",
      workflow: "pr-babysit",
    },
    {
      op: "spawn",
      from: "go",
      task: "watch it",
      key: "no",
      title: "undeclared",
      workflow: "not-a-thing",
    },
    { op: "spawn", from: "go", task: "sneak a graph in", key: "inline", workflow: BABYSIT },
    {
      op: "spawn",
      from: "go",
      task: "hand graphs down",
      key: "down",
      childWorkflows: { evil: BABYSIT },
    },
  ];

  const parent = await api("/api/spawn", {
    id: "cw-parent",
    task: "parent that fans out",
    workflow: {
      name: "fanout",
      nodes: [
        {
          id: "go",
          exec: "shell",
          label: "Go",
          description: "asks the host for children",
          run: asks.map((a) => `printf '%s\\n' ${line(a)} >> "$AF_OUTBOX"`).join("\n") +
            "\necho asked",
        },
        {
          id: "rest",
          exec: "shell",
          label: "Rest",
          description: "a second node, so the spool drains before the task settles",
          run: "sleep 1",
        },
      ],
      edges: [{ from: "go", to: "rest" }],
    },
    childWorkflows: { "pr-babysit": BABYSIT, lintable },
  });
  check(
    "a parent carrying graphs spawns",
    parent.status === 200,
    JSON.stringify(parent.body).slice(0, 160),
  );
  check(
    "the carried graph is stored under the name the agent will ask for",
    parent.body.record?.request?.childWorkflows?.["pr-babysit"]?.name === "pr-babysit",
    `name = ${parent.body.record?.request?.childWorkflows?.["pr-babysit"]?.name}`,
  );

  await settle("cw-parent");
  const log = (await api("/api/task/cw-parent/log")).body as {
    kind: string;
    message: string;
    to?: string | string[];
  }[];
  const toGo = (re: RegExp) =>
    log.find((e) =>
      re.test(e.message) && (e.to === "go" || (Array.isArray(e.to) && e.to.includes("go")))
    );

  check(
    "a carried graph is linted at declaration, onto the parent's stream",
    log.some((e) => e.kind === "workflow" && /lint: childWorkflows\.lintable:/.test(e.message)),
    log.filter((e) => e.kind === "workflow").map((e) => e.message).join(" | ").slice(0, 160),
  );
  check(
    "a declared name spawns a child",
    log.some((e) => e.kind === "spawn" && /spawned/.test(e.message)),
    log.filter((e) => e.kind === "spawn").map((e) => e.message).join(" | "),
  );
  const refusal = toGo(/no workflow "not-a-thing"/);
  check(
    "an undeclared name is refused, addressed to the node that asked",
    !!refusal && /pr-babysit/.test(refusal.message) && /implement-review/.test(refusal.message),
    refusal?.message?.slice(0, 180) ?? "not found",
  );
  check(
    "a graph object over the spool is refused",
    !!toGo(/name of a workflow, not a graph/),
    toGo(/not a graph/)?.message ?? "not found",
  );
  check(
    "a node cannot hand graphs to children of its own",
    !!toGo(/childWorkflows is declared/),
    toGo(/childWorkflows is declared/)?.message?.slice(0, 160) ?? "not found",
  );

  const board = (await api("/api/board")).body as { id: string; parent?: string }[];
  const childId = board.find((t) => t.parent === "cw-parent")?.id;
  if (!childId) {
    check("a child record exists", false, "nothing on the board has cw-parent as its parent");
  } else {
    const child = (await api(`/api/task/${childId}`)).body;
    check(
      "the child runs the declared graph rather than a bundled one",
      child.workflow?.name === "pr-babysit" && child.workflow.nodes.length === 1,
      `${child.workflow?.name} (${child.workflow?.nodes?.length} nodes)`,
    );
    check(
      "the child carries nothing for children of its own",
      child.request?.childWorkflows === undefined,
      JSON.stringify(child.request?.childWorkflows),
    );

    /**
     * Swapping the graphs under a task that is already running them. What this
     * is for is a sweep that has been watching a repo for weeks and should
     * start spawning its reviewers differently — stopping it to change that
     * would throw away everything it knows about what it has already seen.
     *
     * The child spawned above is the assertion that matters: it holds its own
     * copy, so a swap must not reach back into it.
     */
    const swapped = {
      ...BABYSIT,
      nodes: BABYSIT.nodes.map((n) => ({ ...n, exec: "wait", wait: { after: { min: "1h" } } })),
    };
    const bad = await api("/api/task/cw-parent/child-workflows", {
      childWorkflows: { "not a name": swapped },
    });
    check(
      "a swap is checked the way spawn checks it, so a hot edit cannot smuggle one in",
      bad.status === 400 && /letters, digits/.test(bad.body.error ?? ""),
      `${bad.status} ${bad.body.error ?? ""}`,
    );

    const ok = await api("/api/task/cw-parent/child-workflows", {
      childWorkflows: { "pr-babysit": swapped },
    });
    check(
      "a valid swap lands, and drops the graphs left out of it",
      ok.status === 200 &&
        Object.keys(ok.body.request?.childWorkflows ?? {}).join() === "pr-babysit" &&
        ok.body.request.childWorkflows["pr-babysit"].nodes[0].exec === "wait",
      `${ok.status} ${
        JSON.stringify(ok.body.request?.childWorkflows ?? ok.body.error).slice(0, 160)
      }`,
    );
    const after = (await api(`/api/task/${childId}`)).body;
    check(
      "and the child already running keeps the graph it was spawned with",
      after.workflow?.nodes?.[0]?.exec === "shell",
      JSON.stringify(after.workflow?.nodes?.[0]),
    );
  }

  // -------------------------------------------------------------------------
  console.log("\nthe working directory a task with no repo gets\n");

  const cloned = await api("/api/spawn", {
    id: "clone-task",
    task: "clone into an empty working directory",
    // the source is built in the container so the clone has something local to
    // pull from; the half under test is `clone … .`, which is what the docs tell
    // people to do and what git refuses in a directory that is not empty
    setup: {
      run: "git init -q /tmp/src && (cd /tmp/src && echo hi > README.md && git add -A && " +
        "git -c user.email=a@b -c user.name=a commit -qm init) && git clone -q /tmp/src .",
      required: true,
    },
    workflow: shell("clone", "test -f README.md && echo CLONE_OK && pwd && ls -a"),
  });
  check("the clone task spawns", cloned.status === 200, JSON.stringify(cloned.body).slice(0, 160));
  const cloneDone = await settle("clone-task");
  const cloneOut = cloneDone.runs?.[0]?.output ?? "";
  check(
    "the documented `gh repo clone … .` shape works",
    cloneDone.status === "succeeded" && /CLONE_OK/.test(cloneOut),
    `${cloneDone.status}: ${(cloneOut || cloneDone.error || "").slice(0, 180)}`,
  );
  check(
    "the working directory sits below the mount root",
    cloneDone.cwd === "/ws/clone-task/work",
    String(cloneDone.cwd),
  );
  check(
    "the harness is not in the working directory",
    !/af-mcp\.mjs/.test(cloneOut),
    cloneOut.replace(/\n/g, " ").slice(0, 180),
  );

  // -------------------------------------------------------------------------
  console.log("\nmoving a ceiling on a live task\n");

  await api("/api/spawn", {
    id: "budget-task",
    task: "park on cost",
    maxCostUsd: 0,
    // a claude node, because only those are admitted against a budget — it parks
    // before its container is built, so no credential is ever needed here
    workflow: {
      name: "spendy",
      nodes: [{
        id: "think",
        exec: "claude",
        label: "Think",
        description: "would spend",
        run: "hi",
      }],
      edges: [],
    },
  });
  const parked = await settle("budget-task");
  check(
    "a breached ceiling parks the task rather than failing it",
    parked.status === "waiting" && parked.wait?.reason === "budget",
    `${parked.status} / ${parked.wait?.reason}`,
  );
  check(
    "the park names the command that raises it",
    /af budget budget-task --max-cost/.test(parked.wait?.ask ?? ""),
    parked.wait?.ask ?? "(no message)",
  );

  const view = (await api("/api/task/budget-task/budget")).body;
  check(
    "the view carries the ceiling, the spend and the host window",
    view.maxCostUsd === 0 && view.windows?.[0]?.capUsd === 500,
    JSON.stringify(view),
  );
  const same = await api("/api/task/budget-task/budget", { maxCostUsd: 0 });
  check(
    "setting the ceiling it already has is refused",
    same.status === 409,
    same.body.error ?? "",
  );
  const negative = await api("/api/task/budget-task/budget", { maxCostUsd: -5 });
  check("a negative ceiling is refused", negative.status === 400, negative.body.error ?? "");

  const raised = await api("/api/task/budget-task/budget", { maxCostUsd: 25 });
  check(
    "a raise lands on the live record",
    raised.status === 200 && raised.body.request.maxCostUsd === 25,
    `ceiling ${raised.body.request?.maxCostUsd}`,
  );
  const afterRaise = await settle("budget-task");
  check(
    "the raise resumes it instead of leaving a poke to do",
    afterRaise.status !== "waiting" || afterRaise.wait?.reason !== "budget",
    `${afterRaise.status} / ${afterRaise.wait?.reason ?? "-"}`,
  );
  const budgetLog = (await api("/api/task/budget-task/log")).body as { message: string }[];
  check(
    "the change is on the event stream",
    budgetLog.some((e) => /maxCostUsd \$0\.00 → \$25\.00/.test(e.message)),
    budgetLog.map((e) => e.message).join(" | ").slice(0, 160),
  );

  // -------------------------------------------------------------------------
  console.log("\nreaching a task whose container is stopped\n");

  const paths = (await api("/api/task/budget-task/paths")).body;
  check(
    "paths gives the host refs dir without a docker inspect",
    paths.refs?.endsWith("/ws/budget-task/refs") && !!paths.workspace && !!paths.logs,
    JSON.stringify(paths),
  );

  // -------------------------------------------------------------------------
  console.log("\ncarrying one node's field to the next\n");

  /**
   * How the PR half of `implement-pr` knows which PR it is watching: the agent
   * that opened it answers with the URL, and the two shell nodes read it out of
   * `{{ship.url}}` on every lap. They used to rediscover it from the checkout,
   * which needs a git remote that a jj workspace does not have.
   */
  await api("/api/spawn", {
    id: "field-task",
    task: "pass a field down",
    workflow: {
      name: "handoff",
      nodes: [
        {
          id: "publish",
          exec: "shell",
          label: "Publish",
          description: "answers with an object",
          run: `printf '%s' '{"status":"ok","url":"https://example.test/pull/7"}'`,
          outcome: {
            kind: "schema",
            label: "status",
            schema: {
              type: "object",
              required: ["status", "url"],
              properties: { status: { enum: ["ok", "fail"] }, url: { type: "string" } },
            },
          },
        },
        {
          id: "consume",
          exec: "shell",
          label: "Consume",
          description: "reads the field back out of the template",
          run: `url='{{publish.url}}'\n[ -n "$url" ] || { echo NOTHING; exit 1; }\necho "GOT $url"`,
        },
      ],
      edges: [{ from: "publish", to: "consume", when: "ok" }],
    },
  });
  const handed = await settle("field-task");
  check(
    "a schema node's field reaches a downstream shell node",
    handed.status === "succeeded" &&
      /GOT https:\/\/example\.test\/pull\/7/.test(handed.outputs?.consume ?? ""),
    `${handed.status}: ${JSON.stringify(handed.outputs?.consume ?? handed.error ?? "")}`,
  );

  // -------------------------------------------------------------------------
  console.log("\nresuming a task that is already on its way back up\n");

  /**
   * Not a double-click guard. Reviving a container takes as long as docker takes
   * to answer, and the status only read "running" once it was up — so a crashed
   * docker VM held one task in a window where it still looked stopped for an
   * hour and 48 minutes, and the auto-resume, three resumes and a rerun an
   * operator tried in that window each passed their own guard and started
   * another walk of the graph. Five agents ended up sharing one workspace and
   * one claude session, and the node they all began at ran five times.
   */
  await api("/api/spawn", {
    id: "restart-task",
    task: "stopped and resumed",
    workflow: shell("go", "sleep 20; echo GO_OK"),
  });
  await until("restart-task", (t) => t.status === "running");
  await api("/api/task/restart-task/stop", {});
  await until("restart-task", (t) => t.status === "stopped");

  // both in flight before either can answer; which one wins is not the point
  const [first, second] = await Promise.all([
    api("/api/task/restart-task/resume", {}),
    api("/api/task/restart-task/resume", {}),
  ]);
  check(
    "one of two overlapping resumes is refused",
    [first.status, second.status].sort().join() === "200,409",
    `${first.status}/${second.status}: ${first.body.error ?? second.body.error ?? ""}`,
  );
  const stacked = await api("/api/task/restart-task/rerun", { from: "go" });
  check(
    "a rerun arriving while it comes back up asks for force rather than stacking",
    stacked.status === 409 && /force/.test(stacked.body.error ?? ""),
    `${stacked.status} ${stacked.body.error ?? ""}`,
  );

  const restarted = await settle("restart-task");
  const went = (restarted.runs as { node: string; status: string }[])
    .filter((r) => r.node === "go" && r.status !== "cancelled");
  check(
    "the node runs once on the way back, not once per resume",
    restarted.status === "succeeded" && went.length === 1,
    `${restarted.status}, go: ${JSON.stringify(went.map((r) => r.status))}`,
  );

  // -------------------------------------------------------------------------
  console.log("\nwhat a finished node says, and what it leaves behind\n");

  await api("/api/spawn", {
    id: "announce-task",
    task: "announcing and not",
    workflow: {
      name: "announce",
      nodes: [
        {
          id: "loud",
          exec: "shell",
          label: "Loud",
          description: "announces, which is the default",
          run: "echo 'ROUTE: idle'; echo 'new: []'",
        },
        {
          id: "quiet",
          exec: "shell",
          label: "Quiet",
          description: "routes and says nothing about it",
          run: "echo 'ROUTE: idle'; echo 'new: []'",
          announce: false,
        },
        {
          id: "big",
          exec: "shell",
          label: "Big",
          description: "too large to inline, so it spills to refs either way",
          run: "head -c 6000 /dev/zero | tr '\\0' 'x'",
          announce: false,
        },
      ],
      edges: [{ from: "loud", to: "quiet" }, { from: "quiet", to: "big" }],
    },
  });
  const announced = await settle("announce-task");
  const aLog = (await api("/api/task/announce-task/log")).body as {
    kind: string;
    from?: string;
    refs?: string[];
  }[];
  const said = (node: string) => aLog.filter((e) => e.from === node && e.kind === "output");
  check(
    "a node announces its result by default",
    said("loud").length === 1,
    `${said("loud").length} output events from loud`,
  );
  check(
    "announce: false puts nothing on the stream",
    said("quiet").length === 0 && said("big").length === 0,
    `quiet=${said("quiet").length} big=${said("big").length}`,
  );
  check(
    "an announcement that carries the whole output leaves no refs file",
    said("loud")[0]?.refs === undefined,
    JSON.stringify(said("loud")[0]?.refs),
  );
  check(
    "outputs still reach template vars and the record when suppressed",
    /ROUTE: idle/.test(announced.outputs?.quiet ?? "") && announced.status === "succeeded",
    `${announced.status}; quiet output = ${JSON.stringify(announced.outputs?.quiet ?? "")}`,
  );
  const refs = (await api("/api/task/announce-task/paths")).body.refs as string;
  const files: string[] = [];
  try {
    for await (const f of Deno.readDir(refs)) files.push(f.name);
  } catch { /* nothing was written at all, which is a pass */ }
  check(
    "only the output that could not be inlined is on disk",
    files.length === 1 && files[0].startsWith("big-"),
    `refs dir holds [${files.join(", ")}]`,
  );

  // -------------------------------------------------------------------------
  console.log("\ngh without a token\n");

  await api("/api/spawn", {
    id: "gh-lint",
    task: "read it with `gh pr diff` and post a review",
    workflow: shell("ghwf", "gh pr view --json state"),
  });
  const ghLog = (await api("/api/task/gh-lint/log")).body as { kind: string; message: string }[];
  const warned = ghLog.find((e) => e.kind === "workflow" && /gh/.test(e.message));
  check(
    "a task that runs gh with no token is flagged at spawn",
    !!warned && /node "go"/.test(warned.message) && /the task/.test(warned.message),
    warned?.message?.slice(0, 190) ?? "nothing recorded",
  );

  await api("/api/spawn", {
    id: "gh-quiet",
    task: "nothing to do with github",
    gh: true,
    workflow: shell("q", "gh pr view"),
  });
  const quietLog = (await api("/api/task/gh-quiet/log")).body as { message: string }[];
  check(
    "asking for a token silences it",
    !quietLog.some((e) => /gh/.test(e.message) && /token/.test(e.message)),
  );

  // -------------------------------------------------------------------------
  console.log("\nwhat a node's turn is told, first visit versus later ones\n");

  /**
   * `followUp` means "you have been here before", and that used to be decided
   * by whether the *session* had started — so a node joining a thread another
   * node opened was a follow-up on its very first visit, and never got its own
   * brief at all. `polish` and `ship` worked around it by setting `followUp` to
   * the whole brief, which then re-sent that brief on every wake for the life
   * of the pull request, along with the idempotence clause and the full output
   * contract underneath it.
   *
   * The stub over `claude` is what makes this cheap: prompts are recorded
   * before the turn runs, so nothing here needs a model. /opt/npm/bin is ahead
   * of the nix profile on the image's PATH.
   */
  await api("/api/spawn", {
    id: "prompt-task",
    task: "prove what reaches a turn",
    setup: {
      run: [
        "mkdir -p /opt/npm/bin",
        "cat > /opt/npm/bin/claude <<'STUB'",
        "#!/bin/sh",
        `printf '%s' '{"status":"ok","summary":"stub"}'`,
        "STUB",
        "chmod +x /opt/npm/bin/claude",
        "command -v claude",
      ].join("\n"),
      required: true,
    },
    workflow: {
      name: "prompts",
      nodes: [
        {
          id: "first",
          exec: "claude",
          session: "coder",
          label: "First",
          description: "opens the shared thread",
          run: "FIRST_RUN and the task is {{task}}",
          followUp: "FIRST_FOLLOWUP",
        },
        {
          id: "second",
          exec: "claude",
          session: "coder",
          label: "Second",
          description: "joins the thread the first node opened",
          run: "SECOND_RUN",
          followUp: "SECOND_FOLLOWUP",
          effects: "external",
          outcome: {
            kind: "schema",
            label: "status",
            fallback: "ok",
            retries: 0,
            schema: {
              type: "object",
              required: ["status", "summary"],
              properties: { status: { enum: ["ok"] }, summary: { type: "string" } },
            },
          },
        },
        {
          id: "loop",
          exec: "shell",
          label: "Loop",
          description: "sends the pair round exactly once more",
          run: "test -f /tmp/looped && { echo 'ROUTE: stop'; exit 0; }\n" +
            "touch /tmp/looped\necho 'ROUTE: again'",
          outcome: {
            kind: "pattern",
            pattern: "^ROUTE:\\s*(\\w+)",
            map: { again: "again", stop: "stop" },
            fallback: "stop",
          },
        },
      ],
      edges: [
        { from: "first", to: "second" },
        { from: "second", to: "loop", when: "ok" },
        { from: "loop", to: "first", when: "again" },
        { from: "loop", to: "@succeeded", when: "stop" },
      ],
    },
  });
  const prompted = await settle("prompt-task");
  const promptOf = (node: string, visit: number) =>
    (prompted.runs as { node: string; visit: number; prompt?: string }[])
      .find((r) => r.node === node && r.visit === visit)?.prompt ?? "";
  check(
    "the graph walks both nodes twice",
    prompted.status === "succeeded" && !!promptOf("second", 2),
    `${prompted.status}: ${
      (prompted.runs as { node: string; visit: number }[]).map((r) => `${r.node}#${r.visit}`).join(
        " ",
      )
    } ${prompted.error ?? ""}`,
  );
  check(
    "a node opening its thread gets its run template and the graph map",
    /FIRST_RUN/.test(promptOf("first", 1)) && /\[workflow\]/.test(promptOf("first", 1)),
    promptOf("first", 1).slice(0, 120),
  );
  check(
    "a node JOINING a warm thread gets its run template, not its followUp",
    /SECOND_RUN/.test(promptOf("second", 1)) && !/SECOND_FOLLOWUP/.test(promptOf("second", 1)),
    promptOf("second", 1).slice(0, 120),
  );
  check(
    "its first turn carries the idempotence clause and the contract in full",
    /\[idempotence\]/.test(promptOf("second", 1)) &&
      /summary: string/.test(promptOf("second", 1)),
    promptOf("second", 1).replace(/\n/g, " ").slice(0, 200),
  );
  check(
    "a revisit gets the delta and no second copy of the map",
    /FIRST_FOLLOWUP/.test(promptOf("first", 2)) && !/\[workflow\]/.test(promptOf("first", 2)),
    promptOf("first", 2).slice(0, 120),
  );
  check(
    "and none of the standing blocks its thread already holds",
    /SECOND_FOLLOWUP/.test(promptOf("second", 2)) &&
      !/\[idempotence\]/.test(promptOf("second", 2)) &&
      /Unchanged: one JSON object/.test(promptOf("second", 2)) &&
      !/summary: string/.test(promptOf("second", 2)),
    promptOf("second", 2).replace(/\n/g, " ").slice(0, 240),
  );

  // -------------------------------------------------------------------------
  console.log("\nan urgent event against a parked task\n");

  /**
   * The flag promises delivery now. On a task parked on a timer hours out, with
   * an event whose kind matches nothing the node declared, it used to promise
   * that and then do nothing at all — the event was published, the task slept
   * on, and the operator found out when they happened to read the log for an
   * unrelated reason.
   */
  const watcher = (id: string, wait: Record<string, unknown>) =>
    api("/api/spawn", {
      id,
      task: "park and wait to be told something",
      workflow: {
        name: "watcher",
        nodes: [
          {
            id: "park",
            exec: "wait",
            label: "Park",
            description: "waits for news that matters",
            wait,
          },
          {
            id: "act",
            exec: "shell",
            label: "Act",
            description: "proves the task woke",
            run: "echo WOKE",
          },
        ],
        edges: [
          { from: "park", to: "act", when: "activity" },
          { from: "park", to: "act", when: "due" },
        ],
      },
    });

  await watcher("urgent-task", {
    on: [{ kind: "review", label: "activity" }],
    after: { min: "2h", label: "due" },
  });
  await until("urgent-task", (t) => t.status === "waiting");
  const ignored = await api("/api/task/urgent-task/emit", {
    message: "kind nothing here declared",
    kind: "external",
  });
  check(
    "an ordinary event of an undeclared kind leaves it parked",
    ignored.body.status === "waiting",
    String(ignored.body.status),
  );
  await api("/api/task/urgent-task/emit", {
    message: "this one cannot wait",
    kind: "external",
    urgent: true,
  });
  const woke = await settle("urgent-task");
  check(
    "the same event marked urgent wakes it instead of waiting out the timer",
    woke.status === "succeeded" && /WOKE/.test(woke.outputs?.act ?? ""),
    `${woke.status}: ${JSON.stringify(woke.outputs?.act ?? woke.wait ?? "")}`,
  );

  await watcher("urgent-gate", { ask: "may I?" });
  await until("urgent-gate", (t) => t.status === "waiting");
  const atGate = await api("/api/task/urgent-gate/emit", {
    message: "let me through",
    kind: "external",
    urgent: true,
  });
  check(
    "urgency does not answer a question only the operator can answer",
    atGate.body.status === "waiting" && atGate.body.wait?.reason === "human",
    `${atGate.body.status} / ${atGate.body.wait?.reason}`,
  );
  const gateLog = (await api("/api/task/urgent-gate/log")).body as { message: string }[];
  check(
    "and it says so on the stream rather than filing the flag away",
    gateLog.some((e) => /urgent event .* could not be delivered now/.test(e.message)),
    gateLog.map((e) => e.message).join(" | ").slice(-160),
  );

  // -------------------------------------------------------------------------
  console.log("\nrerunning past a node that has external effects\n");

  /**
   * The guard asks whether anything is out there to be duplicated, which is not
   * the same question as whether an external node is reachable. Refusing on
   * reachability alone put the same alarming message and the same --force in
   * front of a `ship` node that had never run, which teaches reflexive forcing.
   */
  await api("/api/spawn", {
    id: "effects-task",
    task: "one node before the one that touches the world",
    workflow: {
      name: "effects",
      nodes: [
        { id: "local", exec: "shell", label: "Local", description: "stays home", run: "echo A" },
        {
          id: "park",
          exec: "wait",
          label: "Park",
          description: "holds the task before it ships, so the rerun lands with ship unrun",
          wait: { ask: "ship it?" },
        },
        {
          id: "ship",
          exec: "shell",
          label: "Ship",
          description: "the one that touches the world",
          run: "echo SHIPPED",
          effects: "external",
        },
      ],
      edges: [{ from: "local", to: "park" }, { from: "park", to: "ship", when: "approve" }],
    },
  });
  await until("effects-task", (t) => t.status === "waiting");
  const beforeShip = await api("/api/task/effects-task/rerun", { from: "local" });
  check(
    "a rerun past an external node that has never run is allowed",
    beforeShip.status === 200,
    `${beforeShip.status} ${beforeShip.body.error ?? ""}`,
  );

  await until("effects-task", (t) => t.status === "waiting");
  await api("/api/task/effects-task/approve", { label: "approve" });
  await settle("effects-task");
  const afterShip = await api("/api/task/effects-task/rerun", { from: "local" });
  check(
    "once it has run, the same rerun asks for force",
    afterShip.status === 409 && /have already run/.test(afterShip.body.error ?? ""),
    `${afterShip.status} ${afterShip.body.error ?? ""}`,
  );

  // -------------------------------------------------------------------------
  console.log("\na prewarm that failed, long after it scrolled away\n");

  await api("/api/spawn", {
    id: "setup-task",
    task: "carry on with a broken prewarm",
    setup: "echo 'no toolchain for you' >&2; exit 3",
    workflow: shell("go", "echo RAN_ANYWAY"),
  });
  const prewarmed = await settle("setup-task");
  check(
    "a non-required setup failure does not stop the task",
    prewarmed.status === "succeeded",
    `${prewarmed.status}: ${prewarmed.error ?? ""}`,
  );
  check(
    "but it stays on the record, where af show reads it",
    prewarmed.setupExit === 3,
    `setupExit = ${JSON.stringify(prewarmed.setupExit)}`,
  );
  const setupLog = (await api("/api/task/setup-task/log")).body as {
    kind: string;
    to?: string | string[];
    message: string;
  }[];
  check(
    "and the agents are told, since they are the ones who meet it",
    setupLog.some((e) => e.kind === "setup" && e.to === "*" && /exited 3/.test(e.message)),
    setupLog.filter((e) => e.kind === "setup").map((e) => e.message).join(" | ").slice(0, 160),
  );

  // -------------------------------------------------------------------------
  console.log("\namending the task text itself\n");

  /**
   * Withdrawing a requirement is what an interjection cannot do: judges are
   * cold-session and re-read {{task}} every visit, so the old text outlives any
   * note about it. This proves the replacement reaches {{task}} on a node that
   * had not run yet, and that every agent node is told the old text is void.
   */
  await api("/api/spawn", {
    id: "amend-task",
    task: "ORIGINAL: also add section six",
    workflow: {
      name: "amendable",
      nodes: [
        {
          id: "park",
          exec: "wait",
          label: "Park",
          description: "holds the task while the operator rewrites what it is for",
          wait: { ask: "carry on?" },
        },
        {
          id: "read",
          exec: "shell",
          label: "Read",
          description: "renders the task text it is actually working from",
          run: "echo 'TASK IS: {{task}}'",
        },
      ],
      edges: [{ from: "park", to: "read", when: "approve" }],
    },
  });
  await until("amend-task", (t) => t.status === "waiting");
  const unchanged = await api("/api/task/amend-task/task", {
    task: "ORIGINAL: also add section six",
  });
  check(
    "replacing the text with itself is refused",
    unchanged.status === 400,
    `${unchanged.status} ${unchanged.body.error ?? ""}`,
  );
  const amended = await api("/api/task/amend-task/task", {
    task: "REVISED: section six is withdrawn",
  });
  check(
    "the replacement lands on the request",
    amended.status === 200 && amended.body.request?.task === "REVISED: section six is withdrawn",
    `${amended.status} ${JSON.stringify(amended.body.request?.task ?? amended.body.error)}`,
  );
  const amendLog = (await api("/api/task/amend-task/log")).body as {
    kind: string;
    to?: string | string[];
    key?: string;
    message: string;
  }[];
  check(
    "and is published to every agent node, for the threads that re-read nothing",
    amendLog.some((e) =>
      e.kind === "operator" && e.to === "*" && e.key === "task" &&
      /NO LONGER CURRENT/.test(e.message) && /section six is withdrawn/.test(e.message)
    ),
    amendLog.filter((e) => e.kind === "operator").map((e) => e.message.slice(0, 60)).join(" | "),
  );
  await api("/api/task/amend-task/approve", { label: "approve" });
  const read = await settle("amend-task");
  check(
    "a node that had not run yet renders the new text, not the old",
    /TASK IS: REVISED/.test(read.outputs?.read ?? ""),
    JSON.stringify(read.outputs?.read ?? read.error ?? ""),
  );

  // -------------------------------------------------------------------------
  console.log("\nthe revision a workspace is cut from\n");

  /**
   * The base is the repo's working-copy parents, which is invisible until
   * something built on it fails — usually at the first gate, half an hour in.
   * Skipped where there is no jj to ask.
   */
  const repo = await Deno.makeTempDir({ prefix: "agentflow-repo-" });
  // signing off: the host's own jj config may sign through an agent that has no
  // session in a test run, and a throwaway repo has nothing worth signing
  const jjArgs = (args: string[]) => ["--config", 'signing.behavior="drop"', ...args];
  const jj = async (...args: string[]) =>
    await new Deno.Command("jj", { args: jjArgs(["--repository", repo, ...args]), stderr: "null" })
      .output().then((r) => r.success, () => false);
  const haveJj = await new Deno.Command("jj", {
    args: jjArgs(["git", "init", repo]),
    stdout: "null",
    stderr: "null",
  }).output().then((r) => r.success, () => false);
  if (!haveJj) {
    console.log("  skip  no usable jj on this host");
  } else {
    await Deno.writeTextFile(`${repo}/README.md`, "hi\n");
    await jj("describe", "-m", "the base commit");
    await jj("bookmark", "create", "trunk", "-r", "@");
    await jj("new");
    const based = await api("/api/spawn", {
      id: "base-task",
      task: "report where this came from",
      repo,
      workflow: shell("go", "true"),
    });
    check(
      "spawn resolves the base revision the workspace will be cut from",
      /the base commit/.test(based.body.record?.base ?? ""),
      JSON.stringify(based.body.record?.base ?? based.body.error ?? ""),
    );
    check(
      "and names the bookmark on it, which is what an operator recognises",
      /trunk/.test(based.body.record?.base ?? ""),
      JSON.stringify(based.body.record?.base ?? ""),
    );
    const baseLog = (await api("/api/task/base-task/log")).body as { message: string }[];
    check(
      "it is on the event stream from second zero",
      baseLog.some((e) => /^base .*the base commit/.test(e.message)),
      baseLog.map((e) => e.message).join(" | ").slice(0, 160),
    );
    await api("/api/task/base-task/stop", {});
  }
  await Deno.remove(repo, { recursive: true }).catch(() => {});

  // -------------------------------------------------------------------------
  console.log("\ntelling a wedged turn from a slow one\n");

  /**
   * The watchdog kills a node that has gone quiet, but only after asking
   * whether it is actually stuck — a long silent build is the case it exists
   * to spare. That question is answered by reading the node's pidfile, and the
   * pidfile became per-visit while the watchdog kept asking for the per-node
   * name, so for a while the answer was "the process is gone" every time and
   * the check that protects slow nodes was the one killing them.
   *
   * Both halves are asserted because either alone passes for the wrong reason:
   * a watchdog that never fires spares the busy node too.
   *
   * `$SECONDS` and `:` are builtins — the busy loop burns cpu in the node's own
   * process and forks nothing, which is what the probe measures. `sleep` is the
   * opposite: a real child, and no cpu anywhere in the tree.
   *
   * Both start by printing, because the clock the watchdog reads is set by
   * output and a node that has produced nothing at all has no silence to
   * measure — it is never examined, and neither case would fire.
   */
  const IDLE_MIN = 1;
  const quiet = (run: string) => ({
    task: "stay quiet",
    workflow: shell("quiet", `echo started; ${run}`),
    idleMin: IDLE_MIN,
  });

  await api("/api/spawn", { id: "wedge-busy", ...quiet("while [ $SECONDS -lt 200 ]; do :; done") });
  await api("/api/spawn", { id: "wedge-idle", ...quiet("sleep 200") });

  // the threshold, plus a sweep interval and change for the probe's two samples
  const wedged = (t: Record<string, unknown>) =>
    ((t.runs ?? []) as { node: string; visit: number }[]).some((r) => r.visit > 1);
  await until("wedge-idle", wedged, 240);

  const idle = (await api("/api/task/wedge-idle")).body;
  const busy = (await api("/api/task/wedge-busy")).body;
  check(
    "a node burning no cpu is treated as wedged and run again",
    wedged(idle),
    JSON.stringify((idle.runs ?? []).map((r: { visit: number }) => r.visit)),
  );
  const idleLog = (await api("/api/task/wedge-idle/log")).body as { message: string }[];
  check(
    "and the operator is told which turn it was and how it was judged",
    idleLog.some((e) => /go#1.*burning no cpu/.test(e.message)),
    idleLog.map((e) => e.message).join(" | ").slice(0, 200),
  );
  check(
    "a node that is silent but burning cpu is left alone",
    !wedged(busy) && busy.status === "running",
    `${busy.status} ${JSON.stringify((busy.runs ?? []).map((r: { visit: number }) => r.visit))}`,
  );

  await api("/api/task/wedge-busy/stop", {});
  await api("/api/task/wedge-idle/stop", {});

  // -------------------------------------------------------------------------
  console.log("\nwhat a stop leaves running\n");

  /**
   * The most expensive way this can be wrong quietly: stop returns, the board
   * reads "stopped", and a turn nobody is watching goes on spending the
   * operator's model quota. It did — 255M tokens over the 2h47m it took a
   * cancelled reviewer to exhaust a weekly limit.
   *
   * Two survivors, asserted apart, because neither fix catches the other. The
   * turn is killed through the pid recorded for it, and the visit's own
   * cleanup deletes that file on the way out, so the kill only lands if it read
   * the pid first — the bug was that it did not. What the turn leaves behind is
   * not in that tree at all: `(sleep &)` reparents to pid 1 as soon as the
   * subshell exits, and no pidfile has ever pointed at it, so only a sweep of
   * the whole container finds it.
   *
   * Both are checked alive before the stop. A test that skipped that would pass
   * just as well against a node that never started.
   */
  const lingering = async (needle: string) => {
    const r = await new Deno.Command("docker", {
      args: [
        "exec",
        "af-stop-orphans",
        "sh",
        "-c",
        // This script carries the needle in its own cmdline, and every `$(...)`
        // forks another copy of it — matching on its own marker excludes the
        // counting shell and its forks alike, where matching on $$ misses them.
        `n=0; for d in /proc/[0-9]*; do ` +
        `c=$(tr '\\0' ' ' < "$d/cmdline" 2>/dev/null); ` +
        `case "$c" in *AFPROBE*) continue;; esac; ` +
        `case "$c" in *"${needle}"*) n=$((n+1));; esac; done; echo $n # AFPROBE`,
      ],
      stdout: "piped",
      stderr: "null",
    }).output().catch(() => null);
    return r ? Number(new TextDecoder().decode(r.stdout).trim() || "-1") : -1;
  };

  await api("/api/spawn", {
    id: "stop-orphans",
    task: "leave things running",
    workflow: shell("linger", "echo started\n(sleep 3131 &)\nsleep 3130"),
  });
  await until(
    "stop-orphans",
    (t) => t.status === "running" && (t as unknown as { runs?: unknown[] }).runs?.length === 1,
    60,
  );
  // the turn prints before it sleeps, so output is what says the shell got there
  for (let i = 0; i < 40 && await lingering("sleep 3130") < 1; i++) {
    await new Promise((r) => setTimeout(r, 500));
  }
  const turnBefore = await lingering("sleep 3130");
  const orphanBefore = await lingering("sleep 3131");
  check(
    "the turn and what it left running are both up before the stop",
    turnBefore === 1 && orphanBefore === 1,
    `turn ${turnBefore}, orphan ${orphanBefore}`,
  );

  await api("/api/task/stop-orphans/stop", {});
  const turnAfter = await lingering("sleep 3130");
  const orphanAfter = await lingering("sleep 3131");
  check(
    "stop kills the turn inside the container, not just the local client",
    turnAfter === 0,
    `${turnAfter} still running`,
  );
  check(
    "and sweeps what the turn left behind, which no pidfile names",
    orphanAfter === 0,
    `${orphanAfter} still running`,
  );
  check(
    "the container itself is left up, as a stop promises",
    await lingering("sleep infinity") === 1,
    "pid 1 went with them",
  );
} finally {
  await teardown();
}

console.log(`\n${failures ? `${failures} FAILED` : "all passed"}`);
Deno.exit(failures ? 1 : 0);
