return {
  {
    'nvim-lualine/lualine.nvim',
    dependencies = {
      'nvim-tree/nvim-web-devicons',
    },
    -- Event `VeryLazy` is a MUST since the colors will not be set correctly if
    -- the colorscheme is set after the lualine config is loaded.
    event = 'VeryLazy',
    config = function()
      local function get_opts()
        -- TODO: there are cases where the colorscheme is set before our config
        -- is loaded, for example when the Lazy install window is opened on
        -- startup, it will set the colorscheme to Lazy's default colorscheme,
        -- which is not what we have, thus erroring out.
        local theme = require('lualine.themes.' .. (vim.g.colors_name or 'ayu'))

        local palette = require('palette').load_current_theme_palette()

        local b_bg = palette.bg0
        local b_fg = palette.fg0
        local inactive_bg = palette.bg0
        local inactive_fg = palette.fg2

        theme.normal.b.bg = b_bg
        theme.normal.b.fg = b_fg
        theme.insert.b.bg = b_bg
        theme.insert.b.fg = b_fg
        theme.visual.b.bg = b_bg
        theme.visual.b.fg = b_fg
        theme.normal.c.bg = b_bg

        theme.normal.c.bg = b_bg
        theme.inactive.c.bg = inactive_bg
        theme.inactive.c.fg = inactive_fg

        local function get_short_cwd()
          return vim.fn.fnamemodify(vim.fn.getcwd(), ':~')
        end

        local neotree = require 'lualine.extensions.neo-tree'
        local my_neotree = {
          sections = {
            lualine_a = { { get_short_cwd, color = { bg = palette.blue.base, fg = b_bg } } },
          },
          inactive_sections = {
            lualine_a = { { get_short_cwd, color = { bg = b_bg } } },
          },
          filetypes = neotree.filetypes,
        }

        return {
          options = {
            theme = theme,
            component_separators = { left = '', right = '' },
            section_separators = { left = '', right = '' },
          },
          extensions = {
            my_neotree,
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
              {
                function()
                  if not require('copilot.client').is_disabled() then
                    return ''
                  end
                  return ''
                end,
                color = { gui = 'bold' },
                padding = 0,
              },
            },
          },
        }
      end

      -- Reload lualine on colorscheme change, mainly dark/light mode toggle
      vim.api.nvim_create_autocmd('ColorScheme', {
        callback = function()
          require('lualine').setup(get_opts())
        end,
      })

      require('lualine').setup(get_opts())
    end,
  },
}
