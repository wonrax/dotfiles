import { Data, Effect, Schedule } from "effect";
import type { EdgeCondition, LlmStats, NodeRun, TaskRecord, WorkflowNode } from "./model.ts";

export class ExecError extends Data.TaggedError("ExecError")<{
  cmd: string[];
  message: string;
}> {}

export class WorkflowError extends Data.TaggedError("WorkflowError")<{
  message: string;
}> {}

const OUTPUT_CAP = 64 * 1024;

interface ExecResult {
  code: number;
  output: string;
}

/** Spawn a host command, stream combined stdout+stderr, keep a capped tail. */
function spawnCapture(
  cmd: string[],
  onChunk: ((s: string) => void) | undefined,
  signal: AbortSignal,
  extraSignal?: AbortSignal,
): Promise<ExecResult> {
  if (extraSignal) signal = AbortSignal.any([signal, extraSignal]);
  const child = new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    stdout: "piped",
    stderr: "piped",
    stdin: "null",
  }).spawn();

  const onAbort = () => {
    try {
      child.kill("SIGKILL");
    } catch {
      // already exited
    }
  };
  signal.addEventListener("abort", onAbort, { once: true });

  let output = "";
  const decoder = new TextDecoder();
  const pump = async (stream: ReadableStream<Uint8Array>) => {
    for await (const chunk of stream) {
      const text = decoder.decode(chunk);
      output = (output + text).slice(-OUTPUT_CAP);
      onChunk?.(text);
    }
  };

  return Promise.all([pump(child.stdout), pump(child.stderr), child.status])
    .then(([, , status]) => ({ code: status.code, output }))
    .finally(() => signal.removeEventListener("abort", onAbort));
}

export const exec = (
  cmd: string[],
  onChunk?: (s: string) => void,
  extraSignal?: AbortSignal,
): Effect.Effect<ExecResult, ExecError> =>
  Effect.tryPromise({
    try: (signal) => spawnCapture(cmd, onChunk, signal, extraSignal),
    catch: (e) => new ExecError({ cmd, message: e instanceof Error ? e.message : String(e) }),
  });

/** exec that fails the effect on nonzero exit — for setup steps, not workflow nodes */
const execOk = (cmd: string[]): Effect.Effect<ExecResult, ExecError> =>
  exec(cmd).pipe(
    Effect.filterOrFail(
      (r) => r.code === 0,
      (r) => new ExecError({ cmd, message: `exit ${r.code}: ${r.output.slice(-2000)}` }),
    ),
  );

const dockerExec = (
  container: string,
  cwd: string,
  cmd: string[],
  onChunk?: (s: string) => void,
  extraSignal?: AbortSignal,
) => exec(["docker", "exec", "-w", cwd, container, ...cmd], onChunk, extraSignal);

// ---------------------------------------------------------------------------
// Task container lifecycle

export const stateDir = () =>
  `${Deno.env.get("HOME")}/.local/state/agentflow`;

const credentialToken = Effect.gen(function* () {
  const envToken = Deno.env.get("CLAUDE_CODE_OAUTH_TOKEN");
  if (envToken) return envToken;
  const path = `${Deno.env.get("HOME")}/.config/agentflow/token`;
  const fromFile = yield* Effect.tryPromise({
    try: () => Deno.readTextFile(path),
    catch: () =>
      new WorkflowError({
        message:
          `no claude credential: set CLAUDE_CODE_OAUTH_TOKEN on the daemon or write the token to ${path}`,
      }),
  });
  return fromFile.trim();
});

/** Create workspace dir + container (+ jj workspace when repo-backed). Mutates `task` in place
 * so partially-created resources are still recorded for teardown on failure. */
