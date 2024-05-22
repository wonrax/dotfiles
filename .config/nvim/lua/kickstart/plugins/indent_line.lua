return {
  { -- Add indentation guides even on blank lines
    'lukas-reineke/indent-blankline.nvim',
    version = '3.6.*',
    -- Enable `lukas-reineke/indent-blankline.nvim`
    -- See `:help ibl`
    main = 'ibl',
    opts = {
      indent = {
        -- char = '│',
        char = '',
        highlight = 'Conceal',
      },
      scope = { enabled = true, show_start = false, show_end = false, highlight = 'Special' },
    },
  },
}
