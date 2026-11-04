import { useEffect, useState } from 'react';
import type { AutolithAPI, Setting } from './api.js';
import { Button } from './ui/button.js';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from './ui/dialog.js';

const display = (value: unknown): string =>
  value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value);

function SettingRow({ setting, controlling, save }: {
  setting: Setting; controlling: boolean; save(name: string, value: string): Promise<void>;
}) {
  const current = display(setting.value);
  const [value, setValue] = useState(current);
  const [status, setStatus] = useState('');
  const [pending, setPending] = useState(false);
  const editable = controlling && setting.adjustable &&
    ['choice', 'boolean', 'integer', 'pathname', 'string'].includes(setting.type) &&
    (setting.value == null || typeof setting.value !== 'object');
  const choices = setting.type === 'boolean' ? ['true', 'false'] : setting.options.map(display);
  useEffect(() => {
    setValue(current);
    setStatus('');
  }, [current]);
  return <div className="setting-row">
    <div><strong>{setting.label}</strong><small>{setting.group} · {setting.scope} · {setting.source}</small>
      {setting.documentation && <p>{setting.documentation}</p>}</div>
    <div className="setting-edit">
      {choices.length > 0
        ? <select value={value} aria-label={setting.label} disabled={!editable || pending}
            onChange={(event) => setValue(event.target.value)}>
            {!choices.includes(value) && <option value={value}>{value || 'Unset'}</option>}
            {choices.map((option) => <option key={option} value={option}>{option || 'Unset'}</option>)}
          </select>
        : <input aria-label={setting.label} value={value} disabled={!editable || pending}
            onChange={(event) => setValue(event.target.value)} />}
      {editable && <Button size="sm" variant="outline" disabled={pending || value === current} onClick={async () => {
        setPending(true);
        setStatus('');
        try {
          await save(setting.name, value);
          setStatus('Sent to Autolith');
        } catch (error) {
          setStatus(error instanceof Error ? error.message : String(error));
        } finally {
          setPending(false);
        }
      }}>Apply</Button>}
      {status && <small role="status">{status}</small>}
    </div>
  </div>;
}

export function Settings({ id, api, controlling, onClose }: {
  id: string; api: AutolithAPI; controlling: boolean; onClose(): void;
}) {
  const [items, setItems] = useState<Setting[]>([]);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    async function refresh() {
      try {
        const result = await api.settings(id);
        if (!disposed) {
          setItems(result);
          setError('');
        }
      } catch (problem) {
        if (!disposed) setError(problem instanceof Error ? problem.message : String(problem));
      } finally {
        if (!disposed) timer = setTimeout(refresh, 1250);
      }
    }
    void refresh();
    return () => { disposed = true; clearTimeout(timer); };
  }, [api, id]);
  const needle = search.trim().toLowerCase();
  const matching = items.filter((setting) =>
    [setting.label, setting.group, setting.name].some((text) => text.toLowerCase().includes(needle)));
  return <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
    <DialogContent className="palette settings-panel">
      <DialogHeader><DialogTitle>Settings</DialogTitle>
        <DialogDescription>Inspect runtime settings and where their values come from.</DialogDescription></DialogHeader>
      <input className="settings-search" type="search" aria-label="Filter settings" placeholder="Filter settings…"
        value={search} onChange={(event) => setSearch(event.target.value)} />
      <div className="palette-results">
        {matching.map((setting) => <SettingRow key={setting.name} setting={setting} controlling={controlling}
          save={(name, value) => api.setSetting(id, name, value)} />)}
        {matching.length === 0 && <p className="muted">{error || (items.length ? 'No matching settings.' : 'Loading settings…')}</p>}
      </div>
    </DialogContent>
  </Dialog>;
}
