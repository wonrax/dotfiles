return {
  { -- LSP Configuration & Plugins
    'neovim/nvim-lspconfig',
    dependencies = {
      -- Automatically install LSPs and related tools to stdpath for Neovim
      {
        'williamboman/mason.nvim', -- NOTE: Must be loaded before dependants
        opts = {
          ui = {
            border = 'rounded',
          },
        },
      },
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- NOTE: currently disabled to use noice.nvim because it looks better
      -- Useful status updates for LSP.
      -- NOTE: `opts = {}` is the same as calling `require('fidget').setup({})`
      -- { 'j-hui/fidget.nvim', opts = {
      --   notification = {
      --     window = {
      --       winblend = 0,
      --     },
      --   },
      -- } },

      {
        'folke/lazydev.nvim',
        ft = 'lua',
        opts = {
          library = {
            -- See the configuration section for more details
            -- Load luvit types when the `vim.uv` word is found
            { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
          },
        },
      },
    },
    config = function()
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = require('blink.cmp').get_lsp_capabilities(capabilities)

      local servers = {
        lua_ls = {
          settings = {
            Lua = {
              runtime = {
                version = 'LuaJIT',
              },
              completion = {
                callSnippet = 'Replace',
              },
              -- You can toggle below to ignore Lua_LS's noisy `missing-fields` warnings
              -- diagnostics = { disable = { 'missing-fields' } },
              workspace = {
                checkThirdParty = true,
                library = {
                  vim.env.VIMRUNTIME,
                  '${3rd}/luv/library',
                },
              },
            },
          },
        },
      }

      -- nvim-java needs to be setup before lspconfig
      -- uncomment this if you are using java 🤮 otherwise keep it commented so
      -- that it doesn't bloat my setup
      -- require('java').setup()

      require('mason').setup()

      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua', -- Used to format Lua code
      })

      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      require('mason-lspconfig').setup {
        ensure_installed = {},
        automatic_installation = true,
        handlers = {
          function(server_name)
            local server = servers[server_name] or {}
            -- This handles overriding only values explicitly passed
            -- by the server configuration above. Useful when disabling
            -- certain features of an LSP (for example, turning off formatting for tsserver)
            server.capabilities = capabilities
            require('lspconfig')[server_name].setup(server)
          end,
        },
      }

      -- NOTE: disabled to use haskell-tools.nvim
      -- NOTE: won't use mason here because it uses ghcup to install hls and
      -- ghcup is not well supported on nix.
      -- NOTE: that on first install and first invocation (e.g. hls --version),
      -- hls might take a comically long time to run for some reason thus it
      -- might seem like the language server in neovim don't work. Just run
      -- some hls command, wait for it to complete and then open the haskell
      -- project again
      -- require('lspconfig')['hls'].setup {
      --   capabilities = capabilities,
      --   filetypes = { 'haskell', 'lhaskell', 'cabal' },
      -- }
    end,
  },
}
