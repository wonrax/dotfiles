return {
  {
    'kazhala/close-buffers.nvim',
    lazy = false,
    config = function(_, opts)
      require('close_buffers').setup(opts)

      vim.keymap.set('n', '<leader>bco', function()
        require('close_buffers').wipe { type = 'other' }
      end, { desc = 'Close other buffers' })

      vim.api.nvim_create_autocmd('User', {
        pattern = require('events').auto_session.session_restored,
        callback = function()
          require('close_buffers').delete { type = 'nameless' }
        end,
        once = true,
      })
    end,
  },
}
