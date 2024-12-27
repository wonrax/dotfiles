return {
  {
    'FabijanZulj/blame.nvim',
    keys = {
      {
        '<leader>gb',
        mode = { 'n' },
        function()
          vim.cmd 'BlameToggle virtual'
        end,
        desc = 'Toggle Virual Blame',
      },
    },
    lazy = true,
    config = function()
      require('blame').setup {}
    end,
  },
}
