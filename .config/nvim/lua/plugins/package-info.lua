-- npm package info for neovim
return {
  {
    'vuki656/package-info.nvim',
    dependencies = {
      'MunifTanjim/nui.nvim',
      'nvim-telescope/telescope.nvim',
    },
    ft = 'json',
    config = function()
      require('package-info').setup()
    end,
  },
}
