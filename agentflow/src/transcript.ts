/**
 * Queries over a node's stream-json transcript.
 *
 * A single agent turn can produce hundreds of KB of JSON. Anything that reads
 * one — a dispatcher LLM most of all — needs to see its shape before deciding
 * what to pull, so the primitives here are: an index (one line per event),
 * a slice (just these events), and a grep (just the matching events).
 */

export interface TranscriptEvent {
  /** 1-based position in the transcript */
  i: number;
  /** system | assistant | thinking | tool_use | tool_result | result | raw */
  type: string;
  /** tool name for tool_use events */
  tool?: string;
  /** first line of the payload, truncated */
  preview: string;
  /** size of the underlying json line, so callers can predict a fetch */
  chars: number;
  /** 0-based json line this row came from; several rows can share one line */
  line: number;
}

const clip = (s: string, n: number) => {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > n ? flat.slice(0, n) + "…" : flat;
};

const jsonLines = (raw: string) => raw.split("\n").filter((l) => l.trim());

/**
 * One row per meaningful event. An assistant message with three tool calls
 * becomes four rows (text + three tool_use), because "which call was that"
 * is the question this index exists to answer.
 */
export const indexTranscript = (raw: string): TranscriptEvent[] => {
  const out: TranscriptEvent[] = [];
  let i = 0;
  let lineNo = -1;
  const push = (e: Omit<TranscriptEvent, "i" | "line">) => out.push({ i: ++i, line: lineNo, ...e });

  for (const line of jsonLines(raw)) {
    lineNo++;
    const chars = line.length;
    // deno-lint-ignore no-explicit-any
    let ev: any;
    try {
      ev = JSON.parse(line);
    } catch {
      push({ type: "raw", preview: clip(line, 120), chars });
      continue;
    }
    switch (ev.type) {
      case "system":
        push({
          type: "system",
          preview: clip(`${ev.subtype ?? ""} ${ev.model ?? ""}`, 120),
          chars,
        });
        break;
      case "assistant":
        for (const c of ev.message?.content ?? []) {
          if (c.type === "text" && c.text?.trim()) {
            push({ type: "assistant", preview: clip(c.text, 120), chars });
          } else if (c.type === "thinking" && c.thinking?.trim()) {
            push({ type: "thinking", preview: clip(c.thinking, 120), chars });
          } else if (c.type === "tool_use") {
            push({
              type: "tool_use",
              tool: c.name,
              preview: clip(JSON.stringify(c.input ?? {}), 120),
              chars,
            });
          }
        }
        break;
      case "user":
        for (const c of ev.message?.content ?? []) {
          if (c.type !== "tool_result") continue;
          const body = Array.isArray(c.content)
            ? c.content.map((x: { text?: string }) => x.text ?? "").join(" ")
            : String(c.content ?? "");
          push({
            type: "tool_result",
            preview: clip(body, 120),
            chars: body.length,
          });
        }
        break;
      case "result":
        push({
          type: "result",
          preview: clip(
            `${ev.subtype ?? "?"} · ${ev.num_turns ?? "?"} turns · ${ev.result ?? ""}`,
            160,
          ),
          chars,
        });
        break;
      default:
        push({ type: String(ev.type ?? "raw"), preview: clip(line, 120), chars });
    }
  }
  return out;
};

/** readable plain-text rendering of a transcript (or a slice of one) */
export const renderTranscript = (raw: string): string => {
  const out: string[] = [];
  for (const line of jsonLines(raw)) {
    // deno-lint-ignore no-explicit-any
    let ev: any;
    try {
      ev = JSON.parse(line);
    } catch {
      out.push(line);
      continue;
    }
    switch (ev.type) {
      case "system":
        out.push(`· session ${ev.subtype ?? ""} ${ev.model ?? ""}`.trimEnd());
        break;
      case "assistant":
        for (const c of ev.message?.content ?? []) {
          if (c.type === "text" && c.text?.trim()) out.push(c.text.trim());
          else if (c.type === "thinking" && c.thinking?.trim()) {
            out.push(`  (thinking) ${clip(c.thinking, 400)}`);
          } else if (c.type === "tool_use") {
            out.push(`  ⚒ ${c.name} ${clip(JSON.stringify(c.input ?? {}), 300)}`);
          }
        }
        break;
      case "user":
        for (const c of ev.message?.content ?? []) {
          if (c.type !== "tool_result") continue;
          const body = Array.isArray(c.content)
            ? c.content.map((x: { text?: string }) => x.text ?? "").join(" ")
            : String(c.content ?? "");
          out.push(`  ← ${clip(body, 300)}`);
        }
        break;
      case "result":
        out.push(`── result (${ev.subtype ?? "?"}, ${ev.num_turns ?? "?"} turns) ──`);
        if (ev.result) out.push(String(ev.result));
        break;
    }
  }
  return out.join("\n");
};

/** the raw json lines backing index rows [from, to] (1-based, inclusive) */
export const sliceTranscript = (raw: string, from: number, to: number): string => {
  const lines = jsonLines(raw);
  const wanted = new Set(
    indexTranscript(raw).filter((e) => e.i >= from && e.i <= to).map((e) => e.line),
  );
  return [...wanted].sort((a, b) => a - b).map((n) => lines[n]).join("\n");
};

/** index rows matching a regex, with surrounding context rows */
export const grepTranscript = (
  raw: string,
  pattern: string,
  context = 1,
): TranscriptEvent[] => {
  const idx = indexTranscript(raw);
  const re = new RegExp(pattern, "i");
  const keep = new Set<number>();
  idx.forEach((e, n) => {
    if (!re.test(e.preview) && !re.test(e.tool ?? "")) return;
    for (let k = Math.max(0, n - context); k <= Math.min(idx.length - 1, n + context); k++) {
      keep.add(k);
    }
  });
  return [...keep].sort((a, b) => a - b).map((n) => idx[n]);
};
