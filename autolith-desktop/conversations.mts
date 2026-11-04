import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { createInterface } from 'node:readline';
import type { ConversationPage } from './api.js';

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readPage(value: unknown): ConversationPage {
  if (!object(value) || value.outcome !== 'ok' || !object(value.value) ||
      !Array.isArray(value.value.items) ||
      !(value.value.nextCursor === null || typeof value.value.nextCursor === 'string')) {
    throw new Error('Autolith could not read saved conversations.');
  }
  const { items, nextCursor } = value.value;
  return {
    items: items.filter((item): item is Record<string, unknown> => object(item) && typeof item.id === 'string')
      .map((item) => ({
        id: String(item.id),
        title: typeof item.title === 'string' ? item.title : '',
        directory: typeof item.directory === 'string' ? item.directory : '',
        model: typeof item.model === 'string' ? item.model : '',
        preview: typeof item.preview === 'string' ? item.preview : '',
        live: item.live === true,
      })),
    nextCursor,
  };
}

// The ephemeral ACP session supplies native history metadata even with no Localgroup daemon.
export async function savedConversations(cursor: string | null): Promise<ConversationPage> {
  if (cursor !== null && (typeof cursor !== 'string' || !/^\d{1,9}$/.test(cursor))) {
    throw new Error('Invalid conversation page.');
  }
  const child = spawn('autolith', ['acp'], { cwd: homedir(), stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout });
  let rejectPending: ((error: Error) => void) | undefined;
  child.on('error', (error) => rejectPending?.(error));
  child.on('exit', () => rejectPending?.(new Error('Autolith exited while reading conversation history.')));
  child.stdin.on('error', (error) => rejectPending?.(error));
  const reader = lines[Symbol.asyncIterator]();
  let sequence = 0;
  async function request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = ++sequence;
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    for (let next = await reader.next(); !next.done; next = await reader.next()) {
      const line = next.value;
      let message: unknown;
      try { message = JSON.parse(line); } catch { continue; }
      if (!object(message) || message.id !== id) continue;
      if (object(message.error)) throw new Error(String(message.error.message || 'Autolith rejected the request.'));
      return message.result;
    }
    throw new Error('Autolith closed the conversation history connection.');
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      new Promise<never>((_, reject) => {
        rejectPending = reject;
        timer = setTimeout(() => reject(new Error('Reading saved conversations timed out.')), 20000);
      }),
      (async () => {
        await request('initialize', { protocolVersion: 1, clientCapabilities: {} });
        const session = await request('session/new', { cwd: homedir(), mcpServers: [] });
        if (!object(session) || typeof session.sessionId !== 'string') {
          throw new Error('Autolith did not open the history connection.');
        }
        return readPage(await request('_autolith/conversations', {
          sessionId: session.sessionId, limit: 50, cursor: cursor ?? undefined,
        }));
      })(),
    ]);
  } finally {
    clearTimeout(timer);
    rejectPending = undefined;
    lines.close();
    child.stdin.end();
    child.kill();
  }
}
