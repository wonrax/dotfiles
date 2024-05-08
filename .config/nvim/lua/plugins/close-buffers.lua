return {
  {
    'Asheq/close-buffers.vim',
    config = function()
      vim.keymap.set('n', '<leader>bc', ':Bdelete menu<cr>', { desc = 'Open close-buffers menu' })
    end,
  },
}
