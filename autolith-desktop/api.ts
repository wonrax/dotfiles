export type Conversation = { id: string; title: string; directory: string; model: string; preview: string; live: boolean };
export type ConversationPage = { items: Conversation[]; nextCursor: string | null };
export type Session = { id: string; pid: number; title?: string; cwd?: string; active?: boolean };
export type Model = { id: string; provider: string; current: boolean };
export type Update = {
  type: string; text: string; toolId: string; title: string; status: string; output: string; input?: string;
};
export type Picker = {
  id: number; title: string; permission: boolean; detail: string;
  options: { label: string; detail: string }[];
};
export type Snapshot = {
  sessionId: string; pid: number; cwd: string; title: string; state: string;
  active: boolean; model: string; provider: string; updates: Update[];
  stream: string; reasoning: string; approval: string;
  picker?: Picker | null;
  booting?: boolean;
  notices?: { id: number; text: string }[];
  queued?: number; steering?: number; tasks?: number; permission?: string; effort?: string;
};
export type Command = { name: string; argument: string; description: string; tip: string };
export type Setting = {
  name: string; label: string; documentation: string | null; group: string; type: string;
  value: unknown; options: unknown[]; source: string; scope: string; adjustable: boolean;
};
export type Generation = { id: string; created: string; compatible: boolean; source: string; image: string };
export type TerminalEvent =
  | { kind: 'attached'; controlling: boolean; history: string }
  | { kind: 'output'; text: string }
  | { kind: 'closed'; message: string };

export type DesktopResponses = {
  'desktop-snapshot': Snapshot;
  'desktop-models': Model[];
  'desktop-commands': Command[];
  'desktop-generations': Generation[];
  'desktop-settings': Setting[];
};

export interface AutolithAPI {
  conversations(cursor: string | null): Promise<ConversationPage>;
  resume(id: string, directory: string): Promise<string>;
  sessions(): Promise<Session[]>;
  snapshot(id: string): Promise<Snapshot>;
  models(id: string): Promise<Model[]>;
  settings(id: string): Promise<Setting[]>;
  setSetting(id: string, name: string, value: string): Promise<void>;
  generations(id: string): Promise<Generation[]>;
  commands(id: string): Promise<Command[]>;
  attach(id: string, takeOver: boolean): Promise<void>;
  choose(id: string, picker: number, index: number): Promise<void>;
  input(id: string, data: string): Promise<void>;
  submit(id: string, text: string): Promise<void>;
  setModel(id: string, model: string, provider: string): Promise<void>;
  startSession(): Promise<string | null>;
  copy(text: string): Promise<void>;
  onTerminal(listener: (id: string, event: TerminalEvent) => void): () => void;
}
