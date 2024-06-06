return {
  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    config = function() -- This is the function that runs, AFTER loading
      require('which-key').setup {
        window = {
          border = 'double',
        },
      }

      -- Document existing key chains
      require('which-key').register {
        ['<leader>d'] = { name = '[D]ocument', _ = 'which_key_ignore' },
        ['<leader>r'] = { name = '[R]ename', _ = 'which_key_ignore' },
        ['<leader>f'] = { name = '[F]ind', _ = 'which_key_ignore' },
        ['<leader>l'] = { name = '[L]sp', _ = 'which_key_ignore' },
        ['<leader>q'] = { name = '[Q]uit', _ = 'which_key_ignore' },
        ['<leader>t'] = { name = '[T]oggle', _ = 'which_key_ignore' },
        ['<leader>h'] = { name = 'Git [H]unk', _ = 'which_key_ignore' },
        ['<leader>*'] = { name = 'Switch to buffer [number]', _ = 'which_key_ignore' },
      }

      -- Hide <leader>[number] keybinds
      for i = 1, 9 do
        require('which-key').register({
          ['<leader>' .. i] = 'which_key_ignore',
        }, { mode = 'n' })
      end

      -- visual mode
      require('which-key').register({
        ['<leader>h'] = { 'Git [H]unk' },
      }, { mode = 'v' })
    end,
  },
}