export const setupTask = (task: TaskRecord) =>
  Effect.gen(function* () {
    const ws = `${stateDir()}/ws/${task.id}`;
    yield* Effect.promise(() => Deno.mkdir(ws, { recursive: true }));

    const needsClaude = task.workflow.nodes.some((n) => n.type === "agent" || n.type === "review");
    const env: Record<string, string> = { ...task.request.env };
    if (needsClaude) {
      env.CLAUDE_CODE_OAUTH_TOKEN = yield* credentialToken;
      // claude refuses --dangerously-skip-permissions as root unless it knows
      // it's inside a dedicated sandbox, which these containers are
      env.IS_SANDBOX = "1";
      if (task.request.model) env.ANTHROPIC_MODEL = task.request.model;
      if (task.request.effort) env.CLAUDE_CODE_EFFORT_LEVEL = task.request.effort;
    }
    if (task.request.gh) {
      const gh = yield* execOk(["gh", "auth", "token"]);
      env.GH_TOKEN = gh.output.trim();
    }

    const name = `af-${task.id}`;
    const args = ["docker", "run", "-d", "--name", name, "--label", "agentflow=1"];
    for (const [k, v] of Object.entries(env)) args.push("-e", `${k}=${v}`);
    if (needsClaude && task.request.hostAgentConfig !== false) {
      // agents inherit the host's global instructions/skills; ro so a
      // prompt-injected agent can't rewrite them
      const home = Deno.env.get("HOME");
      for (const entry of ["CLAUDE.md", "skills", "agents"]) {
        const src = `${home}/.claude/${entry}`;
        const exists = yield* Effect.promise(() => Deno.stat(src).then(() => true, () => false));
        if (exists) args.push("-v", `${src}:/root/.claude/${entry}:ro`);
      }
    }
    args.push("-v", `${ws}:/ws/${task.id}`);
    if (task.request.repo) args.push("-v", `${task.request.repo}:/repo`);
    if (task.request.docker === "socket") {
      args.push("-v", "/var/run/docker.sock:/var/run/docker.sock");
    } else if (task.request.docker === "dind") {
      // anonymous volume: the inner dockerd's overlayfs cannot nest on the
      // container's own overlay filesystem
      args.push("--privileged", "-v", "/var/lib/docker");
    }
    args.push("agentflow:latest", "sleep", "infinity");
    yield* execOk(args);
    task.container = name;

    if (task.request.docker === "dind") {
      // private daemon inside the privileged container; wait until it answers
      yield* execOk(["docker", "exec", "-d", name, "dockerd"]);
      yield* exec(["docker", "exec", name, "docker", "info"]).pipe(
        Effect.filterOrFail(
          (r) => r.code === 0,
          () => new ExecError({ cmd: ["docker", "info"], message: "dockerd not ready" }),
        ),
        Effect.retry(Schedule.intersect(Schedule.recurs(20), Schedule.spaced("1 second"))),
        Effect.catchAll(() =>
          new WorkflowError({ message: "dockerd failed to start inside the dind container" })
        ),
      );
    }

    if (task.request.repo) {
      const wsName = `af-${task.id}`;
      yield* execOk([
        "docker", "exec", name,
        "jj", "-R", "/repo", "workspace", "add", "--name", wsName, `/ws/${task.id}/wc`,
      ]);
      task.workspace = wsName;
      task.cwd = `/ws/${task.id}/wc`;
    } else {
      task.cwd = `/ws/${task.id}`;
    }
  });

/** Best-effort container removal; clears task.container (disables revive). */
export const teardownContainer = (task: TaskRecord) =>
  Effect.gen(function* () {
    if (!task.container) return;
    // -v also removes anonymous volumes (the dind /var/lib/docker one)
    yield* exec(["docker", "rm", "-f", "-v", task.container]).pipe(Effect.ignore);
    task.container = undefined;
  });

/** Best-effort jj workspace forget (host jj) + workspace dir removal. */
export const teardownWorkspace = (task: TaskRecord) =>
  Effect.gen(function* () {
    if (task.workspace && task.request.repo) {
      yield* exec(["jj", "-R", task.request.repo, "workspace", "forget", task.workspace]).pipe(
        Effect.ignore,
      );
      task.workspace = undefined;
    }
    yield* Effect.promise(() =>
      Deno.remove(`${stateDir()}/ws/${task.id}`, { recursive: true }).catch(() => {})
    );
    task.cwd = undefined;
  });

/** Full teardown; never fails. */
export const teardownTask = (task: TaskRecord) =>
  Effect.gen(function* () {
    yield* teardownContainer(task);
    yield* teardownWorkspace(task);
  });

// ---------------------------------------------------------------------------
// Workflow graph runner

export interface EngineCallbacks {
  emitNode: (run: NodeRun) => void;
  emitLog: (node: string, chunk: string) => void;
  /** drain queued operator feedback (called at every node boundary) */
  takeFeedback: () => string[];
  /** expose the current node's abort controller for interject({interrupt}) */
  onNodeStart: (abort: AbortController) => void;
}

