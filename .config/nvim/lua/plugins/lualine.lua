return {
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = {
      options = {
        -- TODO: maybe readd separators but with a lighter color
        component_separators = { left = '', right = '' },
        section_separators = { left = '', right = '' },
      },
      extensions = {
        'neo-tree',
      },
      sections = {
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
    },
  },
}
