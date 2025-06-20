return {
  { -- Autoformat
    'stevearc/conform.nvim',
    version = '*',
    lazy = false,
    keys = {
      {
        '<leader>lf',
        function()
          require('conform').format { async = true, lsp_fallback = true }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = true,
      format_on_save = function(bufnr)
        return {
          timeout_ms = 5000,
          lsp_format = 'fallback',
        }
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        astro = { 'prettier' },
        javascript = { 'prettier' },
        typescript = { 'prettier' },
        typescriptreact = { 'prettier' },
        json = { 'prettier' },
        jsonc = { 'prettier' },
        graphql = { 'prettier' },
        scss = { 'prettier' },
        css = { 'prettier' },
        nix = { 'nixfmt' },
        sql = { 'sleek' },
        rust = { 'rustfmt' },
        kdl = { 'kdlfmt' },
        -- ['*'] = { 'injected' }, -- enables injected-lang formatting for all filetypes
      },
    },
  },
}
