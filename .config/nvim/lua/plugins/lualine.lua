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
          lualine_c = {
            {
              'filename',
              file_status = true, -- Displays file status (readonly status, modified status)
              newfile_status = true, -- Display new file status (new file means no write after created)
              path = 1, -- 0: Just the filename
              -- 1: Relative path
              -- 2: Absolute path
              -- 3: Absolute path, with tilde as the home directory
              -- 4: Filename and parent dir, with tilde as the home directory

              -- shorting_target = 40, -- Shortens path to leave 40 spaces in the window
              -- for other components. (terrible name, any suggestions?)
              symbols = {
                modified = '[+]', -- Text to show when the file is modified.
                readonly = '[]', -- Text to show when the file is non-modifiable or readonly.
                unnamed = '[No Name]', -- Text to show for unnamed buffers.
                newfile = '[New]', -- Text to show for newly created file before first write
              },
            },
          },
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
