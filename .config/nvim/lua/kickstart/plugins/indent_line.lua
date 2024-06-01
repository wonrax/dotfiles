return {
  { -- Add indentation guides even on blank lines
    'lukas-reineke/indent-blankline.nvim',
    version = '3.6.*',
    -- Enable `lukas-reineke/indent-blankline.nvim`
    -- See `:help ibl`
    main = 'ibl',
    config = function()
      require('ibl').setup {
        indent = {
          char = '┊',
        },
        scope = { enabled = true, show_start = false, show_end = false, char = '│' },
      }
    end,
  },
}
