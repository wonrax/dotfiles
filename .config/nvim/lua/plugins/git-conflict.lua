return {
  {
    'akinsho/git-conflict.nvim',
    version = '*',
    config = true,
    opts = {
      highlights = { -- They must have background color, otherwise the default color will be used
        incoming = 'DiffChange',
        current = 'DiffAdd',
        ancestor = 'DiffDelete',
      },
      -- Hide diagnostic messages because the conflict markers could cause
      -- syntax errors
      disable_diagnostics = true,
    },
  },
}
