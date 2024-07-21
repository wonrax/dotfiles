return {
  -- Highlight todo, notes, etc in comments
  {
    'folke/todo-comments.nvim',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/plenary.nvim',

      -- Set the current using theme as a dependency so that when starting up
      -- the theme is loaded before todo-comments and the highlight groups are
      -- available, otherwise if the hi groups are nil it will use the default
      -- colors
      'EdenEast/nightfox.nvim',
    },
    opts = {
      signs = false,
      highlight = {
        before = '',
        keyword = 'fg',
        after = '',
      },

      -- Test colors:
      -- NOTE: note
      -- TODO: todo
      -- WARN: warn
      -- FIXME: fixme
      colors = {
        error = { 'DiagnosticError', 'ErrorMsg', '#DC2626' },
        warning = { 'DiagnosticWarn', 'WarningMsg', '#FBBF24' },
        info = { 'DiagnosticInfo', '#2563EB' },
        hint = { 'DiagnosticHint', '#10B981' },
        default = { 'Identifier', '#7C3AED' },
        test = { 'Identifier', '#FF00FF' },
      },
    },
  },
}
