/**
 * The `emit`, `spawn` and `meta` tools, as a stdio MCP server claude and codex
 * load inside a task container.
 *
 * It publishes to a spool file on the workspace mount, which the host daemon
 * already has open — no port, no token, nothing for a prompt-injected agent to
 * reach past. The alternative was handing the container an HTTP client for the
 * daemon's API, which is unauthenticated and can spawn, stop and remove every
 * other task on the host.
 *
 * Deliberately not exposed: `urgent`. It interrupts a running node, and the
 * engine runs exactly one node at a time, so from in here the only node it
 * could ever interrupt is this one.
 */
import { appendFileSync } from "node:fs";

const OUTBOX = process.env.AF_OUTBOX;
const FROM = process.env.AF_NODE ?? "agent";

/**
 * The one directory backing files belong in. Without a named place, every cold
 * session invents its own — and the tempting spot is the checkout, where a
 * scratch file lands in the diff the reviewer is judging.
 */
const REFS = process.env.AF_REFS;

/**
 * Generous on purpose: an event that had to be cut down to fit is an event
 * that lost the part someone needed. This is only here so a stray `cat` of a
 * large file into the summary cannot swallow every downstream prompt.
 */
const SUMMARY_MAX = 16000;

const PARENT = process.env.AF_PARENT;
const SELF = process.env.AF_TASK;

/**
 * Graphs this task was given for its children, by name. The image is generic
 * across every task, so the list arrives as an env var rather than being baked
 * in — and it is a name only. A graph contains shell nodes, so a definition
 * arriving from in here would be arbitrary command execution downstream of
 * whatever text this agent last read.
 *
 * This is presentation. The host resolves the name against the same task's
 * declarations when it drains the spool, which is the check that counts: an
 * env var lives in the container and the container is what is being bounded.
 */
const BUNDLED = ["implement-review", "implement-pr", "survey", "quick"];
const DECLARED = (() => {
  try {
    const names = JSON.parse(process.env.AF_CHILD_WORKFLOWS ?? "[]");
    if (!Array.isArray(names)) return [];
    return names.filter((n) => typeof n === "string" && n && !BUNDLED.includes(n));
  } catch {
    return [];
  }
})();

const EMIT = {
  name: "emit",
  // No list of things worth publishing, deliberately: naming four of them
  // fences the model into those four. The situation — they read the diff and
  // nothing else of yours — is what it needs to work out the rest. Who
  // actually receives an event is not restated here either; the workflow map
  // in the agent's prompt is where that lives, and it cannot drift from the
  // graph the way a sentence in here would.
  description:
    "Tell the rest of this workflow something. Agent nodes on this task receive what you publish " +
    "here on their next turn — the workflow map in your prompt says what each one is for, and " +
    "some accept only certain kinds. They read the diff already; this is for what the diff " +
    "cannot carry. Publishing nothing is a fine turn.",
  inputSchema: {
    type: "object",
    required: ["summary"],
    properties: {
      summary: {
        type: "string",
        description:
          "The whole event as far as the reader is concerned. One or two sentences when `refs` " +
          "points at the detail; a paragraph when there is nowhere to point.",
      },
      refs: {
        type: "array",
        items: { type: "string" },
        description:
          "Where a reader who cares can go deeper: a URL, an issue, or a path. Nothing fetches " +
          "these — they exist so the summary can stay a summary." +
          (REFS
            ? ` Anything you write for another agent to read goes in ${REFS}, which sits outside ` +
              `the checkout so it never lands in the diff under review, and which every agent on ` +
              `this task is told to look in. Read what is already there before adding to it.`
            : ""),
      },
      kind: {
        type: "string",
        description:
          'What sort of event this is; nodes filter on it. Default "handoff", meaning context ' +
          "for whoever works on this next. Pick another word when it is plainly not that.",
      },
      to: {
        type: "array",
        items: { type: "string" },
        description:
          "Node ids this is for, from the workflow map in your prompt. Omit to reach every " +
          "agent node, which is usually right — a node that does not care filters it out, and " +
          "guessing wrong means the one who needed it never hears.",
      },
      key: {
        type: "string",
        description:
          "Set when this event restates a fact rather than adding one, using the same key each " +
          "time. Only the newest event per key is delivered, so the reader sees where something " +
          "ended up instead of every step it took to get there.",
      },
      task: {
        type: "string",
        description:
          "Another task this is for, by id or key. Omit for this one, which is almost always " +
          "right. Only this task's own parent and the tasks it spawned can be reached; anything " +
          "else is refused" +
          (PARENT ? `. This task's parent is ${PARENT}.` : ", and this task has no parent."),
      },
    },
  },
};

/**
 * Spawning is asynchronous and cannot be otherwise: this writes to a spool the
 * daemon reads host-side, and it reads it when the turn ends. So the tool
 * promises a request rather than a task, and the id comes back as an event —
 * which is also how the caller learns a key was already taken.
 */
