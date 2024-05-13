return {
  {
    -- More advanced LSP support for Rust
    'mrcjkb/rustaceanvim',
    config = function()
      vim.g.rustaceanvim = {
        tools = {
          float_win_config = {
            border = 'rounded',
          },
        },
      }
    end,
  },
}
