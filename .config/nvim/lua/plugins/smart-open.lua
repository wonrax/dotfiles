-- A better telescope-frecency.nvim
return {
  {
    'danielfalk/smart-open.nvim',
    branch = '0.3.x',
    init = function()
      -- LIBSQLITE is exported by home-manager (home/desktop.nix) so sqlite.lua
      -- can find libsqlite3 without relying on nix-ld / DYLD_LIBRARY_PATH.
      if vim.env.LIBSQLITE then
        vim.g.sqlite_clib_path = vim.env.LIBSQLITE
      end
    end,
    config = function()
      require('telescope').load_extension 'smart_open'
      vim.keymap.set('n', '<leader><leader>', function()
        require('telescope').extensions.smart_open.smart_open {
          cwd_only = true,
        }
      end, { noremap = true, silent = true, desc = 'Pick recent files or buffers' })
    end,
    dependencies = {
      'kkharji/sqlite.lua',
    },
  },
}