const template = (text: string, vars: Record<string, string>) =>
  text.replaceAll(/\{\{(\w+)\}\}/g, (_, key: string) => vars[key] ?? "");

/** which template a node will render this visit (resumed agents get followUp) */
const templateFor = (node: WorkflowNode, sessionExists: boolean): string =>
  node.type === "agent" && node.resume !== false && sessionExists
    ? node.followUp ?? node.run
    : node.run;

const buildCommand = (
  node: WorkflowNode,
  sessionExists: boolean,
  coderSession: string,
  rendered: string,
): string[] => {
  switch (node.type) {
    case "shell":
      return ["sh", "-c", rendered];
    case "agent": {
      const args = [
        "claude", "-p", "--dangerously-skip-permissions",
        "--output-format", "stream-json", "--verbose",
      ];
      if (node.resume === false) return [...args, rendered];
      // resumed turns append only the delta; the session already has the task
      return sessionExists
        ? [...args, "--resume", coderSession, rendered]
        : [...args, "--session-id", coderSession, rendered];
    }
    case "review":
      // fresh session every visit so the reviewer judges the diff cold
      return [
        "claude", "-p", "--dangerously-skip-permissions",
        "--output-format", "stream-json", "--verbose", rendered,
      ];
  }
};

/**
 * Agent nodes emit stream-json (one event per line). The node's public output
 * is the final `result` event's text; the raw stream is kept on disk for the
 * dashboard's full-transcript mode.
 */
const extractLlm = (raw: string): LlmStats | undefined => {
  // deno-lint-ignore no-explicit-any
  let model: string | undefined, result: any, lastUsage: any;
  for (const line of raw.split("\n")) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.type === "system" && ev.subtype === "init") model = ev.model;
      else if (ev.type === "assistant" && ev.message?.usage) {
        lastUsage = ev.message.usage;
        model ??= ev.message.model;
      } else if (ev.type === "result") result = ev;
    } catch {
      // truncated line at the start of the capped tail
    }
  }
  if (!model && !result) return undefined;
  const u = result?.usage ?? {};
  const ctx = lastUsage
    ? (lastUsage.input_tokens ?? 0) + (lastUsage.cache_read_input_tokens ?? 0) +
      (lastUsage.cache_creation_input_tokens ?? 0) + (lastUsage.output_tokens ?? 0)
    : undefined;
  return {
    model,
    inputTokens: u.input_tokens,
    outputTokens: u.output_tokens,
    cacheRead: u.cache_read_input_tokens,
    cacheWrite: u.cache_creation_input_tokens,
    costUsd: result?.total_cost_usd,
    turns: result?.num_turns,
    apiMs: result?.duration_api_ms,
    contextTokens: ctx,
    contextPct: ctx ? Math.round((ctx / 200_000) * 100) : undefined,
  };
};

const summarize = (node: WorkflowNode, raw: string): string => {
  if (node.type === "shell") return raw;
  for (const line of raw.split("\n").reverse()) {
    if (!line.startsWith('{"type":"result"')) continue;
    try {
      const ev = JSON.parse(line);
      return ev.result ?? ev.error ?? raw;
    } catch {
      break;
    }
  }
  return raw;
};

/**
 * The review contract requires the verdict as the final line — matching
 * anywhere in the text is defeated by replies that merely quote the options.
 */
const verdictOf = (text: string): "APPROVE" | "REQUEST_CHANGES" | undefined => {
  const last = text.trim().split("\n").map((l) => l.trim()).filter(Boolean).at(-1) ?? "";
  const m = last.match(/^VERDICT:\s*(APPROVE|REQUEST_CHANGES)\b/i);
  return m?.[1].toUpperCase() as "APPROVE" | "REQUEST_CHANGES" | undefined;
};

const classify = (node: WorkflowNode, res: ExecResult): EdgeCondition => {
  if (res.code !== 0) return "fail";
  if (node.type !== "review") return "ok";
  const verdict = verdictOf(res.output);
  if (verdict === "APPROVE") return "approve";
  if (verdict === "REQUEST_CHANGES") return "request_changes";
  return "fail";
};

/** session id of a stream-json run, so corrective retries can resume it */
const extractSessionId = (raw: string): string | undefined => {
  for (const line of raw.split("\n")) {
    if (!line.startsWith('{"type":"system"')) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.subtype === "init" && ev.session_id) return ev.session_id;
    } catch {
      // truncated line
    }
  }
  return undefined;
};

