return {
  {
    'nvim-telescope/telescope-frecency.nvim',
    commit = '25d01edae8a2d74bcaa706c003b2712bce1e3301',
    config = function()
      -- This extension may conflict with the auto-session plugin when it tries
      -- to prompt a 'Delete n entries from the database' by opening a new
      -- telescope window, but the auto-session may have already remove the
      -- window by the time the prompt is shown. The workaround is to disable
      -- restore on startup in auto-session plugin config.
      require('telescope').load_extension 'frecency'

      -- Temporarily disable this so my muscle memory doesn't get confused
      -- with the new smart-open keybind.
      -- vim.keymap.set('n', '<leader>ff', function()
      --   require('telescope').extensions.frecency.frecency { workspace = 'CWD' }
      -- end, { desc = '[F]ind [F]iles by frecency' })
    end,
  },
}
