import { registry } from "./registry.ts";
import type { Registry } from "./registry.ts";
import { stateDir } from "./engine.ts";
import { createClient } from "rivetkit/client";

await Deno.mkdir(`${stateDir()}/ws`, { recursive: true });

// A rejected fire-and-forget promise anywhere (rivet client retries, ws proxy)
// must not kill the daemon.
globalThis.addEventListener("unhandledrejection", (e) => {
  console.error("unhandled rejection:", e.reason);
  e.preventDefault();
});

registry.start();

// Static server for the dashboard. The dashboard talks to the rivet engine
// (default http://127.0.0.1:6420) directly from the browser.
const WEB_ROOT = new URL("../web", import.meta.url).pathname;
const TYPES: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
};

const ENGINE = "127.0.0.1:6420";

// Chrome fails direct browser->engine requests with ERR_ALPN_NEGOTIATION_FAILED,
// so the dashboard talks same-origin and we pipe /rivet/* through to the engine.
const proxy = (req: Request, path: string): Response | Promise<Response> => {
  const url = new URL(req.url);
  const target = `${path}${url.search}`;
  if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
    const protocols = req.headers.get("sec-websocket-protocol")?.split(",").map((s) => s.trim());
    const { socket: client, response } = Deno.upgradeWebSocket(req, {
      protocol: protocols?.[0],
    });
    try {
      const upstream = new WebSocket(`ws://${ENGINE}${target}`, protocols ?? []);
      upstream.binaryType = "arraybuffer";
      const buffer: (string | ArrayBufferLike)[] = [];
      upstream.onopen = () => buffer.splice(0).forEach((m) => upstream.send(m));
      client.onmessage = (e) =>
        upstream.readyState === WebSocket.OPEN ? upstream.send(e.data) : buffer.push(e.data);
      upstream.onmessage = (e) => client.readyState === WebSocket.OPEN && client.send(e.data);
      client.onclose = () => upstream.readyState <= WebSocket.OPEN && upstream.close();
      upstream.onclose = () => client.readyState <= WebSocket.OPEN && client.close();
      client.onerror = () => upstream.readyState <= WebSocket.OPEN && upstream.close();
      upstream.onerror = (e) => {
        console.error("ws proxy upstream error", target, e instanceof ErrorEvent ? e.message : e);
        if (client.readyState <= WebSocket.OPEN) client.close();
      };
    } catch (e) {
      console.error("ws proxy setup failed", target, e);
      // upgrade already happened; close the client socket once it opens
      client.onopen = () => client.close(1011, "proxy failure");
    }
    return response;
  }
  return fetch(`http://${ENGINE}${target}`, {
    method: req.method,
    headers: req.headers,
    body: req.body,
    redirect: "manual",
  });
};

// The dashboard talks only to this server (plain fetch + SSE); we bridge to
// rivet with the in-process client, which is far more reliable than the
// browser client through Chrome.
const api = createClient<Registry>({ endpoint: `http://${ENGINE}` });
const apiBoard = api.board.getOrCreate(["main"]);

const json = (data: unknown) =>
  new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } });

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

Deno.serve({ port: 4200 }, async (req) => {
  const path = new URL(req.url).pathname;
  if (path.startsWith("/rivet/") || path === "/rivet") {
    return proxy(req, path.slice("/rivet".length) || "/");
  }

  if (path === "/api/board") return json(await apiBoard.list());

  if (path === "/api/workflows") {
    const { bundled } = await import("./workflows.ts");
    return json(bundled);
  }

  if (path === "/api/board/events") {
    return sse((send) => {
      const conn = apiBoard.connect();
      conn.on("board", (list: unknown) => send("board", list));
      return () => conn.dispose();
    });
  }

  const taskMatch = path.match(/^\/api\/task\/([\w-]+)$/);
  if (taskMatch) return json(await api.task.getOrCreate([taskMatch[1]]).getState());

  const interjectMatch = path.match(/^\/api\/task\/([\w-]+)\/interject$/);
  if (interjectMatch && req.method === "POST") {
    const body = await req.json();
    return json(await api.task.getOrCreate([interjectMatch[1]]).interject(body));
  }

  const cleanupMatch = path.match(/^\/api\/task\/([\w-]+)\/cleanup$/);
  if (cleanupMatch && req.method === "POST") {
    try {
      const body = await req.json();
      return json(await api.task.getOrCreate([cleanupMatch[1]]).cleanup(body));
    } catch (e) {
      return new Response(String(e instanceof Error ? e.message : e), { status: 409 });
    }
  }

  const removeMatch = path.match(/^\/api\/task\/([\w-]+)\/remove$/);
  if (removeMatch && req.method === "POST") {
    await api.task.getOrCreate([removeMatch[1]]).remove();
    return json({ removed: removeMatch[1] });
  }

  const logMatch = path.match(/^\/api\/task\/([\w-]+)\/log\/([\w-]+)\/(\d+)$/);
  if (logMatch) {
    try {
      const body = await Deno.readTextFile(
        `${stateDir()}/logs/${logMatch[1]}/${logMatch[2]}-${logMatch[3]}.log`,
      );
      return new Response(body, { headers: { "content-type": "text/plain" } });
    } catch {
      return new Response("no transcript", { status: 404 });
    }
  }

  const eventsMatch = path.match(/^\/api\/task\/([\w-]+)\/events$/);
  if (eventsMatch) {
    return sse((send) => {
      const conn = api.task.getOrCreate([eventsMatch[1]]).connect();
      conn.on("update", (t: unknown) => send("update", t));
      conn.on("node", (r: unknown) => send("node", r));
      conn.on("log", (l: unknown) => send("log", l));
      return () => conn.dispose();
    });
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
    return new Response("not found", { status: 404 });
  }
});

console.log("agentflow dashboard: http://127.0.0.1:4200");

// Graceful shutdown: interrupt running workflows (their checkpoint at the
// current node is already persisted), kill in-container agent turns so a
// later revive doesn't contend with orphans on the same session, give rivet
// a moment to flush state, then take the engine child down with us.
let shuttingDown = false;
const shutdown = async (signal: string) => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal}: checkpointing running tasks and shutting down…`);
  try {
    const tasks = await apiBoard.list() as { id: string; status: string }[];
    for (const t of tasks) {
      if (t.status !== "running" && t.status !== "starting") continue;
      const handle = api.task.getOrCreate([t.id]);
      const rec = await handle.getState().catch(() => null);
      await handle.stop().catch(() => {});
      if (rec?.container) {
        await new Deno.Command("docker", {
          args: ["exec", rec.container, "pkill", "-f", "claude"],
          stdout: "null",
          stderr: "null",
        }).output().catch(() => {});
      }
      console.log(`stopped ${t.id} (resume with interject after restart)`);
    }
  } catch (e) {
    console.error("shutdown sweep failed:", e);
  }
  // rivet persists actor state on a ~1s throttle; let it flush
  await new Promise((r) => setTimeout(r, 2000));
  await new Deno.Command("pkill", { args: ["-f", "rivet-engine"], stdout: "null", stderr: "null" })
    .output().catch(() => {});
  Deno.exit(0);
};
Deno.addSignalListener("SIGINT", () => shutdown("SIGINT"));
Deno.addSignalListener("SIGTERM", () => shutdown("SIGTERM"));
