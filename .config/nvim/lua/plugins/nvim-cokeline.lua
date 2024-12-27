return {
  {
    'willothy/nvim-cokeline',
    dependencies = {
      'nvim-lua/plenary.nvim', -- Required for v0.4.0+
      'nvim-tree/nvim-web-devicons', -- If you want devicons
    },
    config = function()
      local function config()
        local colorscheme = require('palette').load_current_theme_palette()

        local get_buffer_bg = function(buffer)
          return buffer.is_focused and colorscheme.black.base or colorscheme.bg0
        end

        require('cokeline').setup {
          default_hl = {
            fg = function(buffer)
              return buffer.is_focused and colorscheme.white.base or colorscheme.fg2
            end,
            bg = get_buffer_bg,
          },
          fill_hl = 'TabLineFill',
          components = {
            {
              text = function(buffer)
                return buffer.index == 1 and '▕' or ' '
              end,
              bg = function(buffer)
                return buffer.index == 1 and 'None' or get_buffer_bg(buffer)
              end,
              fg = colorscheme.bg0,
            },
            {
              text = ' ',
              bg = get_buffer_bg,
            },
            {
              text = function(buffer)
                return buffer.devicon.icon
              end,
              fg = function(buffer)
                return buffer.devicon.color
              end,
              bg = get_buffer_bg,
            },
            {
              text = function(buffer)
                return buffer.index .. ':'
              end,
              bg = get_buffer_bg,
              fg = function(buffer)
                return buffer.is_focused and colorscheme.white.base or colorscheme.fg2
              end,
            },
            {
              text = function(buffer)
                return buffer.unique_prefix
              end,
              fg = colorscheme.comment,
              italic = true,
              bg = get_buffer_bg,
            },
            {
              text = function(buffer)
                return buffer.filename .. ' '
              end,
              bold = function(buffer)
                return buffer.is_focused
              end,
              fg = function(buffer)
                return buffer.is_focused and colorscheme.white.base or colorscheme.fg2
              end,
              bg = get_buffer_bg,
            },
            { -- dirty status
              text = function(buffer)
                return buffer.is_modified and '●' or ' '
              end,
              fg = function(buffer)
                return buffer.is_modified and colorscheme.yellow.base or colorscheme.green.base
              end,
              bg = get_buffer_bg,
            },
            {
              text = ' ',
              bg = get_buffer_bg,
            },
          },
          tabs = {
            placement = 'right',
            components = {
              {
                text = function(tabp)
                  return ' ' .. tabp.number .. ' '
                end,
                bold = function(tabp)
                  return tabp.is_active
                end,
                bg = function(tabp)
                  return tabp.is_active and colorscheme.blue.base or colorscheme.bg0
                end,
                fg = function(tabp)
                  return tabp.is_active and colorscheme.white.base or colorscheme.blue.base
                end,
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
      end

      config()

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

      -- Reload cokeline on colorscheme change, mainly dark/light mode toggle
      vim.api.nvim_create_autocmd('ColorScheme', {
        callback = config,
      })
    end,
  },
}
