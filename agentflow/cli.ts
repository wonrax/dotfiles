#!/usr/bin/env -S deno run --allow-net
/**
 * `af` — the agentflow command line.
 *
 * Built for two audiences with the same needs: a human checking on a task, and
 * a dispatcher agent that must decide what to do next without pulling a
 * hundred kilobytes of transcript into its context. Every command prints a
 * compact human view by default and accepts --json for exact data.
 */
import {
  connect,
  type TaskEventRecord,
  type TaskRecord,
  type TranscriptEvent,
} from "./sdk/standalone.ts";

const DAEMON = Deno.env.get("AGENTFLOW_URL") ?? "http://127.0.0.1:4200";
const af = connect(DAEMON);

// ---------------------------------------------------------------------------
// arg parsing

type Flag = string | boolean | string[];

interface Args {
  _: string[];
  flags: Record<string, Flag>;
}

const parse = (argv: string[]): Args => {
  const _: string[] = [];
  const flags: Record<string, Flag> = {};
  const set = (name: string, value: string | boolean) => {
    const had = flags[name];
    // A repeated flag collects instead of clobbering, because the one flag that
    // repeats (--child-workflow) is the one where a dropped earlier occurrence
    // means a graph the task was supposed to carry simply is not there, found
    // at a fan-out hours later. Everything else is single-valued and `checkFlags`
    // refuses the repeat outright rather than picking a winner.
    if (typeof value !== "string") flags[name] = value;
    else if (Array.isArray(had)) had.push(value);
    else if (typeof had === "string") flags[name] = [had, value];
    else flags[name] = value;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      _.push(a);
      continue;
    }
    const eq = a.indexOf("=");
    if (eq > 0) set(a.slice(2, eq), a.slice(eq + 1));
    else if (argv[i + 1] && !argv[i + 1].startsWith("--")) set(a.slice(2), argv[++i]);
    else set(a.slice(2), true);
  }
  return { _, flags };
};

const str = (v: Flag | undefined) => typeof v === "string" ? v : undefined;
const list = (v: Flag | undefined): string[] | undefined =>
  Array.isArray(v) ? v : typeof v === "string" ? [v] : undefined;
const num = (v: Flag | undefined) => {
  const s = str(v);
  return s === undefined ? undefined : Number(s);
};

class UserError extends Error {}
const out = (s: string) => console.log(s);
const jsonOut = (v: unknown) => console.log(JSON.stringify(v, null, 2));

/**
 * What each command actually reads, so a flag it does not know is refused
 * rather than dropped. `parse` takes anything into an untyped bag, and a
 * dropped flag is worst exactly where it matters most: an `af interject`
 * whose --urgent was misspelled prints the same "noted" as a real one and
 * then waits for the next node boundary instead of stopping the turn you
 * meant to stop. --json is global.
 */
const FLAGS: Record<string, string[]> = {
  ls: ["status"],
  show: [],
  log: ["context", "events", "grep", "index", "raw", "since", "summary", "tail"],
  wait: ["timeout", "until"],
  spawn: [
    "child-workflow",
    "effort",
    "file",
    "gates",
    "gh",
    "id",
    "idle-min",
    "key",
    "max-cost",
    "meta",
    "model",
    "repo",
    "retain",
    "rubric",
    "rubric-file",
    "setup",
    "setup-required",
    "task",
    "title",
    "workflow",
  ],
  stop: [],
  resume: [],
  budget: ["max-cost"],
  refs: ["all"],
  artifacts: [],
  meta: ["unset"],
  poke: ["force", "label"],
  approve: ["label", "message", "no", "yes"],
  rerun: ["force", "from", "message", "reset-workspace", "session"],
  interject: ["message", "target", "urgent"],
  emit: ["from", "key", "kind", "message", "refs", "to", "urgent"],
  task: ["interrupt", "message", "set"],
  workflow: ["interrupt", "set"],
  "child-workflows": ["drop", "set"],
  workflows: [],
  config: ["all"],
  cleanup: ["both", "container", "workspace"],
  rm: [],
  volumes: ["gc", "prune"],
  help: [],
};
FLAGS.events = FLAGS.log; // events forwards its flags to log

/**
 * Flags that mean something given more than once; every other repeat is a
 * mistake. Keyed by command rather than by flag name, because the same word is
 * a list under one command and a single value under another — `af
 * child-workflows --set` names one graph of several, `af workflow --set` names
 * the whole graph, and a global allowlist would quietly let the second be given
 * twice and take neither.
 */
const REPEATABLE: Record<string, Set<string>> = {
  spawn: new Set(["child-workflow", "meta"]),
  "child-workflows": new Set(["set", "drop"]),
  meta: new Set(["unset"]),
};

const checkFlags = (cmd: string, flags: Record<string, Flag>) => {
  const known = FLAGS[cmd];
  if (!known) return;
  for (const [flag, value] of Object.entries(flags)) {
    if (Array.isArray(value) && !REPEATABLE[cmd]?.has(flag)) {
      // said twice and taken once is the same silent drop as a misspelling,
      // and here the value that vanishes is one the operator typed on purpose
      throw new UserError(
        `--${flag} takes one value and was given ${value.length}: ${value.join(", ")}`,
      );
    }
    if (flag === "json" || known.includes(flag)) continue;
    // the same word under another command is the likely mistake, and saying so
    // beats a bare list the reader has to diff against what they typed
    const elsewhere = Object.entries(FLAGS)
      .filter(([other, fs]) => other !== cmd && fs.includes(flag))
      .map(([other]) => `af ${other}`);
    throw new UserError(
      `unknown flag --${flag}` +
        (elsewhere.length ? `; that one belongs to ${elsewhere.join(", ")}` : "") +
        `\ntakes: ${[...known, "json"].map((f) => `--${f}`).join(" ")}`,
    );
  }
};

// ---------------------------------------------------------------------------
// formatting

const AGE = (iso: string) => {
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 60) return `${Math.round(s)}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${(s / 3600).toFixed(1)}h`;
  return `${(s / 86400).toFixed(1)}d`;
};

const pad = (s: string, n: number) => s.length >= n ? s : s + " ".repeat(n - s.length);

const duration = (from: string, to?: string) => {
  const ms = new Date(to ?? new Date().toISOString()).getTime() - new Date(from).getTime();
  return ms < 1000
    ? `${ms}ms`
    : ms < 60_000
    ? `${(ms / 1000).toFixed(1)}s`
    : `${(ms / 60_000).toFixed(1)}m`;
};

const money = (n: number) => n >= 0.01 ? `$${n.toFixed(2)}` : `$${n.toFixed(4)}`;
const bytes = (n: number) =>
  n < 1024
    ? `${n} B`
    : n < 1024 ** 2
    ? `${(n / 1024).toFixed(1)} KiB`
    : `${(n / 1024 ** 2).toFixed(1)} MiB`;
/** key=value arguments into a bag; the daemon does the real validation */
const pairs = (items: string[], what: string): Record<string, string> => {
  const bag: Record<string, string> = {};
  for (const item of items) {
    const eq = item.indexOf("=");
    if (eq <= 0) throw new UserError(`${what} wants key=value, got "${item}"`);
    bag[item.slice(0, eq)] = item.slice(eq + 1);
  }
  return bag;
};

/**
 * Colour only into a terminal. Piping `af config <id>` into a file or another
 * program is a normal thing to do with it, and escape codes in that file are
 * noise the reader then has to strip.
 */
const COLOUR = (() => {
  try {
    return Deno.stdout.isTerminal() && !Deno.env.get("NO_COLOR");
  } catch {
    // env access is not granted in every way this CLI gets run
    return false;
  }
})();
const paint = (code: string) => (s: string) => COLOUR ? `\x1b[${code}m${s}\x1b[0m` : s;
const dim = paint("90");
const keyed = paint("36");
const numeric = paint("33");
const truthy = paint("35");
/** visible width of a coloured string, for lining up what sits under it */
// deno-lint-ignore no-control-regex -- stripping escape codes is the point
const bare = (s: string) => s.replaceAll(/\x1b\[[0-9;]*m/g, "");

/**
 * A record's configuration as something a person reads.
 *
 * `JSON.stringify(record, null, 2)` is unreadable for exactly this data: the
 * fields worth debugging are prompts and rubrics, which are paragraphs, and it
 * renders each of them as one enormous line with literal \n in it. So strings
 * that span lines become blocks, and everything else follows the shape of the
 * value rather than the punctuation of the format.
 *
 * `prefix` is what already sits on the first line — a `key:` or a list dash.
 */
const humanJson = (
  prefix: string,
  value: unknown,
  indent: string,
  out: string[],
  ride = false,
) => {
  const push = (s: string) => out.push(`${indent}${prefix}${s}`);
  if (value === null) return push(dim("null"));
  if (typeof value === "number") return push(numeric(String(value)));
  if (typeof value === "boolean") return push(truthy(String(value)));
  if (typeof value === "string") {
    if (!value.includes("\n")) return push(value === "" ? dim('""') : value);
    push(dim("|"));
    for (const line of value.replace(/\s+$/, "").split("\n")) out.push(`${indent}  ${line}`);
    return;
  }
  // a heading line only when there is something to head: the root has no key of
  // its own, and an empty line above the whole document is just an empty line
  const head = prefix.trimEnd();
  if (Array.isArray(value)) {
    if (!value.length) return push(dim("[]"));
    if (head) out.push(indent + head);
    for (const item of value) humanJson(dim("- "), item, head ? `${indent}  ` : indent, out, true);
    return;
  }
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined);
  if (!entries.length) return push(dim("{}"));
  if (ride) {
    // an object that IS a list item puts its first key on the dash, so a list of
    // nodes reads as a list of nodes rather than as dashes over indented blocks.
    // Only there: riding a `key:` would render `request: task: …`, which reads
    // as though task were all request had.
    const [[k0, v0], ...rest] = entries;
    humanJson(`${prefix}${keyed(k0)}: `, v0, indent, out);
    const deeper = indent + " ".repeat(bare(prefix).length);
    for (const [k, v] of rest) humanJson(`${keyed(k)}: `, v, deeper, out);
    return;
  }
  if (head) out.push(indent + head);
  const inner = head ? `${indent}  ` : indent;
  for (const [k, v] of entries) humanJson(`${keyed(k)}: `, v, inner, out);
};

