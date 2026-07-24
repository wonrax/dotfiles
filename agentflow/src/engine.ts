import { Data, Effect, Schedule } from "effect";
import type {
  LlmStats,
  NodeRun,
  OutcomeContract,
  TaskEventRecord,
  TaskRecord,
  WorkflowNode,
} from "./model.ts";
import type { AgentDefaults, SessionState, WaitState } from "./model.ts";
import { isAgentExec } from "./model.ts";
import {
  backoffMs,
  describeWorkflow,
  formatDuration,
  normalizeNode,
  resolveAgent,
} from "./workflows.ts";
import { extractJson, renderData, resolvePath, toTypeScript, validate } from "./schema.ts";

export class ExecError extends Data.TaggedError("ExecError")<{
  cmd: string[];
  message: string;
}> {}

export class WorkflowError extends Data.TaggedError("WorkflowError")<{
  message: string;
}> {}

const OUTPUT_CAP = 64 * 1024;
const IMAGE = "agentflow:latest";

/**
 * How much of the START of a stream to keep, beside the capped tail. Both
 * agents announce their thread id in the first line or two and never again, so
 * a tail is exactly the wrong half to look in: measured, a codex review turn
 * streamed 433 KB against a 64 KB cap, `thread.started` was six times the cap
 * from the end, and `extractSessionId` came back undefined on every visit. That
 * failure is silent by construction — the node runs fine, it simply opens a
 * cold thread each time, so a reviewer meant to remember a PR across weeks was
 * re-reading it from nothing on every wake.
 */
const HEAD_CAP = 16 * 1024;

interface ExecResult {
  code: number;
  /** the last OUTPUT_CAP bytes */
  output: string;
  /** the first HEAD_CAP bytes, for what is only ever said up front */
  head: string;
}

/** Spawn a host command, stream combined stdout+stderr, keep a capped head and tail. */
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
  let head = "";
  const decoder = new TextDecoder();
  const pump = async (stream: ReadableStream<Uint8Array>) => {
    for await (const chunk of stream) {
      const text = decoder.decode(chunk);
      if (head.length < HEAD_CAP) head = (head + text).slice(0, HEAD_CAP);
      output = (output + text).slice(-OUTPUT_CAP);
      onChunk?.(text);
    }
  };

  return Promise.all([pump(child.stdout), pump(child.stderr), child.status])
    .then(([, , status]) => ({ code: status.code, output, head }))
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

/**
 * Docker's control plane — inspect, start, stop, version — answers in
 * milliseconds or not at all, so anything slower is a broken host rather than a
 * busy one. Worth bounding because of how it fails: a VM that crashed rather
 * than exited leaves the CLI blocked on its socket with no error and no exit,
 * which is not a slow answer but no answer ever. That is also why the retry
 * ladder in `reviveContainer` never engaged on the one host this happened to —
 * it retries failures, and nothing was failing.
 */
const dockerCtl = (cmd: string[]): Effect.Effect<ExecResult, ExecError> =>
  exec(cmd).pipe(
    Effect.timeoutFail({
      duration: "30 seconds",
      onTimeout: () =>
        new ExecError({ cmd, message: "docker did not answer within 30s (is the VM up?)" }),
    }),
  );

const dockerExec = (
  container: string,
  cwd: string,
  cmd: string[],
  onChunk?: (s: string) => void,
  extraSignal?: AbortSignal,
  env: Record<string, string> = {},
) =>
  exec(
    [
      "docker",
      "exec",
      "-w",
      cwd,
      ...Object.entries(env).flatMap(([k, v]) => ["-e", `${k}=${v}`]),
      container,
      ...cmd,
    ],
    onChunk,
    extraSignal,
  );

// ---------------------------------------------------------------------------
// Task container lifecycle

export const stateDir = () => `${Deno.env.get("HOME")}/.local/state/agentflow`;

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

/** where agentflow keeps its own codex login, seeded by the operator */
const CODEX_AUTH = `${Deno.env.get("HOME")}/.config/agentflow/codex-auth.json`;

/**
 * Codex authenticates from a file, not an environment variable, and it rewrites
 * that file whenever it refreshes the token mid-session. Openai's own guidance
 * is one auth.json per serialized stream — this daemon fans six reviewers onto
 * one graph, so every task gets its own copy and nothing shares a writer.
 *
 * Deliberately not `~/.codex/auth.json`: the copies refresh independently of
 * whatever seeded them, and pointing them at the operator's own login means a
 * rotated refresh token can log the operator out of their own terminal. Seed it
 * with a login that exists for this:
 *
 *   CODEX_HOME=~/.config/agentflow/codex-home codex login
 *   cp ~/.config/agentflow/codex-home/auth.json ~/.config/agentflow/codex-auth.json
 */
const codexAuth = Effect.tryPromise({
  try: () => Deno.readTextFile(CODEX_AUTH),
  catch: () =>
    new WorkflowError({
      message: `no codex credential at ${CODEX_AUTH}. Sign in with a CODEX_HOME of its own ` +
        `and copy the auth.json there:\n` +
        `  CODEX_HOME=~/.config/agentflow/codex-home codex login\n` +
        `  cp ~/.config/agentflow/codex-home/auth.json ${CODEX_AUTH}`,
    }),
});

/**
 * The shared nix store is keyed by image id on purpose. Docker only populates
 * a named volume from the image on first mount, so a volume created by an
 * older image would shadow the new image's /nix and leave the container's own
 * profile symlinks pointing at store paths that no longer exist.
 */
const nixVolume = Effect.gen(function* () {
  const r = yield* exec(["docker", "image", "inspect", IMAGE, "-f", "{{.Id}}"]);
  if (r.code !== 0) return undefined;
  const digest = r.output.trim().replace(/^sha256:/, "").slice(0, 12);
  return digest ? `agentflow-nix-${digest}` : undefined;
});

/**
 * That first-mount copy is neither atomic nor safe against a second container
 * naming the same volume: the second mounts it while the first is still filling
 * it. For /nix that hands a container a PATH into a half-empty store, and it
 * dies before its first command with `exec: "sleep": executable file not found`
 * — the volume name is derived from the image id, so rebuilding the image
 * points the whole fleet at a cold volume at once. Six reviewers fanned out
 * onto one; five died, and the survivor was just the one that got there first.
 *
 * So whoever wants a volume that does not exist yet fills it alone and the rest
 * wait on that. In-process is enough: every container agentflow starts is
 * created here, and docker itself is safe once the volume has content.
 */
const seeding = new Map<string, Promise<void>>();

const seedVolume = (vol: string) =>
  Effect.promise(() => {
    const started = seeding.get(vol) ?? (async () => {
      const quiet = { stdout: "null", stderr: "null" } as const;
      const exists = await new Deno.Command("docker", {
        args: ["volume", "inspect", vol],
        ...quiet,
      }).output();
      if (exists.success) return;
      // mounting is what triggers the copy, and docker finishes it before the
      // container's own process runs — so any command will do, and `true` is
      // the cheapest one that proves the store arrived
      await new Deno.Command("docker", {
        args: ["run", "--rm", "-v", `${vol}:/nix`, IMAGE, "true"],
        ...quiet,
      }).output();
    })().catch(() => {
      // a seed that fails is not this task's error to report — let the real
      // `docker run` below fail with the message that actually says why, and
      // let the next task try the seed again rather than inherit this result
      seeding.delete(vol);
    });
    seeding.set(vol, started);
    return started;
  });

const VOLUME_NAME = /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/;

/** Start the private daemon inside a dind container and wait until it answers. */
const startDockerd = (name: string) =>
  Effect.gen(function* () {
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
  });

const remoteList = (repo: string) =>
  exec(["jj", "-R", repo, "--ignore-working-copy", "git", "remote", "list"]);

const jjRemote = (repo: string, ...op: string[]) =>
  exec(["jj", "-R", repo, "--ignore-working-copy", "git", "remote", ...op]).pipe(Effect.ignore);

/**
 * Put the operator's remotes back if a container moved them.
 *
 * A jj workspace shares the repo store it was added from, so a remote edited
 * from inside the container is the operator's remote — and on this host that
 * config is SSH and is the only credential their own `jj git fetch` has. The
 * `url.insteadOf` written at container setup removes the *reason* to edit one;
 * this removes an edit's ability to survive, which is the half that does not
 * depend on an agent choosing well.
 *
 * Re-asserted after every node rather than at teardown: a watch loop lives for
 * weeks, and the operator's next fetch comes long before it ends.
 *
 * Runs host-side on purpose — `jj git remote list` reports the stored URL here,
 * where nothing rewrites it, and reports the rewritten one inside a container.
 */
const guardRepoRemotes = (task: TaskRecord) =>
  Effect.gen(function* () {
    const repo = task.request.repo;
    if (!repo) return [];
    const saved = yield* Effect.promise(() =>
      Deno.readTextFile(`${stateDir()}/ws/${task.id}/repo-remotes.conf`).catch(() => "")
    );
    const now = yield* remoteList(repo);
    if (!saved || now.code !== 0 || now.output.trim() === saved.trim()) return [];

    // `jj git remote list` is one "<name> <url>" per line. A line without a
    // space is not that, and guessing at one would restore a remote to nonsense
    // — skipping it leaves that remote alone, which is the safe direction.
    const parse = (s: string) =>
      new Map(
        s.split("\n").map((l) => l.trim()).filter((l) => l.includes(" ")).map((l) => {
          const cut = l.indexOf(" ");
          return [l.slice(0, cut), l.slice(cut + 1).trim()] as const;
        }),
      );
    const want = parse(saved);
    const have = parse(now.output);
    const undone: string[] = [];
    for (const [name, url] of want) {
      if (have.get(name) === url) continue;
      yield* jjRemote(repo, ...(have.has(name) ? ["set-url", name, url] : ["add", name, url]));
      undone.push(`${name} back to ${url}`);
    }
    for (const name of have.keys()) {
      if (want.has(name)) continue;
      yield* jjRemote(repo, "remove", name);
      undone.push(`removed ${name}`);
    }
    return undone;
  });

/** Create workspace dir + container (+ jj workspace when repo-backed). Mutates `task` in place
 * so partially-created resources are still recorded for teardown on failure. */
