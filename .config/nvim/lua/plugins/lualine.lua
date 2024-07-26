return {
  {
    'nvim-lualine/lualine.nvim',
    dependencies = {
      'nvim-tree/nvim-web-devicons',
    },
    config = function()
      local theme = require 'lualine.themes.nightfox'
      theme.normal.b.bg = 'None'
      theme.normal.b.fg = 'Normal'
      require('lualine').setup {
        options = {
          theme = theme,
          component_separators = { left = '', right = '' },
          section_separators = { left = '', right = '' },
        },
        extensions = {
          'neo-tree',
        },
        sections = {
          lualine_b = { 'diff', 'diagnostics' },
          lualine_x = {
            'encoding',
            {
              'fileformat',
              symbols = {
                unix = '',
                dos = '',
                mac = '',
              },
            },
            'filetype',
          },
        },
      }
    end,
  },
}
