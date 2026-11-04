import type { DesktopResponses, Session, TerminalEvent } from './api.js';
import { EventEmitter } from 'node:events';
import { readdir, readFile } from 'node:fs/promises';
import { createConnection } from 'node:net';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { StringDecoder } from 'node:string_decoder';

const stateHome = process.env.XDG_STATE_HOME;
const registry = join(stateHome && isAbsolute(stateHome) ? stateHome : join(homedir(), '.local/state'),
  'autolith/localgroup');
const limit = 8 * 1024 * 1024;

// Localgroup uses a small subset of Lisp's readable syntax. This parser never evaluates forms.
type Value = string | number | true | null | Value[];
type Endpoint = Session & { token: string; port: number };
type SocketEvents = { packet: [Value[]]; failure: [Error]; close: [] };

function packetList(value: Value): Value[] {
  if (!Array.isArray(value)) throw new Error('Expected a Localgroup list');
  return value;
}

function stringField(value: Value | undefined, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

export function parse(source: string): Value {
  let cursor = 0;
  function read(depth = 0): Value {
    if (depth > 32) throw new Error('Localgroup packet is nested too deeply');
    while (/\s/.test(source[cursor] ?? '')) cursor++;
    const start = cursor;
    const char = source[cursor++];
    if (char === '(') {
      const values: Value[] = [];
      while (true) {
        while (/\s/.test(source[cursor] ?? '')) cursor++;
        if (source[cursor] === ')') {
          cursor++;
          return values;
        }
        values.push(read(depth + 1));
      }
    }
    if (char === '#' && source[cursor]?.toUpperCase() === 'A') {
      cursor++;
      const array = packetList(read(depth + 1));
      const [dimensions, type, dot, value] = array;
      if (array.length !== 4 || !Array.isArray(dimensions) || dimensions.length !== 1 ||
          (type !== 'BASE-CHAR' && type !== 'CHARACTER') || dot !== '.' ||
          typeof value !== 'string' || [...value].length !== dimensions[0]) {
        throw new Error('Unsupported Localgroup array');
      }
      return value;
    }
    if (char === '"') {
      let value = '';
      while (cursor < source.length) {
        const next = source[cursor++];
        if (next === '"') return value;
        value += next === '\\' ? source[cursor++] : next;
      }
      throw new Error('Unterminated Localgroup string');
    }
    if (!char || char === ')') throw new Error('Invalid Localgroup packet');
    while (cursor < source.length && !/[\s()]/.test(source[cursor])) cursor++;
    const atom = source.slice(start, cursor);
    if (/^-?\d+$/.test(atom)) return Number(atom);
    if (atom.toUpperCase() === 'NIL') return null;
    if (atom.toUpperCase() === 'T') return true;
    if (['BASE-CHAR', 'CHARACTER', '.'].includes(atom)) return atom;
    if (atom.startsWith(':')) return atom.toLowerCase();
    throw new Error('Unsupported Localgroup value');
  }
  const value = read();
  if (source.slice(cursor).trim()) throw new Error('Unexpected Localgroup packet suffix');
  return value;
}

export const lispString = (value: string) => '"' + value.replace(/[\\"]/g, '\\$&') + '"';
const fields = (packet: Value[]) => {
  const result: Record<string, Value | undefined> = Object.create(null);
  for (let i = 1; i + 1 < packet.length; i += 2) {
    const key = packet[i];
    if (typeof key === 'string') result[key] = packet[i + 1];
  }
  return result;
};

export async function discover(): Promise<Endpoint[]> {
  const names = await readdir(registry).catch((error) => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const records = await Promise.all(names.filter((name) => /^[\w-]+\.sexp$/.test(name)).map(async (name) => {
    try {
      const record = packetList(parse(await readFile(join(registry, name), 'utf8')));
      const data = fields(record);
      const { ':session-id': id, ':token': token, ':port': port, ':pid': pid } = data;
      if (record[0] !== ':localgroup-endpoint' || data[':version'] !== 1 ||
          data[':address'] !== '127.0.0.1' || id !== name.slice(0, -5) ||
          typeof token !== 'string' || typeof port !== 'number' || !Number.isInteger(port) || port < 1 || port > 65535 ||
          typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid < 1) return null;
      process.kill(pid, 0);
      return { id, port, pid, token };
    } catch {
      return null;
    }
  }));
  return records.filter((record) => record !== null);
}

function socketFor(record: Endpoint) {
  const events = new EventEmitter<SocketEvents>();
  const socket = createConnection({ host: '127.0.0.1', port: record.port });
  const decoder = new StringDecoder('utf8');
  let buffer = '';
  let expected: number | null = null;
  let cursor = 0;
  let count = 0;
  socket.on('data', (chunk) => {
    try {
      buffer += decoder.write(chunk);
      while (buffer.length) {
        if (expected === null) {
          const newline = buffer.indexOf('\n');
          if (newline < 0 && buffer.length < 16) return;
          const header = buffer.slice(0, newline);
          if (newline < 0 || !/^\d{1,8}$/.test(header) || Number(header) < 1 || Number(header) > limit) {
            throw new Error('Invalid Localgroup frame length');
          }
          expected = Number(header);
          buffer = buffer.slice(newline + 1);
        }
        // SBCL counts Unicode characters, not UTF-8 bytes or JS UTF-16 units.
        while (cursor < buffer.length && count < expected) {
          cursor += (buffer.codePointAt(cursor) ?? 0) > 0xffff ? 2 : 1;
          count++;
        }
        if (count < expected) return;
        const payload = buffer.slice(0, cursor);
        buffer = buffer.slice(cursor);
        expected = null;
        cursor = count = 0;
        events.emit('packet', packetList(parse(payload)));
      }
    } catch (error) {
      socket.destroy(error instanceof Error ? error : new Error(String(error)));
    }
  });
  socket.on('error', (error) => events.emit('failure', error));
  socket.on('close', () => events.emit('close'));
  return {
    events,
    close: () => socket.destroy(),
    send: (packet: string) => {
      if (socket.destroyed) throw new Error('Localgroup connection closed');
      const length = [...packet].length;
      if (length > limit) throw new Error('Localgroup frame is too large');
      socket.write(`${length}\n${packet}`);
    },
  };
}

function requestFrame(record: Endpoint, operation: keyof DesktopResponses | 'attach' | 'status' | 'desktop-quit', args = 'nil') {
  return `(:localgroup-request :version 1 :token ${lispString(record.token)} :operation :${operation} :arguments ${args})`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasFields(value: unknown, fields: Record<string, 'string' | 'number' | 'boolean'>): boolean {
  return isRecord(value) && Object.entries(fields).every(([key, kind]) => typeof value[key] === kind);
}

function readResponse<K extends keyof DesktopResponses>(operation: K, json: string): DesktopResponses[K] {
  const value: unknown = JSON.parse(json);
  let valid: boolean;
  switch (operation) {
    case 'desktop-snapshot':
      valid = isRecord(value) && hasFields(value, {
        sessionId: 'string', pid: 'number', cwd: 'string', title: 'string', state: 'string',
        active: 'boolean', model: 'string', provider: 'string', stream: 'string',
        reasoning: 'string', approval: 'string',
      }) && Array.isArray(value.updates) && value.updates.every((update: unknown) => hasFields(update, {
        type: 'string', text: 'string', toolId: 'string', title: 'string', status: 'string', output: 'string',
      }));
      if (valid && isRecord(value) && value.picker != null) {
        const picker = value.picker;
        valid = isRecord(picker) && hasFields(picker, {
          id: 'number', title: 'string', permission: 'boolean', detail: 'string',
        }) && Array.isArray(picker.options) && picker.options.every((option: unknown) =>
          hasFields(option, { label: 'string', detail: 'string' }));
      }
      break;
    case 'desktop-models':
      valid = Array.isArray(value) && value.every((item: unknown) =>
        hasFields(item, { id: 'string', provider: 'string', current: 'boolean' }));
      break;
    case 'desktop-commands':
      valid = Array.isArray(value) && value.every((item: unknown) =>
        hasFields(item, { name: 'string', argument: 'string', description: 'string', tip: 'string' }));
      break;
    case 'desktop-settings':
      valid = Array.isArray(value) && value.every((item: unknown) =>
        isRecord(item) && Array.isArray(item.options) && hasFields(item, {
          name: 'string', label: 'string', group: 'string', type: 'string',
          source: 'string', scope: 'string', adjustable: 'boolean',
        }));
      break;
    case 'desktop-generations':
      valid = Array.isArray(value) && value.every((item: unknown) =>
        hasFields(item, { id: 'string', created: 'string', compatible: 'boolean', source: 'string', image: 'string' }));
      break;
  }
  if (!valid) throw new Error(`Invalid Autolith response for ${operation}`);
  return value as DesktopResponses[K];
}

function request(record: Endpoint, operation: keyof DesktopResponses | 'status' | 'desktop-quit', args = 'nil'): Promise<Record<string, Value | undefined>> {
  return new Promise((resolve, reject) => {
    const connection = socketFor(record);
    const timeout = setTimeout(() => finish(new Error('Localgroup request timed out')), 3000);
    function finish(error: unknown, value?: Record<string, Value | undefined>) {
      clearTimeout(timeout);
      connection.close();
      if (error) reject(error);
      else if (value !== undefined) resolve(value);
    }
    connection.events.on('failure', finish);
    connection.events.on('close', () => finish(new Error('Localgroup closed without a response')));
    connection.events.once('packet', (packet) => {
      try {
        if (packet[0] !== ':ok') {
          const message = stringField(fields(packet)[':message'], 'Desktop adapter unavailable');
          if (/^Unknown localgroup operation :DESKTOP-/i.test(message)) {
            throw new Error(
              'This running session needs the updated desktop bridge. In its controlling Autolith REPL, run ' +
              '(load (merge-pathnames "autolith/desktop.lisp" (uiop:xdg-config-home))) and reopen this panel.',
            );
          }
          throw new Error(message);
        }
        finish(null, fields(packet));
      } catch (error) {
        finish(error);
      }
    });
    connection.send(requestFrame(record, operation, args));
  });
}

export async function query<K extends keyof DesktopResponses>(record: Endpoint, operation: K): Promise<DesktopResponses[K]> {
  const packet = await request(record, operation);
  return readResponse(operation, stringField(packet[':json']));
}

export async function shutdownDesktopSession(record: Endpoint, owner: string) {
  const result = await request(record, 'desktop-quit', `(:owner ${lispString(owner)})`);
  return result[':shutdown'];
}

export async function sessionSummary(record: Endpoint): Promise<Session> {
  const { id, pid } = record;
  try {
    const packet = await request(record, 'status');
    const status = fields(packetList(packet[':status'] ?? null));
    return {
      id, pid,
      title: stringField(status[':conversation-title']),
      cwd: stringField(status[':cwd']),
      active: status[':active-turn-p'] === true,
    };
  } catch {
    return { id, pid };
  }
}

export function attach(record: Endpoint, mode: 'read-only' | 'take-over', notify: (event: TerminalEvent) => void) {
  const connection = socketFor(record);
  let controlling = false;
  let reported = false;
  const timer = setTimeout(() => {
    reported = true;
    notify({ kind: 'closed', message: 'Attachment timed out' });
    connection.close();
  }, 5000);
  connection.events.on('packet', (packet) => {
    const type = packet[0];
    if (type === ':attached') {
      clearTimeout(timer);
      controlling = mode !== 'read-only';
      notify({ kind: 'attached', controlling, history: stringField(fields(packet)[':history']) });
    } else if (type === ':output') {
      notify({ kind: 'output', text: stringField(packet[1]) });
    } else if (type === ':revoked' || type === ':error' || type === ':handoff' || type === ':exit' || type === ':detached') {
      controlling = false;
      reported = true;
      notify({ kind: 'closed', message: stringField(fields(packet)[':message'],
        type === ':revoked' ? 'Input control moved to another terminal' : type.slice(1)) });
      connection.close();
    }
  });
  connection.events.on('failure', (error) => {
    reported = true;
    controlling = false;
    notify({ kind: 'closed', message: error.message });
  });
  connection.events.on('close', () => {
    clearTimeout(timer);
    controlling = false;
    if (!reported) notify({ kind: 'closed', message: 'Terminal attachment closed' });
  });
  connection.send(requestFrame(record, 'attach', `(:mode :${mode} :rows 14 :columns 92 :styled-p t :desktop-p t)`));
  return {
    close: connection.close,
    input(event: string) {
      if (!controlling) throw new Error('Take input control first');
      connection.send(`(:event ${event})`);
    },
  };
}