export const setupTask = (task: TaskRecord) =>
  Effect.gen(function* () {
    const ws = `${stateDir()}/ws/${task.id}`;
    yield* Effect.promise(() => Deno.mkdir(ws, { recursive: true }));

    const nodes = task.workflow.nodes.map(normalizeNode);
    const needsClaude = nodes.some((n) => n.exec === "claude");
    const needsCodex = nodes.some((n) => n.exec === "codex");
    const env: Record<string, string> = { ...task.request.cache?.env, ...task.request.env };
    if (needsClaude) {
      env.CLAUDE_CODE_OAUTH_TOKEN = yield* credentialToken;
      // claude refuses --dangerously-skip-permissions as root unless it knows
      // it's inside a dedicated sandbox, which these containers are
      env.IS_SANDBOX = "1";
    }
    /**
     * Three things a private home buys: the credential copy has somewhere of
     * its own to be refreshed into, codex reads no config the operator did not
     * put there — the equivalent of claude's --strict-mcp-config, which has no
     * flag on this side — and `exec resume` can find the thread at all. Resume
     * reads the rollout files codex writes under this directory, not just the
     * id, and fails with "no rollout found" against a home that has none. On
     * the workspace mount it outlives the container, so a revived task resumes
     * the conversation rather than starting one that has never heard of it.
     *
     * Filled by installHarness, like the emit tool.
     */
    if (needsCodex) env.CODEX_HOME = `/ws/${task.id}/codex`;
    if (task.request.gh) {
      const gh = yield* execOk(["gh", "auth", "token"]);
      env.GH_TOKEN = gh.output.trim();
    }

    const name = `af-${task.id}`;
    const args = ["docker", "run", "-d", "--name", name, "--label", "agentflow=1"];
    for (const [k, v] of Object.entries(env)) args.push("-e", `${k}=${v}`);
    if (task.request.hostAgentConfig !== false) {
      // agents inherit the host's global instructions/skills; ro so a
      // prompt-injected agent can't rewrite them
      const home = Deno.env.get("HOME");
      const mounts = [
        ...needsClaude
          ? ["CLAUDE.md", "skills", "agents"].map((
            e,
          ) => [`${home}/.claude/${e}`, `/root/.claude/${e}`])
          : [],
        // Codex looks for skills under ~/.agents rather than its own home, so
        // this is a mount and not part of the seeded CODEX_HOME. On this host
        // both paths are the same nix store directory (home/desktop.nix), which
        // is why the house-style prompt can name `human-writing` to either agent.
        ...needsCodex ? [[`${home}/.agents/skills`, "/root/.agents/skills"]] : [],
      ];
      for (const [src, dst] of mounts) {
        const exists = yield* Effect.promise(() => Deno.stat(src).then(() => true, () => false));
        if (exists) args.push("-v", `${src}:${dst}:ro`);
      }
    }
    if (needsClaude) {
      /**
       * Claude's session transcripts, on a host directory rather than in the
       * container's writable layer: there they vanish with the container, and
       * nothing on the host can count them. ccusage reads every config dir
       * named in CLAUDE_CONFIG_DIR, so naming this one beside ~/.claude folds
       * agentflow's usage into the operator's own report. One tree for all
       * tasks, not one per workspace, because the report is daily and `af rm`
       * takes the workspace with it; session files are named by uuid, so tasks
       * sharing the tree cannot collide. The operator's own ~/.claude/projects
       * stays out of reach — it is their history, not the agents'.
       */
      const transcripts = `${stateDir()}/claude/projects`;
      yield* Effect.promise(() => Deno.mkdir(transcripts, { recursive: true }));
      args.push("-v", `${transcripts}:/root/.claude/projects`);
    }
    args.push("-v", `${ws}:/ws/${task.id}`);
    if (task.request.repo) args.push("-v", `${task.request.repo}:/repo`);

    const cache = task.request.cache;
    if (cache?.nix !== false) {
      const vol = yield* nixVolume;
      if (vol) {
        yield* seedVolume(vol);
        args.push("-v", `${vol}:/nix`);
      }
    }
    for (const v of cache?.volumes ?? []) {
      if (!VOLUME_NAME.test(v.name)) {
        return yield* new WorkflowError({ message: `invalid cache volume name "${v.name}"` });
      }
      if (!v.at?.startsWith("/")) {
        return yield* new WorkflowError({
          message: `cache volume "${v.name}" needs an absolute mount path, got "${v.at}"`,
        });
      }
      args.push("-v", `${v.name}:${v.at}`);
    }

    if (task.request.docker === "socket") {
      args.push("-v", "/var/run/docker.sock:/var/run/docker.sock");
    } else if (task.request.docker === "dind") {
      // anonymous volume: the inner dockerd's overlayfs cannot nest on the
      // container's own overlay filesystem
      args.push("--privileged", "-v", "/var/lib/docker");
    }
    args.push(IMAGE, "sleep", "infinity");
    // recorded before the run, not after: `docker run -d` creates the container
    // and only then fails to start its process, so a failure here still leaves
    // one holding the name. Unrecorded, teardown skips it and the name is taken
    // for good — every later attempt at this task id dies on a name conflict
    // rather than on whatever actually went wrong.
    task.container = name;
    yield* execOk(args);

    // commits inside the container default to the host operator's identity
    const hostName = yield* exec(["jj", "config", "get", "user.name"]);
    const hostEmail = yield* exec(["jj", "config", "get", "user.email"]);
    if (hostName.code === 0 && hostEmail.code === 0) {
      // deno-fmt-ignore
      yield* exec([
        "docker", "exec", name, "sh", "-c",
        'mkdir -p /root/.config/jj && printf \'[user]\\nname = "%s"\\nemail = "%s"\\n\' "$1" "$2" > /root/.config/jj/config.toml',
        "sh", hostName.output.trim(), hostEmail.output.trim(),
      ]).pipe(Effect.ignore);
    }

    /**
     * The token is HTTPS-only and the container holds no SSH key, so an
     * SSH-form remote dies on host-key verification the first time an agent
     * pushes. An agent that hits that fixes it the obvious way — `jj git remote
     * set-url origin https://…`, or a second remote beside it — and when the
     * workspace was cut from the operator's own repo that rewrite lands in
     * *their* remote config, because a jj workspace shares the repo store it
     * was added from. Both have happened, and both broke the operator's own
     * `jj git fetch`, which has only an SSH credential to offer.
     *
     * Rewriting the URL per container instead leaves the repo alone: jj shells
     * out to git, git resolves through this, and the stored remote still reads
     * git@github.com. Not best-effort — a container that silently lacks it is
     * one where the next agent to push re-opens the same hole.
     */
    if (env.GH_TOKEN) {
      // deno-fmt-ignore
      yield* execOk([
        "docker", "exec", name, "sh", "-c",
        'git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null; ' +
        'git config --global --add url."https://github.com/".insteadOf "git@github.com:" && ' +
        'git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/" && ' +
        'gh auth setup-git',
      ]);
    }

    if (task.request.docker === "dind") yield* startDockerd(name);

    if (task.request.repo) {
      // The remotes as the operator has them, before a container has had any
      // chance at them; guardRepoRemotes re-asserts this after every node. On
      // the workspace mount rather than the task record so it outlives a daemon
      // restart, and so it is readable when the operator wants to know what it
      // is holding them to.
      const remotes = yield* remoteList(task.request.repo);
      if (remotes.code === 0) {
        yield* Effect.promise(() =>
          Deno.writeTextFile(`${ws}/repo-remotes.conf`, remotes.output).catch(() => {})
        );
      }

      const wsName = `af-${task.id}`;
      // deno-fmt-ignore
      yield* execOk([
        "docker", "exec", name,
        "jj", "-R", "/repo", "workspace", "add", "--name", wsName, `/ws/${task.id}/wc`,
      ]);
      task.workspace = wsName;
      task.cwd = `/ws/${task.id}/wc`;

      // A `nix develop` in a plain directory copies the whole tree into the
      // store — .venv, node_modules and all — and copies it again after every
      // edit, because the tree hash moved. Nix filters a directory only when
      // there is a git index to filter against, and a jj workspace has none;
      // measured here, an index took a 101M workspace from a 101M snapshot per
      // run to an 8K one that moves only when source does. Nothing ever
      // commits to or pushes this repo: it exists so nix can tell source from
      // build output. `.jj` is excluded because its working-copy state
      // rewrites on every jj command, which would move the snapshot for free.
      // The reverse direction is safe without doing anything: jj never
      // snapshots `.git`, since colocated repos put one next to `.jj` in the
      // working copy — so none of this reaches a commit. On any failure the
      // .git goes away again — no index is merely slow, a half-built one hides
      // files from the build.
      // deno-fmt-ignore
      yield* dockerExec(name, task.cwd, [
        "sh", "-c",
        "git init -q && printf '.jj/\\n' > .git/info/exclude && git add -A || rm -rf .git",
      ]).pipe(Effect.ignore);
    } else {
      /**
       * Its own directory, one below the mount, for the same reason the
       * repo-backed case gets `wc`: the mount root holds this task's harness —
       * af-mcp.mjs, mcp.json, refs, artifacts, the pidfiles — and a working
       * directory that is not empty is one `git clone .` and `gh repo clone .`
       * both refuse.
       * That is the documented way a task with no repo gets its code, so the
       * documented path was the one that failed.
       *
       * Only new tasks move. `cwd` is persisted on the record and revive reads
       * it from there, so containers built before this keep the layout they
       * were built with.
       */
      yield* Effect.promise(() => Deno.mkdir(`${ws}/work`, { recursive: true }));
      task.cwd = `/ws/${task.id}/work`;
    }
  });

/**
 * Warm caches before the first node so agent turns don't pay for a cold
 * toolchain. Failures are surfaced in the log but never fail the task — a
 * broken prewarm is a slow task, not a wrong one.
 */
export const runSetup = (
  task: TaskRecord,
  onChunk: (s: string) => void,
): Effect.Effect<number | undefined, WorkflowError> =>
  Effect.gen(function* () {
    const setup = task.request.setup;
    const cmd = typeof setup === "string" ? setup : setup?.run;
    const required = typeof setup === "object" && setup?.required === true;
    if (!cmd) return undefined;
    const logDir = `${stateDir()}/logs/${task.id}`;
    yield* Effect.promise(() => Deno.mkdir(logDir, { recursive: true }));
    let captured = `[agentflow] setup: ${cmd}\n`;
    onChunk(captured);
    const tee = (chunk: string) => {
      captured += chunk;
      onChunk(chunk);
    };
    const r = yield* dockerExec(task.container!, task.cwd!, ["sh", "-c", cmd], tee).pipe(
      Effect.catchAll(() => Effect.succeed({ code: -1, output: "" })),
    );
    if (r.code !== 0) {
      const note = required
        ? `[agentflow] setup exited ${r.code} and was marked required; stopping here\n`
        : `[agentflow] setup exited ${r.code}; continuing anyway\n`;
      captured += note;
      onChunk(note);
    }
    // kept on disk like a node transcript, so a failed prewarm is diagnosable
    // long after the live stream is gone
    yield* Effect.promise(() =>
      Deno.writeTextFile(`${logDir}/setup-0.log`, captured).catch(() => {})
    );
    if (r.code !== 0 && required) {
      return yield* new WorkflowError({
        message: `required setup failed (exit ${r.code}): ${cmd}\n` +
          `Nothing ran after it — a node that depends on setup having worked fails in ways that ` +
          `look like its own bug. Full output: af log ${task.id} setup 0\n` +
          r.output.slice(-1000),
      });
    }
    return r.code;
  });

/**
 * A container that outlived a host reboot, a docker restart, or a manual
 * `docker stop` is still recorded on the task, but every `docker exec` against
 * it fails instantly — which reads as a workflow that failed in milliseconds
 * rather than as a container that needs starting. Bring it back before the
 * graph runs. dind's daemon is a foreground process the stop killed too, so it
 * gets started again; the workspace is a bind mount and survives on its own.
 */
export const reviveContainer = (task: TaskRecord) =>
  Effect.gen(function* () {
    const name = task.container;
    if (!name) return;
    let state = yield* dockerCtl(["docker", "inspect", "-f", "{{.State.Running}}", name]);
    if (state.code !== 0) {
      /**
       * A failed inspect has two very different causes and they used to share
       * one message: the container really is gone, or docker itself is not
       * answering yet. The second happens routinely — the host wakes from sleep
       * and the daemon comes back before the docker VM does — and reading it as
       * the first tells the operator to delete a workspace that is perfectly
       * intact. So ask docker whether it is there at all, and wait for it.
       */
      yield* dockerCtl(["docker", "version", "-f", "{{.Server.Version}}"]).pipe(
        Effect.filterOrFail(
          (r) => r.code === 0,
          () => new ExecError({ cmd: ["docker", "version"], message: "docker not answering" }),
        ),
        Effect.retry(Schedule.intersect(Schedule.recurs(30), Schedule.spaced("2 seconds"))),
        Effect.catchAll(() =>
          new WorkflowError({
            message: `docker is not answering on this host, so ${name} cannot be started. ` +
              `Nothing is lost — the container and its workspace are intact and this task ` +
              `resumes once docker is up (\`af resume ${task.id}\`).`,
          })
        ),
      );
      // docker is up, so a still-missing container was genuinely removed
      state = yield* dockerCtl(["docker", "inspect", "-f", "{{.State.Running}}", name]);
      if (state.code !== 0) {
        return yield* new WorkflowError({
          message: `container ${name} is gone (removed outside agentflow), so this task has ` +
            `nowhere to run. Its workspace is still at ${stateDir()}/ws/${task.id}; salvage ` +
            `anything you need, then \`af cleanup ${task.id} --both\` and spawn a new task.`,
        });
      }
    }
    if (state.output.trim() === "true") return;
    yield* dockerCtl(["docker", "start", name]).pipe(
      Effect.filterOrFail(
        (r) => r.code === 0,
        (r) =>
          new ExecError({
            cmd: ["docker", "start", name],
            message: `exit ${r.code}: ${r.output.slice(-2000)}`,
          }),
      ),
    );
    if (task.request.docker === "dind") yield* startDockerd(name);
  });

