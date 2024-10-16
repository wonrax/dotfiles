return {
  {
    'NeogitOrg/neogit',
    keys = {
      {
        '<leader>g',
        mode = { 'n', 'v' },
        function()
          require('neogit').open()
        end,
        desc = 'Open Neogit',
      },
    },
    dependencies = {
      'nvim-lua/plenary.nvim', -- required
      'sindrets/diffview.nvim', -- optional - Diff integration

      -- Only one of these is needed, not both.
      'nvim-telescope/telescope.nvim', -- optional
    },
    config = function(_, opts)
      require('neogit').setup(opts)

      -- TODO: does not automatically change the colors when dark/light theme changes
      local palette = require('palette').load_current_theme_palette()

      vim.api.nvim_set_hl(0, 'NeogitStagedchanges', { fg = palette.fg0, bg = palette.bg0 }) -- Staged changespalette
      vim.api.nvim_set_hl(0, 'NeogitUnstagedchanges', { fg = palette.blue.base, bg = palette.bg0 }) -- Unstaged changespalette
      vim.api.nvim_set_hl(0, 'NeogitRecentCommits', { fg = palette.blue.base, bg = palette.bg0 }) -- Recent commits
      vim.api.nvim_set_hl(0, 'NeogitBranch', { fg = palette.yellow.base, bg = palette.bg0 }) -- Head branch
      vim.api.nvim_set_hl(0, 'NeogitRemote', { fg = palette.yellow.base, bg = palette.bg0 }) -- Push branch
      vim.api.nvim_set_hl(0, 'NeogitDiffAddHighlight', { fg = palette.green.base, bg = palette.bg0 }) -- Added
      vim.api.nvim_set_hl(0, 'NeogitDiffDeleteHighlight', { fg = palette.red.base, bg = palette.bg0 }) -- Removed

      vim.api.nvim_set_hl(0, 'NeogitHunkHeader', { fg = palette.orange.base, bg = palette.bg0 }) -- Header
      vim.api.nvim_set_hl(0, 'NeogitHunkHeaderHighlight', { fg = palette.orange.base, bg = palette.bg0 }) -- Header highlighted
      vim.api.nvim_set_hl(0, 'NeogitDiffContextHighlight', { fg = palette.black.base, bg = palette.bg1 }) -- Header highlighted
      vim.api.nvim_set_hl(0, 'NeogitDiffContext', { fg = palette.black.base, bg = palette.bg0 }) -- Header highlighted
    end,
  },
}
