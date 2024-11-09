-- Diagnostic keymaps
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
vim.keymap.set('n', '<leader>le', vim.diagnostic.open_float, { desc = 'Show [L]sp diagnostic [E]rror messages' })
vim.keymap.set('n', 'gh', vim.diagnostic.open_float, { desc = 'Show cursor diagnostics' })
vim.keymap.set('n', '<leader>lf', vim.diagnostic.setloclist, { desc = '[L]sp Open diagnostic Quick[f]ix list' })
-- NOTE: disabled to use lspsaga show_cursor_diagnostics
-- vim.keymap.set('n', 'gh', vim.diagnostic.open_float, { desc = 'Show [L]sp diagnostic [E]rror messages' })

-- Quit
vim.keymap.set('n', '<leader>qa', function()
  vim.cmd 'qa'
end, { desc = 'Quit [a]ll' })
vim.keymap.set('n', '<leader>qq', function()
  vim.cmd 'q'
end, { desc = '[Q]uit' })

-- Write buffer
vim.keymap.set('n', '<leader>w', function()
  vim.cmd 'w'
end, { desc = '[W]rite current buffer' })

-- Map gj gk
vim.keymap.set('n', 'j', 'gj', { silent = true })
vim.keymap.set('n', 'k', 'gk', { silent = true })
vim.keymap.set('v', 'j', 'gj', { silent = true })
vim.keymap.set('v', 'k', 'gk', { silent = true })

vim.keymap.set('n', '<leader>tc', function()
  vim.cmd 'tabclose'
end, { desc = 'Close current tabpage' })

vim.keymap.set('n', '<leader>tn', function()
  vim.cmd 'tabnext'
end, { desc = 'Switch to next tabpage' })

vim.keymap.set('n', '<leader>tp', function()
  vim.cmd 'tabprev'
end, { desc = 'Switch to previous tabpage' })

vim.keymap.set('n', '<leader>bd', ':bn<cr>:bd#<cr>', { desc = 'Close current buffer without closing the window' })

-- TODO: this does not work because there are multiple Esc mappings, which
-- override each other.
vim.keymap.set('n', '<Esc>', function()
  -- Close every floating window, this is helpful when for example you want to
  -- quit the focused hover window without having to press `q`. Improv of
  -- https://github.com/mawkler/nvim/blob/fc218645/lua/utils.lua#L56-L63
  for _, win in pairs(vim.api.nvim_list_wins()) do
    -- nvim_win_get_config() will throw an error if the window is not valid,
    -- which i guess can happen if the window was closed while we are iterating
    -- over the list of windows
    local ok, conf = pcall(vim.api.nvim_win_get_config, win)

    if ok and conf ~= nil then
      if conf.relative == 'win' then
        vim.api.nvim_win_close(win, false)
      end
    end
  end

  -- Clear the search highlight
  vim.cmd 'nohlsearch'
end, { desc = 'Close every floating window' })

vim.keymap.set('n', '<leader>tt', vim.cmd.terminal, { desc = 'Open Neovim terminal simulator' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- TIP: Disable arrow keys in normal mode
-- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
-- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
-- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
-- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

vim.keymap.set('n', '<leader><Tab>', function()
  vim.cmd 'edit #'
end, { desc = 'Switch to previous buffer' })

vim.keymap.set('n', '<leader>H', function()
  if vim.lsp.inlay_hint.is_enabled { bufnr = 0 } then
    vim.lsp.inlay_hint.enable(false, { bufnr = 0 })
  else
    vim.lsp.inlay_hint.enable(true, { bufnr = 0 })
  end
end, {
  desc = 'Toggle inlay hints',
})