/**
 * Stop the container without removing it, for a task that is parking. A wait
 * measured in hours should not hold a container's memory the whole time, and
 * `reviveContainer` already treats a stopped container as something to start —
 * so the park costs nothing and the wake costs a `docker start`.
 */
export const stopContainer = (task: TaskRecord) =>
  Effect.gen(function* () {
    if (!task.container) return;
    /**
     * No grace period: the container's own process is `sleep infinity`, which
     * ignores SIGTERM, so any timeout here is spent in full and then it is
     * killed anyway. Nothing at a park needs the time — the node that was
     * running has already finished or been killed, and a wait node runs nothing.
     */
    yield* dockerCtl(["docker", "stop", "-t", "0", task.container]).pipe(Effect.ignore);
  });

/**
 * Whether a node's process is doing anything, for a turn that has gone quiet.
 * Samples the process tree's CPU time twice: a claude blocked on a socket the
 * network dropped is alive and burning nothing, while a 40-minute build is
 * alive and burning plenty — and from the outside those look identical until
 * you look at the clock they are spending.
 */
export const probeNode = (
  container: string,
  pidfile: string,
): Effect.Effect<"busy" | "idle" | "gone" | "unknown", never> =>
  Effect.gen(function* () {
    /**
     * Only this node's own process tree. Summing the whole container's CPU was
     * wrong in the direction that matters: anything else ticking in there — and
     * something always is — masks a wedged agent as busy, so the check that
     * exists to notice a stuck turn would never fire.
     *
     * Fields are taken after the last `)` because a process whose name contains
     * a space shifts every positional field after comm, and utime/stime read
     * from the wrong offset is a number that means nothing.
     */
    const script = `
p=$(cat "$1" 2>/dev/null); [ -n "$p" ] || { echo GONE; exit 0; }
[ -d "/proc/$p" ] || { echo GONE; exit 0; }

tree=$p; queue=$p; depth=0
while [ -n "$queue" ] && [ $depth -lt 12 ]; do
  depth=$((depth+1)); next=
  for d in /proc/[0-9]*; do
    [ -r "$d/status" ] || continue
    ppid=
    while read -r k v _; do case $k in PPid:) ppid=$v; break;; esac; done < "$d/status"
    for q in $queue; do
      if [ "$ppid" = "$q" ]; then
        pid=\${d#/proc/}; tree="$tree $pid"; next="$next $pid"
      fi
    done
  done
  queue=$next
done

sample() {
  total=0
  for pid in $tree; do
    [ -r "/proc/$pid/stat" ] || continue
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
    set -- \${line##*) }
    [ $# -ge 13 ] || continue
    # braces are load-bearing: \$12 is "\$1" followed by a literal 2, so the sum
    # was arithmetic on a pid with a digit stuck to it and every probe read idle
    total=$((total + \${12} + \${13}))
  done
  echo $total
}
a=$(sample); sleep 3; b=$(sample)
[ "$a" = "$b" ] && echo IDLE || echo BUSY`;
    const r = yield* exec(["docker", "exec", container, "sh", "-c", script, "sh", pidfile]).pipe(
      Effect.catchAll(() => Effect.succeed({ code: -1, output: "" })),
    );
    if (r.code !== 0) return "unknown";
    const out = r.output.trim();
    return out.endsWith("GONE")
      ? "gone"
      : out.endsWith("IDLE")
      ? "idle"
      : out.endsWith("BUSY")
      ? "busy"
      : "unknown";
  });

/** Best-effort container removal; clears task.container (disables revive). */
export const teardownContainer = (task: TaskRecord) =>
  Effect.gen(function* () {
    if (!task.container) return;
    // -v also removes anonymous volumes (the dind /var/lib/docker one), but
    // never named ones: shared caches outlive the tasks that filled them
    yield* exec(["docker", "rm", "-f", "-v", task.container]).pipe(Effect.ignore);
    task.container = undefined;
  });

const moveInto = async (from: string, to: string) => {
  await Deno.mkdir(to, { recursive: true });
  for await (const entry of Deno.readDir(from)) {
    const src = `${from}/${entry.name}`;
    const dst = `${to}/${entry.name}`;
    if (entry.isDirectory) await moveInto(src, dst);
    else await Deno.rename(src, dst).catch(() => {});
  }
};

/**
 * Artifacts outlive the workspace. They are written on the mount because that
 * is the only place a container can write to, but what an agent left for the
 * operator to look at is wanted most after the checkout it came from has been
 * reclaimed — so before the mount goes they move under logs, the one directory
 * of a task's that no teardown touches. Same filesystem, so one rename; the
 * file-by-file fallback is for a directory an earlier teardown already left
 * there, where a clash would otherwise cost this run's files.
 */
const keepArtifacts = async (id: string) => {
  const from = `${stateDir()}/ws/${id}/artifacts`;
  const to = `${stateDir()}/logs/${id}/artifacts`;
  let any = false;
  try {
    for await (const _ of Deno.readDir(from)) {
      any = true;
      break;
    }
  } catch {
    return;
  }
  if (!any) return;
  await Deno.mkdir(`${stateDir()}/logs/${id}`, { recursive: true });
  try {
    await Deno.rename(from, to);
  } catch {
    await moveInto(from, to);
  }
};

