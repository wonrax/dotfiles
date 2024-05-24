return {
  {
    'akinsho/bufferline.nvim',
    dependencies = 'nvim-tree/nvim-web-devicons',
    -- config = function()
    --   require('bufferline').setup {}
    -- end,
    opts = {
      options = {
        offsets = {
          {
            filetype = 'neo-tree',
            text = 'NeoTree',
            text_align = 'left',
            separator = false,
          },
        },
        indicator = {
          icon = ' ▶️ ',
          style = 'icon',
        },
      },
    },
    lazy = false,
  },
}
