-- TODO: fix todo comments colors somehow showing different colors on different
-- file type, (e.g. FIXME: on tmux.conf)
-- TODO: maybe add LSP and git status to nvim cokeline
-- TODO: persist light/dark theme preference so that it won't flash on startup,
-- especially when on dark mode. save flag to stdpath 'data' every time
-- auto-dark-mode is toggled and load it on startup
-- TODO: shift-k currently shows the documentation of the word under the cursor
-- and <leader>le shows the diagnostics of the word under the cursor, implement
-- a way to show both at the same time

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.opt.exrc = true

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- TODO: why direct assignment doesn't work?
-- i.e. vim.opt.fillchars.vert = '▕'
vim.opt.fillchars = { vert = '▕' }

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- So there won't be no [No name] file when VimEnter
-- but this will not permit switching buffers while dirty
-- vim.cmd 'set nohidden'

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
vim.opt.relativenumber = true

-- Merge statusline and cmdline
vim.opt.cmdheight = 0

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Sync clipboard between OS and Neovim.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.opt.clipboard = 'unnamedplus'

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
-- Displays which-key popup sooner
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

vim.opt.tabstop = 4

-- Set highlight on search
vim.opt.hlsearch = true

vim.diagnostic.config {
  float = {
    border = 'rounded',
  },
  virtual_lines = true,
}

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`
require 'keymaps'

-- [[ Autocommands ]]
require 'autocmds'
require 'tmux'
require 'zellij'

-- [[ Install `lazy.nvim` plugin manager ]]
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
end
vim.opt.rtp:prepend(lazypath)

-- Check for lean mode via environment variable or CLI flag
local is_lean = os.getenv 'NVIM_LEAN_MODE' == '1' or vim.g.nvim_lean_mode == 1

-- Set global flag for later use (optional)
vim.g.nvim_lean_mode = is_lean and 1 or 0

require('lazy').setup({
  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  'tpope/vim-sleuth', -- Detect tabstop and shiftwidth automatically

  -- "gc" to comment visual regions/lines
  { 'numToStr/Comment.nvim', opts = {} },

  { import = 'plugins/core' },
  is_lean and {} or {
    { import = 'plugins' },
  },
}, {
  ui = {
    border = 'rounded',
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
--
vim.filetype.add {
  extension = {
    mdx = 'mdx',
  },
}

require 'usercmds'
