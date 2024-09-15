-- This file defines our custom 'User' events that can be used with autocmds.

local M = {}

M.auto_session = {
  session_restored = 'AutoSession::SessionRestored',
  no_session_restored = 'AutoSession::NoSessionRestored',
  pre_session_save = 'AutoSession::PreSessionSave',
}

return M
