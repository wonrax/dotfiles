/**
 * A small JSON Schema subset used as the output contract for agent nodes.
 *
 * Why JSON Schema and not something bespoke: a workflow is data — it lives in
 * a JSON file, travels over REST, and is editable in the dashboard — so the
 * schema has to be data too, which rules out zod and friends. JSON Schema is
 * also the shape every model has seen a million times through tool calling.
 *
 * Why the agent is shown a TypeScript type instead: nobody reads JSON Schema
 * fluently, models included, and unions in particular are far clearer as
 * `"approve" | "request_changes"` than as an `enum` array. So the schema is
 * authored and validated as data, and rendered to TypeScript for the prompt.
 * One source of truth, presented in the notation each side reads best.
 */

export interface JsonSchema {
  type?: "object" | "string" | "number" | "integer" | "boolean" | "array" | "null";
  /** rendered as a comment above the field, so it reaches the agent */
  description?: string;
  enum?: (string | number | boolean | null)[];
  const?: string | number | boolean | null;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  /** false rejects unknown keys; omitted allows them */
  additionalProperties?: boolean;
  items?: JsonSchema;
  /** union — the value must satisfy at least one branch */
  anyOf?: JsonSchema[];
  minItems?: number;
  minLength?: number;
}

const typeOf = (v: unknown): string => {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
};

const show = (v: unknown): string => {
  const s = typeof v === "string" ? JSON.stringify(v) : JSON.stringify(v) ?? String(v);
  return s.length > 60 ? s.slice(0, 60) + "…" : s;
};

/**
 * Validate a parsed value, returning human-readable errors addressed to the
 * agent that produced it. Messages name the path and say what was expected
 * versus what arrived — they are fed back verbatim as the correction, so
 * vagueness here costs a retry.
 */
export const validate = (schema: JsonSchema, value: unknown, path = ""): string[] => {
  const at = path || "(root)";
  const errors: string[] = [];

  if (schema.anyOf?.length) {
    const branches = schema.anyOf.map((s) => validate(s, value, path));
    if (branches.every((e) => e.length)) {
      errors.push(`${at}: did not match any allowed shape (${show(value)})`);
    }
    return errors;
  }

  if (schema.const !== undefined && value !== schema.const) {
    return [`${at}: must be ${show(schema.const)}, got ${show(value)}`];
  }

  if (schema.enum) {
    if (!schema.enum.includes(value as string)) {
      return [
        `${at}: must be one of ${schema.enum.map(show).join(" | ")}, got ${show(value)}`,
      ];
    }
    return errors;
  }

  if (schema.type) {
    const actual = typeOf(value);
    const ok = schema.type === "integer"
      ? actual === "number" && Number.isInteger(value)
      : actual === schema.type;
    const article = /^[aeio]/.test(schema.type) ? "an" : "a";
    if (!ok) return [`${at}: must be ${article} ${schema.type}, got ${actual}`];
  }

  if (schema.type === "string" && typeof value === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${at}: must be at least ${schema.minLength} characters`);
    }
  }

  if (schema.type === "array" && Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${at}: must have at least ${schema.minItems} item(s)`);
    }
    if (schema.items) {
      value.forEach((item, i) => errors.push(...validate(schema.items!, item, `${path}[${i}]`)));
    }
  }

  if (schema.type === "object" && typeOf(value) === "object") {
    const obj = value as Record<string, unknown>;
    for (const key of schema.required ?? []) {
      if (!(key in obj)) errors.push(`${path ? path + "." : ""}${key}: required field is missing`);
    }
    for (const [key, sub] of Object.entries(schema.properties ?? {})) {
      if (key in obj) errors.push(...validate(sub, obj[key], `${path ? path + "." : ""}${key}`));
    }
    if (schema.additionalProperties === false) {
      const known = new Set(Object.keys(schema.properties ?? {}));
      for (const key of Object.keys(obj)) {
        if (!known.has(key)) errors.push(`${at}: unexpected field "${key}"`);
      }
    }
  }

  return errors;
};

/** Render a schema as a TypeScript type, which is what the agent is shown. */
/**
 * Field descriptions are where a contract's usage guidance lives, so they are
 * often a sentence or three. Wrapped rather than emitted as one long line —
 * the type is the thing the agent actually reads, and it should read like
 * source, not like a spreadsheet cell.
 */
