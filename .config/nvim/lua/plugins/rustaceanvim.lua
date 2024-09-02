return {
  {
    -- More advanced LSP support for Rust
    'mrcjkb/rustaceanvim',
    init = function()
      vim.g.rustaceanvim = {
        tools = {
          float_win_config = {
            border = 'rounded',
          },
        },
        server = {
          default_settings = {
            ['rust-analyzer'] = {
              files = { excludeDirs = { 'node_modules' } },
            },
          },
        },
      }
    end,
  },
}
