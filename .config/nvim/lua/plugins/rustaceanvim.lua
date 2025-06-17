return {
  {
    -- More advanced LSP support for Rust
    'mrcjkb/rustaceanvim',
    version = '*',
    init = function()
      local defaults = {
        tools = {
          float_win_config = {
            border = 'rounded',
          },
        },
        server = {
          on_attach = function(_, bufnr)
            vim.keymap.set(
              'n',
              'K', -- Override Neovim's built-in hover keymap with rustaceanvim's hover actions
              function()
                vim.cmd.RustLsp { 'hover', 'actions' }
              end,
              { silent = true, buffer = bufnr }
            )
          end,
          default_settings = {
            ['rust-analyzer'] = {
              files = { excludeDirs = { 'node_modules' } },
              check = {
                command = 'clippy',
              },
              inlayHints = {
                implicitDrops = {
                  enable = true,
                },
                -- closingBraceHints = {
                --   enable = false,
                -- },
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
