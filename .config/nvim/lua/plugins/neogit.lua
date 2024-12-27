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

      local update_neogit_colors = function()
        local palette = require('palette').load_current_theme_palette()

        vim.api.nvim_set_hl(0, 'NeogitStagedchanges', { fg = palette.green.base, bg = 'None' }) -- Staged changespalette
        vim.api.nvim_set_hl(0, 'NeogitUnstagedchanges', { fg = palette.red.base, bg = 'None' }) -- Unstaged changespalette
        vim.api.nvim_set_hl(0, 'NeogitRecentCommits', { fg = palette.blue.base, bg = 'None' }) -- Recent commits
        vim.api.nvim_set_hl(0, 'NeogitBranch', { fg = palette.yellow.base, bg = 'None' }) -- Head branch
        vim.api.nvim_set_hl(0, 'NeogitRemote', { fg = palette.blue.dim, bg = 'None' }) -- Push branch
        vim.api.nvim_set_hl(0, 'NeogitDiffAddHighlight', { fg = palette.green.base, bg = palette.bg1 }) -- Added
        vim.api.nvim_set_hl(0, 'NeogitDiffDeleteHighlight', { fg = palette.red.base, bg = palette.bg1 }) -- Removed

        vim.api.nvim_set_hl(0, 'NeogitHunkHeader', { fg = palette.orange.base, bg = 'None' }) -- Header
        vim.api.nvim_set_hl(0, 'NeogitHunkHeaderHighlight', { fg = palette.orange.base, bg = 'None' }) -- Header highlighted
        vim.api.nvim_set_hl(0, 'NeogitDiffContextHighlight', { fg = palette.black.bright, bg = palette.bg3 }) -- Header highlighted
        vim.api.nvim_set_hl(0, 'NeogitDiffContext', { fg = palette.black.bright, bg = palette.bg1 }) -- Header highlighted
      end

      update_neogit_colors()

      vim.api.nvim_create_autocmd('ColorScheme', {
        callback = update_neogit_colors,
      })
    end,
  },
}
