import { stateDir } from "./engine.ts";
import { bundled } from "./workflows.ts";
import {
  grepTranscript,
  indexTranscript,
  renderTranscript,
  sliceTranscript,
} from "./transcript.ts";
import type { TaskEventRecord } from "./model.ts";
import * as store from "./store.ts";
import * as tasks from "./tasks.ts";

const PORT = Number(Deno.env.get("AGENTFLOW_PORT") ?? 4200);
const WEB_ROOT = new URL("../web", import.meta.url).pathname;
const TYPES: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
};

// A rejected fire-and-forget promise anywhere must not kill the daemon.
globalThis.addEventListener("unhandledrejection", (e) => {
  console.error("unhandled rejection:", e.reason);
  e.preventDefault();
});

await Deno.mkdir(`${stateDir()}/ws`, { recursive: true });
await tasks.loadConfig();
await store.load();

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });

const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

const sse = (setup: (send: (event: string, data: unknown) => void) => () => void) => {
  let cleanup: (() => void) | undefined;
  let ping: ReturnType<typeof setInterval> | undefined;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const enc = new TextEncoder();
      const send = (event: string, data: unknown) => {
        try {
          controller.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        } catch {
          // controller already closed; cancel() handles cleanup
        }
      };
      ping = setInterval(() => send("ping", Date.now()), 15_000);
      cleanup = setup(send);
    },
    cancel() {
      clearInterval(ping);
      cleanup?.();
    },
  });
  return new Response(body, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
};

/**
 * Live task stream. With ?since=<seq> the backlog is replayed first, so a
 * dispatcher that was away misses nothing. The stream lives in memory, so the
 * backlog and the subscription are taken in one tick and nothing can land in
 * between — the seq check is belt-and-braces against a double send.
 */
const taskStream = (id: string, since?: number) =>
  sse((send) => {
    if (since === undefined) return store.subscribeTask(id, send);

    let lastSeq = since;
    for (const ev of store.events(id, since)) {
      lastSeq = Math.max(lastSeq, ev.seq);
      send("event", ev);
    }
    const unsubscribe = store.subscribeTask(id, (event, data) => {
      if (event === "event") {
        const ev = data as TaskEventRecord;
        if (ev.seq <= lastSeq) return;
        lastSeq = ev.seq;
      }
      send(event, data);
    });
    const task = store.get(id);
    if (task) send("update", store.updateFrame(task));
    return unsubscribe;
  });

/** transcript views: raw by default, or an index / slice / grep of it */
const transcript = async (id: string, node: string, visit: string, q: URLSearchParams) => {
  let raw: string;
  try {
    raw = await Deno.readTextFile(`${stateDir()}/logs/${id}/${node}-${visit}.log`);
  } catch {
    return text("no transcript", 404);
  }
  if (q.get("index") !== null) return json(indexTranscript(raw));
  const grep = q.get("grep");
  if (grep) {
    try {
      return json(grepTranscript(raw, grep, Number(q.get("context") ?? 1)));
    } catch (e) {
      return json({ error: `bad grep pattern: ${e instanceof Error ? e.message : e}` }, 400);
    }
  }
  const events = q.get("events");
  if (events) {
    const [from, to] = events.split("-").map(Number);
    if (!Number.isFinite(from)) return json({ error: "events wants A-B, e.g. 40-55" }, 400);
    raw = sliceTranscript(raw, from, Number.isFinite(to) ? to : from);
  }
  return text(q.get("render") !== null ? renderTranscript(raw) : raw);
};

const MEDIA: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
};
const TEXT = new Set(
  (".txt .log .md .json .jsonl .yaml .yml .toml .csv .diff .patch .html .htm .xml .sh .ts .js " +
    ".py .rs .go .sql .out .err").split(" "),
);