/**
 * `--urgent` promises delivery now, and there are three parks it cannot honour:
 * a question only the operator answers, a ceiling only they raise, and a task
 * that is not running at all. In every one of them the flag used to be a silent
 * no-op — the event was published, the task went on sleeping, and nothing said
 * so until someone noticed hours later that nobody had read it.
 */
const reportUndelivered = (t: TaskRecord) => {
  if (t.status === "waiting" && t.wait) {
    out(
      `  NOT delivered: parked on ${t.wait.reason} at ${t.wait.node}, which an event cannot clear`,
    );
    out(
      `  ${
        t.wait.reason === "human"
          ? `af approve ${t.id} --label <...>`
          : `af poke ${t.id}${t.wait.reason === "budget" ? " --force" : ""}`
      }`,
    );
  } else if (["succeeded", "failed", "stopped"].includes(t.status)) {
    out(`  NOT delivered: ${t.id} is ${t.status}. af interject revives a task; af emit does not`);
  }
};

const summarizeTask = (t: TaskRecord, events: TaskEventRecord[] = []): string => {
  const lines: string[] = [];
  const cost = t.runs.reduce((s, r) => s + (r.llm?.costUsd ?? 0), 0);
  lines.push(`${t.id}  ${t.status}${t.error ? `  (${t.error.split("\n")[0]})` : ""}`);
  if (t.request.title) lines.push(`  title     ${t.request.title}`);
  lines.push(`  task      ${t.request.task.replace(/\s+/g, " ").slice(0, 160)}`);
  if (t.request.repo) {
    lines.push(`  repo      ${t.request.repo}${t.base ? `   base ${t.base}` : ""}`);
  }
  /**
   * A prewarm that failed and was not marked required leaves a task whose gates
   * are already doomed, and it says so once on an event stream that ends in the
   * hundreds. This is the screen someone actually looks at, so it says so here
   * for as long as the task exists.
   */
  if (t.setupExit) {
    lines.push(`  SETUP     FAILED (exit ${t.setupExit}) — af log ${t.id} setup 0`);
  }
  lines.push(
    `  workflow  ${t.workflow.name}` +
      (t.checkpoint ? `   resumes at: ${t.checkpoint.node}` : "   (graph finished)"),
  );
  if (t.request.key) lines.push(`  key       ${t.request.key}`);
  if (t.request.parent) lines.push(`  parent    ${t.request.parent}`);
  if (t.status === "waiting" && t.wait) {
    const w = t.wait;
    lines.push(
      `  waiting   ${w.reason} at ${w.node}, parked ${AGE(w.since)}` +
        (w.until ? `, timer due ${new Date(w.until).toLocaleTimeString()}` : ""),
    );
    if (w.ask) lines.push(`  question  ${w.ask}`);
    lines.push(
      `  answer    ${
        w.reason === "human"
          ? `af approve ${t.id} --label <${
            [
              ...new Set(
                t.workflow.edges.filter((e) => e.from === w.node).map((e) => e.when ?? "ok"),
              ),
            ]
              .join("|")
          }>`
          : `af poke ${t.id}${w.reason === "budget" ? " --force" : ""}`
      }`,
    );
  }
  lines.push(`  age       ${AGE(t.createdAt)}${cost ? `   spent ${money(cost)}` : ""}`);
  if (t.container) {
    lines.push(`  container ${t.container}${t.workspace ? `   ws ${t.workspace}` : ""}`);
  }
  if (Object.keys(t.sessions ?? {}).length) {
    lines.push(`  sessions  ${Object.keys(t.sessions).join(", ")}`);
  }

  lines.push("");
  // `sub` is subagents started inside the run. Their spend is already in `cost`
  // — claude reports one total per turn — so a turn that fanned out to four of
  // them reads as one implausibly expensive agent until the count is next to it.
  lines.push("  node          visit  status           took     ctx    cost      sub   all visits");
  for (const n of t.workflow.nodes) {
    const runs = t.runs.filter((r) => r.node === n.id);
    const last = runs.at(-1);
    if (!last) {
      lines.push(`  ${pad(n.id, 14)}${pad("-", 7)}${"awaiting"}`);
      continue;
    }
    const total = runs.reduce((s, r) => s + (r.llm?.costUsd ?? 0), 0);
    const subs = runs.reduce((s, r) => s + (r.llm?.subagents ?? 0), 0);
    lines.push(
      `  ${pad(n.id, 14)}${pad(`#${last.visit}`, 7)}${pad(last.status, 17)}` +
        `${pad(duration(last.startedAt, last.finishedAt), 9)}` +
        `${pad(last.llm?.contextPct != null ? `${last.llm.contextPct}%` : "-", 7)}` +
        `${pad(last.llm?.costUsd != null ? money(last.llm.costUsd) : "-", 10)}` +
        `${pad(last.llm?.subagents ? String(last.llm.subagents) : "-", 6)}` +
        // the last visit is the whole story only for a node visited once; a
        // rework loop or a watch node hides most of its spend behind that number
        (runs.length > 1 ? `${runs.length}× ${money(total)}${subs ? `, ${subs} sub` : ""}` : ""),
    );
  }
  // only the events that reach agents: the rest of the stream is node
  // boundaries and status flips, which the table above already says
  const delivered = events.filter((e) => e.to !== undefined);
  if (delivered.length) {
    lines.push("");
    lines.push("  events reaching the agents:");
    for (const e of delivered.slice(-12)) {
      const to = Array.isArray(e.to) ? e.to.join(",") : e.to;
      lines.push(
        `    ${pad(`${e.from ?? "system"}→${to}`, 22)}${e.kind}: ` +
          e.message.replace(/\s+/g, " ").slice(0, 100),
      );
      if (e.refs?.length) lines.push(`    ${" ".repeat(22)}refs: ${e.refs.join("  ")}`);
    }
    if (delivered.length > 12) {
      lines.push(`    … ${delivered.length - 12} earlier; all of them: af log ${t.id}`);
    }
  }
  lines.push("");
  lines.push(`  transcripts: af log ${t.id} <node> [visit] --index`);
  return lines.join("\n");
};

// ---------------------------------------------------------------------------
// commands

