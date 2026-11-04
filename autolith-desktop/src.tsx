import { memo, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ArrowDownIcon, ArrowUpIcon, CommandIcon, FolderIcon, GitBranchIcon,
  HistoryIcon, PanelLeftIcon, PlusIcon, SettingsIcon, ShieldIcon, SquareIcon, TerminalIcon } from 'lucide-react';
import { AgentPicker, AgentTrace, ChatMessage } from './agent-elements.js';
import { Terminal } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import './style.css';
import { WorkspaceSearch } from './workspace-search.js';
import { ConversationHistory } from './conversation-history.js';
import { ModelPicker } from './model-picker.js';
import { Settings } from './settings.js';
import { Button } from './ui/button.js';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from './ui/dialog.js';
import { Textarea } from './ui/textarea.js';

import type { AutolithAPI, Command, Conversation, Generation, Model, Session, Snapshot, Update } from './api.js';

declare global {
  interface Window { autolith: AutolithAPI }
}
const api = window.autolith;
const errorMessage = (error: unknown) => error instanceof Error
  ? error.message.replace(/^Error invoking remote method '[^']+': Error: /, '')
  : String(error);

function Generations({ id, controlling, onStage, onClose }: {
  id: string; controlling: boolean; onStage(command: string): void; onClose(): void;
}) {
  const [items, setItems] = useState<Generation[]>();
  const [error, setError] = useState('');
  useEffect(() => {
    let live = true;
    api.generations(id).then((result) => {
      if (live) setItems(result);
    }).catch((problem) => {
      if (live) setError(errorMessage(problem));
    });
    return () => { live = false; };
  }, [id]);
  return <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
    <DialogContent className="palette">
      <DialogHeader>
        <DialogTitle>Generations</DialogTitle>
        <DialogDescription>Retained images of this Autolith installation.</DialogDescription>
      </DialogHeader>
      <Button variant="outline" disabled={!controlling} onClick={() => onStage('/checkpoint')}>Prepare checkpoint</Button>
      <div className="palette-results">
        {items?.map((item) => <article key={item.id} className="generation">
          <div>
            <code>{item.id}</code> <small>{item.created}</small>
            <div className="muted">Image {item.image} · {item.compatible ? 'Compatible' : 'Incompatible'}
              {item.source && <span title={item.source}> · Source {item.source.slice(0, 10)}</span>}
            </div>
          </div>
          <Button variant="outline" disabled={!controlling || !item.compatible}
            onClick={() => onStage(`/rollback ${item.id}`)}>Prepare rollback</Button>
        </article>)}
        {!items?.length && <p className="muted" role="status">{error || (items ? 'No retained generations.' : 'Loading generations…')}</p>}
      </div>
      <p className="muted">Rollback selects an image for the next recovery start. Review the command in the composer before running it.</p>
    </DialogContent>
  </Dialog>;
}

const History = memo(function History({ updates }: { updates: Update[] }) {
  const results = new Map(updates.filter((item) => item.type === 'tool_call_update')
    .map((item) => [item.toolId, item]));
  const calls = new Set(updates.filter((item) => item.type === 'tool_call').map((item) => item.toolId));
  return updates.map((item, index) => {
    if (item.type === 'agent_thought_chunk') return <AgentTrace key={index} title="Reasoning" reasoning><p className="whitespace-pre-wrap">{item.text}</p></AgentTrace>;
    if (item.type === 'tool_call' || (item.type === 'tool_call_update' && !calls.has(item.toolId))) {
      const result = results.get(item.toolId);
      return <AgentTrace key={index} title={item.title || 'Tool result'} status={result?.status || item.status}>
        {item.input && <pre>{item.input}</pre>}
        {(result?.output || item.output) && <pre>{result?.output || item.output}</pre>}
      </AgentTrace>;
    }
    if (item.type === 'user_message_chunk') return <ChatMessage key={index} role="user" text={item.text} />;
    if (item.type === 'agent_message_chunk') {
      return <ChatMessage key={index} role="assistant" text={item.text} />;
    }
    return null;
  });
});

