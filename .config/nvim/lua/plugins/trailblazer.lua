return {
  {
    'LeonHeidelbach/trailblazer.nvim',
    config = function()
      require('trailblazer').setup {
        mappings = { -- rename this to "force_mappings" to completely override default mappings and not merge with them
          nv = { -- Mode union: normal & visual mode. Can be extended by adding i, x, ...
            motions = {
              new_trail_mark = '<A-+>',
            },
          },
        },
      }
    end,
  },
}
