import { useEffect, useState } from 'react';
import { ArrowUpRightIcon, MessageSquareIcon, TerminalIcon, type LucideIcon } from 'lucide-react';
import type { AutolithAPI, Command, Conversation } from './api.js';
import { Command as CommandMenu, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from './ui/command.js';
import { Dialog, DialogContent, DialogDescription, DialogTitle } from './ui/dialog.js';

export type QuickAction = { label: string; icon: LucideIcon; run(): void };
const scopes = ['All', 'Actions', 'Chats', 'Commands'] as const;
type Scope = typeof scopes[number];

export function WorkspaceSearch({ api, actions, commands, commandError, onCommand, onResume, onClose }: {
  api: AutolithAPI; actions: QuickAction[]; commands: Command[]; commandError: string;
  onCommand(command: Command): void; onResume(id: string, directory: string): Promise<void>; onClose(): void;
}) {
  const [scope, setScope] = useState<Scope>('All');
  const [search, setSearch] = useState('');
  const [chats, setChats] = useState<Conversation[]>([]);
  const [loading, setLoading] = useState(true);
  const [opening, setOpening] = useState('');
  const [error, setError] = useState('');
  useEffect(() => {
    let live = true;
    void api.conversations(null).then((page) => {
      if (live) setChats(page.items);
    }).catch((problem: unknown) => {
      if (live) setError(problem instanceof Error ? problem.message.replace(/^Error invoking remote method '[^']+': Error: /, '') : String(problem));
    }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [api]);

  const home = scope === 'All' && !search.trim();
  const showActions = scope === 'All' || scope === 'Actions';
  const showChats = scope === 'All' || scope === 'Chats';
  const showCommands = scope === 'Commands' || scope === 'All';

  return <Dialog open onOpenChange={(next) => { if (!next && !opening) onClose(); }}>
    <DialogContent placement="top" className="workspace-search" showCloseButton={false}>
      <DialogTitle className="sr-only">Search Autolith</DialogTitle>
      <DialogDescription className="sr-only">Find actions, conversations, and native Autolith commands.</DialogDescription>
      <CommandMenu label="Search Autolith" loop className="workspace-search-menu">
        <CommandInput autoFocus placeholder="Search Autolith…" value={search} onValueChange={setSearch} />
        <CommandList className="workspace-search-results">
          <CommandEmpty>{loading && showChats ? 'Loading conversations…' : 'No matching results.'}</CommandEmpty>
          {showActions && <CommandGroup heading="Quick actions">
            {actions.map(({ label, icon: Icon, run }) => <CommandItem key={label} value={label}
              disabled={Boolean(opening)} onSelect={() => { onClose(); run(); }}>
              <Icon aria-hidden="true" /><span>{label}</span>
            </CommandItem>)}
          </CommandGroup>}
          {showChats && chats.length > 0 && <CommandGroup heading="Chats">
            {(home ? chats.slice(0, 6) : chats).map((chat) => <CommandItem key={chat.id}
              value={`chat ${chat.title || chat.preview || chat.id} ${chat.id}`}
              keywords={[chat.preview, chat.directory, chat.model]} disabled={Boolean(opening)}
              onSelect={async () => {
                setOpening(chat.id);
                setError('');
                try { await onResume(chat.id, chat.directory); onClose(); } catch (problem) {
                  setError(problem instanceof Error ? problem.message : String(problem));
                } finally { setOpening(''); }
              }}>
              <MessageSquareIcon aria-hidden="true" /><span>{chat.title || chat.preview || chat.id}</span>
              <small>{opening === chat.id ? 'Opening…' : chat.directory.split('/').filter(Boolean).at(-1) || (chat.live ? 'Live' : '')}</small>
            </CommandItem>)}
          </CommandGroup>}
          {showCommands && commands.length > 0 && <CommandGroup heading="Autolith commands">
            {(home ? commands.slice(0, 6) : commands).map((command) => <CommandItem key={command.name} value={command.name}
              keywords={[command.argument, command.description]} disabled={Boolean(opening)}
              onSelect={() => onCommand(command)} title={command.tip}>
              <TerminalIcon aria-hidden="true" /><span>{command.name}</span>
              <small>{command.description}</small><ArrowUpRightIcon aria-hidden="true" />
            </CommandItem>)}
          </CommandGroup>}
        </CommandList>
        {(error || (showCommands && commandError)) && <p className="notice workspace-search-error" role="status">{error || commandError}</p>}
      </CommandMenu>
      <div className="workspace-search-footer" role="group" aria-label="Search category">
        {scopes.map((item) => <button key={item} type="button" aria-pressed={scope === item}
          onClick={() => setScope(item)}>{item}</button>)}
        <span>↑ ↓ to navigate · ↵ to open</span>
      </div>
    </DialogContent>
  </Dialog>;
}
