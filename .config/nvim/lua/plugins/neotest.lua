return {
  {
    'nvim-neotest/neotest',
    dependencies = {
      'nvim-neotest/nvim-nio',
      'mrcjkb/neotest-haskell',
    },
    config = function()
      require('neotest').setup {
        adapters = {
          require 'neotest-haskell',
          require 'rustaceanvim.neotest',
        },
      }
    end,
  },
}
