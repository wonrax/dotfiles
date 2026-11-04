import { useEffect, useState } from 'react';
import { ArrowLeftIcon, CheckIcon, ChevronDownIcon, ChevronRightIcon } from 'lucide-react';
import { Popover } from 'radix-ui';
import type { AutolithAPI, Model } from './api.js';
import { Button } from './ui/button.js';
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from './ui/command.js';

const modelLabel = (id: string) => id.split('/').at(-1) || id;
const effortLabel = (effort: string) => effort.charAt(0).toUpperCase() + effort.slice(1);

export function ModelPicker({ api, id, models, model, provider, effort, disabled, onError }: {
  api: AutolithAPI; id: string; models: Model[]; model: string; provider: string; effort: string;
  disabled: boolean; onError(error: unknown): void;
}) {
  const [open, setOpen] = useState(false);
  const [page, setPage] = useState<'summary' | 'model' | 'effort'>('summary');
  const [efforts, setEfforts] = useState<string[]>([]);
  const [effortStatus, setEffortStatus] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open || page !== 'effort') return;
    let live = true;
    setEfforts([]);
    setEffortStatus('Loading effort levels…');
    void api.settings(id).then((settings) => {
      if (!live) return;
      const setting = settings.find((item) => item.name === 'reasoning-effort');
      const options = setting?.options.filter((option): option is string => typeof option === 'string') ?? [];
      setEfforts(setting?.adjustable ? options : []);
      setEffortStatus(setting?.adjustable && options.length ? '' : 'No adjustable effort levels for this model.');
    }).catch((error: unknown) => {
      if (live) setEffortStatus(error instanceof Error
        ? error.message.replace(/^Error invoking remote method '[^']+': Error: /, '')
        : String(error));
    });
    return () => { live = false; };
  }, [api, id, model, provider, open, page]);

  async function choose(action: () => Promise<void>) {
    if (disabled || saving) return;
    setSaving(true);
    try {
      await action();
      setOpen(false);
    } catch (error) {
      onError(error);
    } finally {
      setSaving(false);
    }
  }

  return <Popover.Root open={open} onOpenChange={(next) => {
    setOpen(next);
    if (next) setPage('summary');
  }}>
    <Popover.Trigger asChild>
      <Button type="button" variant="ghost" size="sm" className="model-button" aria-label="Model and reasoning effort"
        title={[provider, model].filter(Boolean).join(' / ')} disabled={disabled || saving}>
        <span>{modelLabel(model) || 'Model'}</span>
        {effort && <small>{effortLabel(effort)}</small>}
        <ChevronDownIcon className={open ? 'rotate-180' : ''} />
      </Button>
    </Popover.Trigger>
    <Popover.Portal>
      <Popover.Content className="model-popover" side="top" align="end" sideOffset={8} collisionPadding={12}
        aria-label="Model and reasoning effort">
        {page === 'summary' ? <>
          <button type="button" className="model-menu-row" onClick={() => setPage('model')}>
            <span>Model</span><small>{modelLabel(model) || 'Choose'}</small><ChevronRightIcon />
          </button>
          <button type="button" className="model-menu-row" onClick={() => setPage('effort')}>
            <span>Effort</span><small>{effort ? effortLabel(effort) : 'Choose'}</small><ChevronRightIcon />
          </button>
        </> : <>
          <button type="button" className="model-menu-back" onClick={() => setPage('summary')}>
            <ArrowLeftIcon /> {page === 'model' ? 'Models' : 'Reasoning effort'}
          </button>
          {page === 'model' ? <Command label="Models" loop>
            <CommandInput autoFocus placeholder="Search models…" />
            <CommandList className="model-menu-list">
              <CommandEmpty>No matching models.</CommandEmpty>
              {[...new Set(models.map((item) => item.provider))].map((group) => <CommandGroup key={group} heading={group}>
                {models.filter((item) => item.provider === group).map((item) =>
                  <CommandItem key={item.id} value={JSON.stringify([item.id, group])}
                    keywords={[item.id, group]} disabled={disabled || saving}
                    onSelect={() => void choose(() => api.setModel(id, item.id, item.provider))}>
                    <span>{modelLabel(item.id)}</span>
                    {model === item.id && provider === item.provider && <CheckIcon aria-label="Current model" />}
                  </CommandItem>)}
              </CommandGroup>)}
            </CommandList>
          </Command> : <div className="model-efforts">
            {effortStatus && <p role="status">{effortStatus}</p>}
            {efforts.map((item) => <button key={item} type="button" className="model-menu-row"
              disabled={disabled || saving} onClick={() => void choose(() => api.submit(id, `/effort ${item}`))}>
              <span>{effortLabel(item)}</span>{effort === item && <CheckIcon aria-label="Current effort" />}
            </button>)}
          </div>}
        </>}
      </Popover.Content>
    </Popover.Portal>
  </Popover.Root>;
}
