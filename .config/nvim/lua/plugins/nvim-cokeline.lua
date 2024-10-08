return {
  {
    'willothy/nvim-cokeline',
    dependencies = {
      'nvim-lua/plenary.nvim', -- Required for v0.4.0+
      'nvim-tree/nvim-web-devicons', -- If you want devicons
    },
    config = function()
      local get_hex = require('cokeline.hlgroups').get_hl_attr
      local green = vim.g.terminal_color_2
      local yellow = vim.g.terminal_color_3

      local focused_bg = function(buffer)
        return buffer.is_focused and get_hex('WinSeparator', 'fg') or get_hex('None', 'bg')
      end

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
            text = '  ',
            bg = focused_bg,
          },
          {
            text = function(buffer)
              return buffer.devicon.icon
            end,
            fg = function(buffer)
              return buffer.devicon.color
            end,
            bg = focused_bg,
          },
          {
            text = function(buffer)
              return buffer.index .. ':'
            end,
            bg = focused_bg,
          },
          {
            text = function(buffer)
              return buffer.unique_prefix
            end,
            fg = get_hex('Comment', 'fg'),
            italic = true,
            bg = focused_bg,
          },
          {
            text = function(buffer)
              return buffer.filename .. ' '
            end,
            bold = function(buffer)
              return buffer.is_focused
            end,
            bg = focused_bg,
          },
          { -- dirty status
            text = function(buffer)
              return buffer.is_modified and '●' or ' '
            end,
            fg = function(buffer)
              return buffer.is_modified and yellow or green
            end,
            bg = focused_bg,
          },
          {
            text = ' ',
            bg = focused_bg,
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
        vim.keymap.set('n', ('<Leader>%s'):format(i), ('<Plug>(cokeline-focus-%s)'):format(i), { silent = true, desc = nil })
      end

      vim.keymap.set('n', '<M-Right>', function()
        vim.cmd 'bnext'
      end, { desc = 'Next tab' })

      vim.keymap.set('n', '<C-Tab>', function()
        vim.cmd 'bnext'
      end, { desc = 'Next tab' })

      vim.keymap.set('n', '<M-Left>', function()
        vim.cmd 'bprevious'
      end, { desc = 'Previous tab' })

      vim.keymap.set('n', '<C-S-Tab>', function()
        vim.cmd 'bprevious'
      end, { desc = 'Previous tab' })
    end,
  },
}
