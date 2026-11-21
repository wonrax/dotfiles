return {
  {
    'smart-splits-nvim/smart-splits.nvim',
    version = '^3.0.0',
    dependencies = {
      {
        -- Rex's init.lua passes alt+hjkl and ctrl+alt+hjkl through to nvim, so
        -- this backend hands off to Rex panes at nvim's edges.
        'rawnly/smart-splits-backend-rex',
        opts = {
          -- REX_BIN_DIR is set in every Rex terminal; the CLI isn't on PATH elsewhere.
          bin = vim.env.REX_BIN_DIR and vim.env.REX_BIN_DIR .. '/rex' or 'rex',
        },
      },
      { 'smart-splits-nvim/backend-tmux', main = 'smart-splits-backend-tmux', opts = {} },
      { 'smart-splits-nvim/backend-zellij-lua', main = 'smart-splits-backend-zellij-lua', opts = {} },
    },
    opts = {
      mux = {
        backend = { 'smart-splits-backend-rex', 'smart-splits-backend-tmux', 'smart-splits-backend-zellij-lua' },
        -- don't warn when running nvim outside of a multiplexer
        warn_if_unusable = false,
      },
    },
    config = function(_, opts)
      local smart_splits = require 'smart-splits'
      smart_splits.setup(opts)

      -- resizing splits
      -- these keymaps will also accept a range,
      -- for example `10<M-h>` will `resize_left` by `(10 * config.resize.amount)`
      vim.keymap.set('n', '<C-M-h>', smart_splits.resize_left)
      vim.keymap.set('n', '<C-M-j>', smart_splits.resize_down)
      vim.keymap.set('n', '<C-M-k>', smart_splits.resize_up)
      vim.keymap.set('n', '<C-M-l>', smart_splits.resize_right)

      -- moving between splits
      vim.keymap.set('n', '<M-h>', smart_splits.move_cursor_left)
      vim.keymap.set('n', '<M-j>', smart_splits.move_cursor_down)
      vim.keymap.set('n', '<M-k>', smart_splits.move_cursor_up)
      vim.keymap.set('n', '<M-l>', smart_splits.move_cursor_right)
      -- v3 dropped move_cursor_previous, this only jumps between nvim windows
      vim.keymap.set('n', '<M-\\>', '<cmd>wincmd p<cr>')
    end,
  },
}