/** Best-effort jj workspace forget (host jj) + workspace dir removal. */
export const teardownWorkspace = (task: TaskRecord) =>
  Effect.gen(function* () {
    if (task.workspace && task.request.repo) {
      yield* exec(["jj", "-R", task.request.repo, "workspace", "forget", task.workspace]).pipe(
        Effect.ignore,
      );
      task.workspace = undefined;
    }
    yield* Effect.promise(() => keepArtifacts(task.id).catch(() => {}));
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
// Workspace snapshots

/** commit id of the workspace's working copy right now, for rerun --reset-workspace */
export const snapshotCommit = (task: TaskRecord): Effect.Effect<string | undefined, never> =>
  Effect.gen(function* () {
    if (!task.request.repo || !task.container || !task.cwd) return undefined;
    // deno-fmt-ignore
    const r = yield* dockerExec(task.container, task.cwd, [
      "jj", "log", "--no-graph", "-r", "@", "-T", "commit_id",
    ]).pipe(Effect.catchAll(() => Effect.succeed({ code: -1, output: "" })));
    const id = r.output.trim();
    return r.code === 0 && /^[0-9a-f]{8,}$/.test(id) ? id : undefined;
  });

/**
 * Restore the workspace's files from an earlier snapshot. This reverts tracked
 * file contents in this workspace only — it does not move bookmarks, touch
 * other workspaces, rewrite history, or undo anything the agent did outside
 * the workspace (pushes, PRs, network calls). Callers must say so out loud.
 */
export const restoreWorkspace = (task: TaskRecord, commit: string) =>
  Effect.gen(function* () {
    if (!task.container || !task.cwd) {
      return yield* new WorkflowError({ message: "task has no container to restore in" });
    }
    const r = yield* dockerExec(task.container, task.cwd, ["jj", "restore", "--from", commit]);
    if (r.code !== 0) {
      return yield* new WorkflowError({
        message: `jj restore --from ${commit} failed (the snapshot may have been garbage ` +
          `collected): ${r.output.slice(-500)}`,
      });
    }
    return r.output;
  });

// ---------------------------------------------------------------------------
// Workflow graph runner

/**
 * Why a node may not start yet, from a caller that knows about money and slots
 * and a graph that does not. Returning a reason parks the task in front of the
 * node rather than failing it: the work is fine, the moment is wrong.
 */
export interface Admission {
  reason: "budget" | "slot";
  /** when to try again; absent means only an external change will free it */
  until?: string;
  /** what the operator should read on the board */
  message: string;
}

export interface EngineCallbacks {
  emitNode: (run: NodeRun) => void;
  emitLog: (node: string, chunk: string) => void;
  /** consulted before every node; a reason parks the task instead of running it */
  admit: (node: WorkflowNode) => Admission | undefined;
  /** expose the current node's abort controller for interject({urgent}) */
  onNodeStart: (abort: AbortController) => void;
  /**
   * Put an event on the task's stream. Reaches the store through the caller
   * rather than directly: the store imports `stateDir` from here, and an
   * import back the other way would close the cycle.
   */
  publish: (event: Omit<TaskEventRecord, "seq" | "at">) => void;
  /** the events this node should be shown, given what its thread already knows */
  deliverable: (
    node: { id: string; accepts?: string[]; ignores?: string[] },
    since: number,
  ) => TaskEventRecord[];
  /**
   * A spool line that asked for something other than publishing here: spawning
   * a task, reaching another one. The engine does not know what is allowed —
   * that policy belongs to whoever owns the board — so it hands the line over
   * and reports back whatever comes of it.
   */
  request: (op: string, line: Record<string, unknown>) => string;
}

/**
 * `{{node}}` injects a node's readable output; `{{node.field}}` reaches into
 * the validated object of a schema-contract node, so a prompt can ask for the
 * blocking problems without also dragging in the whole review. `{{meta.key}}`
 * reads the task's metadata the same way, and `{{#meta.pr}}…{{/meta.pr}}`
 * keeps a section only once someone has recorded a value.
 */
const template = (
  text: string,
  vars: Record<string, string>,
  data: Record<string, unknown>,
) => {
  const lookup = (key: string): string => {
    if (!key.includes(".")) return vars[key] ?? "";
    const [head, ...path] = key.split(".");
    const resolved = resolvePath(data[head], path);
    return resolved === undefined ? "" : renderData(resolved);
  };
  // `{{#key}}…{{/key}}` keeps its body only when the key has something to say.
  // A node that has not run yet resolves to nothing, and without this its
  // heading still arrives, so the first rework loop asks the implementer to
  // read a review section that is blank. An empty list is not the same case —
  // it renders "(none)", which is an answer, and stays.
  return text
    .replaceAll(
      /\{\{#([\w.]+)\}\}([\s\S]*?)\{\{\/\1\}\}/g,
      (_, key: string, body: string) => lookup(key).trim() ? body : "",
    )
    .replaceAll(/\{\{([\w.]+)\}\}/g, (_, key: string) => lookup(key));
};

/**
 * The output contract the agent is held to, appended to its prompt. Generated
 * from the same schema the validator uses — a hand-written format instruction
 * in the prompt template drifts from the checker, which is how the previous
 * last-line convention went wrong.
 */
const contractBlock = (contract: OutcomeContract, brief = false): string => {
  if (contract.kind !== "schema") return "";
  // A revisit has the type in its own history, and every reply it has already
  // made in this thread is an example of satisfying it. Restating it in full
  // was the largest fixed cost of a watch loop's turn after the brief itself.
  if (brief) {
    return `

[output contract] Unchanged: one JSON object of the same type, every field,
nothing outside it.`;
  }
  return `

[output contract]
Your final message is read as data, not prose: one JSON object matching this
TypeScript type. Anything outside the object is discarded, so the reasoning
belongs in the fields.

${toTypeScript(contract.schema)}

If it does not parse or does not match, you will be asked for it again, and
that correction replaces this whole reply — so send every field, not only the
ones that were wrong.`;
};

const IDEMPOTENCE_CLAUSE = `

[idempotence] This node runs more than once — rework loops revisit it and the
operator can rerun it — and it touches state outside the workspace, which
nothing here can revert. Assume an earlier run may already have created what
you are about to create, and look before you create it.`;

/**
 * Context window for the model a run actually used, since the percentage was
 * being computed against a hardcoded 200k and read over 100% for every model
 * with a bigger window. 1M is the window on opus/sonnet from 4.6 onward and on
 * the whole 5 series; 200k covers haiku, the 4.0–4.5 opus/sonnet models, and
 * the 3.x line.
 *
 * An unrecognised model returns undefined, and the percentage is then omitted
 * rather than guessed — a number that is quietly wrong is worse than no number
 * on a figure the operator uses to decide whether a task is about to run out
 * of room.
 */
export const contextWindow = (model?: string): number | undefined => {
  if (!model) return undefined;
  // bedrock/vertex prefixes, and the [1m] suffix claude appends when a model
  // is running under the long-context beta
  const id = model.replace(/^(?:us|eu|apac)\.|^anthropic\./, "");
  if (/\[1m\]$/.test(id)) return 1_000_000;
  if (/^claude-haiku/.test(id) || /^claude-3/.test(id)) return 200_000;
  if (/^claude-(?:opus|sonnet)-4-[0-5]\b/.test(id)) return 200_000;
  if (/^claude-(?:opus|sonnet|fable|mythos)-/.test(id)) return 1_000_000;
  return undefined;
};

/**
 * What claude calls the tool that starts a subagent. "Agent" is the current
 * name and "Task" the older one; both are matched exactly, because the tools
 * actually sitting next to it in these transcripts are TaskCreate, TaskUpdate,
 * TaskOutput and TaskStop — a prefix or substring test counts a todo list as a
 * fan-out, which is precisely backwards for a number meant to explain cost.
 */
const SUBAGENT_TOOLS = new Set(["Agent", "Task"]);

/**
 * Agent nodes emit stream-json (one event per line). The node's public output
 * is the final `result` event's text; the raw stream is kept on disk for the
 * dashboard's full-transcript mode.
 */
type CodexUsage = { input: number; output: number; cacheRead: number; cacheWrite: number };

const ZERO_USAGE: CodexUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

/**
 * Codex's `turn.completed` carries the usage of the whole THREAD, not of the
 * turn — measured across three turns of one conversation: output 5 → 10 → 15,
 * input 16477 → 32980 → 49500. So every figure here is a difference rather than
 * a sum, and summing the events (the obvious reading, and the one the claude
 * side does) would bill a run for every run before it on the same thread.
 *
 * `baseline` is where that thread stood when this run started. It is zero for a
 * cold-session node, which opens a thread per visit, and the previous run's
 * total for a node on a persistent session. Retries inside one run resume the
 * same thread, so within a transcript the last event is the total and the
 * earlier ones are its history.
 *
 * No cost at all: codex runs on a subscription, so there is no per-token price.
 * `costUsd` stays absent rather than zero — the dashboard sums it across a task,
 * and a zero reads as a task that spent nothing rather than one whose spend is
 * not money.
 */
const extractCodexLlm = (
  raw: string,
  model?: string,
  baseline: CodexUsage = ZERO_USAGE,
): (LlmStats & { cumulative: CodexUsage }) | undefined => {
  const seen: CodexUsage[] = [];
  for (const line of raw.split("\n")) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.type !== "turn.completed") continue;
      const u = ev.usage ?? {};
      seen.push({
        input: u.input_tokens ?? 0,
        output: u.output_tokens ?? 0,
        cacheRead: u.cached_input_tokens ?? 0,
        cacheWrite: u.cache_write_input_tokens ?? 0,
      });
    } catch {
      // truncated line at the start of the capped tail
    }
  }
  const last = seen.at(-1);
  if (!last) return undefined;

  /**
   * The final turn's own tokens, differenced out of the running totals because
   * no event states them: turn 3 above sent 49500 - 32980 = 16520, not the
   * 49500 it reported.
   *
   * Read as an upper bound on context, not context. One `codex exec` turn is
   * several model round-trips when the agent uses tools, and each re-sends the
   * conversation — so a turn that edited files reports their sum, well above
   * the conversation's actual size (measured: 46742 for a turn whose context
   * was nearer 16k). The last round-trip's own input is the true figure and the
   * stream does not carry it. Harmless in the dashboard, which shows no
   * percentage for codex because `contextWindow` knows no gpt models, and would
   * stop being harmless the day it did.
   */
  const prev = seen.at(-2) ?? baseline;
  const ctx = last.input - prev.input + (last.output - prev.output);
  const window = contextWindow(model);
  return {
    model,
    inputTokens: last.input - baseline.input,
    outputTokens: last.output - baseline.output,
    cacheRead: last.cacheRead - baseline.cacheRead,
    cacheWrite: last.cacheWrite - baseline.cacheWrite,
    turns: seen.length,
    contextTokens: ctx > 0 ? ctx : undefined,
    contextWindow: window,
    contextPct: ctx > 0 && window ? Math.round((ctx / window) * 100) : undefined,
    cumulative: last,
  };
};

/**
 * Per-run telemetry, and for codex the new watermark to carry on the session —
 * see `extractCodexLlm` for why one cannot be had without the other.
 */
const extractLlm = (
  node: WorkflowNode,
  raw: string,
  model: string | undefined,
  session: SessionState | undefined,
): LlmStats | undefined => {
  if (node.exec !== "codex") return extractClaudeLlm(raw);
  const stats = extractCodexLlm(raw, model, session?.usage);
  if (!stats) return undefined;
  const { cumulative, ...llm } = stats;
  if (session) session.usage = cumulative;
  return llm;
};

const extractClaudeLlm = (raw: string): LlmStats | undefined => {
  // deno-lint-ignore no-explicit-any
  let model: string | undefined, lastUsage: any;
  // a run can span several claude invocations (contract corrections), so
  // totals are summed across every result event, not read off the last one
  let sawResult = false;
  let subagents = 0;
  const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0, api: 0 };
  for (const line of raw.split("\n")) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.type === "system" && ev.subtype === "init") model ??= ev.model;
      else if (ev.type === "assistant") {
        if (ev.message?.usage) {
          lastUsage = ev.message.usage;
          model ??= ev.message.model;
        }
        // Subagents are the one thing a turn can spend heavily on that leaves no
        // trace anywhere an operator looks: their cost lands in this turn's
        // total, their existence only in the transcript. Counting the calls here
        // is what lets `af show` say four agents ran inside that number instead
        // of presenting it as one agent's turn.
        for (const c of ev.message?.content ?? []) {
          if (c?.type === "tool_use" && SUBAGENT_TOOLS.has(c.name)) subagents++;
        }
      } else if (ev.type === "result") {
        sawResult = true;
        const u = ev.usage ?? {};
        total.input += u.input_tokens ?? 0;
        total.output += u.output_tokens ?? 0;
        total.cacheRead += u.cache_read_input_tokens ?? 0;
        total.cacheWrite += u.cache_creation_input_tokens ?? 0;
        total.cost += ev.total_cost_usd ?? 0;
        total.turns += ev.num_turns ?? 0;
        total.api += ev.duration_api_ms ?? 0;
      }
    } catch {
      // truncated line at the start of the capped tail
    }
  }
  if (!model && !sawResult) return undefined;
  const ctx = lastUsage
    ? (lastUsage.input_tokens ?? 0) + (lastUsage.cache_read_input_tokens ?? 0) +
      (lastUsage.cache_creation_input_tokens ?? 0) + (lastUsage.output_tokens ?? 0)
    : undefined;
  const window = contextWindow(model);
  return {
    model,
    inputTokens: total.input,
    outputTokens: total.output,
    cacheRead: total.cacheRead,
    cacheWrite: total.cacheWrite,
    costUsd: total.cost,
    turns: total.turns,
    apiMs: total.api,
    subagents: subagents || undefined,
    contextTokens: ctx,
    contextWindow: window,
    contextPct: ctx && window ? Math.round((ctx / window) * 100) : undefined,
  };
};

/**
 * Parse each line rather than matching on `{"type":"result"` as a prefix:
 * claude's stream-json does not guarantee key order, and it has already moved
 * `type` off the front of the result event once. When that happened this
 * returned the entire raw transcript as the node's "summary", which quietly
 * broke every outcome contract — the verdict line was no longer the last line
 * of the text being matched.
 */
const lastEventOfType = (raw: string, type: string): Record<string, unknown> | undefined => {
  for (const line of raw.split("\n").reverse()) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (ev?.type === type) return ev;
    } catch {
      // truncated line at the edge of the capped tail
    }
  }
  return undefined;
};

/**
 * The node's public output: what the agent actually said, with the event stream
 * around it stripped. Everything routes on this — outcome contracts, template
 * variables, what the next node is told — so getting it wrong does not look
 * like a parsing bug, it looks like every downstream node losing its mind.
 *
 * Codex is read from the file it was told to write rather than from its stream,
 * and the asymmetry is deliberate: claude has no equivalent flag, and this is
 * the exact failure the comment on `lastEventOfType` describes. A file whose
 * path we chose cannot reorder its keys.
 */
const summarize = (node: WorkflowNode, raw: string, lastMessage?: string): string => {
  if (node.exec === "shell") return raw;
  if (node.exec === "codex") {
    // the stream is still the fallback: a turn killed before it wrote the file
    // has its reply nowhere else
    if (lastMessage?.trim()) return lastMessage;
    const item = lastItemOfType(raw, "agent_message");
    return (item?.text as string) ?? raw;
  }
  const ev = lastEventOfType(raw, "result");
  return (ev?.result as string) ?? (ev?.error as string) ?? raw;
};

/** codex's `item.completed` payload for a given item type, most recent first */
const lastItemOfType = (raw: string, itemType: string): Record<string, unknown> | undefined => {
  for (const line of raw.split("\n").reverse()) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (ev?.type === "item.completed" && ev.item?.type === itemType) return ev.item;
    } catch {
      // truncated line at the edge of the capped tail
    }
  }
  return undefined;
};

/**
 * Apply a pattern contract to a node's text output.
 *
 * `miss` carries why nothing matched, because the caller routes on the fallback
 * either way and a fallback that happens to be right on the quiet path hides a
 * contract that has never matched at all. A sweep printing its diagnostics
 * after its `ROUTE:` line read as "idle" for 1286 laps — correct every time
 * until the one lap that found work, which it also called idle.
 */
const patternLabel = (
  c: Extract<OutcomeContract, { kind: "pattern" }>,
  text: string,
): { label?: string; miss?: string } => {
  const lines = text.trim().split("\n").map((l) => l.trim()).filter(Boolean);
  const haystack = c.lastLineOnly === false ? lines : [lines.at(-1) ?? ""];
  const re = new RegExp(c.pattern, "i");
  let unmapped: string | undefined;
  for (const line of haystack) {
    const cap = line.match(re)?.[1];
    if (cap === undefined) continue;
    const label = c.map[cap] ?? c.map[cap.toUpperCase()] ?? c.map[cap.toLowerCase()];
    if (label) return { label };
    unmapped ??= cap;
  }
  if (unmapped !== undefined) {
    return { miss: `captured "${unmapped}", which the contract's map does not name` };
  }
  // the authoring mistake this exists for: the line is there, just not the one
  // a last-line contract looks at
  if (haystack.length === 1 && lines.some((l) => re.test(l))) {
    return {
      miss: `the last line (${JSON.stringify(lines.at(-1))}) does not match, ` +
        `but an earlier line does — a pattern contract reads only the last line ` +
        `unless it sets lastLineOnly: false`,
    };
  }
  return { miss: `no line matched ${c.pattern}` };
};

interface SchemaResult {
  data?: unknown;
  label?: string;
  errors: string[];
}

/** parse + validate a reply against a schema contract, keeping the reasons */
const checkSchema = (
  c: Extract<OutcomeContract, { kind: "schema" }>,
  text: string,
): SchemaResult => {
  const { value, error } = extractJson(text);
  if (error) return { errors: [error] };
  const errors = validate(c.schema, value);
  if (errors.length) return { errors };

  const raw = resolvePath(value, c.label.split("."));
  if (typeof raw !== "string") {
    return { errors: [`${c.label}: must be a string naming the outcome, got ${typeof raw}`] };
  }
  const label = c.map?.[raw] ?? raw;
  return { data: value, label, errors: [] };
};

