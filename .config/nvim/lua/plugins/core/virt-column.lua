return {
  {
    'lukas-reineke/virt-column.nvim',
    opts = {
      enabled = true,
      virtcolumn = '80',
      char = '│',
    },
    config = function(_, opts)
      require('virt-column').setup(opts)
    end,
  },
}