/**
 * A file out of a directory that was written from inside a container, which
 * is what makes two refusals necessary that a plain read would not need. A
 * path that resolves outside the directory — `..`, or a symlink the agent
 * planted, and the operator's codex credential sits on the same mount — is
 * checked after every link is resolved, not before. And nothing is served
 * with a type the browser would execute on this origin: HTML arrives as text,
 * every response is sandboxed and nosniffed, because a page the container
 * authored running here has the unauthenticated API of every task on the box.
 */
const serveFile = async (root: string, encoded: string, req: Request): Promise<Response> => {
  const segments = encoded.split("/").map((s) => {
    try {
      return decodeURIComponent(s);
    } catch {
      return "";
    }
  });
  if (segments.some((s) => !s || s === "." || s === ".." || /[\0/\\]/.test(s))) {
    return text("not found", 404);
  }
  const rel = segments.join("/");
  let rootReal: string;
  let fileReal: string;
  try {
    rootReal = await Deno.realPath(root);
    fileReal = await Deno.realPath(`${root}/${rel}`);
  } catch {
    return text("not found", 404);
  }
  if (!fileReal.startsWith(`${rootReal}/`)) return text("not found", 404);
  const stat = await Deno.stat(fileReal).catch(() => undefined);
  if (!stat?.isFile) return text("not found", 404);
  // the dashboard redraws its thumbnails on every update frame; a screenshot
  // that has not changed should cost a revalidation, not a download
  const etag = `"${stat.size}-${stat.mtime?.getTime() ?? 0}"`;
  if (req.headers.get("if-none-match") === etag) return new Response(null, { status: 304 });
  const ext = rel.slice(rel.lastIndexOf(".")).toLowerCase();
  const type = MEDIA[ext] ??
    (TEXT.has(ext) ? "text/plain; charset=utf-8" : "application/octet-stream");
  const file = await Deno.open(fileReal, { read: true });
  return new Response(file.readable, {
    headers: {
      "content-type": type,
      "content-length": String(stat.size),
      etag,
      "x-content-type-options": "nosniff",
      "content-security-policy": "sandbox",
      // an agent overwrites its screenshot; the operator reloads and sees the
      // new one
      "cache-control": "no-cache",
    },
  });
};

const route = async (req: Request, path: string, q: URLSearchParams): Promise<Response> => {
  const post = req.method === "POST";
  const body = post ? await req.json().catch(() => ({})) : {};

  if (path === "/api/board") return json(store.list());
  if (path === "/api/workflows") return json(bundled);
  if (path === "/api/board/events") return sse((send) => store.subscribeBoard(send));

  if (path === "/api/spawn" && post) {
    const { task, joined } = tasks.spawn(body);
    return json({ id: task.id, joined, record: task });
  }

  /**
   * A task is addressable by id or by key, because whoever is emitting into "the
   * task for PR 42" knows the PR and not the id agentflow gave it.
   */
  const m = path.match(/^\/api\/task\/([\w.:-]+)(\/.*)?$/);
  if (!m) return text("not found", 404);
  const [, handle, rest = ""] = m;
  const id = store.resolve(handle)?.id ?? handle;

  if (!rest) {
    const task = store.get(id);
    return task ? json(task) : json({ error: `no task "${id}"` }, 404);
  }

  if (rest === "/events") {
    const since = q.get("since");
    return taskStream(id, since === null ? undefined : Number(since) || 0);
  }
  if (rest === "/log") return json(store.events(id, Number(q.get("since") ?? 0)));

  if (rest === "/paths") return json(tasks.paths(id));
  if (rest === "/artifacts") return json(await tasks.artifacts(id));
  if (rest === "/meta") return json(post ? tasks.setMeta(id, body) : tasks.meta(id));
  // files out of the two directories agents write to: artifacts outlive the
  // workspace, refs go with it
  const file = rest.match(/^\/(artifacts|refs)\/(.+)$/);
  if (file && !post) {
    const p = tasks.paths(id);
    return await serveFile(file[1] === "refs" ? p.refs : p.artifacts, file[2], req);
  }
  // GET reads the ceilings that could park it and what each has spent; POST
  // moves this task's own, and resumes it when the move is what was holding it
  if (rest === "/budget") return json(post ? tasks.setBudget(id, body) : tasks.budget(id));
  if (rest === "/interject" && post) return json(tasks.interject(id, body));
  if (rest === "/emit" && post) return json(tasks.emit(id, body));
  if (rest === "/stop" && post) return json(await tasks.stop(id));
  if (rest === "/resume" && post) return json(tasks.resume(id));
  if (rest === "/poke" && post) return json(tasks.poke(id, body));
  if (rest === "/approve" && post) return json(tasks.approve(id, body));
  if (rest === "/rerun" && post) return json(await tasks.rerun(id, body));
  if (rest === "/cleanup" && post) return json(await tasks.cleanup(id, body));
  if (rest === "/remove" && post) {
    await tasks.remove(id);
    return json({ removed: id });
  }
  if (rest === "/workflow") {
    const task = store.get(id);
    if (!task) return json({ error: `no task "${id}"` }, 404);
    if (!post) return json(task.workflow);
    return json(tasks.setWorkflow(id, body.workflow ?? body, { interrupt: body.interrupt }));
  }
  if (rest === "/child-workflows") {
    const task = store.get(id);
    if (!task) return json({ error: `no task "${id}"` }, 404);
    if (!post) return json(task.request.childWorkflows ?? {});
    return json(tasks.setChildWorkflows(id, body.childWorkflows ?? body));
  }
  if (rest === "/task") {
    const task = store.get(id);
    if (!task) return json({ error: `no task "${id}"` }, 404);
    if (!post) return json({ task: task.request.task });
    return json(tasks.setTask(id, body.task ?? body.text, { interrupt: body.interrupt }));
  }

  const log = rest.match(/^\/log\/([\w-]+)\/(\d+)$/);
  if (log) return await transcript(id, log[1], log[2], q);

  return text("not found", 404);
};