/**
 * The thread this run's turns landed on, so a corrective retry continues it
 * rather than asking a stranger to fix a reply it never made.
 *
 * For codex this is also how the thread is learned at all: it names its own,
 * and a node whose session key outlives the run has nothing else to store.
 */
const extractSessionId = (node: WorkflowNode, raw: string): string | undefined => {
  for (const line of raw.split("\n")) {
    if (!line.startsWith("{")) continue;
    try {
      const ev = JSON.parse(line);
      if (node.exec === "codex") {
        // `thread_id` is what codex 0.146 emits; `id` is what the published jq
        // one-liner reads, and covering both costs a line. Getting this wrong
        // does not fail — every codex node just silently opens a cold thread on
        // every visit, and a rework loop stops being a conversation.
        if (ev.type === "thread.started") return ev.thread_id ?? ev.id;
      } else if (ev.type === "system" && ev.subtype === "init" && ev.session_id) {
        return ev.session_id;
      }
    } catch {
      // truncated line
    }
  }
  return undefined;
};

// deno-fmt-ignore
const CLAUDE_BASE = [
  "claude", "-p", "--dangerously-skip-permissions",
  "--output-format", "stream-json", "--verbose",
];

/**
 * Appended to the system prompt of every claude turn the engine starts, rather
 * than to the prompt templates. A node's template is about that node's job, and
 * something that applies to all of them drifts the moment one is edited.
 *
 * It names the skill instead of restating it, and that is load-bearing rather
 * than tidy. Skills reach an agent as a listing of names with one-line
 * descriptions, and when there are enough of them the descriptions are dropped
 * — measured in these containers, `human-writing` arrived as a bare name with
 * no description in every sample taken, so nothing ever told the agent what it
 * was for and it was loaded exactly once across forty tasks. An instruction to
 * use it by name survives a listing that has lost its description.
 */
const HOUSE_STYLE = `Some of what you write here leaves this system and is read by people who were
never in it: a commit message, a pull request title or body, a review comment,
anything posted to an issue or a PR. That writing is judged as writing, by
readers who never saw the task, the diff, or this conversation. Load the
\`human-writing\` skill before you write any of it.`;

/**
 * Rides on every agent turn for the same reason as TOOLING below: it describes
 * the harness, which is there whether or not the host's agent config was
 * mounted.
 *
 * It states the teardown mechanism rather than a rule because the rule failed,
 * in both directions. A codex reviewer built its own persistence out of a goal;
 * goals live in CODEX_HOME, so every later `exec resume` woke the goal engine,
 * which re-fired the turn 17ms after the model had said "no action taken" — 938
 * laps of `gh pr view` in under three hours, the operator's weekly quota and
 * credit balance both gone. Then a claude node, carrying an earlier version of
 * this text, put its test suite on a Monitor and replied "ok — rerunning in the
 * background". That version opened with "the engine wakes you when there is
 * something to do" — Monitor's own pitch, so ending the turn with a watcher
 * pending read as compliance — and its only stated rationale was orphan spend,
 * which a bounded test run does not resemble. The suite died at teardown,
 * review approved work whose verification never ran, and the kill left a
 * half-installed venv. The same thread chose the foreground on its own the
 * moment a later turn observed "killed again at session teardown" — the fact,
 * stated up front, is what the rule could not do.
 */
const SCHEDULING = `You are one turn of a workflow the engine drives, and the turn is a one-shot
process: your final message is the node's entire result, and sending it tears
the process down. Nothing you start survives that — a backgrounded command, a
monitor, a background subagent, a goal. Whatever those tools promise, no
notification ever arrives here and no wake ever comes: background work is
either killed mid-flight or orphaned outside every ceiling and every count the
engine keeps. Both have scarred real tasks — one shipped with its test suite
"rerunning in the background" (it was killed unfinished, and the kill left a
half-installed venv); a goal that outlived its turn burned a weekly model quota
polling a pull request that had not changed. So run the work in the foreground
and let the turn take the time it takes — the engine judges a quiet turn by its
CPU, not the clock, and a 40-minute build is a normal turn. Waiting on the
world is the graph's job: end your turn and say what you are waiting for.`;

/**
 * Rides on every agent turn, mounted host config or not: it describes the
 * container, not the host's skills, so a task that opted out of that mount
 * still needs it.
 *
 * The image carries a deliberately small profile, and an agent that reaches for
 * a tool and does not find it reads that as a broken container rather than as
 * one command of work — measured here while fixing a node script, which was
 * written around missing `sed` and `awk` that `nix shell` would have supplied
 * outright. Naming the flake-ref form is the load-bearing part: it is not
 * guessable from `nix --help`, and without it the fallback is `apt-get`, which
 * this image has never had.
 *
 * The artifacts paragraph is the other thing about this container an agent
 * cannot infer: who is on the far side of its work, and that they will not be
 * reading the transcript. Without it a verifier reports "confirmed working" in
 * a reply nobody sees, and the screenshot that would have settled it lands in
 * the checkout — where it is the diff under review — or in /tmp, which the
 * teardown takes. The path is literal rather than only an env var because
 * the agent writes it into refs and messages as well as into commands.
 */
const tooling = (taskId: string) =>
  `This container is a nix image with the flakes CLI and a network, so a tool that is
not on PATH is one command away rather than a dead end: \`nix shell nixpkgs#<pkg>
-c <cmd>\` to use it once, \`nix profile add nixpkgs#<pkg>\` to keep it for the rest
of the task. The profile is small on purpose.

The operator reviews this work from a dashboard, not from your transcript. What
would let them see it done rather than take your word for it — a screenshot of
the feature working, the output of the run that proves it, the log of the one
that failed — goes in /ws/${taskId}/artifacts (also $AF_ARTIFACTS). That
directory is listed on the task's page, images shown inline, and is kept after
the workspace and everything else on this mount are gone.`;

/**
 * One invocation of an agent. Both agents take a prompt and a thread to put it
 * on; they disagree only on who names the thread. Claude is handed an id before
 * its first turn, so a node's whole history is addressable before any of it
 * exists. Codex names its own and reports it on the stream, so `resume` is
 * empty on a codex node's first turn and the engine reads the id back after it.
 */
interface Turn {
  prompt: string;
  /** thread to continue; absent starts a fresh one */
  resume?: string;
  /** claude only: the id to open a fresh thread under */
  open?: string;
  /** file codex writes its final message to; see `summarize` */
  lastMessage: string;
}

/**
 * `--strict-mcp-config` so the server list is exactly this one: the host's
 * ~/.claude is mounted into these containers, and a task's agents publishing
 * through whatever the operator happens to have configured locally is a
 * surprise nobody asked for.
 *
 * The house style rides along only when that mount happened — it points at a
 * skill, and a task that opted out of the host's agent config has no skills to
 * point at. The scheduling and tooling notes ride along either way, describing
 * the harness and the container rather than the host. Codex gets all three
 * through its AGENTS.md instead: it has no flag for appending to the system
 * prompt, and its global instructions file is the channel with the same reach.
 */
const claudeCmd = (task: TaskRecord, agent: AgentDefaults, ...args: string[]) => [
  ...CLAUDE_BASE,
  "--mcp-config",
  `/ws/${task.id}/mcp.json`,
  "--strict-mcp-config",
  "--append-system-prompt",
  [
    ...(task.request.hostAgentConfig !== false ? [HOUSE_STYLE] : []),
    SCHEDULING,
    tooling(task.id),
  ].join("\n\n"),
  ...(agent.model ? ["--model", agent.model] : []),
  ...args,
];

/**
 * `--dangerously-bypass-approvals-and-sandbox` because the container already is
 * the sandbox: codex's own would deny the agent the workspace it was given, and
 * there is no approver on the other end of a prompt to unblock it.
 *
 * `--skip-git-repo-check` because the `.git` in a task workspace exists only so
 * nix can tell source from build output, and setup deletes it again on any
 * failure — codex refusing to start without one would turn a slow build into a
 * failed task.
 */
const codexCmd = (agent: AgentDefaults, turn: Turn) => [
  "codex",
  "exec",
  ...(turn.resume ? ["resume", turn.resume] : []),
  "--json",
  "--output-last-message",
  turn.lastMessage,
  "--dangerously-bypass-approvals-and-sandbox",
  "--skip-git-repo-check",
  ...(agent.model ? ["-m", agent.model] : []),
  ...(agent.effort ? ["-c", `model_reasoning_effort="${agent.effort}"`] : []),
  turn.prompt,
];

/** the command for one turn of whichever agent this node runs */
const agentCmd = (
  task: TaskRecord,
  node: WorkflowNode,
  agent: AgentDefaults,
  turn: Turn,
): string[] => {
  if (node.exec === "codex") return codexCmd(agent, turn);
  const thread = turn.resume
    ? ["--resume", turn.resume]
    : turn.open
    ? ["--session-id", turn.open]
    : [];
  return claudeCmd(task, agent, ...thread, turn.prompt);
};

/**
 * Put the container-side half of the task there: the emit tool, and the private
 * CODEX_HOME a codex node runs out of. It goes on the workspace mount rather
 * than in the image so it tracks the daemon that speaks to it, and rewriting
 * it on every run means a daemon upgrade reaches containers built by the old
 * one — and a reseeded codex credential reaches a revived task. The spool the
 * emit tool writes to is read straight off the host side of the same mount, so
 * the container needs no network, no port and no credential to publish — which
 * is the point, given the daemon's own API is unauthenticated and can stop and
 * remove every other task on the box.
 */
const installHarness = (task: TaskRecord) =>
  Effect.gen(function* () {
    const ws = `${stateDir()}/ws/${task.id}`;
    const needsCodex = task.workflow.nodes.map(normalizeNode).some((n) => n.exec === "codex");
    // read before the writes so a missing credential fails the task with the
    // message that says how to fix it, rather than as a codex exit code
    const auth = needsCodex ? yield* codexAuth : undefined;
    yield* Effect.tryPromise({
      try: async () => {
        // created here rather than left to the first agent that wants it: a
        // directory that may or may not exist is one an agent works around by
        // picking somewhere else, which is the scattering this is meant to stop
        await Deno.mkdir(`${ws}/refs`, { recursive: true });
        await Deno.mkdir(`${ws}/artifacts`, { recursive: true });
        const src = await Deno.readTextFile(new URL("../image/af-mcp.mjs", import.meta.url));
        await Deno.writeTextFile(`${ws}/af-mcp.mjs`, src);
        await Deno.writeTextFile(
          `${ws}/mcp.json`,
          JSON.stringify({
            mcpServers: { af: { command: "node", args: [`/ws/${task.id}/af-mcp.mjs`] } },
          }),
        );
        if (auth === undefined) return;

        const home = `${ws}/codex`;
        await Deno.mkdir(home, { recursive: true });
        // 600 because this is the operator's ChatGPT session sitting on a bind
        // mount, and the container side of it belongs to an agent running as root
        await Deno.writeTextFile(`${home}/auth.json`, auth, { mode: 0o600 });
        await Deno.writeTextFile(
          `${home}/config.toml`,
          `[mcp_servers.af]\ncommand = "node"\nargs = ["/ws/${task.id}/af-mcp.mjs"]\n`,
        );
        // Codex reads its global instructions from CODEX_HOME, so this is a copy
        // rather than the read-only mount its skills get — and it is where both
        // appended prompts have to go, codex having no --append-system-prompt.
        // The tooling note is unconditional for the same reason it is on the
        // claude side: it describes this container, which exists either way.
        const hosted = task.request.hostAgentConfig !== false
          ? `${await Deno.readTextFile(`${Deno.env.get("HOME")}/.codex/AGENTS.md`)
            .catch(() => "")}\n\n${HOUSE_STYLE}\n`
          : "";
        await Deno.writeTextFile(
          `${home}/AGENTS.md`,
          `${hosted}\n${SCHEDULING}\n\n${tooling(task.id)}\n`,
        );
      },
      catch: (e) => new WorkflowError({ message: `could not install the task harness: ${e}` }),
    });
  });

