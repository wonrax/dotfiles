return {
  {
    -- More advanced LSP support for Rust
    'mrcjkb/rustaceanvim',
    init = function()
      local defaults = {
        tools = {
          float_win_config = {
            border = 'rounded',
          },
        },
        server = {
          default_settings = {
            ['rust-analyzer'] = {
              files = { excludeDirs = { 'node_modules' } },
              check = {
                command = 'clippy',
              },
            },
          },
        },
      }

      -- merge with existing vim.g.rustaceanvim
      vim.g.rustaceanvim = vim.tbl_deep_extend('force', defaults, vim.g.rustaceanvim or {})
    end,
  },
}
