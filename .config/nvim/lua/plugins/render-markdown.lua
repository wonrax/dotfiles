return {
  {
    'MeanderingProgrammer/render-markdown.nvim',
    ft = { 'markdown' },
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'nvim-tree/nvim-web-devicons',
    },
    opts = {},
    keys = {
      { '<leader>m', '<cmd>RenderMarkdown toggle<cr>', ft = 'markdown', desc = 'Toggle [M]arkdown render' },
    },
  },
}
