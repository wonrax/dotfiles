-- A better telescope-frecency.nvim
return {
  {
    'danielfalk/smart-open.nvim',
    branch = '0.3.x',
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
      -- Optional.  If installed, native fzy will be used when match_algorithm is fzy
      -- { 'nvim-telescope/telescope-fzy-native.nvim' },
    },
  },
}