const commentBlock = (description: string, indent: string): string => {
  const width = Math.max(40, 88 - indent.length);
  const lines: string[] = [];
  for (const paragraph of description.split("\n")) {
    let line = "";
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      if (line && line.length + 1 + word.length > width) {
        lines.push(line);
        line = word;
      } else line = line ? `${line} ${word}` : word;
    }
    lines.push(line);
  }
  return lines.map((l) => `${indent}// ${l}`.trimEnd()).join("\n") + "\n";
};

export const toTypeScript = (schema: JsonSchema, indent = ""): string => {
  if (schema.anyOf?.length) return schema.anyOf.map((s) => toTypeScript(s, indent)).join(" | ");
  if (schema.const !== undefined) return JSON.stringify(schema.const);
  if (schema.enum) return schema.enum.map((v) => JSON.stringify(v)).join(" | ");

  switch (schema.type) {
    case "array":
      return schema.items ? `${wrapUnion(toTypeScript(schema.items, indent))}[]` : "unknown[]";
    case "object": {
      const inner = indent + "  ";
      const required = new Set(schema.required ?? []);
      const fields = Object.entries(schema.properties ?? {}).map(([key, sub]) => {
        const comment = sub.description ? commentBlock(sub.description, inner) : "";
        return `${comment}${inner}${key}${required.has(key) ? "" : "?"}: ${
          toTypeScript(sub, inner)
        }`;
      });
      return fields.length ? `{\n${fields.join("\n")}\n${indent}}` : "Record<string, unknown>";
    }
    case "integer":
      return "number";
    case undefined:
      return "unknown";
    default:
      return schema.type;
  }
};

/** unions need parens before a [] suffix */
const wrapUnion = (ts: string) => (ts.includes(" | ") ? `(${ts})` : ts);

/**
 * Pull a JSON object out of an agent's reply.
 *
 * The contract asks for a bare object and nothing else, but models add fences
 * and the occasional "Here you go:", and failing a whole turn over that would
 * be gratuitous. Strict in what we demand, lenient in what we accept: fences
 * are stripped, and otherwise the last balanced top-level object wins, since
 * any preamble comes before the real answer.
 */
export const extractJson = (text: string): { value?: unknown; error?: string } => {
  const trimmed = text.trim();
  if (!trimmed) return { error: "reply was empty" };

  const fenced = trimmed.match(/```(?:json)?\s*\n([\s\S]*?)\n?```/);
  for (const candidate of [fenced?.[1], trimmed, lastObject(trimmed)]) {
    if (!candidate) continue;
    try {
      return { value: JSON.parse(candidate) };
    } catch {
      // try the next candidate
    }
  }
  return {
    error: "reply did not contain a parseable JSON object",
  };
};

/** the last brace-balanced top-level object in a string, ignoring braces in strings */
const lastObject = (text: string): string | undefined => {
  let depth = 0, start = -1, inString = false, escaped = false;
  let best: string | undefined;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (inString) {
      if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") {
      if (depth === 0) start = i;
      depth++;
    } else if (c === "}") {
      depth--;
      if (depth === 0 && start >= 0) best = text.slice(start, i + 1);
      if (depth < 0) depth = 0;
    }
  }
  return best;
};

/** resolve a dotted path into parsed output, for {{node.field}} template vars */
export const resolvePath = (value: unknown, path: string[]): unknown => {
  let cur = value;
  for (const key of path) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
};

/** readable rendering of structured output, for prompts and the dashboard */
export const renderData = (value: unknown, indent = ""): string => {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  if (typeof value !== "object") return String(value);
  if (Array.isArray(value)) {
    if (!value.length) return "(none)";
    return value.map((v) => `${indent}- ${renderData(v, indent + "  ").trimStart()}`).join("\n");
  }
  return Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => {
      const rendered = renderData(v, indent + "  ");
      // lists always get their own lines, even at length one, so a rendered
      // object reads the same however many items came back
      const block = rendered.includes("\n") || (Array.isArray(v) && v.length > 0);
      return block ? `${indent}${k}:\n${rendered}` : `${indent}${k}: ${rendered}`;
    })
    .join("\n");
};