const SPAWN = {
  name: "spawn",
  description:
    "Ask for another task, with its own container and its own workflow. Use it to break work " +
    "into pieces that should run and be judged separately rather than as more turns of this one. " +
    "The daemon creates it when this turn ends and publishes the result to this task, so the id " +
    "arrives on a later turn rather than in this reply.",
  inputSchema: {
    type: "object",
    required: ["task"],
    properties: {
      task: {
        type: "string",
        description:
          "The assignment for the new task, written for an agent that has none of your context " +
          "and cannot ask: what the job is, and whatever it could not find out by looking. Name " +
          "the files, commands and interfaces it should look at rather than describing them — it " +
          "can read them, and a pointer stays true as the code moves. What you make of the work " +
          "is not part of the assignment: findings, suspicions, a verdict on someone else's " +
          "decision are conclusions the new agent starts from rather than reaches, which costs " +
          "you the independent read that a separate task was for. If writing it meant doing the " +
          "job first, you are doing the job.",
      },
      title: {
        type: "string",
        description:
          "A few words naming what this task is for. It becomes the task's id and the name of its " +
          "jj workspace, which the operator reads in their own repo later.",
      },
      key: {
        type: "string",
        description:
          "Stable name for the subject this task is about — the PR, the issue, the file. " +
          "Spawning again with a key that a live task already holds joins that task instead of " +
          "making a second one, so re-asserting the same set on every lap of a loop is safe and " +
          "costs nothing. Letters, digits and . : _ - only.",
      },
      workflow: {
        enum: [...DECLARED, ...BUNDLED],
        description:
          "implement-review writes a change and has it verified and reviewed. implement-pr does " +
          "that and then opens a PR and watches it. survey is a loop that keeps looking at " +
          "something. quick is one agent turn, unchecked. Defaults to implement-review." +
          (DECLARED.length
            ? ` Then ${
              DECLARED.join(", ")
            }: graphs written for this task in particular and carried ` +
              `by no other, described in your own task rather than here.`
            : ""),
      },
      gates: {
        type: "string",
        description: "how the new task's work should be checked, if you know the command",
      },
      rubric: {
        type: "string",
        description:
          "The standard the new task is held to, seen by its implementer and both of its judges. " +
          "A pointer at code that already gets this right carries further than a description of it.",
      },
      setup: {
        type: "string",
        description:
          "One shell command run in the new task's empty workspace before its first node — how " +
          "code gets there at all when the task has no repository of its own.",
      },
      maxCostUsd: {
        type: "number",
        description:
          "Ceiling on what the new task may spend. It parks rather than failing when it hits it, " +
          "so this bounds cost without losing work.",
      },
      meta: {
        type: "object",
        additionalProperties: { type: "string" },
        description:
          "Facts the new task starts with, key → string, shown on its dashboard page. `pr` is " +
          "the URL of the pull request the task is about and becomes the link on its board row — " +
          "set it whenever the task has one, so the operator reaches the PR from the board " +
          "instead of asking. The task's own nodes can add keys later.",
      },
    },
  },
};

/**
 * Metadata is what a node records for people first: the bag sits on the task
 * record, the dashboard shows it, and the board row shows `pr`. Later nodes
 * read it back as {{meta.<key>}}. Same spool as everything else, so it lands
 * when the turn ends — which the reply says, so the model does not read the
 * record back expecting to find it there already.
 */
const META_KEY = /^[A-Za-z][\w.-]{0,63}$/;
const META = {
  name: "meta",
  description:
    "Attach a fact to this task — a key and a value — for the operator and for later nodes. The " +
    "operator sees it on the task's page without reading your transcript, and `pr`, the URL of " +
    "the pull request this task's work is in, on the board itself; later nodes of this workflow " +
    "read it as {{meta.<key>}}. Applied when this turn ends. For telling another node something " +
    "that happened, use emit.",
  inputSchema: {
    type: "object",
    required: ["set"],
    properties: {
      set: {
        type: "object",
        additionalProperties: { type: ["string", "null"] },
        description:
          "Keys to write, a string each; null removes a key. A key starts with a letter and is " +
          "letters, digits, . _ - only; a value is at most 2000 characters — point at a file in " +
          "$AF_ARTIFACTS for anything longer. `pr` has to be an http(s) URL.",
      },
    },
  },
};

const TOOLS = [EMIT, SPAWN, META];

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const ok = (id, result) => send({ jsonrpc: "2.0", id, result });
const say = (id, text, isError) => ok(id, { content: [{ type: "text", text }], isError });

const append = (line) => {
  if (!OUTBOX) return "this container has no outbox; nothing was sent";
  appendFileSync(OUTBOX, JSON.stringify(line) + "\n");
  return undefined;
};

