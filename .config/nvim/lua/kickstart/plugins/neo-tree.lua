-- Neo-tree is a Neovim plugin to browse the file system
-- https://github.com/nvim-neo-tree/neo-tree.nvim

return {
  'nvim-neo-tree/neo-tree.nvim',
  version = '*',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons', -- not strictly required, but recommended
    'MunifTanjim/nui.nvim',
  },
  cmd = 'Neotree',
  lazy = false,
  keys = {
    { '<leader>e', ':Neotree reveal<CR>', { desc = 'NeoTree reveal' } },
  },
  opts = {
    close_if_last_window = true,
    sources = { 'filesystem', 'buffers', 'git_status' },
    source_selector = {
      winbar = true,
      content_layout = 'center',
      sources = {
        { source = 'filesystem', display_name = 'File' },
        { source = 'buffers', display_name = 'Bufs' },
        { source = 'git_status', display_name = 'Git' },
        { source = 'diagnostics', display_name = 'Diagnostic' },
      },
    },
    filesystem = {
      filtered_items = {
        visible = true, -- This is what you want: If you set this to `true`, all "hide" just mean "dimmed out"
        hide_dotfiles = false,
        hide_gitignored = true,
      },
      window = {
        mappings = {
          ['<leader>e'] = 'close_window',
          ['<space>'] = false, -- disable space until we figure out which-key disabling
          o = 'open',
        },
      },
      follow_current_file = { enabled = true, leave_dirs_open = true },
      hijack_netrw_behavior = 'open_default',
      use_libuv_file_watcher = true,
    },
  },
  config = function(_, opts)
    require('neo-tree').setup(opts)
  end,
}
