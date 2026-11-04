import { useEffect, useState } from 'react';
import { ArrowUpRightIcon, HistoryIcon } from 'lucide-react';
import type { AutolithAPI, Conversation } from './api.js';
import { Button } from './ui/button.js';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from './ui/dialog.js';

const message = (error: unknown) => error instanceof Error
  ? error.message.replace(/^Error invoking remote method '[^']+': Error: /, '') : String(error);

export function ConversationHistory({ api, onResume, onClose }: {
  api: AutolithAPI; onResume(id: string, directory: string): Promise<void>; onClose(): void;
}) {
  const [items, setItems] = useState<Conversation[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');
  const [resuming, setResuming] = useState('');
  useEffect(() => {
    let live = true;
    void api.conversations(null).then((page) => {
      if (live) { setItems(page.items); setNext(page.nextCursor); }
    }).catch((problem: unknown) => {
      if (live) setError(message(problem));
    }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [api]);

  async function more() {
    if (!next || loading) return;
    setLoading(true);
    setError('');
    try {
      const page = await api.conversations(next);
      setItems((previous) => [...new Map([...previous, ...page.items].map((item) => [item.id, item])).values()]);
      setNext(page.nextCursor);
    } catch (problem) {
      setError(message(problem));
    } finally {
      setLoading(false);
    }
  }

  const needle = search.trim().toLowerCase();
  const matches = items.filter((item) => [item.title, item.directory, item.id, item.preview]
    .some((text) => text.toLowerCase().includes(needle)));
  return <Dialog open onOpenChange={(open) => { if (!open && !resuming) onClose(); }}>
    <DialogContent className="palette conversation-history">
      <DialogHeader>
        <DialogTitle>Conversation history</DialogTitle>
        <DialogDescription>Open a running conversation or resume one from disk.</DialogDescription>
      </DialogHeader>
      <input type="search" className="settings-search" aria-label="Filter conversations"
        placeholder="Filter conversations…" value={search} onChange={(event) => setSearch(event.target.value)} />
      <div className="palette-results">
        {matches.map((item) => <button type="button" key={item.id} className="conversation-row"
          disabled={Boolean(resuming)} onClick={async () => {
            setResuming(item.id);
            setError('');
            try { await onResume(item.id, item.directory); } catch (problem) {
              setError(message(problem));
              setResuming('');
            }
          }}>
          <HistoryIcon aria-hidden="true" />
          <span className="conversation-row-content">
            <strong>{item.title || item.preview || item.id}</strong>
            <small>{item.directory || item.id}{item.model ? ` · ${item.model}` : ''}</small>
          </span>
          <small>{resuming === item.id ? 'Opening…' : item.live ? 'Live' : 'Resume'}</small>
          <ArrowUpRightIcon aria-hidden="true" />
        </button>)}
        {error && <p className="notice" role="status">{error}</p>}
        {!matches.length && !error && <p className="muted" role="status">
          {loading ? 'Loading saved conversations…' : search ? 'No matches on the loaded pages.' : 'No saved conversations yet.'}
        </p>}
      </div>
      {next && <Button variant="outline" size="sm" disabled={loading || Boolean(resuming)}
        onClick={() => void more()}>{loading ? 'Loading…' : 'Load older conversations'}</Button>}
    </DialogContent>
  </Dialog>;
}
