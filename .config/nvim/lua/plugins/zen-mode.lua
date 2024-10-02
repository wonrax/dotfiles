return {
  {
    'folke/zen-mode.nvim',
    opts = {
      -- your configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
    },
    config = function(_, opts)
      require('zen-mode').setup(opts)

      vim.keymap.set('n', '<leader>z', function()
        require('zen-mode').toggle()
      end, { noremap = true, silent = true, desc = 'Toggle zen mode' })
    end,
  },
}