/**
 * Agents publish by appending to a spool on the workspace mount; this folds
 * whatever is there into the task's event stream. Only whole lines are taken —
 * a trailing partial write belongs to an append still in flight and is picked
 * up by the next drain.
 *
 * Every field is re-derived rather than trusted: the spool is a plain file in
 * a container the agent controls, so `seq`, `at` and `urgent` are the engine's
 * to assign, and the message is capped here as well as in the tool, since a
 * direct write bypasses the tool's own check.
 */
const EVENT_MESSAGE_MAX = 16000;

const drainOutbox = (
  task: TaskRecord,
  publish: EngineCallbacks["publish"],
  request: EngineCallbacks["request"],
) =>
  Effect.promise(async () => {
    const path = `${stateDir()}/ws/${task.id}/outbox.jsonl`;
    const text = await Deno.readTextFile(path).catch(() => undefined);
    if (text === undefined) return;
    const offset = task.outboxOffset ?? 0;
    const end = text.slice(offset).lastIndexOf("\n");
    if (end < 0) return;
    const chunk = text.slice(offset, offset + end);
    task.outboxOffset = offset + end + 1;

    const strings = (v: unknown) =>
      Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && !!x) : undefined;
    for (const line of chunk.split("\n")) {
      if (!line.trim()) continue;
      let ev: Record<string, unknown>;
      try {
        ev = JSON.parse(line);
      } catch {
        continue;
      }
      /**
       * A line can ask for something rather than say something. The reply goes
       * back as an event addressed to the node that asked, which is the only
       * channel there is — the tool that wrote the line was answered the moment
       * it wrote it, long before anything here ran.
       */
      const op = typeof ev.op === "string" && ev.op !== "emit" ? ev.op : undefined;
      const elsewhere = typeof ev.task === "string" && ev.task && ev.task !== task.id;
      if (op || elsewhere) {
        const asker = typeof ev.from === "string" && ev.from ? ev.from : "*";
        /**
         * Keyed by the spawn key so deliverable collapses the acks: a sweep
         * re-asserting its whole set every lap gets one "already exists" per
         * child per lap, and without a key each of those survives into every
         * later cold visit of the asker. The latest ack per child is the whole
         * truth, and a refusal a later lap resolved collapses away under it.
         * Keyless spawns each name a distinct child, so their acks stay.
         */
        const ackKey = op === "spawn" && typeof ev.key === "string" && ev.key
          ? `spawn:${ev.key}`
          : undefined;
        try {
          const result = request(op ?? "emit", ev);
          publish({ kind: "control", from: "agentflow", to: asker, message: result, key: ackKey });
        } catch (e) {
          publish({
            kind: "error",
            from: "agentflow",
            to: asker,
            key: ackKey,
            message: `${op ?? "emit"} was refused: ${e instanceof Error ? e.message : String(e)}`,
          });
        }
        continue;
      }
      const message = typeof ev.message === "string" ? ev.message.trim() : "";
      if (!message) continue;
      const to = typeof ev.to === "string" ? ev.to : strings(ev.to);
      publish({
        kind: typeof ev.kind === "string" && ev.kind ? ev.kind : "handoff",
        from: typeof ev.from === "string" ? ev.from : undefined,
        to: to === undefined || (Array.isArray(to) && !to.length) ? "*" : to,
        message: message.length > EVENT_MESSAGE_MAX
          ? `${
            message.slice(0, EVENT_MESSAGE_MAX)
          }\n[… truncated by agentflow at ${EVENT_MESSAGE_MAX} chars …]`
          : message,
        refs: strings(ev.refs),
        key: typeof ev.key === "string" && ev.key ? ev.key : undefined,
      });
    }
  });

/**
 * How a delivered event reaches a prompt. `refs` are printed, never fetched:
 * a reader that cares follows them, and one that does not pays for a path
 * instead of a file.
 */
const renderEvent = (ev: TaskEventRecord): string => {
  const head = `- ${ev.from ?? "system"} · ${ev.kind}: ${ev.message}`;
  return ev.refs?.length ? `${head}\n  refs: ${ev.refs.join("  ")}` : head;
};

/**
 * Record the node process's pid inside the container so a cancel can kill the
 * real process. Killing the local `docker exec` client does not signal the
 * remote process — it keeps running, detached, and a later resume would then
 * contend with it on the same claude session.
 */
const withPidfile = (pidfile: string, cmd: string[]) => [
  "sh",
  "-c",
  'echo $$ > "$1"; shift; exec "$@"',
  "sh",
  pidfile,
  ...cmd,
];

/**
 * Kill a pid and everything below it. Walks /proc rather than calling pkill/ps:
 * the task image has neither, and killing only the pid leaves the agent's own
 * subprocesses orphaned and still running.
 *
 * Takes the pid, not the pidfile it was recorded in. Reading the file here is
 * what let a stopped turn keep running: the pidfile lives on the workspace bind
 * mount and the visit's own cleanup unlinks it, so `cat` inside the container
 * raced a `Deno.remove` on the host that had a full `docker exec` startup of a
 * head start. It lost every time, the script read an empty pid and exited 0
 * reporting nothing, and the agent went on billing — measured once at 255M
 * tokens over the 2h47m before the operator's quota ran out.
 */
const KILL_TREE = `
p=$1; [ -n "$p" ] || exit 0
targets=$p; queue=$p; depth=0
while [ -n "$queue" ] && [ $depth -lt 12 ]; do
  depth=$((depth+1)); next=
  for d in /proc/[0-9]*; do
    [ -r "$d/status" ] || continue
    ppid=
    while read -r k v _; do case $k in PPid:) ppid=$v; break;; esac; done < "$d/status"
    for q in $queue; do
      if [ "$ppid" = "$q" ]; then
        pid=\${d#/proc/}; targets="$targets $pid"; next="$next $pid"
      fi
    done
  done
  queue=$next
done
kill $targets 2>/dev/null
sleep 2
kill -9 $targets 2>/dev/null
exit 0`;

const killNodeProcess = (container: string, pid: string): Promise<void> =>
  new Deno.Command("docker", {
    args: ["exec", container, "sh", "-c", KILL_TREE, "sh", pid],
    stdout: "null",
    stderr: "null",
  }).output().then(() => {}).catch(() => {});

/**
 * The pid of a node's turn, read from the host side of the workspace mount.
 * Synchronous on purpose: the callers run as finalizers, and the one that
 * deletes this file is the next finalizer along.
 */
const turnPid = (taskId: string, node: string, visit: number): string => {
  try {
    return Deno.readTextFileSync(`${stateDir()}/ws/${taskId}/${scratchFile("pid", node, visit)}`)
      .trim();
  } catch {
    // the turn never got as far as recording one, or its cleanup already ran
    return "";
  }
};

/** kill this node's turn inside the container; resolves once it is gone */
const killTurn = (container: string, taskId: string, node: string, visit: number) => {
  const pid = turnPid(taskId, node, visit);
  return pid ? killNodeProcess(container, pid) : Promise.resolve();
};

/**
 * Per-visit scratch files on the workspace mount, named here because both sides
 * of that mount build the paths and they drifted once already: the pidfile went
 * from per-node to per-visit and the wedge watchdog kept probing the old name,
 * so the check that exists to tell a stuck turn from a slow one read `cat` on a
 * path that never existed and answered "gone" every time — killing healthy nodes
 * that were merely quiet inside a long build. Callers add their own prefix,
 * `/ws/<id>` from inside the container and `<stateDir>/ws/<id>` from the host.
 */
export const scratchFile = (kind: "pid" | "reply", node: string, visit: number) =>
  `.${kind}-${node}-${visit}`;

/**
 * Kill whatever this task left running in its container, for the paths that
 * cannot name it: a stop, a teardown, a daemon shutdown.
 *
 * Deliberately not the pidfiles. They are per-visit and the visit deletes its
 * own on the way out, so a sweep that reads them finds nothing precisely when
 * it matters — the process that outlives its turn is the one no file points at
 * any more. Everything in a task container belongs to the task, so the sweep is
 * everything but pid 1, which is the `sleep infinity` the container is built
 * around, and this shell, which would otherwise kill itself before the SIGKILL
 * pass.
 */
export const killTaskProcesses = async (container: string) => {
  await new Deno.Command("docker", {
    args: [
      "exec",
      container,
      "sh",
      "-c",
      `self=$$
targets=
for d in /proc/[0-9]*; do
  pid=\${d#/proc/}
  [ "$pid" = 1 ] && continue
  [ "$pid" = "$self" ] && continue
  targets="$targets $pid"
done
kill $targets 2>/dev/null
sleep 2
kill -9 $targets 2>/dev/null
exit 0`,
    ],
    stdout: "null",
    stderr: "null",
  }).output().catch(() => {});
};

// Outputs beyond this size are not injected into prompts verbatim — that
// bloats the context and the bill. The template var then carries excerpts
// plus a pointer at the file.
const INJECT_LIMIT = 4000;

/**
 * A node's output goes to the refs directory when something will actually reach
 * for it: it is too big to inline in a prompt, or it is being announced and the
 * announcement cannot carry the whole thing.
 *
 * It used to be written unconditionally, on the reasoning that an event's shape
 * is a brief message pointing at where the detail lives, so a ref that existed
 * only above 4KB would be a ref that usually wasn't there. That holds for an
 * output the message truncates. It does not hold for `ROUTE: idle` — the
 * message already contains every byte, and a poll node inside a watch loop was
 * leaving a 20-byte file behind on every lap, for as long as the task lived.
 */
const recordOutput = (
  task: TaskRecord,
  nodeId: string,
  visit: number,
  text: string,
  /** what the stream will say about this output, or undefined if nothing will */
  announcement: string | undefined,
): Effect.Effect<{ inline: string; ref?: string }, never> =>
  Effect.gen(function* () {
    // compared flattened, because that is the shape the message quotes it in.
    // The exact text with its newlines is still on the record and still what
    // {{thisNode}} injects; what is being decided here is only whether a reader
    // of the event has anywhere left to go.
    const spoken = announcement?.includes(text.trim().replace(/\s+/g, " ")) ?? true;
    if (text.length <= INJECT_LIMIT && spoken) return { inline: text };
    const hostDir = `${stateDir()}/ws/${task.id}/refs`;
    const file = `${nodeId}-${visit}.txt`;
    const path = `/ws/${task.id}/refs/${file}`;
    const written = yield* Effect.promise(() =>
      Deno.mkdir(hostDir, { recursive: true })
        .then(() => Deno.writeTextFile(`${hostDir}/${file}`, text))
        .then(() => true, () => false)
    );
    const ref = written ? path : undefined;
    if (text.length <= INJECT_LIMIT) return { inline: text, ref };
    if (!ref) return { inline: text.slice(0, INJECT_LIMIT), ref };
    return {
      inline: `${text.slice(0, 1500)}
[… output truncated: ${text.length} chars total. Full output saved to ${path} — inspect it with rg/sed/tail as needed …]
${text.slice(-1500)}`,
      ref,
    };
  });

/**
 * What a node's completion says on the stream. Brief on purpose: the label and
 * a sentence or two, with the whole output one ref away. A schema node already
 * writes the sentence — its `summary` field exists to be the first thing the
 * next agent reads — so use it; anything else gets the head of its output.
 */
const briefOutput = (outcome: string, data: unknown, text: string): string => {
  const said = (data as Record<string, unknown> | undefined)?.summary;
  if (typeof said === "string" && said.trim()) return `${outcome} — ${said.trim()}`;
  const head = text.trim().replace(/\s+/g, " ").slice(0, 400);
  return head ? `${outcome} — ${head}${text.trim().length > 400 ? "…" : ""}` : outcome;
};

/**
 * Where a wait node parks, and for how long. The deadline is absolute so a host
 * that slept through it wakes up already due, and the attempt counter lives on
 * the task so the backoff survives the park being rebuilt every lap.
 */