const commands: Record<string, (a: Args) => Promise<void> | void> = {
  async ls({ flags }) {
    const list = await af.list();
    const filtered = str(flags.status) ? list.filter((t) => t.status === flags.status) : list;
    if (flags.json) return jsonOut(filtered);
    if (!filtered.length) return out("no tasks");
    // A task waiting on a human is the one thing here that will not resolve
    // itself, so it says so where the status goes rather than reading as idle
    const state = (t: typeof filtered[number]) =>
      t.status !== "waiting"
        ? t.status
        : t.waitingOn === "human"
        ? "NEEDS YOU"
        : `waiting:${t.waitingOn}`;
    for (const t of filtered) {
      const due = t.waitUntil ? ` (due in ${AGE(t.waitUntil).replace(/^-/, "")})` : "";
      out(
        `${pad(state(t), 12)} ${pad(t.id, 22)} ${pad(AGE(t.createdAt), 6)} ${
          (t.title ?? t.task).replace(/\s+/g, " ").slice(0, 62)
        }${due}`,
      );
      if (t.waitingOn === "human" && t.ask) out(`${" ".repeat(12)} ? ${t.ask}`);
    }
  },

  async show({ _, flags }) {
    const handle = af.task(need(_[0], "task id"));
    const t = await handle.getState();
    if (flags.json) return jsonOut(t);
    out(summarizeTask(t, await handle.events().catch(() => [])));
  },

  async log({ _, flags }) {
    const id = need(_[0], "task id");
    const handle = af.task(id);

    // no node given: the task's event history, not a transcript
    if (!_[1]) {
      const events = await handle.events(num(flags.since) ?? 0);
      if (flags.json) return jsonOut(events);
      if (!events.length) return out("no events");
      for (const e of events) {
        // a delivered event is marked: it went into an agent's prompt, which
        // is a different thing from the engine narrating itself
        const to = e.to === undefined ? "  " : `→ ${Array.isArray(e.to) ? e.to.join(",") : e.to} `;
        out(
          `${pad(String(e.seq), 5)} ${e.at.slice(11, 19)}  ${
            pad(`${e.from ?? "system"} ${to}`, 24)
          }${e.kind}: ${e.message.replace(/\s+/g, " ").slice(0, 120)}`,
        );
        if (e.refs?.length) out(`${" ".repeat(40)}refs: ${e.refs.join("  ")}`);
      }
      return;
    }

    const node = _[1];
    const t = await handle.getState();
    const visits = t.runs.filter((r) => r.node === node);
    if (!visits.length) throw new UserError(`node "${node}" has not run in task ${id}`);
    const visit = _[2] ? Number(_[2]) : visits.at(-1)!.visit;

    if (flags.summary) {
      const run = visits.find((r) => r.visit === visit);
      return out(run?.output ?? "(no output)");
    }

    const grep = str(flags.grep);
    if (flags.index || grep) {
      const rows = await handle.transcript(node, visit, {
        index: !grep,
        grep,
        context: num(flags.context),
      }) as TranscriptEvent[];
      if (flags.json) return jsonOut(rows);
      if (!rows.length) return out("no matching events");
      for (const r of rows) {
        out(`${pad(String(r.i), 5)} ${pad(r.type, 12)} ${pad(r.tool ?? "", 14)} ${r.preview}`);
      }
      out("");
      out(`${rows.length} event(s). fetch some: af log ${id} ${node} ${visit} --events A-B`);
      return;
    }

    const events = str(flags.events);
    const range = events?.split("-").map(Number) as [number, number] | undefined;
    const body = await handle.transcript(node, visit, {
      events: range && [range[0], Number.isFinite(range[1]) ? range[1] : range[0]],
      render: !flags.raw,
    }) as string;
    const tail = num(flags.tail);
    out(tail ? body.split("\n").slice(-tail).join("\n") : body);
  },

  async events(a) {
    await commands.log({ _: [a._[0]], flags: a.flags });
  },

  async wait({ _, flags }) {
    const id = need(_[0], "task id");
    const handle = af.task(id);
    const until = str(flags.until) ?? "terminal";
    const timeout = num(flags.timeout);

    /**
     * "terminal" also returns on a park that only a human can clear. A parked
     * task is not finished, so waiting through a poll timer is right — but a
     * question nobody has been told about is the one way this command can wait
     * forever on something that was never going to happen by itself.
     */
    const matches = (t: TaskRecord): boolean => {
      if (until === "terminal") {
        if (["succeeded", "failed", "stopped"].includes(t.status)) return true;
        return t.status === "waiting" &&
          (t.wait?.reason === "human" || t.wait?.reason === "budget");
      }
      if (until.startsWith("node=")) return t.checkpoint?.node === until.slice(5);
      if (until === "waiting") return t.status === "waiting";
      return t.status === until;
    };

    const conn = handle.connect();
    const settled = new Promise<TaskRecord>((resolve) => {
      conn.on("update", (t) => matches(t) && resolve(t));
      conn.on("node", async () => {
        const t = await handle.getState();
        if (matches(t)) resolve(t);
      });
    });
    // the timer must be cleared once the race is decided, or deno keeps the
    // process alive for the full timeout after the task has already settled
    let timer: ReturnType<typeof setTimeout> | undefined;
    const expiry = new Promise<null>((resolve) => {
      if (timeout !== undefined) timer = setTimeout(() => resolve(null), timeout * 1000);
    });

    const current = await handle.getState();
    const result = matches(current) ? current : await Promise.race([settled, expiry]);
    clearTimeout(timer);
    await conn.dispose();

    if (!result) {
      out(`timed out after ${timeout}s; task is ${(await handle.getState()).status}`);
      Deno.exit(2);
    }
    if (flags.json) return jsonOut(result);
    out(summarizeTask(result));
    if (result.status === "failed") Deno.exit(1);
    // its own exit code: nothing is wrong, but nothing moves until someone acts
    if (result.status === "waiting") Deno.exit(3);
  },

  /**
   * `--child-workflow name=path` repeats, and each path is a graph this task's
   * agents may spawn children with. It reads the file here rather than sending
   * the path, because the daemon may be on the other end of AGENTFLOW_URL and
   * `--rubric-file` already settled that question the same way.
   */
  async spawn({ flags }) {
    const file = str(flags.file);
    const rubricFile = str(flags["rubric-file"]);
    const setup = str(flags.setup);
    const childWorkflows: Record<string, unknown> = {};
    for (const entry of list(flags["child-workflow"]) ?? []) {
      const eq = entry.indexOf("=");
      if (eq <= 0) {
        throw new UserError(`--child-workflow wants name=path, got "${entry}"`);
      }
      const [name, path] = [entry.slice(0, eq), entry.slice(eq + 1)];
      try {
        childWorkflows[name] = JSON.parse(await Deno.readTextFile(path));
      } catch (e) {
        throw new UserError(
          `--child-workflow ${name}: ${e instanceof Error ? e.message : e}`,
        );
      }
    }
    const req = file ? JSON.parse(await Deno.readTextFile(file)) : {
      id: str(flags.id),
      title: str(flags.title),
      key: str(flags.key),
      task: need(str(flags.task), "--task"),
      repo: str(flags.repo),
      gates: str(flags.gates),
      rubric: rubricFile ? await Deno.readTextFile(rubricFile) : str(flags.rubric),
      workflow: str(flags.workflow),
      model: str(flags.model),
      effort: str(flags.effort),
      setup: setup && flags["setup-required"] === true ? { run: setup, required: true } : setup,
      maxCostUsd: num(flags["max-cost"]),
      idleMin: num(flags["idle-min"]),
      retain: str(flags.retain)
        ? { container: str(flags.retain) as "always" | "onFailure" | "never" }
        : undefined,
      gh: flags.gh === true || undefined,
      meta: list(flags.meta)?.length ? pairs(list(flags.meta)!, "--meta") : undefined,
    };
    // merged rather than exclusive, so a --file request can pick up a graph
    // without the file having to carry it inline
    if (Object.keys(childWorkflows).length) {
      req.childWorkflows = { ...req.childWorkflows, ...childWorkflows };
    }
    const { id, record, joined } = await af.spawn(req);
    if (flags.json) return jsonOut(record);
    if (joined) {
      out(`joined ${id} — it already holds key "${record.request.key}" and is ${record.status}`);
      return;
    }
    // the base is what the workspace was cut from, and getting it wrong — a
    // working copy left on someone else's half-finished branch — stays
    // invisible until the first gate fails half an hour later
    out(`spawned ${id}${record.base ? ` (base: ${record.base})` : ""}`);
    out(`  af wait ${id}     # block until it settles`);
    out(`  af show ${id}     # current state`);
  },

  /**
   * Bare, it answers the question a budget park raises and does not itself
   * answer: which of the three ceilings stopped this, and what would clear it.
   * With --max-cost it moves this task's own, and a raise resumes a task parked
   * on it — the alternative being teardown and respawn, which discards the
   * session thread a long-lived task is mostly made of.
   */
  async budget({ _, flags }) {
    const handle = af.task(need(_[0], "task id"));
    const raw = str(flags["max-cost"]);
    if (raw === undefined) {
      const b = await handle.budget();
      if (flags.json) return jsonOut(b);
      out(`${b.id}`);
      out(
        `  ceiling   ${b.maxCostUsd === undefined ? "none" : money(b.maxCostUsd)}` +
          `   spent ${money(b.spentUsd)}` +
          (b.spentTreeUsd > b.spentUsd ? `   with children ${money(b.spentTreeUsd)}` : ""),
      );
      for (const a of b.ancestors) {
        out(
          `  ancestor  ${a.id}  ${money(a.spentTreeUsd)} of ${
            money(a.maxCostUsd)
          } across its subtree`,
        );
      }
      for (const w of b.windows) {
        out(`  host ${pad(w.window, 9)}${money(w.spentUsd)} of ${money(w.capUsd)}`);
      }
      if (!b.ancestors.length && !b.windows.length && b.maxCostUsd === undefined) {
        out(`  nothing bounds this task's spend`);
      }
      return;
    }
    const clear = raw === "none" || raw === "off";
    const value = clear ? null : Number(raw);
    if (!clear && !Number.isFinite(value)) {
      throw new UserError(`--max-cost wants a number of dollars, or "none" to remove the ceiling`);
    }
    const t = await handle.setBudget({ maxCostUsd: value });
    if (flags.json) return jsonOut(t);
    out(
      `${t.id}: ceiling ${clear ? "removed" : money(value as number)}; now ${t.status}` +
        (t.status === "waiting" && t.wait?.reason === "budget"
          ? ` — still parked on cost, af budget ${t.id} says what by`
          : ""),
    );
  },

  /**
   * The container stops two minutes into a park, so `docker exec` fails exactly
   * when a parked watcher's refs are what you want to read. Bare output is the
   * refs path alone, so it substitutes into a command.
   */
  async refs({ _, flags }) {
    const p = await af.task(need(_[0], "task id")).paths();
    if (flags.json) return jsonOut(p);
    if (flags.all !== true) return out(p.refs);
    out(`  refs       ${p.refs}`);
    out(`  artifacts  ${p.artifacts}`);
    out(`  workspace  ${p.workspace}`);
    out(`  logs       ${p.logs}`);
    if (p.cwd) out(`  cwd        ${p.cwd}   (inside the container)`);
  },

  /**
   * What the task's agents left for a person to look at, as host paths so a
   * screenshot opens from here. The dashboard shows the same list inline;
   * this is for a terminal, and for after the workspace is gone.
   */
  async artifacts({ _, flags }) {
    const a = await af.task(need(_[0], "task id")).artifacts();
    if (flags.json) return jsonOut(a);
    if (!a.files.length) return out(`no artifacts   (${a.dir})`);
    for (const f of a.files) out(`  ${pad(bytes(f.size), 10)} ${a.dir}/${f.path}`);
    if (a.truncated) {
      out(`  … listing stopped at ${a.files.length} files; the rest are in ${a.dir}`);
    }
  },

  /**
   * Bare: the bag. key=value arguments write, --unset removes; the daemon
   * checks the values and records each change as an event, so the agents
   * hear about it on their next turn.
   */
  async meta({ _, flags }) {
    const handle = af.task(need(_[0], "task id"));
    const set: Record<string, string | null> = pairs(_.slice(1), "meta");
    for (const key of list(flags.unset) ?? []) set[key] = null;
    if (!Object.keys(set).length) {
      const bag = await handle.meta();
      if (flags.json) return jsonOut(bag);
      const keys = Object.keys(bag);
      if (!keys.length) return out("no metadata");
      const width = Math.max(...keys.map((k) => k.length));
      for (const k of keys) out(`  ${pad(k, width)}  ${bag[k]}`);
      return;
    }
    const t = await handle.setMeta(set);
    if (flags.json) return jsonOut(t.meta);
    out(
      `${t.id}: ${
        Object.entries(set).map(([k, v]) => v === null ? `${k} removed` : `${k} = ${v}`).join(", ")
      }`,
    );
  },

  async poke({ _, flags }) {
    const t = await af.task(need(_[0], "task id")).poke({
      label: str(flags.label),
      force: flags.force === true,
    });
    flags.json ? jsonOut(t) : out(`${t.id} ${t.status} at ${t.checkpoint?.node ?? "?"}`);
  },

  /**
   * Answering a gate. --yes / --no are shorthands for the two answers almost
   * every gate has; anything else is named with --label, and what a given gate
   * accepts comes from its outgoing edges rather than from here.
   */
  async approve({ _, flags }) {
    const id = need(_[0], "task id");
    const message = _.slice(1).join(" ") || str(flags.message);
    const label = flags.yes === true
      ? "approve"
      : flags.no === true
      ? "decline"
      : need(str(flags.label), "--label (or --yes / --no)");
    const t = await af.task(id).approve({ label, message });
    flags.json ? jsonOut(t) : out(`${t.id}: answered "${label}"; now ${t.status}`);
  },

  async stop({ _, flags }) {
    const t = await af.task(need(_[0], "task id")).stop();
    flags.json ? jsonOut(t) : out(`${t.id} ${t.status}`);
  },

  async resume({ _, flags }) {
    const t = await af.task(need(_[0], "task id")).resume();
    flags.json ? jsonOut(t) : out(`${t.id} resumed at ${t.checkpoint?.node}`);
  },

  async rerun({ _, flags }) {
    const id = need(_[0], "task id");
    const t = await af.task(id).rerun({
      from: str(flags.from),
      // positional, like interject: rerouting somewhere and saying why is one act
      message: _.slice(1).join(" ") || str(flags.message),
      session: flags.session === "fresh" ? "fresh" : undefined,
      resetWorkspace: flags["reset-workspace"] === true,
      force: flags.force === true,
    });
    flags.json ? jsonOut(t) : out(`${t.id} rerunning from ${t.checkpoint?.node}`);
  },

  async interject({ _, flags }) {
    const id = need(_[0], "task id");
    const message = _.slice(1).join(" ") || str(flags.message);
    const t = await af.task(id).interject({
      message: need(message, "a message"),
      target: str(flags.target),
      urgent: flags.urgent === true,
    });
    if (flags.json) return jsonOut(t);
    out(`noted; ${t.id} is ${t.status}`);
    // A note at a gate is recorded but answers nothing, and a task left parked
    // because its operator thought they had replied is the failure worth
    // spending two lines to avoid.
    if (t.status === "waiting" && t.wait?.reason === "human") {
      const answers = [
        ...new Set(
          t.workflow.edges.filter((e) => e.from === t.wait!.node).map((e) => e.when ?? "ok"),
        ),
      ];
      out(`  it is still waiting on an answer: ${t.wait.ask ?? ""}`);
      out(`  af approve ${t.id} --label <${answers.join("|")}>`);
    }
  },

  async emit({ _, flags }) {
    const id = need(_[0], "task id");
    const message = _.slice(1).join(" ") || str(flags.message);
    const csv = (v: Flag | undefined) => {
      const s = str(v);
      return s ? s.split(",").map((x) => x.trim()).filter(Boolean) : undefined;
    };
    const t = await af.task(id).emit({
      message: need(message, "a message"),
      kind: str(flags.kind),
      from: str(flags.from),
      to: csv(flags.to),
      refs: csv(flags.refs),
      key: str(flags.key),
      urgent: flags.urgent === true,
    });
    if (flags.json) return jsonOut(t);
    out(`published; ${t.id} is ${t.status}`);
    if (flags.urgent === true) reportUndelivered(t);
  },

  /**
   * Read or replace the task text. `--set` takes a file because a task worth
   * rewriting is usually longer than a shell line, and it is read here rather
   * than sent as a path for the same reason `--rubric-file` is: the daemon may
   * be on the other end of AGENTFLOW_URL.
   */
  async task({ _, flags }) {
    const id = need(_[0], "task id");
    const handle = af.task(id);
    const file = str(flags.set);
    const text = file ? await Deno.readTextFile(file) : _.slice(1).join(" ") || str(flags.message);
    if (!text) {
      const t = await handle.getState();
      return flags.json ? jsonOut({ task: t.request.task }) : out(t.request.task);
    }
    const t = await handle.setTask(text, { interrupt: flags.interrupt === true });
    if (flags.json) return jsonOut(t);
    out(`${t.id}: task text replaced, and every agent node told that the old one is void`);
    if (!flags.interrupt && t.status === "running") {
      out(`  the running turn finishes on the old text; --interrupt stops it instead`);
    }
  },

  async workflow({ _, flags }) {
    const id = need(_[0], "task id");
    const handle = af.task(id);
    const set = str(flags.set);
    if (!set) return jsonOut(await handle.workflow());
    const def = JSON.parse(await Deno.readTextFile(set));
    const t = await handle.setWorkflow(def, { interrupt: flags.interrupt === true });
    flags.json
      ? jsonOut(t.workflow)
      : out(`${id}: workflow replaced (${t.workflow.nodes.length} nodes)`);
  },

  /**
   * The graphs a task hands its children, and how to change them without
   * stopping it. A long-lived sweep is exactly the case: it holds the graph its
   * reviewers are spawned from, that graph is only read at the next fan-out,
   * and stopping the sweep to change it would lose the state it has built up
   * about what it has already seen.
   */
  async "child-workflows"({ _, flags }) {
    const id = need(_[0], "task id");
    const handle = af.task(id);
    const sets = list(flags.set) ?? [];
    if (!sets.length) return jsonOut(await handle.childWorkflows());

    // merged onto what is there, because the common edit is one graph out of
    // several and naming the rest again just to keep them is how they get lost
    const defs = { ...await handle.childWorkflows() };
    for (const entry of sets) {
      const eq = entry.indexOf("=");
      if (eq <= 0) throw new UserError(`--set wants name=path, got "${entry}"`);
      const [name, path] = [entry.slice(0, eq), entry.slice(eq + 1)];
      try {
        defs[name] = JSON.parse(await Deno.readTextFile(path));
      } catch (e) {
        throw new UserError(`--set ${name}: ${e instanceof Error ? e.message : e}`);
      }
    }
    for (const name of list(flags.drop) ?? []) delete defs[name];

    const t = await handle.setChildWorkflows(defs);
    const names = Object.keys(t.request.childWorkflows ?? {});
    if (flags.json) return jsonOut(t.request.childWorkflows ?? {});
    out(`${id}: child workflows now ${names.length ? names.join(", ") : "none"}`);
    out("  children already running keep the graph they were spawned with");
  },

  /**
   * Everything the task was configured with, in one place. `af show` answers
   * "how is it going" and `af workflow` gives the graph alone; this is for the
   * other question — what is this task actually running with — where the answer
   * is spread across the request, the graph, and where it ended up on disk.
   *
   * Run history is left out by default because it is the bulk of the record and
   * none of it is configuration; --all puts it back.
   */
  async config({ _, flags }) {
    const t = await af.task(need(_[0], "task id")).getState();
    const view = flags.all === true ? t : {
      id: t.id,
      status: t.status,
      createdAt: t.createdAt,
      error: t.error,
      container: t.container,
      workspace: t.workspace,
      cwd: t.cwd,
      sessions: t.sessions,
      checkpoint: t.checkpoint,
      wait: t.wait,
      request: t.request,
      workflow: t.workflow,
    };
    if (flags.json) return jsonOut(view);
    const lines: string[] = [];
    humanJson("", view, "", lines);
    out(lines.join("\n"));
    if (flags.all !== true && t.runs.length) {
      out("");
      out(dim(
        `  ${t.runs.length} run${t.runs.length === 1 ? "" : "s"} omitted — ` +
          `af config ${t.id} --all for the whole record`,
      ));
    }
  },

  async workflows({ flags }) {
    const wfs = await af.workflows();
    if (flags.json) return jsonOut(wfs);
    for (const [name, wf] of Object.entries(wfs)) {
      out(`${name}`);
      for (const n of wf.nodes) {
        const edges = wf.edges.filter((e) => e.from === n.id)
          .map((e) => `${e.when ?? "ok"}→${e.to}`).join(" ");
        out(
          `  ${pad(n.id, 14)}${pad(n.exec ?? n.type ?? "claude", 8)}${
            pad(n.session ?? "none", 8)
          }${edges}`,
        );
        if (n.description) out(`  ${" ".repeat(14)}${n.description}`);
      }
      out("");
    }
  },

  async cleanup({ _, flags }) {
    const t = await af.task(need(_[0], "task id")).cleanup({
      container: flags.container === true || flags.both === true,
      workspace: flags.workspace === true || flags.both === true,
    });
    flags.json ? jsonOut(t) : out(`${t.id} cleaned`);
  },

  async rm({ _ }) {
    await af.task(need(_[0], "task id")).remove();
    out(`removed ${_[0]}`);
  },

  async volumes({ flags }) {
    const vols = await agentflowVolumes();
    if (flags.json) return jsonOut(vols);

    if (flags.prune === true) {
      const stale = vols.filter((v) => v.stale && !v.containers.length);
      if (!stale.length) return out("nothing to prune");
      for (const v of stale) {
        const r = await docker(["volume", "rm", v.name]);
        out(`${r.code === 0 ? "removed" : "FAILED "} ${pad(v.name, 30)}${v.size}`);
        if (r.code !== 0) out(`  ${r.err || r.out}`);
      }
      return;
    }

    if (flags.gc === true) {
      const live = vols.find((v) => !v.stale);
      if (!live) return out("no nix volume for the current image yet — nothing to collect");
      if (live.running.length) {
        // nix tracks in-flight builds with pid files under the store, and a pid
        // means nothing across a container boundary: a gc running in its own
        // container can read another task's temproots as dead and delete out
        // from under it
        throw new UserError(
          `${live.name} is mounted by running container(s) ${live.running.join(", ")}. ` +
            `Stop those tasks first (af stop <id>) — rerun starts their containers back up.`,
        );
      }
      out(`collecting garbage in ${live.name} (${live.size}) — expect minutes, not seconds`);
      const code = await dockerStream(
        // no -v: gc already prints a line per deletion, and on a store this
        // size that is hundreds of thousands of them
        ["run", "--rm", "-v", `${live.name}:/nix`, IMAGE, "nix", "store", "gc"],
      );
      if (code !== 0) throw new UserError(`nix store gc exited ${code}`);
      const after = (await agentflowVolumes()).find((v) => v.name === live.name);
      out(`${live.size} -> ${after?.size ?? "?"}`);
      return;
    }

    if (!vols.length) return out("no agentflow cache volumes");
    out(`${pad("VOLUME", 30)}${pad("SIZE", 10)}${pad("STATE", 9)}USED BY`);
    for (const v of vols) {
      out(
        `${pad(v.name, 30)}${pad(v.size, 10)}${pad(v.stale ? "stale" : "current", 9)}${
          v.containers.join(" ") || "-"
        }`,
      );
    }
    out("");
    out("af volumes --prune   remove stale volumes (old image builds, no container attached)");
    out("af volumes --gc      nix store gc inside the current volume; needs its tasks stopped");
  },

  help({ _ }) {
    out(_[0] ? topic(_[0]) : HELP);
  },
};

