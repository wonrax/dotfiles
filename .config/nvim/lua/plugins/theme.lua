return {
  {
    'EdenEast/nightfox.nvim',
    opts = {
      options = {
        transparent = true,
        styles = { -- Style to be applied to different syntax groups
          comments = 'italic', -- Value is any valid attr-list value `:help attr-list`
          conditionals = 'NONE',
          constants = 'NONE',
          functions = 'NONE',
          keywords = 'NONE',
          numbers = 'NONE',
          operators = 'NONE',
          strings = 'NONE',
          types = 'NONE',
          variables = 'NONE',
        },
      },
      palettes = {
        dayfox = {
          -- BG color for current line selection etc. since it's a bit too
          -- dimmed when using the transparent window bg
          bg3 = '#e7e7e7',
        },
        nightfox = {
          bg0 = '#24292e',
        },
      },
      groups = {
        all = {
          -- The two below set the bg color for the floating windows to be
          -- transparent
          NormalFloat = { link = 'Normal' },
          FloatBorder = { bg = 'None' },
        },
      },
    },
    lazy = false, -- make sure we load this during startup if it is your main colorscheme
    config = function(_, opts)
      require('nightfox').setup(opts)

      -- TODO: This line prevents light themes from flashing on startup however in
      -- system dark mode it will still flash the light theme
      vim.cmd 'colorscheme dayfox'
    end,
  },

  {
    'projekt0n/github-nvim-theme',
    priority = 1000, -- make sure to load this before all the other start plugins
    lazy = true,
    config = function()
      require('github-theme').setup {
        options = {
          -- Compiled file's destination location
          hide_end_of_buffer = true, -- Hide the '~' character at the end of the buffer for a cleaner look
          hide_nc_statusline = true, -- Override the underline style for non-active statuslines
          transparent = true, -- Disable setting background
          terminal_colors = true, -- Set terminal colors (vim.g.terminal_color_*) used in `:terminal`
          dim_inactive = true, -- Non focused panes set to alternative background
          module_default = true, -- Default enable value for modules
          styles = { -- Style to be applied to different syntax groups
            comments = 'italic', -- Value is any valid attr-list value `:help attr-list`
            functions = 'NONE',
            keywords = 'NONE',
            variables = 'NONE',
            conditionals = 'NONE',
            constants = 'NONE',
            numbers = 'NONE',
            operators = 'NONE',
            strings = 'NONE',
            types = 'NONE',
          },
          inverse = { -- Inverse highlight for different types
            match_paren = false,
            visual = false,
            search = false,
          },
          darken = { -- Darken floating windows and sidebar-like windows
            floats = true,
            sidebars = {
              enabled = true,
            },
          },
        },
        palettes = {},
      }

      -- NOTE: We don't need to set the colorscheme here, as it is done automatically
      -- by the `auto-dark-mode` plugin. Setting the colorscheme here could cause
      -- theme flashing on startup if the auto-dark-mode plugin is enabled.
      -- vim.cmd 'colorscheme github_light'
    end,
  },

  {
    'f-person/auto-dark-mode.nvim',
    config = function()
      require('auto-dark-mode').setup {
        update_interval = 1000,
        set_dark_mode = function()
          vim.cmd 'colorscheme nightfox'
        end,
        set_light_mode = function()
          vim.cmd 'colorscheme dayfox'
        end,
      }
    end,
    lazy = false,
  },
}