const spawn = (id, args) => {
  const task = typeof args.task === "string" ? args.task.trim() : "";
  if (!task) return say(id, "task is required and must be a non-empty string", true);
  const pick = (k) => (typeof args[k] === "string" && args[k].trim() ? args[k].trim() : undefined);
  const failed = append({
    op: "spawn",
    from: FROM,
    task,
    title: pick("title"),
    key: pick("key"),
    workflow: pick("workflow"),
    gates: pick("gates"),
    rubric: pick("rubric"),
    setup: pick("setup"),
    maxCostUsd: typeof args.maxCostUsd === "number" ? args.maxCostUsd : undefined,
    meta: typeof args.meta === "object" && args.meta !== null && !Array.isArray(args.meta)
      ? args.meta
      : undefined,
  });
  if (failed) return say(id, failed, true);
  return say(
    id,
    `requested. The daemon creates it when this turn ends and tells this task what it got — the ` +
      `id, or that a live task already held the key. Nothing is waiting on you meanwhile.`,
  );
};

const meta = (id, args) => {
  const set = args.set;
  if (typeof set !== "object" || set === null || Array.isArray(set)) {
    return say(id, "set is required: an object of key → string, with null to remove a key", true);
  }
  const keys = Object.keys(set);
  if (!keys.length) return say(id, "set is empty; nothing was recorded", true);
  for (const key of keys) {
    if (!META_KEY.test(key)) {
      return say(
        id,
        `"${key}" is not a usable key: start with a letter, then letters, digits, . _ -`,
        true,
      );
    }
    const value = set[key];
    if (value !== null && typeof value !== "string") {
      return say(id, `${key} must be a string, or null to remove it`, true);
    }
    if (typeof value === "string" && value.length > 2000) {
      return say(
        id,
        `${key} is ${value.length} characters and the limit is 2000. Nothing was recorded — write ` +
          `the detail to a file under $AF_ARTIFACTS and record its path instead.`,
        true,
      );
    }
    if (key === "pr" && value !== null && !/^https?:\/\/\S+$/.test(value.trim())) {
      return say(id, "pr must be an http(s) URL; the board shows it as a link", true);
    }
  }
  const failed = append({ op: "meta", from: FROM, set });
  if (failed) return say(id, failed, true);
  return say(
    id,
    `recorded ${keys.join(", ")}. It is applied when this turn ends; from then on the dashboard ` +
      `shows it and later nodes can read {{meta.<key>}}. Refused values come back as an event.`,
  );
};

const call = (id, params) => {
  if (params?.name === META.name) return meta(id, params.arguments ?? {});
  if (params?.name === SPAWN.name) return spawn(id, params.arguments ?? {});
  if (params?.name !== EMIT.name) return say(id, `no tool "${params?.name}"`, true);
  const args = params.arguments ?? {};
  const summary = typeof args.summary === "string" ? args.summary.trim() : "";
  if (!summary) return say(id, "summary is required and must be a non-empty string", true);
  if (summary.length > SUMMARY_MAX) {
    return say(
      id,
      `summary is ${summary.length} characters and the limit is ${SUMMARY_MAX}. Nothing was ` +
        `published. Send it again shorter — if the length is a file or a transcript you pasted ` +
        `in, put its path in refs and describe it in a sentence instead.`,
      true,
    );
  }
  if (!OUTBOX) return say(id, "this container has no outbox; nothing was published", true);

  const list = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string" && x) : undefined);
  const elsewhere = typeof args.task === "string" && args.task.trim() && args.task.trim() !== SELF
    ? args.task.trim()
    : undefined;
  const event = {
    kind: typeof args.kind === "string" && args.kind.trim() ? args.kind.trim() : "handoff",
    from: FROM,
    to: list(args.to)?.length ? list(args.to) : "*",
    message: summary,
    refs: list(args.refs),
    key: typeof args.key === "string" && args.key.trim() ? args.key.trim() : undefined,
    task: elsewhere,
  };
  try {
    const failed = append(event);
    if (failed) return say(id, failed, true);
  } catch (e) {
    return say(id, `could not publish: ${e?.message ?? e}`, true);
  }
  if (elsewhere) {
    return say(
      id,
      `sent to ${elsewhere}. It is delivered when this turn ends, and refused there if that task ` +
        `is neither this one's parent nor one it spawned — you will see either outcome as an event.`,
    );
  }
  const to = event.to === "*" ? "every agent node" : event.to.join(", ");
  return say(id, `published to ${to}; they see it on their next turn`);
};

const handle = (msg) => {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return ok(id, {
      // echo the client's version rather than pinning one: this server is two
      // methods deep and every revision of the protocol has had both
      protocolVersion: params?.protocolVersion ?? "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "af", version: "1.0.0" },
    });
  }
  if (method === "tools/list") return ok(id, { tools: TOOLS });
  if (method === "tools/call") return call(id, params);
  // notifications carry no id and want no reply
  if (id !== undefined) {
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: `unknown method "${method}"` } });
  }
};

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch {
      // a malformed frame has no id to answer on; dropping it is all we can do
    }
  }
});
