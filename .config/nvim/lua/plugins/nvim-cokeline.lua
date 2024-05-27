return {
  {
    'willothy/nvim-cokeline',
    dependencies = {
      'nvim-lua/plenary.nvim', -- Required for v0.4.0+
      'nvim-tree/nvim-web-devicons', -- If you want devicons

      -- WARN: remove this if history is not needed
      'stevearc/resession.nvim', -- Optional, for persistent history
    },
    config = function()
      local get_hex = require('cokeline.hlgroups').get_hl_attr
      local green = vim.g.terminal_color_2
      local yellow = vim.g.terminal_color_3

      require('cokeline').setup {
        default_hl = {
          fg = function(buffer)
            return buffer.is_focused and get_hex('Normal', 'bg') or get_hex('Normal', 'fg')
          end,
          bg = function()
            return get_hex('None', 'fg')
          end,
        },
        fill_hl = 'None',
        components = {
          {
            text = ' ',
            fg = function(buffer)
              return buffer.is_modified and yellow or green
            end,
          },
          {
            text = function(buffer)
              return buffer.devicon.icon .. ' '
            end,
            fg = function(buffer)
              return buffer.devicon.color
            end,
          },
          {
            text = function(buffer)
              return buffer.index .. ': '
            end,
          },
          {
            text = function(buffer)
              return buffer.unique_prefix
            end,
            fg = get_hex('Comment', 'fg'),
            italic = true,
          },
          {
            text = function(buffer)
              return buffer.filename .. ' '
            end,
            bold = function(buffer)
              return buffer.is_focused
            end,
          },
          {
            text = ' ',
          },
        },
        tabs = {
          placement = 'right',
          components = {
            {
              text = ' ',
            },
            {
              text = function(tabp)
                return tabp.number
              end,
              bold = function(tabp)
                return tabp.is_active
              end,
            },
            {
              text = ' ',
            },
          },
        },
        history = {
          enabled = true,
          size = 2,
        },
        sidebar = {
          filetype = 'neo-tree',
          components = {
            {
              text = function()
                return ' Neo-tree'
              end,
            },
          },
        },
      }

      for i = 1, 9 do
        vim.keymap.set('n', ('<Leader>%s'):format(i), ('<Plug>(cokeline-focus-%s)'):format(i), { silent = true })
      end

      -- FIXME: currently not working
      vim.api.nvim_create_autocmd('User', {
        pattern = 'AutoSession::SessionRestored',
        callback = function()
          local last_buffer = require('cokeline.history'):last()
          if last_buffer then
            last_buffer:focus()
          end
        end,
      })
    end,
  },
}