const planPark = (task: TaskRecord, node: WorkflowNode): WaitState => {
  const spec = node.wait ?? {};
  const now = Date.now();
  task.waitAttempts ??= {};
  const arrivedWith = task.runs.at(-1)?.status;
  if (arrivedWith && spec.after?.resetOn?.includes(arrivedWith)) task.waitAttempts[node.id] = 0;
  const attempt = task.waitAttempts[node.id] ?? 0;
  return {
    node: node.id,
    reason: spec.ask ? "human" : spec.on?.length ? "event" : "timer",
    since: new Date(now).toISOString(),
    until: spec.after ? new Date(now + backoffMs(spec.after, attempt)).toISOString() : undefined,
    attempt,
    ask: spec.ask,
  };
};

/** how a resolved wait reads on the board and in the next agent's events */
const describeWake = (wait: WaitState, label: string): string => {
  const waited = formatDuration(Date.now() - new Date(wait.since).getTime());
  const by = wait.resolvedBy ?? "unknown";
  return `${label} — woke on ${by} after ${waited} parked${
    wait.reason === "human" ? "" : ` (${wait.reason})`
  }`;
};

export const runWorkflow = (
  task: TaskRecord,
  cb: EngineCallbacks,
): Effect.Effect<"succeeded" | "failed" | "waiting", ExecError | WorkflowError> =>
  Effect.gen(function* () {
    const container = task.container!;
    const cwd = task.cwd!;
    yield* installHarness(task);
    const visits = new Map<string, number>();
    // continue visit numbering across revives so history is never overwritten
    for (const r of task.runs) {
      visits.set(r.node, Math.max(visits.get(r.node) ?? 0, r.visit));
    }
    // maxVisits budgets this run only; a revive gets a fresh allowance
    const runCounts = new Map<string, number>();
    task.outputs ??= {};
    task.data ??= {};
    task.sessions ??= {};
    task.cursors ??= {};
    // records written before sessions were keyed carried a single task session
    if (task.session && !task.sessions.coder) {
      task.sessions.coder = { id: task.session, started: true };
    }

    let currentId: string | undefined = task.checkpoint?.node ??
      task.workflow.start ?? task.workflow.nodes[0]?.id;

    while (currentId) {
      // re-read every iteration: the workflow can be edited mid-run, and a
      // rerun can move the checkpoint while we were between nodes
      const wf = task.workflow;
      const raw = wf.nodes.find((n) => n.id === currentId);
      if (!raw) return yield* new WorkflowError({ message: `unknown node "${currentId}"` });
      const node = normalizeNode(raw);

      const visit = (visits.get(node.id) ?? 0) + 1;
      const ceiling = node.maxVisits ?? 10;
      const runCount = (runCounts.get(node.id) ?? 0) + 1;
      if (ceiling !== 0 && runCount > ceiling) {
        return yield* new WorkflowError({
          message: `node "${node.id}" exceeded maxVisits (${ceiling})`,
        });
      }

      // checkpoint before executing: a stop mid-node resumes at this node
      task.checkpoint = { node: node.id };

      /**
       * A wait node runs no process. Its two states are parked — persist what it
       * is waiting for and hand the fiber back, which is what lets a task idle
       * for weeks at no cost — and resolved, where whatever woke it becomes the
       * outcome label and the graph routes on it like any other.
       */
      if (node.exec === "wait") {
        const parked = task.wait?.node === node.id ? task.wait : undefined;
        if (!parked?.resolved) {
          task.wait = parked ?? planPark(task, node);
          return "waiting";
        }
        const label = parked.resolved;
        task.wait = undefined;
        visits.set(node.id, visit);
        runCounts.set(node.id, runCount);
        const output = describeWake(parked, label);
        task.outputs[node.id] = output;
        cb.emitNode({
          node: node.id,
          visit,
          status: label,
          startedAt: parked.since,
          finishedAt: new Date().toISOString(),
          output,
        });
        cb.publish({
          kind: "wake",
          from: node.id,
          to: "*",
          key: `output:${node.id}`,
          message: output,
        });
        const waitEdge = wf.edges.find((e) => e.from === node.id && (e.when ?? "ok") === label);
        if (!waitEdge || waitEdge.to.startsWith("@")) {
          task.checkpoint = undefined;
          if (waitEdge) return waitEdge.to === "@succeeded" ? "succeeded" : "failed";
          return (wf.successLabels ?? ["ok", "approve"]).includes(label) ? "succeeded" : "failed";
        }
        currentId = waitEdge.to;
        continue;
      }

      /**
       * Money and slots are the caller's to know about. A refusal here is not a
       * failure — the node has not run — so the task parks in front of it and
       * comes back when the window rolls or a slot frees.
       */
      const denied = cb.admit(node);
      if (denied) {
        task.wait = {
          node: node.id,
          reason: denied.reason,
          since: new Date().toISOString(),
          until: denied.until,
          ask: denied.message,
        };
        return "waiting";
      }

      visits.set(node.id, visit);
      runCounts.set(node.id, runCount);

      const commit = yield* snapshotCommit(task);
      const run: NodeRun = {
        node: node.id,
        visit,
        status: "running",
        startedAt: new Date().toISOString(),
        output: "",
        commit,
      };

      const nodeAbort = new AbortController();
      cb.onNodeStart(nodeAbort);

      const sessionKey = node.session ?? "none";
      const persistent = isAgentExec(node.exec) && sessionKey !== "none";
      const agent = resolveAgent(node, wf, task.request);
      let session = persistent ? task.sessions[sessionKey] : undefined;
      if (persistent && !session) {
        session = task.sessions[sessionKey] = {
          // claude is told the id; codex reports the one it chose, so its thread
          // has no id here until the first turn has run
          id: node.exec === "codex" ? undefined : crypto.randomUUID(),
          started: false,
          nodes: [],
        };
      }
      // records written before the thread tracked who had spoken on it: the
      // nodes sharing this key that already have runs behind them are the ones
      if (session && !session.nodes) {
        session.nodes = [...new Set(task.runs.map((r) => r.node))].filter((id) => {
          const other = wf.nodes.find((n) => n.id === id);
          return other && normalizeNode(other).session === sessionKey;
        });
      }

      /**
       * A revisit gets only the delta; the thread already has the task. What
       * counts as a revisit is per node and not per session, because the two
       * came apart the moment a node joined a thread another node had opened:
       * `polish` and `ship` were follow-ups on their very first visit, so both
       * had to set `followUp` to the entire brief just to have it delivered
       * once — which then re-sent that brief on every later visit, for the life
       * of the pull request.
       *
       * `run` is optional only because wait nodes have nothing to run, and
       * those returned above.
       */
      const returning = Boolean(session?.started) && (session?.nodes?.includes(node.id) ?? false);
      const delta = returning && node.followUp !== undefined;
      const tpl = (delta ? node.followUp : node.run) ?? "";

      /**
       * On a delta turn, another node's output is worth sending only if it
       * landed since this node last ran — everything older is already in the
       * thread, and re-sending it hides which half of the prompt is new. A
       * loop back from a failed gate would otherwise hand the implementer the
       * review it already acted on. The current run is not in `task.runs` yet,
       * so this index is the previous visit.
       *
       * Only on delta turns: a full `run` template is the whole scaffold, and
       * a cold-session node re-reading it has no thread to have seen anything
       * in, so every reference it names has to arrive.
       */
      const lastRunOf = (id: string) => task.runs.findLastIndex((r) => r.node === id);
      const fresh = <T>(source: Record<string, T>): Record<string, T> => {
        if (!delta) return source;
        const since = lastRunOf(node.id);
        return Object.fromEntries(
          Object.entries(source).filter(([id]) => lastRunOf(id) > since),
        ) as Record<string, T>;
      };

      const vars = {
        task: task.request.task,
        gates: task.request.gates ?? "",
        // wrapped here rather than in the templates so a task with no rubric
        // renders no empty heading — an unused section is prompt noise every
        // node pays for
        rubric: task.request.rubric
          ? `\n[rubric — the standards this work is held to]\n${task.request.rubric}\n`
          : "",
        ...fresh(task.outputs),
      };

      // whatever the last node published lands on the stream before this one's
      // prompt is built, which is the whole handoff: an agent emits mid-turn
      // and the next node reads it here
      yield* drainOutbox(task, cb.publish, cb.request);

      /**
       * Events addressed to this node. A persistent thread was told everything
       * up to its cursor and still has it, so it gets only what arrived since;
       * a cold session has been told nothing, so it gets the lot, every visit.
       *
       * The cursor advances at send time, not on success: the block is in the
       * session transcript the moment the turn starts, so an interrupted turn
       * must not be handed the same events again as though they were new.
       */
      let eventBlock = "";
      let delivered: TaskEventRecord[] = [];
      if (isAgentExec(node.exec) && (node.events ?? node.notes) !== false) {
        delivered = cb.deliverable(node, persistent ? task.cursors[sessionKey] ?? 0 : 0);
        if (delivered.length) {
          eventBlock = "\n\n[events] published by the rest of this task, oldest first. Nothing " +
            `behind a\nref has been fetched for you; what this task's agents write for each ` +
            `other is\nunder /ws/${task.id}/refs.\n` + delivered.map(renderEvent).join("\n");
          if (persistent) task.cursors[sessionKey] = delivered.at(-1)!.seq;
        }
      }

      // Only on a full turn, like the map below: this is a standing fact about
      // the node, and a thread that has been told it once still has it. A node
      // whose session is cold is told every visit, because that thread has not.
      const effectsClause = isAgentExec(node.exec) && node.effects === "external" && !delta
        ? IDEMPOTENCE_CLAUSE
        : "";
      // Only on a full turn: a delta turn's thread already carries the map,
      // and a graph the operator edited mid-task takes effect at the next cold
      // turn rather than contradicting what this thread was already told.
      const graphBlock = isAgentExec(node.exec) && !delta && task.workflow.nodes.length > 1
        ? describeWorkflow(task.workflow, node.id)
        : "";
      // meta is not a node's output, so it is never "fresh": a follow-up that
      // asks for {{meta.pr}} wants the value, whenever it was recorded
      const rendered = template(tpl, vars, { ...fresh(task.data), meta: task.meta ?? {} }) +
        graphBlock + eventBlock +
        effectsClause +
        // agents only, like every other block appended here: a shell node's
        // rendered string is the command, so an instruction block on the end of
        // it is executed rather than read. Shell nodes still get their contract
        // validated — they just cannot be told about it.
        (isAgentExec(node.exec) && node.outcome ? contractBlock(node.outcome, delta) : "");
      run.prompt = rendered.slice(0, 16 * 1024);
      if (delivered.length) run.events = [delivered[0].seq, delivered.at(-1)!.seq];
      cb.emitNode({ ...run });

      // Nix reads modified tracked files straight from the worktree, so only
      // paths the previous node created need staging for this node's gates to
      // see them — but a file nix cannot see fails the build with no visible
      // cause, and after the first pass this is a stat walk costing a few
      // milliseconds.
      if (task.request.repo) {
        yield* dockerExec(container, cwd, ["git", "add", "-A"]).pipe(Effect.ignore);
      }

      /**
       * Per visit, not per node. Cancelling a node kills its process tree
       * through a fire-and-forget `docker exec` that reads this file and, two
       * seconds later, sends SIGKILL — while the engine has already looped round
       * and started the node again. Sharing one path per node meant that second
       * signal read the *new* run's pid and killed it, so every urgent interject
       * cancelled the turn it was meant to interrupt and then failed its
       * replacement. A stale kill now finds a pid that is already gone.
       */
      const pidfile = `/ws/${task.id}/${scratchFile("pid", node.id, visit)}`;
      /**
       * Per visit, like the pidfile, and for a milder version of the same
       * reason: a retried visit reading the previous one's file would take a
       * reply that was already rejected as this one's answer.
       */
      const lastMessage = `/ws/${task.id}/${scratchFile("reply", node.id, visit)}`;
      const baseCmd = node.exec === "shell" ? ["sh", "-c", rendered] : agentCmd(task, node, agent, {
        prompt: rendered,
        // a thread that exists is continued; one that does not is opened
        // under the id claude was given, or left for codex to name
        ...(session?.started ? { resume: session.id } : { open: session?.id }),
        lastMessage,
      });
      // both at send time rather than on success, for the same reason the event
      // cursor advances there: the turn is in the session transcript the moment
      // it starts, so an interrupted node must not be handed the whole brief
      // again as though the thread had never heard it
      if (session) {
        session.started = true;
        session.nodes ??= [];
        if (!session.nodes.includes(node.id)) session.nodes.push(node.id);
      }

      /**
       * The emit tool is a child of claude, so it inherits these: where to
       * spool, and which node it is publishing as. Shell nodes get them too —
       * the spool is a JSONL file and every field is re-derived host-side, so a
       * `>> $AF_OUTBOX` from a shell node is the same publish an agent makes,
       * and a poll node that noticed something is exactly the case for it.
       */
      const childWorkflows = Object.keys(task.request.childWorkflows ?? {});
      const nodeEnv: Record<string, string> = {
        AF_OUTBOX: `/ws/${task.id}/outbox.jsonl`,
        AF_NODE: node.id,
        AF_REFS: `/ws/${task.id}/refs`,
        AF_ARTIFACTS: `/ws/${task.id}/artifacts`,
        AF_TASK: task.id,
        // named in the emit tool's own description, so an agent is told which
        // other task it may reach rather than finding out by being refused
        ...(task.request.parent ? { AF_PARENT: task.request.parent } : {}),
        // Same reason: the spawn tool offers these alongside the bundled names
        // rather than leaving an agent to guess one. Names only, and the host
        // re-checks every one against this task's own declarations when the
        // spool is drained — this is here to be read, not believed.
        ...(childWorkflows.length ? { AF_CHILD_WORKFLOWS: JSON.stringify(childWorkflows) } : {}),
        // codex takes effort as a config override on the command line; claude
        // reads it from here, and it is per node rather than per container so a
        // graph can think hard about its review and not about its formatting
        ...(node.exec === "claude" && agent.effort
          ? { CLAUDE_CODE_EFFORT_LEVEL: agent.effort }
          : {}),
      };

      // the in-container process must die with the cancel, not just the client
      nodeAbort.signal.addEventListener(
        "abort",
        () => void killTurn(container, task.id, node.id, visit),
        { once: true },
      );

      // full transcript on disk for the dashboard's "everything" mode
      const logDir = `${stateDir()}/logs/${task.id}`;
      yield* Effect.promise(() => Deno.mkdir(logDir, { recursive: true }));
      const logFile = yield* Effect.promise(() =>
        Deno.open(`${logDir}/${node.id}-${visit}.log`, {
          create: true,
          write: true,
          truncate: true,
        })
      );
      const logEnc = new TextEncoder();
      const onChunk = (chunk: string) => {
        // emitLog is also how the watchdog learns this run is still talking; a
        // turn producing nothing at all for half an hour is the only visible
        // difference between wedged and slow
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
        const exec_ = dockerExec(
          container,
          cwd,
          withPidfile(pidfile, args),
          onChunk,
          nodeAbort.signal,
          nodeEnv,
        );
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

      /**
       * A reply that misses its schema is malformed, not failed: the same
       * session is told exactly what was wrong and asked for the object
       * again. Each correction REPLACES the previous reply rather than being
       * appended to it — that is only sound because the contract makes the
       * object self-contained. The old last-line convention appended, so
       * correcting a bad verdict line returned a bare verdict and silently
       * dropped the review it belonged to.
       */
      const contract = node.outcome;
      /**
       * Read once per turn and immediately: the path is per visit, so what is
       * there belongs to the turn that just ended, and a correction overwrites
       * it. Absent when the turn was killed before it could write.
       */
      const takeLastMessage = () =>
        Effect.promise(() =>
          Deno.readTextFile(`${stateDir()}/ws/${task.id}/${scratchFile("reply", node.id, visit)}`)
            .catch(() => undefined)
        );
      const nodeExec = Effect.gen(function* () {
        let r = yield* runOnce(baseCmd);
        let transcript = r.output;
        let summary = summarize(node, r.output, yield* takeLastMessage());
        // The thread codex opened for itself, learned only now. Recorded before
        // any early return, so a node that failed its gate still resumes the
        // conversation it had rather than starting one that has never heard of
        // the work it is being asked to fix.
        // r.head, not r.output: the announcement is the first line of the
        // stream and the tail is capped, so a turn longer than the cap had
        // already thrown it away by the time this ran.
        if (session && node.exec === "codex") session.id ??= extractSessionId(node, r.head);
        if (!contract || contract.kind !== "schema" || r.code !== 0) {
          return { code: r.code, transcript, summary, data: undefined, label: undefined };
        }

        // only an agent can be asked to try again; a shell node's output is
        // whatever the command printed, so it gets one shot and the fallback
        const retries = isAgentExec(node.exec) ? contract.retries ?? 2 : 0;
        let check = checkSchema(contract, summary);
        for (
          let attempt = 1;
          check.errors.length && attempt <= retries && !nodeAbort.signal.aborted && r.code === 0;
          attempt++
        ) {
          onChunk(
            `\n[agentflow] node "${node.id}" reply did not satisfy its output contract:\n` +
              check.errors.map((e) => `  - ${e}`).join("\n") +
              `\n[agentflow] requesting correction (${attempt}/${retries})\n`,
          );
          // The id the session already knows beats re-deriving it, and beats it
          // for claude too, which was handed its id rather than announcing one.
          // Falling back to the head rather than the tail for the same reason as
          // above: a node with no persistent session only ever said it up front.
          const sid = session?.id ?? extractSessionId(node, r.head);
          const correction = `Your previous reply did not satisfy the output contract:
${check.errors.map((e) => `  - ${e}`).join("\n")}

Reply again with the COMPLETE JSON object. This correction replaces your
entire previous reply, so send every field — not only the ones that were
wrong. Output the object and nothing else.`;
          // No thread flag on the fallback, deliberately: without an id there is
          // no conversation to correct, so the turn is the whole prompt again
          // with the complaint on the end rather than a bare demand for JSON.
          const retry = yield* runOnce(
            agentCmd(
              task,
              node,
              agent,
              sid
                ? { prompt: correction, resume: sid, lastMessage }
                : { prompt: rendered + "\n\n" + correction, lastMessage },
            ),
          );
          r = retry;
          transcript = (transcript + "\n" + retry.output).slice(-OUTPUT_CAP);
          summary = summarize(node, retry.output, yield* takeLastMessage());
          check = checkSchema(contract, summary);
        }
        return { code: r.code, transcript, summary, data: check.data, label: check.label };
      });

      const res = yield* nodeExec.pipe(
        // a stop or a timeout interrupts the fiber, which kills the local
        // `docker exec` client but leaves the process inside the container
        // running — it must die too, or a resume contends with it. Awaited, so
        // the pidfile cleanup below cannot outrun it and a task that reads
        // "stopped" has actually stopped.
        Effect.onInterrupt(() => Effect.promise(() => killTurn(container, task.id, node.id, visit))),
        Effect.ensuring(Effect.sync(() => {
          try {
            logFile.close();
          } catch {
            // already closed
          }
          // one file per visit would otherwise accumulate for the life of a
          // watch loop; the workspace is a bind mount, so the host can drop it
          const ws = `${stateDir()}/ws/${task.id}`;
          Deno.remove(`${ws}/${scratchFile("pid", node.id, visit)}`).catch(() => {});
          Deno.remove(`${ws}/${scratchFile("reply", node.id, visit)}`).catch(() => {});
        })),
      );

      // again after the turn, so what this node published is on the stream
      // before anything routes off its result — including for the last node of
      // a graph, which has no next iteration to drain it
      yield* drainOutbox(task, cb.publish, cb.request);

      // a validated object reads far better than its json, both in the
      // dashboard and when injected into the next node's prompt
      const summary = res.data !== undefined ? renderData(res.data) : res.summary;

      // operator interrupted this node: re-run it (undelivered notes and the
      // cold-session note block reach the re-run's prompt)
      if (nodeAbort.signal.aborted) {
        cb.emitNode({
          ...run,
          status: "cancelled",
          finishedAt: new Date().toISOString(),
          exitCode: res.code,
          output: summary,
        });
        continue;
      }

      const pattern = res.code === 0 && contract?.kind === "pattern"
        ? patternLabel(contract, summary)
        : undefined;
      const outcome = res.code !== 0
        ? "fail"
        : !contract
        ? "ok"
        : contract.kind === "schema"
        ? res.label ?? contract.fallback ?? "fail"
        : pattern?.label ?? contract.fallback ?? "fail";
      // routing on a fallback is a guess, and a silent one is indistinguishable
      // from the contract working — say it where the operator reads the node
      if (pattern?.miss) {
        onChunk(
          `\n[agentflow] node "${node.id}" outcome contract did not match: ${pattern.miss}\n` +
            `[agentflow] routing on the fallback label "${outcome}"\n`,
        );
      }
      /**
       * Every node announces what it produced, unless its author said not to.
       * Wiring a template var was the only way a node learned what another had
       * done, so anything the graph's author didn't think to connect went
       * nowhere — the coordination problem the stream exists to fix, left in
       * place for the outputs that matter most.
       *
       * The message stays short and the output rides behind the ref, which is
       * what makes broadcasting-by-default affordable at all. Keyed per node,
       * so an agent arriving in round five reads where review landed rather
       * than all five rounds of it — and a watch loop on its four hundredth lap
       * delivers one line, not four hundred. Template vars keep their job: news
       * is pushed, but a node acting on one specific field still pulls it —
       * {{review.blocking}} is a work order, not an announcement.
       *
       * `announce: false` is for a node whose result is only how the graph
       * routes. Nothing downstream reads `ROUTE: idle`, so the line it costs in
       * every later prompt buys nothing — and with no announcement there is
       * nothing for a ref to be the detail of, so the output stops being
       * written to the refs directory too.
       */
      const announcement = node.announce === false
        ? undefined
        : briefOutput(outcome, res.data, summary);
      // Only nodes that ran something reach here — a wait node never does, so a
      // watch loop ticking for weeks does not pay for this on every lap.
      const undone = yield* guardRepoRemotes(task);
      if (undone.length) {
        cb.publish({
          kind: "control",
          from: "agentflow",
          to: "*",
          message: `a container edited ${task.request.repo}'s git remotes, which a jj workspace ` +
            `shares with the operator's repo; put back: ${undone.join("; ")}`,
          urgent: true,
        });
      }
      const recorded = yield* recordOutput(task, node.id, visit, summary, announcement);
      task.outputs[node.id] = recorded.inline;
      if (res.data !== undefined) task.data[node.id] = res.data;
      if (announcement !== undefined) {
        cb.publish({
          kind: contract?.kind === "schema" ? "verdict" : "output",
          from: node.id,
          to: "*",
          key: `output:${node.id}`,
          message: announcement,
          refs: recorded.ref ? [recorded.ref] : undefined,
        });
      }

      cb.emitNode({
        ...run,
        status: outcome,
        finishedAt: new Date().toISOString(),
        exitCode: res.code,
        output: summary,
        data: res.data,
        llm: node.exec === "shell"
          ? undefined
          : extractLlm(node, res.transcript, agent.model, session),
      });

      // force a working-copy snapshot so the host sees the agent's files immediately
      if (task.request.repo) {
        yield* dockerExec(container, cwd, ["jj", "st"]).pipe(Effect.ignore);
      }

      const success = wf.successLabels ?? ["ok", "approve"];
      const edge = wf.edges.find((e) => e.from === node.id && (e.when ?? "ok") === outcome);
      if (!edge || edge.to === "@succeeded" || edge.to === "@failed") {
        task.checkpoint = undefined;
        if (edge) return edge.to === "@succeeded" ? "succeeded" : "failed";
        return success.includes(outcome) ? "succeeded" : "failed";
      }
      currentId = edge.to;
    }
    task.checkpoint = undefined;
    return "failed";
  });
