return {
  {
    'rhysd/git-messenger.vim',
    init = function()
      vim.g.git_messenger_floating_win_opts = { border = 'rounded' }
      vim.keymap.set('n', '<Esc>', function()
        vim.cmd 'GitMessengerClose'
      end, {
        desc = 'Close any git-messenger window',
      })
    end,
  },
}