const CONTRACT_RETRIES = 2;


// Outputs beyond this size are not injected into prompts verbatim — that
// bloats the context and the bill. They spill to a file in the task mount
// and the template var carries excerpts plus a pointer.
const INJECT_LIMIT = 4000;

const spillLargeOutput = (
  task: TaskRecord,
  nodeId: string,
  visit: number,
  text: string,
): Effect.Effect<string, never> =>
  Effect.gen(function* () {
    if (text.length <= INJECT_LIMIT) return text;
    const hostDir = `${stateDir()}/ws/${task.id}/out`;
    const file = `${nodeId}-${visit}.log`;
    const containerPath = `/ws/${task.id}/out/${file}`;
    const written = yield* Effect.promise(() =>
      Deno.mkdir(hostDir, { recursive: true })
        .then(() => Deno.writeTextFile(`${hostDir}/${file}`, text))
        .then(() => true, () => false)
    );
    if (!written) return text.slice(0, INJECT_LIMIT);
    return `${text.slice(0, 1500)}
[… output truncated: ${text.length} chars total. Full output saved to ${containerPath} — inspect it with rg/sed/tail as needed …]
${text.slice(-1500)}`;
  });

export const runWorkflow = (
  task: TaskRecord,
  cb: EngineCallbacks,
): Effect.Effect<"succeeded" | "failed", ExecError | WorkflowError> =>
  Effect.gen(function* () {
    const wf = task.workflow;
    const container = task.container!;
    const cwd = task.cwd!;
    const visits = new Map<string, number>();
    // continue visit numbering across revives so history is never overwritten
    for (const r of task.runs) {
      visits.set(r.node, Math.max(visits.get(r.node) ?? 0, r.visit));
    }
    // maxVisits budgets this run only; a revive gets a fresh allowance
    const runCounts = new Map<string, number>();
    const outputs: Record<string, string> = {};
    let sessionExists = task.session != null;
    const coderSession = task.session ?? (task.session = crypto.randomUUID());
    let currentId: string | undefined = wf.start ?? wf.nodes[0]?.id;
    let feedback = "";
    // every piece of operator feedback permanently amends the task, so
    // reviewers judge against it instead of flagging it as scope creep
    const amendments: string[] = [];

    // resume from the persisted graph position after a daemon stop/revive
    if (task.checkpoint) {
      currentId = task.checkpoint.node;
      Object.assign(outputs, task.checkpoint.outputs);
      amendments.push(...task.checkpoint.amendments);
      feedback = task.checkpoint.feedback;
    }

    while (currentId) {
      const node = wf.nodes.find((n) => n.id === currentId);
      if (!node) return yield* new WorkflowError({ message: `unknown node "${currentId}"` });

      const visit = (visits.get(node.id) ?? 0) + 1;
      visits.set(node.id, visit);
      const runCount = (runCounts.get(node.id) ?? 0) + 1;
      runCounts.set(node.id, runCount);
      if (runCount > (node.maxVisits ?? 10)) {
        return yield* new WorkflowError({
          message: `node "${node.id}" exceeded maxVisits (${node.maxVisits ?? 10})`,
        });
      }

      const drained = cb.takeFeedback();
      if (drained.length) {
        feedback = drained.join("\n\n");
        amendments.push(...drained);
      }

      // checkpoint before executing: a stop mid-node resumes at this node
      task.checkpoint = {
        node: node.id,
        outputs: { ...outputs },
        amendments: [...amendments],
        feedback,
      };

      const run: NodeRun = {
        node: node.id,
        visit,
        status: "running",
        startedAt: new Date().toISOString(),
        output: "",
      };

      const vars = {
        task: task.request.task,
        gates: task.request.gates ?? "",
        feedback,
        amendments: amendments.join("\n\n"),
        notes: `/ws/${task.id}/notes.md`,
        ...outputs,
      };
      const nodeAbort = new AbortController();
      cb.onNodeStart(nodeAbort);
      const tpl = templateFor(node, sessionExists);
      const rendered = template(tpl, vars);
      run.prompt = rendered.slice(0, 16 * 1024);
      cb.emitNode({ ...run });
      const cmd = buildCommand(node, sessionExists, coderSession, rendered);
      if (node.type === "agent" && node.resume !== false) sessionExists = true;

      // full transcript on disk for the dashboard's "everything" mode
      const logDir = `${stateDir()}/logs/${task.id}`;
      yield* Effect.promise(() => Deno.mkdir(logDir, { recursive: true }));
      const logFile = yield* Effect.promise(() =>
        Deno.open(`${logDir}/${node.id}-${visit}.log`, { create: true, write: true, truncate: true })
      );
      const logEnc = new TextEncoder();
      const onChunk = (chunk: string) => {
        cb.emitLog(node.id, chunk);
        try {
          logFile.writeSync(logEnc.encode(chunk));
        } catch {
          // transcript file is best-effort
        }
      };
      // no timeout unless one was asked for — tasks may legitimately run for
      // days; interject/stop are the operator's levers for stuck runs
      const timeoutMin = node.timeoutMin ?? task.request.nodeTimeoutMin;
      const runOnce = (args: string[]) => {
        const exec_ = dockerExec(container, cwd, args, onChunk, nodeAbort.signal);
        return timeoutMin
          ? exec_.pipe(
            Effect.timeoutFail({
              duration: `${timeoutMin} minutes`,
              onTimeout: () =>
                new WorkflowError({ message: `node "${node.id}" timed out after ${timeoutMin}m` }),
            }),
          )
          : exec_;
      };

      // Output-contract validation: a review reply without a verdict line is
      // malformed, not a failure — ask the same session to correct itself
      // (bounded), and only classify as fail if it stays malformed.
      const nodeExec = Effect.gen(function* () {
        let r = yield* runOnce(cmd);
        for (
          let attempt = 1;
          node.type === "review" && attempt <= CONTRACT_RETRIES &&
          !nodeAbort.signal.aborted && r.code === 0 && !verdictOf(summarize(node, r.output));
          attempt++
        ) {
          onChunk(
            `\n[agentflow] reviewer reply missing VERDICT line; requesting correction (${attempt}/${CONTRACT_RETRIES})\n`,
          );
          const sid = extractSessionId(r.output);
          const corrective =
            'Your previous reply did not end with the required verdict line. Based on your review, reply with exactly one line and nothing else: "VERDICT: APPROVE" or "VERDICT: REQUEST_CHANGES".';
          const base = [
            "claude", "-p", "--dangerously-skip-permissions",
            "--output-format", "stream-json", "--verbose",
          ];
          const retry = yield* runOnce(
            sid ? [...base, "--resume", sid, corrective] : [...base, rendered + "\n\n" + corrective],
          );
          r = { code: retry.code, output: (r.output + "\n" + retry.output).slice(-64 * 1024) };
        }
        return r;
      });

      const res = yield* nodeExec.pipe(
        Effect.ensuring(Effect.sync(() => {
          try {
            logFile.close();
          } catch {
            // already closed
          }
        })),
      );

      const summary = summarize(node, res.output);

      // operator interrupted this node: re-run it with the queued feedback
      if (nodeAbort.signal.aborted) {
        cb.emitNode({
          ...run,
          status: "fail",
          finishedAt: new Date().toISOString(),
          exitCode: res.code,
          output: summary + "\n[interrupted by operator]",
        });
        continue;
      }

      // feedback is consumed only when a template actually rendered it, so an
      // interject arriving before the first agent turn isn't silently dropped
      if (node.type === "agent" && feedback && tpl.includes("{{feedback}}")) feedback = "";

      outputs[node.id] = yield* spillLargeOutput(task, node.id, visit, summary);
      const outcome = classify(node, { ...res, output: summary });
      cb.emitNode({
        ...run,
        status: outcome,
        finishedAt: new Date().toISOString(),
        exitCode: res.code,
        output: summary,
        llm: node.type === "shell" ? undefined : extractLlm(res.output),
      });

      // force a working-copy snapshot so the host sees the agent's files immediately
      if (task.request.repo) {
        yield* dockerExec(container, cwd, ["jj", "st"]).pipe(Effect.ignore);
      }

      const edge = wf.edges.find((e) => e.from === node.id && (e.when ?? "ok") === outcome);
      if (!edge) {
        task.checkpoint = undefined;
        return outcome === "ok" || outcome === "approve" ? "succeeded" : "failed";
      }
      currentId = edge.to;
    }
    task.checkpoint = undefined;
    return "failed";
  });
