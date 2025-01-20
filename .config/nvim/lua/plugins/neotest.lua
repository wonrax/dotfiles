return {
  {
    'nvim-neotest/neotest',
    dependencies = {
      'nvim-neotest/nvim-nio',
      'mrcjkb/neotest-haskell',
    },
    config = function()
      ---@diagnostic disable-next-line: missing-fields
      require('neotest').setup {
        adapters = {
          require 'neotest-haskell',
          require 'rustaceanvim.neotest',
        },
      }

      require('which-key').add {
        { '<leader>tr', group = 'Neotest run' },
        {
          '<leader>trr',
          desc = 'Neotest run cursor',
          function()
            vim.cmd 'Neotest run'
          end,
        },
        {
          '<leader>trf',
          desc = 'Neotest run file',
          function()
            vim.cmd 'Neotest run file'
          end,
        },
        {
          '<leader>trl',
          desc = 'Neotest run last',
          function()
            vim.cmd 'Neotest run last'
          end,
        },
        {
          '<leader>ts',
          desc = 'Neotest summary',
          function()
            vim.cmd 'Neotest summary'
          end,
        },
        {
          '<leader>to',
          desc = 'Neotest show output',
          function()
            vim.cmd 'Neotest output'
          end,
        },
      }
    end,
  },
}
