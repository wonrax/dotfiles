import type { AutolithAPI, TerminalEvent } from './api.js';
import type { IpcRendererEvent } from 'electron';

const { contextBridge, ipcRenderer }: typeof import('electron') = require('electron');

const api: AutolithAPI = {
  conversations: (cursor) => ipcRenderer.invoke('conversations', cursor),
  resume: (id, directory) => ipcRenderer.invoke('resume', id, directory),
  sessions: () => ipcRenderer.invoke('sessions'),
  snapshot: (id) => ipcRenderer.invoke('snapshot', id),
  models: (id) => ipcRenderer.invoke('models', id),
  settings: (id) => ipcRenderer.invoke('settings', id),
  setSetting: (id, name, value) => ipcRenderer.invoke('setSetting', id, name, value),
  generations: (id) => ipcRenderer.invoke('generations', id),
  commands: (id) => ipcRenderer.invoke('commands', id),
  attach: (id, takeOver) => ipcRenderer.invoke('attach', id, takeOver),
  choose: (id, picker, index) => ipcRenderer.invoke('choose', id, picker, index),
  input: (id, data) => ipcRenderer.invoke('input', id, data),
  submit: (id, text) => ipcRenderer.invoke('submit', id, text),
  setModel: (id, model, provider) => ipcRenderer.invoke('setModel', id, model, provider),
  startSession: () => ipcRenderer.invoke('startSession'),
  copy: (text) => ipcRenderer.invoke('copy', text),
  onTerminal: (listener) => {
    const wrapped = (_event: IpcRendererEvent, id: string, packet: TerminalEvent) => listener(id, packet);
    ipcRenderer.on('terminal', wrapped);
    return () => ipcRenderer.removeListener('terminal', wrapped);
  },
};

contextBridge.exposeInMainWorld('autolith', api);
