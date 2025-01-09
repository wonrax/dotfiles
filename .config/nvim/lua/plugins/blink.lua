return {
  {
    'saghen/blink.cmp',
    lazy = false, -- lazy loading handled internally
    -- optional: provides snippets for the snippet source
    dependencies = {
      'rafamadriz/friendly-snippets',
      'xzbdmw/colorful-menu.nvim',
    },
    -- OR build from source, requires nightly: https://rust-lang.github.io/rustup/concepts/channels.html#working-with-nightly-rust
    -- build = 'cargo build --release',
    -- If you use nix, you can build from source using latest nightly rust with:
    -- build = 'nix run .#build-plugin',
    version = '*',

    -- allows extending the providers array elsewhere in your config
    -- without having to redefine it
    opts_extend = { 'sources.default' },
    config = function()
      ---@module 'blink.cmp'
      ---@type blink.cmp.Config
      local config = {
        -- Disable for some filetypes
        enabled = function()
          -- Ignore copilot chat buffers because they use neovim default
          -- completion engine, begins with copilot-*
          local buffer_name = vim.fn.expand '%:t'
          return not string.match(buffer_name, '^copilot-') and vim.bo.buftype ~= 'prompt' and vim.b.completion ~= false
        end,
        -- 'default' for mappings similar to built-in completion
        -- 'super-tab' for mappings similar to vscode (tab to accept, arrow keys to navigate)
        -- 'enter' for mappings similar to 'super-tab' but with 'enter' to accept
        -- see the "default configuration" section below for full documentation on how to define
        -- your own keymap.
        keymap = {
          preset = 'default',
          ['<C-j>'] = { 'select_next' },
          ['<C-k>'] = { 'select_prev' },
          ['<C-n>'] = { 'snippet_forward' },
          ['<C-p>'] = { 'snippet_backward' },
        },

        completion = {
          menu = {
            border = 'rounded',
            winhighlight = 'None:BlinkCmpMenu,LspFloatWinBorder:BlinkCmpMenuBorder,CursorLine:BlinkCmpMenuSelection,Search:None',
            draw = {
              -- We don't need label_description now because label and label_description are already
              -- conbined together in label by colorful-menu.nvim.
              columns = { { 'kind_icon' }, { 'label', gap = 1 } },
              components = {
                label = {
                  text = require('colorful-menu').blink_components_text,
                  highlight = require('colorful-menu').blink_components_highlight,
                },
              },
            },
          },
          documentation = {
            auto_show = true,
            window = {
              border = 'rounded',
              winhighlight = 'None:BlinkCmpMenu,LspFloatWinBorder:BlinkCmpMenuBorder,CursorLine:BlinkCmpMenuSelection,Search:None',
            },
          },
        },

        appearance = {
          -- Sets the fallback highlight groups to nvim-cmp's highlight groups
          -- Useful for when your theme doesn't support blink.cmp
          -- will be removed in a future release
          use_nvim_cmp_as_default = true,
          -- Set to 'mono' for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
          -- Adjusts spacing to ensure icons are aligned
          nerd_font_variant = 'mono',
        },

        -- experimental signature help support
        -- signature = { enabled = true }
      }

      require('blink.cmp').setup(config)
    end,
  },
}
