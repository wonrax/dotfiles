-- npm package info for neovim
return {
  {
    'vuki656/package-info.nvim',
    dependencies = {
      'MunifTanjim/nui.nvim',
      'nvim-telescope/telescope.nvim',
    },
    version = '2.*',
    ft = 'json',
    config = function()
      require('package-info').setup()
    end,
  },
}
