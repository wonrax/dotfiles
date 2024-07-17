return {
  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    config = function() -- This is the function that runs, AFTER loading
      require('which-key').setup {
        preset = 'helix',
      }

      -- Document existing key chains
      require('which-key').add {
        { '<leader>*', group = 'Switch to buffer [number]' },
        { '<leader>f', group = '[F]ind', icon = { icon = '', color = 'grey' } },
        { '<leader>h', group = 'Git [H]unk' },
        { '<leader>l', group = '[L]sp', icon = '' },
        { '<leader>q', group = '[Q]uit', icon = { icon = '󰈆', color = 'red' } },
        { '<leader>r', group = '[R]ename', icon = '' },
        { '<leader>t', group = '[T]oggle/[T]abpage/[T]erminal', icon = '' },
        { '<leader>b', group = '[B]uffer', icon = '󰈔' },
        { '<leader>c', group = '[C]opilot', icon = '', mode = { 'v', 'n' } },
      }

      -- Hide <leader>[number] keybinds
      for i = 1, 9 do
        require('which-key').add {
          { '<leader>' .. i, hidden = true },
        }
      end

      -- visual mode
      require('which-key').add {
        { '<leader>h', desc = 'Git [H]unk', mode = 'v' },
      }
    end,
  },
}
