-- Neo-tree is a Neovim plugin to browse the file system
-- https://github.com/nvim-neo-tree/neo-tree.nvim

local function suppress_netrw()
  -- inspired by
  -- https://github.com/nvim-telescope/telescope-file-browser.nvim/blob/8574946bf6d0d820d7f600f3db808f5900a2ae23/lua/telescope/_extensions/file_browser/config.lua#L73
  local netrw_bufname
  -- clear FileExplorer appropriately to prevent netrw from launching on folders
  -- netrw may or may not be loaded before telescope-file-browser config
  -- conceptual credits to nvim-tree
  pcall(vim.api.nvim_clear_autocmds, { group = 'FileExplorer' })
  vim.api.nvim_create_autocmd('VimEnter', {
    pattern = '*',
    once = true,
    callback = function()
      pcall(vim.api.nvim_clear_autocmds, { group = 'FileExplorer' })
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('suppress_netrw_on_open', { clear = true }),
    pattern = '*',
    callback = function()
      vim.schedule(function()
        if vim.bo[0].filetype == 'netrw' then
          return
        end
        local bufname = vim.api.nvim_buf_get_name(0)
        if vim.fn.isdirectory(bufname) == 0 then
          _, netrw_bufname = pcall(vim.fn.expand, '#:p:h')
          return
        end

        -- prevents reopening of file-browser if exiting without selecting a file
        if netrw_bufname == bufname then
          netrw_bufname = nil
          return
        else
          netrw_bufname = bufname
        end

        -- ensure no buffers remain with the directory name
        vim.api.nvim_buf_set_option(0, 'bufhidden', 'wipe')
      end)
    end,
    desc = 'Prevent netrw from opening on directory',
  })
end

return {
  'nvim-neo-tree/neo-tree.nvim',
  version = '3.*',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons', -- not strictly required, but recommended
    'MunifTanjim/nui.nvim',
  },
  cmd = 'Neotree',
  lazy = false,
  keys = {
    { '<leader>e', ':Neotree reveal position=left<CR>', { desc = 'NeoTree reveal' } },
  },
  opts = {
    close_if_last_window = true,
    sources = { 'filesystem', 'buffers', 'git_status' },
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
      use_libuv_file_watcher = true,
      hijack_netrw_behavior = 'disabled',
    },
  },
  config = function(_, opts)
    require('neo-tree').setup(opts)

    suppress_netrw()

    -- open the file browser when no session is restored
    vim.api.nvim_create_autocmd('User', {
      pattern = 'AutoSession::NoSessionRestored',
      callback = function()
        require('neo-tree.command').execute { action = 'focus' }
      end,
    })
  end,
}
