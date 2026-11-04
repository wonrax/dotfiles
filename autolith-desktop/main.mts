import { randomUUID } from 'node:crypto';
import { stat } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { savedConversations } from './conversations.mjs';
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { promisify } from 'node:util';
import type { AutolithAPI, TerminalEvent } from './api.js';
import { app, BrowserWindow, clipboard, dialog, ipcMain } from 'electron';
import { fileURLToPath } from 'node:url';
import { attach, discover, lispString, query, sessionSummary, shutdownDesktopSession } from './localgroup.mjs';

const keys: Partial<Record<string, string>> = {
  '\r': ':submit', '\n': ':submit', '\x1b': ':escape', '\x03': ':interrupt',
  '\x7f': ':backspace', '\t': ':complete', '\x1b[A': ':up', '\x1b[B': ':down',
  '\x1b[C': ':right', '\x1b[D': ':left',
  '\x1bOA': ':up', '\x1bOB': ':down', '\x1bOC': ':right', '\x1bOD': ':left',
};

async function start() {
  const window = new BrowserWindow({
    width: 1130,
    height: 820,
    minWidth: 740,
    minHeight: 500,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#191919',
    webPreferences: { preload: fileURLToPath(new URL('./preload.cjs', import.meta.url)),
      contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  window.webContents.session.setPermissionCheckHandler(() => false);
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, respond) => respond(false));
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  const owner = randomUUID();
  const launches = new Set<Promise<string>>();
  const ownedTokens = new Set<string>();
  let quitting = false;
  let shutdownComplete = false;
  let terminal: ReturnType<typeof attach> | undefined;
  let ownsControl = false;
  let takeover: Promise<ReturnType<typeof attach>> | undefined;
  let cancelAttach: (() => void) | undefined;
  let selected: string | undefined;
  let generation = 0;
  let output = '';
  let flushTimer: ReturnType<typeof setTimeout> | undefined;
  function clearTerminal() {
    generation++;
    cancelAttach?.();
    cancelAttach = undefined;
    takeover = undefined;
    ownsControl = false;
    terminal?.close();
    terminal = undefined;
    clearTimeout(flushTimer);
    flushTimer = undefined;
    output = '';
  }
  window.on('closed', clearTerminal);
  app.on('window-all-closed', () => app.quit());
  app.on('before-quit', (event) => {
    if (shutdownComplete) return;
    event.preventDefault();
    if (quitting) return;
    quitting = true;
    clearTerminal();
    void stopOwnedSessions().catch((error) => console.error('Autolith shutdown:', error)).finally(() => {
      shutdownComplete = true;
      app.quit();
    });
  });

  async function stopOwnedSessions() {
    await Promise.allSettled(launches);
    const records = (await discover()).filter((item) => ownedTokens.has(item.token));
    await Promise.all(records.map(async (record) => {
      try {
        // A just-closed desktop attachment can still be unwinding on the server.
        for (let attempt = 0; attempt < 5; attempt++) {
          const result = await shutdownDesktopSession(record, owner);
          if (result === ':requested' || result === ':stopping') {
            for (let wait = 0; wait < 30; wait++) {
              if (!(await discover()).some((item) => item.token === record.token)) return;
              await new Promise((resolve) => setTimeout(resolve, 100));
            }
            console.error(`Autolith session ${record.id} is still shutting down.`);
            return;
          }
          if (result !== ':in-use') throw new Error('Session could not accept shutdown.');
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
      } catch (error) {
        if ((await discover()).some((item) => item.token === record.token)) {
          console.error(`Autolith session ${record.id} could not be stopped:`, error);
        }
      }
    }));
  }

  async function record(id: string) {
    const result = (await discover()).find((item) => item.id === id);
    if (!result) throw new Error('The session is no longer running.');
    return result;
  }

  function launchSession(args: string[], cwd: string): Promise<string> {
    if (quitting) return Promise.reject(new Error('Autolith Desktop is quitting.'));
    const launch = startDetached(args, cwd);
    launches.add(launch);
    void launch.finally(() => launches.delete(launch)).catch(() => {});
    return launch;
  }

  async function startDetached(args: string[], cwd: string): Promise<string> {
    try {
      const { stdout } = await promisify(execFile)('autolith', args, {
        cwd, env: {
          ...process.env, AUTOLITH_DESKTOP_OWNER: owner, AUTOLITH_KEEP_ALIVE: '1', AUTOLITH_BOOT_SCREEN: 'false', AUTOLITH_ONBOARDING: 'false',
        }, timeout: 60000,
      });
      const pid = Number(/^Conversation [-\w]+\s+PID (\d+)/m.exec(stdout)?.[1]);
      const endpoint = (await discover()).find((item) => item.pid === pid);
      if (!endpoint) throw new Error('Autolith did not report a reachable conversation.');
      ownedTokens.add(endpoint.token);
      return endpoint.id;
    } catch (error) {
      if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
        throw new Error('Autolith was not found on PATH. Launch this app from your configured shell.');
      }
      throw error;
    }
  }

  async function sendLine(id: string, text: string) {
    if (id !== selected) throw new Error('The selected session changed.');
    let state = await query(await record(id), 'desktop-snapshot');
    if (state.picker) throw new Error('Answer the active prompt before sending another command');
    const attachment = await controlSession(id);
    state = await query(await record(id), 'desktop-snapshot');
    if (attachment !== terminal) throw new Error('The attachment changed');
    if (state.picker) throw new Error('Answer the active prompt before sending another command');
    if (state.booting) attachment.input(':escape');
    attachment.input(`(:line ${lispString(text)})`);
  }
  function handle<K extends keyof Omit<AutolithAPI, 'onTerminal'>>(
    name: K, action: (...args: Parameters<AutolithAPI[K]>) => ReturnType<AutolithAPI[K]>,
  ) {
    ipcMain.handle(name, (event, ...args) => {
      if (event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame) {
        throw new Error('Unexpected IPC sender');
      }
      return action(...args as Parameters<AutolithAPI[K]>);
    });
  }
  handle('sessions', async () => Promise.all((await discover()).map(sessionSummary)));
  handle('snapshot', async (id) => query(await record(id), 'desktop-snapshot'));
  handle('models', async (id) => query(await record(id), 'desktop-models'));
  handle('settings', async (id) => query(await record(id), 'desktop-settings'));
  handle('setSetting', async (id, name, value) => {
    if (id !== selected || typeof name !== 'string' || name.length > 200 ||
        typeof value !== 'string' || value.length > 16000) throw new Error('Invalid setting input');
    await sendLine(id, `(desktop-setting ${lispString(name)} ${lispString(value)})`);
  });
  handle('generations', async (id) => query(await record(id), 'desktop-generations'));
  handle('commands', async (id) => query(await record(id), 'desktop-commands'));
  handle('copy', async (text) => {
    if (typeof text !== 'string' || text.length > 16000) throw new Error('Invalid clipboard text');
    clipboard.writeText(text);
  });
  handle('conversations', savedConversations);
  handle('resume', async (id, directory) => {
    if (typeof id !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,127}$/.test(id)) {
      throw new Error('Invalid conversation ID');
    }
    const live = (await discover()).find((item) => item.id === id || item.id.replaceAll('-', '') === id.replaceAll('-', ''));
    if (live) return live.id;
    const cwd = typeof directory === 'string' && isAbsolute(directory) ? directory : homedir();
    if (!(await stat(cwd).catch(() => null))?.isDirectory()) throw new Error('The saved workspace folder is unavailable.');
    return launchSession(['resume', id, '--detached'], cwd);
  });
  handle('startSession', async () => {
    const { canceled, filePaths } = await dialog.showOpenDialog(window, {
      title: 'Choose an Autolith workspace', properties: ['openDirectory'],
    });
    const cwd = filePaths[0];
    if (canceled || !cwd) return null;
    return launchSession(['--detached'], cwd);
  });
  function emitTerminal(id: string, event: TerminalEvent) {
    if (event.kind === 'output') {
      output += event.text;
      flushTimer ??= setTimeout(() => {
        if (output && !window.isDestroyed()) window.webContents.send('terminal', id, { kind: 'output', text: output });
        output = '';
        flushTimer = undefined;
      }, 16);
    } else {
      if (output) window.webContents.send('terminal', id, { kind: 'output', text: output });
      output = '';
      window.webContents.send('terminal', id, event);
    }
  }

  async function connect(id: string, control: boolean) {
    const current = generation;
    let endpoint = await record(id);
    for (;;) {
      if (current !== generation) throw new Error('The selected session changed.');
      const result = await new Promise<ReturnType<typeof attach> | 'handoff'>((resolve, reject) => {
        cancelAttach = () => reject(new Error('The selected session changed.'));
        let attached = false;
        const connection = attach(endpoint, control ? 'take-over' : 'read-only', (event) => {
          if (current !== generation || window.isDestroyed()) return;
          if (event.kind === 'attached') {
            attached = true;
            ownsControl = event.controlling;
            cancelAttach = undefined;
            resolve(connection);
          } else if (event.kind === 'closed') {
            ownsControl = false;
            cancelAttach = undefined;
            if (!attached) {
              if (control && event.message === 'handoff') resolve('handoff');
              else reject(new Error(event.message));
              return;
            }
          }
          emitTerminal(id, event);
        });
        terminal = connection;
      });
      if (result !== 'handoff') return result;
      const old = endpoint;
      const deadline = Date.now() + 15000;
      do {
        if (current !== generation) throw new Error('The selected session changed.');
        const replacement = (await discover()).find((item) =>
          item.id === old.id && item.pid !== old.pid && item.token === old.token);
        if (replacement) { endpoint = replacement; break; }
        if (Date.now() >= deadline) throw new Error('Autolith did not finish handing off the terminal.');
        await new Promise((resolve) => setTimeout(resolve, 100));
      } while (true);
    }
  }

  async function controlSession(id: string) {
    if (quitting) throw new Error('Autolith Desktop is quitting.');
    if (id !== selected) throw new Error('The selected session changed.');
    if (ownsControl && terminal) return terminal;
    if (!takeover) {
      clearTerminal();
      const request = connect(id, true);
      takeover = request;
      void request.finally(() => { if (takeover === request) takeover = undefined; }).catch(() => {});
    }
    return takeover;
  }

  handle('attach', async (id, takeOver) => {
    if (quitting) return;
    if (selected === id && takeover && !takeOver) return;
    clearTerminal();
    selected = id;
    if (!id) return;
    if (takeOver) await controlSession(id);
    else await connect(id, false);
  });
  handle('choose', async (id, picker, index) => {
    if (id !== selected || !Number.isSafeInteger(picker) || picker < 1 ||
        !Number.isSafeInteger(index) || index < -1 || index > 100000) {
      throw new Error('Invalid selection');
    }
    const before = await record(id);
    const initial = (await query(before, 'desktop-snapshot')).picker;
    if (initial?.id !== picker || index >= initial.options.length) throw new Error('This prompt has changed.');
    const attachment = await controlSession(id);
    const after = await record(id);
    const { picker: current } = await query(after, 'desktop-snapshot');
    if (before.pid !== after.pid || attachment !== terminal || current?.id !== picker || index >= current.options.length) {
      throw new Error('This prompt has changed. Review the current options.');
    }
    if (current.permission && index >= 0 && current.options[index]?.label !== 'deny' && !current.detail) {
      throw new Error('Autolith did not provide the full authorization request.');
    }
    attachment.input(`(:desktop-choice ${picker} ${index})`);
  });
  handle('input', async (id, data) => {
    if (id !== selected || typeof data !== 'string' || data.length > 16000) throw new Error('Invalid terminal input');
    const key = Object.hasOwn(keys, data) ? keys[data] : undefined;
    const input = key ?? (!/[\x00-\x1f\x7f]/.test(data) ? `(:insert ${lispString(data)})` : undefined);
    if (!input) return;
    const attachment = await controlSession(id);
    if (attachment !== terminal) throw new Error('The attachment changed.');
    attachment.input(input);
  });
  handle('submit', async (id, text) => {
    if (id !== selected || typeof text !== 'string' || !text.trim() || text.length > 16000) {
      throw new Error('Invalid session input');
    }
    await sendLine(id, text);
  });
  handle('setModel', async (id, model, provider) => {
    const endpoint = await record(id);
    const choices = await query(endpoint, 'desktop-models');
    if (id !== selected || !choices.some((item) => item.id === model && item.provider === provider)) {
      throw new Error('Model is unavailable for this session');
    }
    await sendLine(id, `(desktop-model ${lispString(model)} :provider ${lispString(provider)})`);
  });

  await window.loadFile(fileURLToPath(new URL('./index.html', import.meta.url)));
}

app.whenReady().then(start).catch((error) => {
  console.error("Autolith Desktop failed to start:", error);
  app.exit(1);
});