Deno.serve({ port: PORT }, async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;

  if (path.startsWith("/api/")) {
    try {
      return await route(req, path, url.searchParams);
    } catch (e) {
      const status = e instanceof tasks.TaskError ? e.status : 500;
      const message = e instanceof Error ? e.message : String(e);
      if (status === 500) console.error(`${path} failed:`, e);
      return json({ error: message }, status);
    }
  }

  if (path === "/sdk.ts" || path === "/sdk") {
    const src = await Deno.readTextFile(new URL("../sdk/standalone.ts", import.meta.url));
    return new Response(src, { headers: { "content-type": "application/typescript" } });
  }

  const file = path === "/" ? "/index.html" : path;
  try {
    const body = await Deno.readFile(`${WEB_ROOT}${file}`);
    const ext = file.slice(file.lastIndexOf("."));
    return new Response(body, { headers: { "content-type": TYPES[ext] ?? "text/plain" } });
  } catch {
    return text("not found", 404);
  }
});

console.log(`agentflow dashboard: http://127.0.0.1:${PORT}`);

/**
 * The sweep runs the clock: due timers, settled bursts of events, and turns that
 * have gone silent long enough to be worth probing. Auto-resume comes after it
 * so a task the restart interrupted is picked up by a daemon that is already
 * watching, and after `serve` so the dashboard answers while containers start.
 */
tasks.startSweep();
tasks.autoResume().catch((e) => console.error("auto-resume failed:", e));

// Graceful shutdown: interrupt running workflows (their checkpoint at the
// current node is already persisted), kill in-container agent turns so a later
// revive doesn't contend with orphans on the same session, flush pending writes.
let shuttingDown = false;
const shutdown = async (signal: string) => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal}: checkpointing running tasks and shutting down…`);
  await tasks.stopAllForShutdown().catch((e) => console.error("shutdown sweep failed:", e));
  await store.flush();
  Deno.exit(0);
};
Deno.addSignalListener("SIGINT", () => shutdown("SIGINT"));
Deno.addSignalListener("SIGTERM", () => shutdown("SIGTERM"));
