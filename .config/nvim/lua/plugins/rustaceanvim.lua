return {
  {
    -- More advanced LSP support for Rust
    'mrcjkb/rustaceanvim',
    tag = 'v8.0.5', -- v4 requires neovim 0.12

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
              procMacro = {
                ignored = {
                  ['napi-derive'] = { 'napi' },
                },
              },
              diagnostics = { disabled = { 'proc-macro-disabled' } },
            },
          },
        },
      }

      -- merge with existing vim.g.rustaceanvim
      vim.g.rustaceanvim = vim.tbl_deep_extend('force', defaults, vim.g.rustaceanvim or {})
    end,
  },
}
