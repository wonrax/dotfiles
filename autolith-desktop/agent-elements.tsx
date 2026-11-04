import { useState, type ReactNode } from 'react';
import Markdown from 'react-markdown';
import { BrainIcon, TerminalIcon, WrenchIcon } from 'lucide-react';
import type { Picker } from './api.js';
import { Bubble, BubbleContent } from './ui/bubble.js';
import { Message, MessageContent } from './ui/message.js';
import { Button } from './ui/button.js';
import { Item, ItemActions, ItemContent, ItemDescription, ItemMedia, ItemTitle } from './ui/item.js';
import { Trace, TraceCollapsible, TraceCollapsibleContent, TraceCollapsibleTrigger,
  TraceDescription, TraceIcon, TraceLine, TraceTitle } from './ui/trace.js';

export function ChatMessage({ role, text }: { role: 'user' | 'assistant'; text: string }) {
  const user = role === 'user';
  return <Message align={user ? 'end' : 'start'} className="my-3">
    <MessageContent>
      <Bubble align={user ? 'end' : 'start'} variant={user ? 'secondary' : 'ghost'}>
        <BubbleContent className={user ? 'whitespace-pre-wrap' : 'message'}>
          {user ? text : <Markdown>{text}</Markdown>}
        </BubbleContent>
      </Bubble>
    </MessageContent>
  </Message>;
}

export function AgentTrace({ title, status, reasoning, children }: {
  title: string; status?: string; reasoning?: boolean; children?: ReactNode;
}) {
  const traceStatus = status === 'failed' || status === 'error' ? 'error'
    : status === 'in_progress' || status === 'running' ? 'running'
    : status === 'pending' ? 'pending' : undefined;
  return <Trace className="my-2"><TraceCollapsible>
    <TraceCollapsibleTrigger>
      <TraceLine status={traceStatus}>
        <TraceIcon>{reasoning ? <BrainIcon /> : <WrenchIcon />}</TraceIcon>
        <TraceTitle>{title}</TraceTitle>
        {status && <TraceDescription>{status.replaceAll('_', ' ')}</TraceDescription>}
      </TraceLine>
    </TraceCollapsibleTrigger>
    <TraceCollapsibleContent>{children}</TraceCollapsibleContent>
  </TraceCollapsible></Trace>;
}

const labels: Record<string, string> = {
  deny: 'Deny', once: 'Allow once', always: 'Always allow this exact request',
  auto: 'Classify automatically', sandbox: 'Sandbox for this session', full: 'Full access for this session',
};

export function AgentPicker({ picker, controlling, pending, onChoose }: {
  picker: Picker; controlling: boolean; pending: boolean; onChoose(index: number): void;
}) {
  const [search, setSearch] = useState('');
  const needle = search.trim().toLowerCase();
  if (!picker.permission) return <section className="picker" aria-label={picker.title}>
    <strong>{picker.title}</strong>
    {picker.options.length > 8 && <input className="settings-search picker-search" type="search"
      placeholder="Filter options…" aria-label="Filter options" value={search}
      onChange={(event) => setSearch(event.target.value)} />}
    <div className="picker-options">
      {picker.options.map((option, index) => (option.label + ' ' + option.detail).toLowerCase().includes(needle) &&
        <Button key={index} variant="outline"
        disabled={!controlling || pending} onClick={() => onChoose(index)} title={option.detail}>
        <span>{option.label}</span><small>{option.detail}</small>
      </Button>)}
    </div>
    <Button size="sm" variant="ghost" disabled={!controlling || pending} onClick={() => onChoose(-1)}>Cancel</Button>
  </section>;

  const deny = picker.options.findIndex(({ label }) => label === 'deny');
  const once = picker.options.findIndex(({ label }) => label === 'once');
  const disabled = !controlling || pending;
  return <Item variant="outline" size="sm" className="approval-card" role="group" aria-label="Tool approval">
    <ItemMedia variant="icon"><TerminalIcon /></ItemMedia>
    <ItemContent className="min-w-0">
      <ItemTitle>{picker.title}</ItemTitle>
      <ItemDescription>{controlling ? 'Review the exact request before deciding.' : 'Waiting for the controlling client.'}</ItemDescription>
      {picker.detail && <pre className="whitespace-pre-wrap">{picker.detail}</pre>}
    </ItemContent>
    <ItemActions className="approval-actions">
      <Button size="sm" variant="outline" disabled={disabled} onClick={() => onChoose(deny)}>Deny</Button>
      {once >= 0 && <Button size="sm" disabled={disabled || !picker.detail} onClick={() => onChoose(once)}>Allow once</Button>}
      <details>
        <summary>More permission options</summary>
        {picker.options.map((option, index) => index !== deny && index !== once &&
          <Button key={index} size="sm" variant="outline" disabled={disabled || !picker.detail}
            title={option.detail} onClick={() => onChoose(index)}>{labels[option.label] || option.label}</Button>)}
      </details>
    </ItemActions>
  </Item>;
}