const need = <T>(v: T | undefined | null, what: string): T => {
  if (v === undefined || v === null || v === "") throw new UserError(`missing ${what}`);
  return v;
};

// ---------------------------------------------------------------------------
// nix store volumes

const IMAGE = "agentflow:latest";

const docker = async (args: string[]) => {
  const { code, stdout, stderr } = await new Deno.Command("docker", {
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const dec = new TextDecoder();
  return { code, out: dec.decode(stdout).trim(), err: dec.decode(stderr).trim() };
};

/** docker with its output going straight to the terminal, for the slow ones */
const dockerStream = async (args: string[]) => {
  const child = new Deno.Command("docker", {
    args,
    stdout: "inherit",
    stderr: "inherit",
    stdin: "null",
  }).spawn();
  return (await child.status).code;
};

interface NixVolume {
  name: string;
  size: string;
  /** every task container mounting it, exited ones included — those can still be revived */
  containers: string[];
  /** the subset that is up right now */
  running: string[];
  /** left behind by an image build that is no longer agentflow:latest */
  stale: boolean;
}

/**
 * The shared nix store is keyed by image id, so every image rebuild strands the
 * previous volume: still full, no longer referenced, and invisible until the
 * disk fills. Nothing reclaims them on its own.
 */
const agentflowVolumes = async (): Promise<NixVolume[]> => {
  const img = await docker(["image", "inspect", IMAGE, "-f", "{{.Id}}"]);
  if (img.code !== 0) {
    throw new UserError(
      `no ${IMAGE} image on this host, so there is no telling which nix volume is the live one ` +
        `and which are leftovers. Build the image first.`,
    );
  }
  const live = `agentflow-nix-${img.out.replace(/^sha256:/, "").slice(0, 12)}`;

  const ls = await docker([
    "volume",
    "ls",
    "--filter",
    "name=agentflow-nix-",
    "--format",
    "{{.Name}}",
  ]);
  if (ls.code !== 0) throw new UserError(`docker volume ls failed: ${ls.err || ls.out}`);

  // Sizes are best-effort on purpose: `docker system df` walks the whole image
  // tree, which is exactly what breaks when the daemon's storage is damaged —
  // and a daemon that just filled its disk is when you most need this command
  // to still answer. Enumeration comes from the cheap metadata read instead.
  const sizes = new Map<string, string>();
  const df = await docker(["system", "df", "-v", "--format", "{{json .Volumes}}"]);
  if (df.code === 0) {
    try {
      for (const v of JSON.parse(df.out) as { Name: string; Size: string }[]) {
        sizes.set(v.Name, v.Size);
      }
    } catch {
      // unparseable df output is a missing column, not a reason to fail
    }
  }

  const vols: NixVolume[] = [];
  for (const name of ls.out.split("\n").filter(Boolean)) {
    const used = await docker([
      "ps",
      "-a",
      "--filter",
      `volume=${name}`,
      "--format",
      "{{.Names}}\t{{.State}}",
    ]);
    const rows = used.out.split("\n").filter(Boolean).map((l) => l.split("\t"));
    vols.push({
      name,
      size: sizes.get(name) ?? "?",
      containers: rows.map((r) => r[0]),
      running: rows.filter((r) => r[1] === "running").map((r) => r[0]),
      stale: name !== live,
    });
  }
  return vols.sort((a, b) => Number(a.stale) - Number(b.stale));
};

// ---------------------------------------------------------------------------
// help

const HELP = `af — agentflow command line   (daemon: ${DAEMON})

INSPECT
  af ls [--status S] [--json]           every task, newest first
  af show <id> [--json]                 status, per-node runs, cost, context%, resume point
  af log <id> [--since N]               the task's event stream, in order. Rows with "→ node"
                                        went into that agent's prompt; the rest is bookkeeping
  af log <id> <node> [visit] --index    ONE LINE PER TRANSCRIPT EVENT — start here
  af log <id> <node> [visit] --events A-B [--raw]
                                        just those events, rendered readable
  af log <id> <node> [visit] --grep RE [--context N]
                                        only matching events, with surrounding rows
  af log <id> <node> [visit] --summary  the node's final result text
  af workflows                          bundled workflow graphs
  af workflow <id>                      this task's graph as json
  af child-workflows <id>               the graphs it spawns children with
  af config <id> [--all] [--json]       everything it was configured with — request, graph, where
                                        it lives on disk — with prompts as blocks, not escaped
  af budget <id>                        every ceiling that could park it, and what each has spent
  af refs <id> [--all]                  host path to its refs dir — works while it is parked and
                                        its container is stopped, when docker exec does not
  af artifacts <id>                     what its agents left for you to look at — screenshots,
                                        proof of a run — as host paths. See af help artifacts
  af meta <id>                          facts attached to the task: the PR it opened, and
                                        whatever else its nodes or you recorded
  af volumes [--prune] [--gc]           nix store volumes: sizes, leftovers, collection

CONTROL
  af spawn --task "..." [--repo P] [--title T] [--gates C] [--workflow W]
           [--rubric "..." | --rubric-file F] [--model M] [--effort E]
           [--setup CMD] [--setup-required] [--gh] [--id ID]
           [--key K] [--max-cost USD] [--idle-min N] [--retain always|onFailure|never]
           [--meta KEY=VALUE]           repeatable: metadata the task starts with, e.g. the PR
                                        a watcher is for. See af help artifacts
           [--child-workflow NAME=graph.json]
                                        repeatable: a graph this task's agents may spawn
                                        children with, by the name they ask for it by
  af spawn --file req.json              full SpawnRequest, for anything the flags miss
  af wait <id> [--until X] [--timeout S]
                                        block until it settles; exit 1 if failed, 2 on timeout,
                                        3 parked on a human — a gate question or a budget park
  af stop <id>                          cancel now, keep the checkpoint. On a parked task this
                                        cancels the wait, so it stays stopped across a restart
  af resume <id>                        continue from the checkpoint (pokes a parked task)
  af budget <id> --max-cost USD|none    move its ceiling while it runs; a raise resumes a task
                                        parked on cost, keeping its container and session thread
  af poke <id> [--label L] [--force]    stop waiting, go now. Refused at a question (nothing can
                                        guess your answer) and on a budget park without --force
  af approve <id> ["message"] --label L | --yes | --no
                                        answer a parked gate. The labels a gate takes are its
                                        node's outgoing edges — af show <id> prints them
  af rerun <id> ["why"] [--from NODE] [--session fresh] [--reset-workspace] [--force]
                                        re-enter the graph at any node. The message is recorded
                                        before it starts, so that node reads it on its first turn
  af interject <id> "message" [--target NODE] [--urgent]
  af emit <id> "message" [--kind K] [--from SRC] [--to a,b] [--refs p,q] [--key K] [--urgent]
                                        publish an event from outside the workflow (CI, a
                                        webhook). See af help events
  af meta <id> KEY=VALUE... [--unset KEY]
                                        write metadata; pr must be a URL, it becomes the link
                                        on the board row
  af task <id>                          the task text it is working from
  af task <id> --set new.md [--interrupt]
                                        replace it. For what a note cannot do — withdrawing a
                                        requirement, which the judges would go on failing the
                                        work for. See af help events
  af workflow <id> --set graph.json [--interrupt]
  af child-workflows <id>               the graphs it hands its children
  af child-workflows <id> --set name=graph.json [--drop name]
                                        swap them without stopping it. Only children spawned from
                                        here on get the new graph — the ones already running keep
                                        what they were created with
  af cleanup <id> [--container] [--workspace] [--both]
  af rm <id>                            stop, tear down, forget

Every command takes --json. Global: AGENTFLOW_URL overrides the daemon address.

TOPICS   af help <topic>
  workflow   how nodes, sessions, and outcomes work; writing a custom graph
  model      picking the agent and model per node; the codex credential
  events     how nodes tell each other things, and how to publish from outside
  artifacts  files and facts a task leaves for you: screenshots, proof, the PR URL
  prompt     writing node prompts and rubrics that hold up
  monitor    how to watch tasks without drowning in transcript
  rerun      reruns, sessions, side effects, what reset does and does not do
  cache      shared caches and how to pick volume names
  wait       parking, backoff, approval gates, and tasks that run for weeks
  budget     cost ceilings, what happens on breach, and the config file
`;

const TOPICS: Record<string, string> = {
  workflow: `WORKFLOWS

A workflow is nodes plus edges. A node is three independent choices:

  exec      "shell" runs a command in the workspace.
            "claude" runs a Claude Code turn there.
            "codex"  runs a Codex turn there. The agent is the exec, so one
            graph can implement on claude and review on codex; they share the
            workspace and the event stream and nothing else. A codex node needs
            a credential on the daemon — see "af help model".

  model     what this node's turns run as, overriding the workflow's and the
  effort     task's. Named in whatever form the node's exec understands —
            "claude-opus-5" for claude, "gpt-5.6-sol" for codex — with effort
            "low" | "medium" | "high". Both optional: unset, they resolve
            through the workflow, then the task, then the built-in floor
            (opus 5 / gpt-5.6-sol, both high). This is how one graph thinks
            hard about its review and cheaply about its formatting. Full
            precedence in "af help model".

  session   which conversation the turn belongs to.
            "none" (default) = cold session every visit; the node has no
            memory of its own past runs.
            any other string = a session key. Nodes sharing a key share one
            thread, and a revisit continues it — those visits send
            \`followUp\` instead of \`run\`, so only the delta is sent and the
            cached prompt prefix stays stable. "Revisit" is per node: a node
            joining a thread some other node opened gets its \`run\` template
            the first time, however warm that thread already is.

  outcome   how the result becomes an edge label.
            omitted = exit code decides: "ok" or "fail".
            {kind:"pattern"} = a regex over the output picks the label. For
            deterministic producers (a script printing "ROUTE: bug"). No
            correction loop — there is nobody to correct.
            It reads ONLY THE LAST non-empty line, so the routing line must be
            the last thing the script prints — a diagnostic echoed after it is
            what the regex sees, and the node routes on its fallback instead.
            Set lastLineOnly:false to scan every line, first match wins. Either
            way a miss now prints why on the node's transcript, because a
            fallback that happens to be the right answer looks exactly like a
            contract that works.
            {kind:"schema"} = the reply must be one JSON object matching a
            schema. For agents. See "structured output" below.

STRUCTURED OUTPUT

A schema contract makes an agent node answer with data instead of prose:

  outcome: {
    kind: "schema",
    label: "verdict",              // property that decides routing
    schema: {
      type: "object",
      required: ["verdict", "summary"],
      properties: {
        verdict: { enum: ["approve", "request_changes"] },
        summary: { type: "string", description: "your overall judgement" },
        blocking: { type: "array", items: { type: "string" } }
      }
    }
  }

You write the schema; the engine writes the format instruction into the
prompt — rendered as a TypeScript type, because that is what a model reads
best — then validates the reply. On a mismatch it quotes the exact errors
("verdict: must be one of \\"approve\\" | \\"request_changes\\", got
\\"APPROVED\\"") and asks for the WHOLE object again.

That last part is the point. The reasoning and the label arrive together, so
a correction swaps one complete answer for another. The older "end your reply
with VERDICT: X" convention could not: correcting a bad last line got back a
bare verdict, and the review it belonged to was silently discarded.

Put a \`description\` on any field that is not self-evident — it becomes a
comment in the type the agent reads. Unions come from \`enum\` or \`anyOf\`.
Other nodes then take exactly the field they need: {{review.blocking}} rather
than the entire review.

Edges fire on the source node's label (\`when\`, default "ok"). An edge
pointing back at an earlier node is a rework loop, bounded by \`maxVisits\`.
Edges may target "@succeeded" / "@failed". When no edge matches, the task ends:
succeeded if the label is in \`successLabels\` (default ["ok","approve"]),
failed otherwise. Execution starts at \`start ?? nodes[0]\`.

The old \`type: agent|shell|review\` shorthand still works: agent = claude on
the shared "coder" session, review = claude with a cold session and the
VERDICT contract.

Templates in run/followUp: {{task}} {{gates}} {{rubric}}, {{<nodeId>}} for
another node's latest output, and {{<nodeId>.<field>}} for one field of a
schema node's validated object. Outputs over ~4KB spill to a file and the
variable carries excerpts plus the path. {{rubric}} arrives pre-wrapped in its
own section and is empty when the task set none, so it costs nothing unused —
see \`af help prompt\`.

In a shell node a template expands into the SCRIPT, before sh reads a word of
it, so "{{task}}" is not a string — it is source. Task text is prose someone
else wrote (a PR title, an issue body), and prose carries quotes, backticks and
parens, so it is a syntax error on a good day and a command on a bad one. Take
it through a quoted-delimiter heredoc, which sh does not expand:

    cat > "$AF_REFS/task.txt" <<'AF_EOF'
    {{task}}
    AF_EOF
    pr=$(grep -oE 'PR #[0-9]+' "$AF_REFS/task.txt" | head -1)

Agent nodes are fine — there the template is prompt text, not code.

Templates are the pull side of context sharing: deterministic, and the only
thing edges can route on. What a node wants to SAY rather than return goes on
the event stream instead — see \`af help events\`.

ANNOUNCING

Every node's result goes on the stream when it finishes, so a node's work does
not go nowhere because you forgot to wire a template var for it. Delivery is
keyed per node, so this stays cheap under repetition: a watch loop on its four
hundredth lap delivers its LATEST result, not four hundred of them. The standing
cost is one line in a downstream prompt.

Set \`announce: false\` on a node whose result is only how the graph routes — a
poll printing "ROUTE: idle", a bookkeeping step nobody reads. That line buys
nothing in every later prompt, and with no announcement there is nothing for a
ref to be the detail of, so the output also stops being written to the refs
directory — which for a node inside a watch loop was one small file per lap for
as long as the task lived. The bundled \`implement-pr\` sets it on its poll node;
\`af workflows\` shows it.

Leave it alone otherwise. Routing, {{thisNode}} and the run history are
unaffected either way — this is only whether the rest of the workflow is told.

Wrap a section in {{#<name>}}...{{/<name>}} to drop it when that variable has
nothing in it. A node that has not run yet resolves to nothing, so without the
wrapper its heading still reaches the agent over blank space. An empty list is
a different case: it renders "(none)" and the section stays.

On a followUp, {{<nodeId>}} carries a node's output only if it landed since
this node last ran. Older results are already in the thread, and re-sending
them buries what is actually new — a loop back from a failed gate would
otherwise hand the implementer the review it already acted on. A full \`run\`
template is never filtered: a first turn has no thread to have seen anything in.

Every agent node's full turn also gets a map of the graph with its own position
marked, so nodes do not redo each other's work — plus the idempotence warning a
node marked effects:"external" carries, and its output contract in full. A
followUp turn gets none of them: the thread has them, and a watch loop that
restated all three on every wake spent more on repeating itself than on the
news it woke for.

GRAPHS A TASK CARRIES FOR ITS CHILDREN

An agent inside a task can ask for a task of its own, and it names the graph
rather than writing one — a graph runs shell nodes, so taking a definition from
in there would put arbitrary commands downstream of whatever text the agent last
read. By default the names it may use are the bundled four.

A task can carry more:

  af spawn --workflow survey --child-workflow pr-babysit=./babysit.json --task '...'

Now its agents may spawn with "pr-babysit" too, and the graph they get is the one
in that file. This is what a survey that fans out to watchers of its own needs,
since no bundled graph is a six-node poller with your digest comparison in it.

  · The name is a lookup key, always. Resolution is this task's own declarations
    first, then the bundled record; a name in neither is refused, and the refusal
    reaches the node that asked as an event on the stream (af log <id>), because
    spawning is asynchronous and a sweep loop with nothing to read would ask for
    the same child again every lap.
  · Every graph is validated and linted at spawn, not at the first fan-out. A
    malformed one fails the parent's spawn outright; lint warnings land on its
    event stream like its own graph's do.
  · A name that collides with a bundled one is refused. The agent reads the
    bundled description of "survey" in its tool either way, so a "survey" that
    means something else in one subtree is a name it picks for a wrong reason.
  · Children do not inherit the set. A spawned watcher spawns nothing, and
    passing the graphs down is what makes one compromised agent's reach the whole
    tree's. A child that needs its own gets them from the host-side request that
    creates it, which is the invariant: every graph that executes was written by
    a person and arrived through an \`af spawn\`.

  af workflows              see the bundled graphs
  af workflow <id>          see one task's graph
  af workflow <id> --set g.json [--interrupt]
                            replace it, even mid-run. validated whole; takes
                            effect at the next node boundary unless you
                            interrupt. edit + rerun is the iterate loop.
`,

  events: `EVENTS

Everything that happens to a task is one event on one append-only, seq-ordered
stream: node boundaries, status flips, your interjections, whatever an agent
publishes about its own work, whatever an outside source reports. \`af log <id>\`
is that stream.

Being on the stream does not put an event in front of an agent — most of it is
bookkeeping that would be noise in a prompt. Delivery is opt-in: an event
reaches prompts only if it names an audience.

  to        "*" for every agent node, or node ids. Absent = history only.
  kind      what sort of event it is. spawned/status/node/workflow/control/
            error are the engine's bookkeeping and never reach a prompt;
            output/verdict announce a finished node; "operator" is an
            interjection; agents default to "handoff". Nodes filter on this.
  message   the event entire. One or two sentences when refs carries the
            detail, a paragraph when there is nowhere to point.
  refs      pointers — a path, a URL, an id. Nothing is fetched for the
            reader; a reader who cares follows them. This is what keeps a
            summary a summary: "wrote the new dispatch table, see refs" beats
            pasting the table into every prompt downstream.
            Backing files belong in /ws/<id>/refs, which the engine creates and
            every agent is pointed at: outside the checkout, so a scratch file
            never lands in the diff under review, and in one place rather than
            wherever each cold session decided to put its own.
  key       set it when the event restates a fact instead of adding one (CI
            status, PR state). Only the newest per key is delivered, so a node
            arriving after six rounds of a flapping check sees where it landed
            rather than all six, five of which are now lies.
  urgent    deliver now rather than at the next node boundary. It interrupts a
            running turn, and it wakes a parked task even when the event's kind
            matches no trigger the wait node declared — otherwise the news sits
            unread until a backed-off poll timer comes round hours later. A
            gate and a budget park are the two it cannot clear, and both say so
            rather than accepting the flag and doing nothing with it.

WHO PUBLISHES

  nodes       every node announces its own result when it finishes, without
              being asked: a brief message — a schema node's \`summary\`, else
              the head of its output — with the full text one ref away. This
              used to reach another node only if the graph's author remembered
              to wire a {{var}} for it, so whatever nobody thought to connect
              went nowhere. A node is never sent its own output back.

              Template vars still have the complementary job. News is pushed;
              a node acting on one particular field pulls it, because
              {{review.blocking}} is a work order rather than an announcement.
  agents      an \`emit\` MCP tool, present in every claude node. It writes to a
              spool on the workspace mount that the daemon reads host-side —
              no port, no token, nothing reachable from a prompt-injected
              agent. It cannot set \`urgent\`: one node runs at a time, so the
              only node it could interrupt is itself.
  you         af interject <id> "..." [--target NODE] [--urgent]
  outside     af emit <id> "..." --kind ci --key ci:pr-42 [--urgent], or
              POST /api/task/<id>/emit. For CI, webhooks, a PR watcher.

WHO RECEIVES

A node with a persistent session is shown each event once — its thread keeps
what it was told, so a revisit gets only what arrived since. A cold-session
node is shown everything addressed to it on every visit, because every visit
is a thread that has been told nothing.

Nothing is dropped for length. An event omitted to save tokens is the one
piece of context that run needed.

  accepts   kinds this node will see; omitted = all of them.
  ignores   kinds withheld from it.
  events    false switches the node off the stream entirely.

\`accepts\` is the one to reach for when a node's value is in what it has NOT
been told. The bundled reviewer takes accepts:["operator"] — it judges the
diff blind, and a denylist would only hold until an agent published under a
kind nobody thought to name.

A rerun delivers what is known NOW, never a replay of what the node saw the
first time: you rerun to get a better result, and withholding what has been
learned since is how a node repeats its mistake. What it actually saw is
recorded as a seq range on the run, so "what did it know?" stays answerable.

CHANGING THE TASK, NOT COMMENTING ON IT

  af task <id>                     print the text it is working from
  af task <id> --set new.md [--interrupt]

An interjection adds to the task, and additions compose with it. Removals do
not, and the task text wins that argument by default: the judges are
cold-session and re-read {{task}} on every visit. Tell the implementer to drop a
requirement and the verifier and the reviewer go on failing the work for its
absence, round after round, until the implementer concludes its workspace is
being corrupted and defends the code you withdrew.

So say it where they read it. \`af task --set\` replaces the text \`{{task}}\`
renders, and publishes the replacement to every agent node as well, since a warm
thread was told the old task once and re-reads nothing. --interrupt stops the
running turn rather than letting it finish against text that is now void.
`,

  artifacts: `ARTIFACTS AND METADATA

Two things a task leaves for a person rather than for the next node. Both
reach the dashboard, both outlive the workspace, and neither needs the
transcript read.

ARTIFACTS   files: a screenshot of the feature working, the output of the
            run that proves it, the log of the one that failed.

  where     /ws/<id>/artifacts inside the container, also $AF_ARTIFACTS.
            Every agent turn is told this; a shell node has the env var.
            Refs (/ws/<id>/refs) are the other directory, and the difference
            is the reader: refs are for another agent and go with the
            workspace, artifacts are for you and are kept — teardown moves
            them under the task's logs directory, which nothing removes.
  reading   the task's page lists them, images inline; af artifacts <id>
            prints host paths; GET /api/task/<id>/artifacts/<path> serves
            one. Served as text or image only, never as a page: the
            directory is written from inside a container, and a page it
            authored running on the dashboard's origin would have the API.
  asking    say it in the task or rubric — "leave a screenshot of each state
            in $AF_ARTIFACTS" — and the verifier is the node to ask, since
            proof is what it is there to produce.

METADATA    facts: a flat bag of key → string on the task record.

  pr        the one key the board knows. Set it to the PR's URL and the task's
            row and header carry a link to it; anything that is not an
            http(s) URL is refused.
  writing   agents have a \`meta\` tool. A shell node appends a line to the
            outbox, the same way it publishes an event:
              printf '{"op":"meta","set":{"pr":"%s"}}\\n' "$url" >> "$AF_OUTBOX"
            You: af meta <id> pr=https://… [--unset key], or --meta at spawn
            for what is known up front. A spawning agent hands a child its
            starting bag the same way, through the spawn tool's meta field —
            how a sweep's "review PR N" children get their board link when
            nothing inside them ever opens a PR. null (or --unset) removes.
  reading   the dashboard lists the bag on the task's page. Prompts read a
            value as {{meta.<key>}}, and {{#meta.pr}}…{{/meta.pr}} keeps a
            section only once one is recorded — so a watch node can be told
            which PR it is for without the URL being threaded through task
            text. Every change is also an event (kind "meta", key meta:<k>)
            delivered to the agent nodes, so a warm thread hears it once.
  limits    keys start with a letter, letters digits . _ - after; values up
            to 2000 chars, 64 keys. A value that wants to be longer is a file
            in the artifacts directory, with its path here.
`,

  prompt: `WRITING PROMPTS FOR NODES

The bundled prompts are the worked examples — read them with \`af workflows\`.
What they follow, and what a custom graph should:

Say what the situation is and what the node is for, then stop. A list of things
not to do costs tokens on every visit, only covers the cases you thought of,
and reads as distrust to a model that would have made the same call from the
reason alone. "The operator reviews your work as this workspace's diff, so keep
it there as one commit" carries further than four prohibitions about jj
subcommands, because it explains the constraint instead of enumerating its
consequences.

Do not restate a schema field in the prompt. Field \`description\`s are rendered
into the prompt as comments on the type the agent must satisfy, so that is the
one place the guidance cannot drift from what the validator accepts. A prompt
that also explains when to use \`blocking\` is paying twice for one instruction
and inviting the two copies to disagree.

Point at the codebase instead of describing it. "Match the error handling in
src/net/retry.rs" beats a paragraph about error handling: the agent can go read
the file, and the file is always current. Same for a test that must pass, an
API to conform to, a commit that did this well last time.

Keep followUp small, and write \`run\` as though the node had never been here —
because on its first visit it never has, whatever the session has been doing.
A node that joins a thread another node opened still needs its own brief once,
and \`run\` is where that lives; \`followUp\` is every visit after, and should
carry only the delta. The bundled \`ship\` node is the shape to copy: a full
charter when it opens the pull request, and two sentences on every wake after
that, for however many weeks the PR stays open.

RUBRICS

--rubric (or --rubric-file, for anything long) is the standards the work is
held to, and every bundled prompt shows the same text to the implementer, the
verifier and the reviewer. That shared copy is the point: the reviewer is
otherwise blind, so a rubric is the only way to hold it and the implementer to
one definition of done.

Use it for what the task states but cannot enforce — what "done" means on this
codebase, what a reviewer here always catches, which checks actually matter.
Keep the task itself about what to build. Highest fidelity is again a pointer
into the repo rather than prose about it.

  af spawn --task "add retry to the upload path" \\
           --rubric-file .agentflow/review-rubric.md --repo /path
`,

  monitor: `MONITORING WITHOUT DROWNING

The transcripts are big. Read them in layers, most useful first:

  af ls                       is anything running at all
  af show <id>                per-node status, visits, duration, cost, ctx%,
                              and where the task would resume
  af log <id>                 the event history: node starts, outcomes, status
                              changes, notes, reruns — in order, one line each.
                              --since N skips what you already saw, so a
                              dispatcher waking up asks only for the delta.
  af log <id> <node> --index  one line per transcript event: index, type, tool,
                              first 120 chars. A 200KB transcript becomes 40
                              readable lines.
  af log <id> <node> --events 40-55
                              only those events, rendered readable.
  af log <id> <node> --grep "cargo test" --context 2
                              only matching events.
  af log <id> <node> --summary
                              the node's final result text, nothing else.

Waking up when something happens, rather than polling:

  af wait <id>                blocks until the task settles. Exit 0 succeeded,
                              1 failed, 2 timed out (--timeout S).
  af wait <id> --until node=review
                              blocks until the task reaches that node.

Run \`af wait\` in the background and let its exit re-invoke you; that beats
polling on an interval. The raw transcripts are also plain files at
~/.local/state/agentflow/logs/<task>/<node>-<visit>.log — rg and jq work fine
on them and never touch your context.
`,

  rerun: `RERUN, RETRY, AND SIDE EFFECTS

  af stop <id>       kills the running node's process inside the container and
                     keeps the checkpoint.
  af resume <id>     continues from that checkpoint.
  af rerun <id> ["why"] [--from NODE]
                     restarts at a node — any node, from any state, including a
                     parked one. Default: the last node that did not succeed.
                     Visit numbers keep counting up, so history is never
                     overwritten. The message is recorded before the node starts,
                     so it arrives on the turn this triggers rather than the next
                     one: a node sent back with no reason redoes what it did.

REROUTING VS ANSWERING

Both put the graph at a node and start it, and they are not the same thing.

  af approve <id> --label revise    follows the graph. The gate's edges decide
                                    where revise goes, so a graph that later
                                    routes revise through a replanning step
                                    keeps working and your answer does not
                                    change.
  af rerun <id> --from plan         overrides the graph. It goes where you said,
                                    edges ignored.

Answering is normal operation; rerouting is the escape hatch — for when the
right destination is not one the graph offers, or the gate has no way back at
all. Reach for the answer first: it stays correct as the workflow changes.

Two knobs:

  --session fresh    mint a new conversation for that node's session key. The
                     node re-reads its full prompt with no memory of earlier
                     attempts — as do any other nodes sharing that key.
                     Without it the agent continues its existing thread.

  --reset-workspace  restore the workspace's tracked files to their state when
                     that node last started.

WHAT --reset-workspace DOES NOT DO. It reverts files in this workspace. It
does not move bookmarks, un-push a branch, close a PR, delete a release, stop
a container the agent started, or undo an API call. The world outside the
workspace is not revertible, and this makes no attempt to pretend otherwise.
If the agent pushed a bookmark, the workspace files go back but the bookmark
and the remote do not — leaving the two disagreeing.

The real defense is idempotence, not rollback. Mark any node that touches the
outside with:

  { "id": "pr", "exec": "claude", "effects": "external", "run": "..." }

That makes rerun refuse without --force when such a node is reachable from
where you are restarting, and adds a clause to the node's prompt telling it to
check whether its earlier run already created the branch/PR/release and update
that instead of duplicating it.

Note the difference between a rerun and a revisit. A revisit is the graph
doing its job — review requests changes, the loop edge sends the implementer
back — and that agent re-enters its own conversation, so it knows what it
already did. Reruns and cold-session nodes have no such memory.
`,

  wait: `WAITING, AND TASKS THAT OUTLIVE THE WORK

A node with exec "wait" runs no process. It parks the task — status "waiting",
no fiber, and the container stopped if the wait is longer than two minutes —
until something wakes it. That is what lets one task watch a PR for a fortnight
at the cost of a stopped container, instead of a loop that burns tokens asking
whether anything happened yet.

Whatever wakes it becomes an outcome label, and edges route on it exactly as
they route on a shell node's exit code. Three things can wake one:

  on:      [{kind: "ci", label: "activity"}, …]
           an event of that kind arriving — from af emit, from another task, or
           from an agent's own emit tool
  after:   {min: "2m", max: "1h", factor: 2, label: "tick", resetOn: [...]}
           a timer. The delay grows by factor on each firing that found nothing
           and drops back to min when a real event arrives, so a quiet subject
           is polled hourly and a busy one every minute with nothing tuned.
           resetOn names labels on the run that led back here which also reset it
  ask:     "Push this and open a PR?"
           a question for the operator. Nothing proceeds without an answer

  settle:  "45s"
           after the first matching event, hold this long for more and restart
           the hold on each one. Eight review comments left in one sitting are
           one thing that happened; without this they are eight rounds of rework

Deadlines are absolute, so a laptop that slept through one wakes up already due.

ANSWERING

  af approve <id> --label L ["message"]   answer a gate. The labels it takes are
                                         the wait node's outgoing edges, so a
                                         graph decides its own answers
  af poke <id> [--force]                  stop waiting, go now
  af interject <id> "..."                 steer a parked task. A graph that
                                         declares what an operator note means
                                         routes on that; otherwise it just stirs

A poke is refused at a gate, because impatience does not say which answer you
meant, and on a budget park without --force, because that is a limit you set.

af ls shows a task waiting on a person as NEEDS YOU and groups it with the
failures; the dashboard does the same and counts them in the tab title. A task
waiting on a timer is working correctly and reads that way.

WHAT THIS CHANGES ABOUT FAILURE

A node the loop returns to will meet a rate limit or a dropped connection
eventually, and with no edge for "fail" that one moment ends a task meant to run
for weeks. Give those nodes a fail edge — usually back to the wait node, which
also means the backoff absorbs the retry. af spawn lints the graph and records
what it finds on the task.
`,

  budget: `COST CEILINGS

Three scopes, because they fail differently:

  per task     maxCostUsd on the spawn request
  per subtree  an ancestor's maxCostUsd bounds everything it spawned, which is
               the only scope that helps when a poller fans out — forty children
               each politely under their own cap is still forty children
  per window   ~/.config/agentflow/config.json, across every task on the host:

    {"budget": {"daily": 20, "weekly": 100}, "maxRunningTasks": 4, "maxChildren": 50}

ON BREACH THE TASK PARKS, IT DOES NOT FAIL. A week-old watcher killed over a
cost cap loses more than the cap saved, so it waits with waitingOn "budget" and
picks up when the window rolls. Nothing is created for a task that cannot run —
the check happens before the container, which is also what makes maxRunningTasks
work as a queue rather than as fifty containers all parked at once.

  af budget <id>                     what could park it, and what each has spent
  af budget <id> --max-cost 80       raise it; a raise resumes a task parked on
                                     cost, keeping the container and the session
                                     thread that a respawn would throw away
  af budget <id> --max-cost none     remove the ceiling entirely
  af poke <id> --force               spend past a park without moving the number

A RAISE IS NOT RETROACTIVE AND A CEILING IS NOT A CAP. The check runs before a
node starts, never during one, and nothing interrupts a turn already in flight.
So maxCostUsd is a stop-AFTER line: it decides whether the next node begins, not
how much the current one may spend. One turn can cross it by a lot — an agent
that fans out to subagents spends all of their budget inside a single turn, and
their cost only lands when it ends. $10 becoming $50 in one turn is the ordinary
behaviour of this design, not a bug in it. Size the ceiling for the turn you are
willing to pay for, not the total you want, and read the \`sub\` column in
af show to see where a surprising number came from.

Only agent nodes are checked. A shell node spends nothing, and stopping a poll
loop at one would strand it short of the wait node it needs to reach.

Codex nodes are checked too, but they contribute nothing to the number: they
run on a ChatGPT subscription, so there is no per-token price and no cost to
total. A graph that moved its expensive step to codex will look cheap here and
still be spending — the limit it runs into is the subscription's, not this one.
`,

  model: `MODELS AND PROVIDERS

Which agent runs a node is the node's \`exec\`: "claude" or "codex". Model and
effort resolve through four levels, nearest wins:

  node.model / node.effort           one node
  workflow.defaults[exec]            every node of that exec in the graph
  request.agents[exec]               every node of that exec in the task
  built in                           claude: claude-opus-5, effort high
                                     codex:  gpt-5.6-sol,   effort high

Every level is keyed by exec, which is what keeps a model name away from an
agent that never heard of it:

  agents: { claude: { model: "claude-opus-5", effort: "high" },
            codex:  { model: "gpt-5.6-sol" } }

The floor is stated rather than left to each CLI, because "the CLI's default"
is not one thing — claude follows the operator's subscription, and codex reads
a config.toml that for these tasks is the one the engine generates, so the
operator's own choice never reached it. A task is worth more than the cheapest
model that could have run it; say otherwise at any level above.

\`model\`/\`effort\` at the top of a request still work and mean claude.

Effort is "low" | "medium" | "high" for both agents. Codex accepts more names
than that; using one would make the workflow fail the day it was pointed at
claude, so the union is the two agents' overlap.

CREDENTIALS

Claude's is one opaque bearer token — no expiry you can read off it, nothing in
the container ever writes it, so every task can share the one in
CLAUDE_CODE_OAUTH_TOKEN or ~/.config/agentflow/token.

Codex's is a JWT plus a refresh token in a file the CLI rewrites on refresh, so
each task gets its own copy of it, retaken on every run and on every wake of a
parked task. Measured lifetime of the access token is 10 days, so a container
holding a copy for one task's length almost never refreshes at all.

Do not mount ~/.codex/auth.json in instead: read-write gives every task's codex
the same file to rewrite, and read-only forbids the refresh outright.

  CODEX_HOME=~/.config/agentflow/codex-home codex login
  cp ~/.config/agentflow/codex-home/auth.json ~/.config/agentflow/codex-auth.json

Copying your own ~/.codex/auth.json there works and is the same format — it is
just your desktop session, so on the rare run that does refresh, a rotated token
costs you that rather than a login you can reseed. Reseed the same way if codex
nodes start failing to authenticate.

WHAT DIFFERS PER AGENT

Codex has no cost telemetry (see "af help budget"), no context-window percentage
(only claude's windows are known, and a guessed one is worse than none), and no
model id beyond the one resolved for the node — codex exec never says what it
ran as, so that resolution is the only handle on it.
Tokens are reported for both. So is \`turns\`, meaning different things: claude's
counts assistant turns, codex's counts exec invocations — one, plus corrections.

Both get the task's MCP emit tool and the host's skills. Claude is told the
house style through --append-system-prompt; codex has no such flag, so it
arrives in the AGENTS.md of the private CODEX_HOME each task runs out of.
`,

  cache: `SHARED CACHES

The nix store is shared automatically: one docker volume per image build,
mounted at /nix in every task container. Without it each container downloads
its own store, which runs to tens of GB per task. Disable with
cache: { nix: false }.

Rebuilding the image strands the old volume at full size. \`af volumes\` marks
the leftovers and \`af volumes --prune\` removes them; prune before a rebuild
rather than after, since the new volume needs room to populate.

A \`nix develop\` gate snapshots the workspace into the store, filtered by the
repo's .gitignore. A repo that does not ignore its build output snapshots that
output on every run — which is what makes .venv and node_modules worth moving.

Everything else you declare, because only you know what the repo builds with.
Look at the repo first, then pass volumes plus the env that points the
toolchain at them:

  cache: {
    volumes: [{ name: "cargo-global",  at: "/cache/cargo" },
              { name: "myrepo-target", at: "/cache/target" }],
    env: { CARGO_HOME: "/cache/cargo", CARGO_TARGET_DIR: "/cache/target" }
  }

Same volume name in two tasks = one shared cache. That is the whole sharing
model: a name derived from the repo shares across tasks on that repo, a name
with the task id in it isolates. Concurrent tasks sharing a build dir
serialize on the toolchain's own lock rather than corrupting anything —
usually the right trade, but use distinct names when you want parallelism more
than reuse.

Recipes (copy and adjust; these are documentation, not built-in behavior):

  rust    CARGO_HOME=/cache/cargo (global), CARGO_TARGET_DIR=/cache/target (per repo)
  node    npm_config_cache=/cache/npm (global), pnpm store via PNPM_HOME=/cache/pnpm
  go      GOMODCACHE=/cache/gomod (global), GOCACHE=/cache/gobuild (per repo)
  python  UV_CACHE_DIR=/cache/uv, PIP_CACHE_DIR=/cache/pip (both global)

Moving .venv and node_modules out of the tree (both per repo, not global):

  python  UV_PROJECT_ENVIRONMENT=/cache/venv
  node    setup: "mkdir -p /cache/nm && ln -sfn /cache/nm node_modules"
          — no env var does it, but nix copies a symlink as a symlink.

  setup: "nix develop -c true"   runs once before the first node, so the agent
                                 is not paying tokens to watch a cold build.
  af volumes                     what exists now, and what is leftover.
`,
};

const topic = (name: string) =>
  TOPICS[name] ?? `no help topic "${name}". known: ${Object.keys(TOPICS).join(", ")}`;

// ---------------------------------------------------------------------------

const { _, flags } = parse(Deno.args);
const cmd = _[0] ?? "help";
const fn = commands[cmd];
if (!fn) {
  console.error(`unknown command "${cmd}"\n`);
  console.error(HELP);
  Deno.exit(64);
}
try {
  checkFlags(cmd, flags);
  await fn({ _: _.slice(1), flags });
} catch (e) {
  if (e instanceof UserError) {
    console.error(`af ${cmd}: ${e.message}`);
    console.error(`\ntry: af help ${cmd in TOPICS ? cmd : ""}`.trimEnd());
    Deno.exit(64);
  }
  const msg = e instanceof Error ? e.message : String(e);
  console.error(`af ${cmd}: ${msg}`);
  if (msg.includes("connection refused") || msg.includes("error sending request")) {
    console.error(`\nthe daemon is not answering at ${DAEMON}. start it with:`);
    console.error(`  cd ~/.dotfiles/agentflow && deno task daemon`);
  }
  Deno.exit(1);
}
