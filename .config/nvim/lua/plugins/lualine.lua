return {
  {
    'nvim-lualine/lualine.nvim',
    dependencies = {
      'nvim-tree/nvim-web-devicons',
    },
    config = function()
      local theme = require 'lualine.themes.nightfox'

      local b_bg = 'None'
      local b_fg = 'Normal'

      theme.normal.b.bg = b_bg
      theme.normal.b.fg = b_fg
      theme.insert.b.bg = b_bg
      theme.insert.b.fg = b_fg
      theme.visual.b.bg = b_bg
      theme.visual.b.fg = b_fg
      theme.normal.a.bg = '#7AA2F7'
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