function App() {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [id, setId] = useState('');
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [models, setModels] = useState<Model[]>([]);
  const [saved, setSaved] = useState<Conversation[]>([]);
  const [savedError, setSavedError] = useState('');
  const [openingSaved, setOpeningSaved] = useState('');
  const [commandError, setCommandError] = useState('');
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [consoleOpen, setConsoleOpen] = useState(false);
  const [outputOpen, setOutputOpen] = useState(false);
  const seenOutput = useRef(new Map<string, number>());
  const [input, setInput] = useState('');
  const [error, setError] = useState('');
  const [connectionError, setConnectionError] = useState('');
  const [pending, setPending] = useState(false);
  const [starting, setStarting] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [commands, setCommands] = useState<Command[]>([]);
  const [generationsOpen, setGenerationsOpen] = useState(false);
  const [handoffOpen, setHandoffOpen] = useState(false);
  const [copied, setCopied] = useState('');
  const [atBottom, setAtBottom] = useState(true);
  const composer = useRef<HTMLTextAreaElement>(null);
  const consoleNode = useRef<HTMLDivElement>(null);
  const timeline = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  const terminal = useRef<Terminal>(null);
  const history = useRef<{ key: string; updates: Update[] }>({ key: '', updates: [] });

  useEffect(() => {
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    let missingPolls = 0;
    async function refresh() {
      try {
        const items = await api.sessions();
        if (!live) return;
        setSessions(items);
        setId((current) => {
          if (items.some((item) => item.id === current)) {
            missingPolls = 0;
            return current;
          }
          if (current && ++missingPolls < 8) return current;
          missingPolls = 0;
          return items[0]?.id || '';
        });
      } catch (problem) {
        if (live) setError(errorMessage(problem));
      } finally {
        if (live) timer = setTimeout(refresh, 2000);
      }
    }
    void refresh();
    return () => { live = false; clearTimeout(timer); };
  }, []);

  useEffect(() => {
    if (!id) { void api.attach('', false).catch(() => {}); return; }
    if (!consoleNode.current) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    let reconnect: ReturnType<typeof setTimeout> | undefined;
    history.current = { key: '', updates: [] };
    follow.current = true;
    setSnapshot(undefined);
    setModels([]);
    setError('');
    setConnectionError('');
    setInput('');
    setConsoleOpen(false);
    setOutputOpen(false);
    setSettingsOpen(false);
    setPaletteOpen(false);
    setGenerationsOpen(false);
    setHandoffOpen(false);
    setAtBottom(true);
    const view = new Terminal({
      cols: 92, rows: 14, fontSize: 12, convertEol: false, scrollback: 1200,
      theme: { background: '#131417', foreground: '#e8e8ec' },
    });
    view.open(consoleNode.current);
    terminal.current = view;
    let ownsInput = false;
    const subscription = view.onData((data) => {
      api.input(id, data).catch((problem) => setError(errorMessage(problem)));
    });
    function retryWatching() {
      clearTimeout(reconnect);
      if (!disposed) reconnect = setTimeout(attachWatching, 1500);
    }
    function attachWatching() {
      api.attach(id, false).catch((problem) => {
        if (!disposed) {
          setError(errorMessage(problem));
          retryWatching();
        }
      });
    }
    const unsubscribe = api.onTerminal((sessionId, event) => {
      if (sessionId !== id) return;
      if (event.kind === 'attached') {
        clearTimeout(reconnect);
        view.reset();
        view.write(event.history);
        ownsInput = event.controlling;
        setError('');
      } else if (event.kind === 'output') {
        view.write(event.text);
      } else {
        const lostControl = ownsInput;
        ownsInput = false;
        if (lostControl) attachWatching();
        else {
          setError(event.message);
          retryWatching();
        }
      }
    });
    async function poll() {
      try {
        const state = await api.snapshot(id);
        if (disposed) return;
        const key = JSON.stringify(state.updates);
        if (key !== history.current.key) history.current = { key, updates: state.updates };
        setSnapshot({ ...state, updates: history.current.updates });
        setConnectionError('');
      } catch (problem) {
        if (!disposed) {
          setConnectionError(errorMessage(problem));
        }
      } finally {
        if (!disposed) timer = setTimeout(poll, 350);
      }
    }
    void poll();
    attachWatching();
    api.models(id).then((items) => {
      if (!disposed) setModels(items);
    }).catch(() => {});
    return () => {
      disposed = true;
      clearTimeout(timer);
      clearTimeout(reconnect);
      unsubscribe();
      subscription.dispose();
      view.dispose();
      terminal.current = null;
    };
  }, [id]);

  useEffect(() => {
    if (follow.current && timeline.current) timeline.current.scrollTop = timeline.current.scrollHeight;
  }, [snapshot]);

  useEffect(() => {
    const open = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setPaletteOpen((previous) => !previous);
      }
    };
    window.addEventListener('keydown', open);
    return () => window.removeEventListener('keydown', open);
  }, []);

  useEffect(() => {
    let live = true;
    setSavedError('');
    const timer = setTimeout(() => {
      void api.conversations(null).then((page) => {
        if (live) setSaved(page.items);
      }).catch((problem) => { if (live) setSavedError(errorMessage(problem)); });
    }, 250);
    return () => { live = false; clearTimeout(timer); };
  }, [sessions.length]);

  useEffect(() => {
    if (!id || !paletteOpen) return;
    let live = true;
    setCommands([]);
    setCommandError('');
    api.commands(id).then((items) => {
      if (live) setCommands(items);
    }).catch((problem) => { if (live) setCommandError(errorMessage(problem)); });
    return () => { live = false; };
  }, [id, paletteOpen]);

  async function newSession() {
    setStarting(true);
    setError('');
    try {
      const started = await api.startSession();
      if (started) {
        setSessions(await api.sessions());
        setId(started);
      }
    } catch (problem) {
      setError(errorMessage(problem));
    } finally {
      setStarting(false);
    }
  }

  async function resumeConversation(conversationId: string, directory: string) {
    const resumed = await api.resume(conversationId, directory);
    setSessions(await api.sessions());
    setId(resumed);
  }

  async function copyCommand(label: string, text: string) {
    try {
      await api.copy(text);
      setCopied(label);
    } catch (problem) {
      setError(errorMessage(problem));
    }
  }

  async function act(action: () => Promise<void>) {
    setPending(true);
    setError('');
    try {
      await action();
    } catch (problem) {
      setError(errorMessage(problem));
    } finally {
      setPending(false);
    }
  }

  function stageCommand(command: string) {
    setInput(command);
    setPaletteOpen(false);
    setGenerationsOpen(false);
    requestAnimationFrame(() => composer.current?.focus());
  }

  const nativeInput = /^[(/]/.test(input.trimStart());
  const composerBlocked = !snapshot || Boolean(snapshot.picker || snapshot.approval) || Boolean(connectionError);
  const workspaceName = snapshot?.cwd.split('/').filter(Boolean).at(-1);
  const notices = snapshot?.notices ?? [];
  const outputKey = `${id}:${snapshot?.pid ?? ''}`;
  const latestOutput = notices.at(-1)?.id ?? 0;
  const hasNewOutput = latestOutput > (seenOutput.current.get(outputKey) ?? 0);
  function toggleOutput(open: boolean) {
    seenOutput.current.set(outputKey, latestOutput);
    setOutputOpen(open);
  }
  return <div className={sidebarOpen ? 'shell' : 'shell sidebar-hidden'}>
    <div className="window-bar">
      <div className="window-leading">
        <Button variant="ghost" size="icon-sm" title="Toggle sidebar" aria-label="Toggle sidebar"
          aria-expanded={sidebarOpen} onClick={() => setSidebarOpen(!sidebarOpen)}><PanelLeftIcon /></Button>
      </div>
      <div className="heading">
        <FolderIcon aria-hidden="true" />
        <div><strong>{snapshot?.title || workspaceName || 'Autolith'}</strong>
          <small title={snapshot?.cwd}>{snapshot?.cwd || 'Local workspace'}</small></div>
      </div>
      {id && <div className="toolbar">
        <Button size="sm" variant="ghost" title="SSH handoff" aria-expanded={handoffOpen} onClick={() => {
          setCopied('');
          setHandoffOpen(!handoffOpen);
        }}>SSH</Button>
      </div>}
    </div>
    {sidebarOpen && <aside className="sidebar">
      <div className="brand"><span className="brand-icon" aria-hidden="true">◈</span>Autolith</div>
      <Button variant="ghost" className="nav-item new-session" disabled={starting} onClick={() => void newSession()}>
        <PlusIcon /> {starting ? 'Starting…' : 'New session'}
      </Button>
      <Button variant="ghost" className="nav-item" onClick={() => setHistoryOpen(true)}>
        <HistoryIcon /> Conversation history
      </Button>
      <div className="session-list">
        <div className="label">Live sessions <span>{sessions.length}</span></div>
        {sessions.map((session) => {
          const liveTitle = session.id === id ? snapshot?.title : undefined;
          const previous = saved.find((item) => item.id === session.id);
          const name = liveTitle || session.title || previous?.title || previous?.preview
            || session.cwd?.split('/').filter(Boolean).at(-1) || 'Untitled session';
          return <Button variant="ghost" key={session.id}
            className={session.id === id ? 'session-row selected' : 'session-row'}
            aria-current={session.id === id ? 'true' : undefined} onClick={() => setId(session.id)}>
            <span className="session-dot" data-active={session.id === id ? Boolean(snapshot?.active) : session.active} />
            <span className="session-name" title={name}>{name}</span>
          </Button>;
        })}
        {sessions.length === 0 && <p className="muted">No live sessions.</p>}
        <div className="label">Past sessions</div>
        {saved.filter((item) => !item.live && !sessions.some((session) => session.id === item.id)).map((item) => {
          const name = item.title || item.preview || item.directory.split('/').filter(Boolean).at(-1) || 'Untitled conversation';
          return <Button key={item.id} variant="ghost" className="session-row" disabled={Boolean(openingSaved)}
            onClick={async () => {
              setOpeningSaved(item.id);
              try { await resumeConversation(item.id, item.directory); } catch (problem) { setError(errorMessage(problem)); }
              finally { setOpeningSaved(''); }
            }}>
            <HistoryIcon /><span className="session-name" title={name}>{openingSaved === item.id ? 'Opening…' : name}</span>
          </Button>;
        })}
        {savedError && <p className="muted">Saved history could not be loaded.</p>}
      </div>
      <nav className="sidebar-footer" aria-label="Workspace tools">
        <Button variant="ghost" className="nav-item" onClick={() => setPaletteOpen(true)}>
          <CommandIcon /> Search <kbd>⌘ K</kbd>
        </Button>
        <Button variant="ghost" className="nav-item" disabled={!id} onClick={() => setGenerationsOpen(true)}>
          <GitBranchIcon /> Generations
        </Button>
        <Button variant="ghost" className="nav-item" disabled={!id}
          onClick={() => setSettingsOpen(true)}><SettingsIcon /> Settings</Button>
      </nav>
    </aside>}
    <main className={handoffOpen && id ? 'with-handoff' : ''}>
      {id && handoffOpen && <section className="handoff" aria-label="SSH handoff">
        <div><strong>SSH handoff</strong><p>Run on this host as the same user. Session <code>{id}</code></p></div>
        <div className="handoff-actions">
          {[
            ['Watch', `autolith lg attach ${id} --read-only`],
            ['Take over', `autolith lg attach ${id} --take-over`],
            ['Detach', `autolith lg detach ${id}`],
          ].map(([label, command]) => <Button variant="outline" key={label} title={command}
            onClick={() => void copyCommand(label, command)}>{copied === label ? 'Copied' : `Copy ${label}`}</Button>)}
        </div>
      </section>}
      <div className="timeline" ref={timeline} onScroll={(event) => {
        const element = event.currentTarget;
        follow.current = element.scrollHeight - element.clientHeight - element.scrollTop < 80;
        setAtBottom(follow.current);
      }}>
        <div className="thread">
          {!snapshot && <div className="empty">
            <div className="brand-icon">◈</div>
            <h2>{id ? 'Waiting for Autolith' : 'Your Autolith workspace'}</h2>
            <p>{connectionError || 'Your running conversations appear in the sidebar.'}</p>
            {!id && <div className="empty-actions">
              <Button disabled={starting} onClick={() => void newSession()}>Choose a workspace</Button>
              <Button variant="outline" onClick={() => setHistoryOpen(true)}>Conversation history</Button>
            </div>}
            {connectionError && <p>Start the session with <code>autolith --detached</code>.</p>}
          </div>}
          {snapshot && <>
            {snapshot.updates.length === 0 && !snapshot.active && <div className="empty"><div className="brand-icon">◈</div><h2>What are we working on?</h2>
              <p>Ask a question or describe a task.</p>
            </div>}
            <History updates={snapshot.updates} />
            {snapshot.reasoning && <AgentTrace title="Reasoning" status="running" reasoning><p className="whitespace-pre-wrap">{snapshot.reasoning}</p></AgentTrace>}
            {snapshot.stream && <ChatMessage role="assistant" text={snapshot.stream} />}
            {snapshot.active && <div className="muted activity">● {snapshot.state}</div>}
          </>}
        </div>
      </div>
      <div className="bottom"><div className="composer-area">
        {!atBottom && <Button variant="outline" className="jump" onClick={() => {
          follow.current = true;
          setAtBottom(true);
          if (timeline.current) timeline.current.scrollTop = timeline.current.scrollHeight;
        }} title="Jump to latest" aria-label="Jump to latest"><ArrowDownIcon /></Button>}
        {snapshot && connectionError && <p className="notice" role="status">Reconnecting · {connectionError}</p>}
        {snapshot?.picker && <AgentPicker key={snapshot.picker.id} picker={snapshot.picker}
          controlling={!connectionError} pending={pending} onChoose={(index) => {
            const picker = snapshot.picker;
            if (picker) void act(() => api.choose(id, picker.id, index));
          }} />}
        {error && <p className="notice" role="status">{error}</p>}
        {id && <div hidden={!consoleOpen} className="console" ref={consoleNode}
          onClick={() => terminal.current?.focus()} />}
        {id && <form onSubmit={(event) => {
          event.preventDefault();
          if (!input.trim() || composerBlocked || pending) return;
          void act(async () => {
            await api.submit(id, input);
            setInput('');
          });
        }}>
          <Textarea className="composer-input" ref={composer} aria-label="Message or native command" value={input} onChange={(event) => setInput(event.target.value)} maxLength={16000}
            placeholder="Message Autolith…"
            disabled={!snapshot || Boolean(snapshot.picker)} rows={2}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                event.currentTarget.form?.requestSubmit();
              }
            }} />
          <div className="composer-tools">
            <div className="composer-actions">
              <Button type="button" variant="ghost" size="icon-sm" aria-label="Commands" title="Commands (⌘K)"
                onClick={() => setPaletteOpen(true)}><CommandIcon /></Button>
              <Button type="button" variant="ghost" size="icon-sm" aria-label="Lisp REPL" title="Lisp REPL"
                disabled={composerBlocked} onClick={() => { setInput('('); composer.current?.focus(); }}><TerminalIcon /></Button>
              {snapshot?.permission && <Button type="button" variant="ghost" size="sm" className="permission-mode"
                disabled={composerBlocked || pending} onClick={() => void act(() => api.submit(id, '/permissions'))}>
                <ShieldIcon /> {snapshot.permission.replaceAll('-', ' ')}
              </Button>}
            </div>
            <div className="composer-actions">
              <ModelPicker key={id} api={api} id={id} models={models} model={snapshot?.model || ''}
                provider={snapshot?.provider || ''} effort={snapshot?.effort || ''}
                disabled={composerBlocked || Boolean(snapshot?.active) || pending}
                onError={(problem) => setError(errorMessage(problem))} />
              {snapshot?.active && !input.trim()
                ? <Button type="button" size="icon-sm" className="send-button" aria-label="Interrupt" title="Interrupt"
                    onClick={() => void act(() => api.input(id, '\x03'))}><SquareIcon /></Button>
                : <Button type="submit" size="icon-sm" className="send-button"
                    aria-label={nativeInput ? 'Run command' : 'Send message'} title={nativeInput ? 'Run command' : 'Send message'}
                    disabled={composerBlocked || pending || !input.trim()}><ArrowUpIcon /></Button>}
            </div>
          </div>
        </form>}
        {id && <div className="composer-status">
          <span>{!!snapshot?.queued && `${snapshot.queued} queued · `}
            {!!snapshot?.steering && `${snapshot.steering} steering · `}
            {!!snapshot?.tasks && `${snapshot.tasks} live ${snapshot.tasks === 1 ? 'task' : 'tasks'} · `}
            {nativeInput ? 'Native command' : snapshot?.active ? snapshot.state : 'Enter to send · Shift+Enter for a new line'}</span>
          <div className="composer-status-actions">
            <button type="button" className="diagnostics-toggle" aria-haspopup="dialog"
              aria-label={hasNewOutput ? 'Output, new results' : 'Output'} onClick={() => toggleOutput(true)}>
              {hasNewOutput && <span className="output-dot" aria-hidden="true" />}Output
            </button>
            <button type="button" className="diagnostics-toggle" aria-expanded={consoleOpen}
              onClick={() => setConsoleOpen(!consoleOpen)}>{consoleOpen ? 'Hide diagnostics' : 'Diagnostics'}</button>
          </div>
        </div>}
      </div></div>
      {id && outputOpen && <Dialog open onOpenChange={toggleOutput}>
        <DialogContent className="palette">
          <DialogHeader>
            <DialogTitle>Session output</DialogTitle>
            <DialogDescription>Recent command results, Lisp evaluations, and session notices. Newest first.</DialogDescription>
          </DialogHeader>
          <div className="palette-results session-output">
            {notices.length ? [...notices].reverse().map(({ id: noticeId, text }) =>
              <pre key={noticeId} className="whitespace-pre-wrap">{text.trimEnd()}</pre>)
              : <p className="muted">No command output yet.</p>}
          </div>
        </DialogContent>
      </Dialog>}
      {historyOpen && <ConversationHistory api={api} onClose={() => setHistoryOpen(false)}
        onResume={async (conversationId, directory) => {
          await resumeConversation(conversationId, directory);
          setHistoryOpen(false);
        }} />}
      {id && settingsOpen && <Settings id={id} api={api} controlling={!composerBlocked} onClose={() => setSettingsOpen(false)} />}
      {paletteOpen && <WorkspaceSearch api={api} commands={id ? commands : []} commandError={commandError}
        actions={[
          { label: 'New session', icon: PlusIcon, run: () => void newSession() },
          { label: 'Conversation history', icon: HistoryIcon, run: () => setHistoryOpen(true) },
          ...(id ? [
            { label: 'Settings', icon: SettingsIcon, run: () => setSettingsOpen(true) },
            { label: 'Generations', icon: GitBranchIcon, run: () => setGenerationsOpen(true) },
          ] : []),
        ]}
        onResume={resumeConversation} onClose={() => setPaletteOpen(false)}
        onCommand={(command) => stageCommand(command.name + (command.argument ? ' ' : ''))} />}
      {id && generationsOpen && <Generations id={id} controlling={!composerBlocked}
        onStage={stageCommand} onClose={() => setGenerationsOpen(false)} />}

    </main>
  </div>;
}

createRoot(document.getElementById('root')!).render(<App />);
