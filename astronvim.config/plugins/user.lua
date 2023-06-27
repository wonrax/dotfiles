return {
  -- You can also add new plugins here as well:
  -- Add plugins, the lazy syntax
  -- "andweeb/presence.nvim",
  -- {
  --   "ray-x/lsp_signature.nvim",
  --   event = "BufRead",
  --   config = function()
  --     require("lsp_signature").setup()
  --   end,
  -- },
  {
    'projekt0n/github-nvim-theme', tag = 'v1.0.0',
    config = function()
      require('github-theme').setup({
        options = {
          transparent = true,
          styles = {                 -- Style to be applied to different syntax groups
            comments = 'italic',     -- Value is any valid attr-list value `:help attr-list`
            functions = 'NONE',
            keywords = 'NONE',
            variables = 'NONE',
            conditionals = 'NONE',
            constants = 'NONE',
            numbers = 'NONE',
            operators = 'NONE',
            strings = 'NONE',
            types = 'NONE',
          },
        },
      })
    end,
  },
  {
    "ggandor/leap.nvim",
    config = function()
      require("leap").setup {
        -- max_phase_one_targets = nil,
        -- highlight_unlabeled_phase_one_targets = false,
        -- max_highlighted_traversal_targets = 10,
        -- case_sensitive = false,
        -- equivalence_classes = { ' \t\r\n', },
        -- substitute_chars = {},
        -- safe_labels = { 's', 'f', 'n', 'u', 't' },
        -- labels = { 's', 'f', 'n', 'j', 'k' },
        -- special_keys = {
        --   repeat_search = '<enter>',
        --   next_phase_one_target = '<enter>',
        --   next_target = { '<enter>', ';' },
        --   prev_target = { '<tab>', ',' },
        --   next_group = '<space>',
        --   prev_group = '<tab>',
        --   multi_accept = '<enter>',
        --   multi_revert = '<backspace>',
        -- }
      }
    end,
    init = function()
      require('leap').add_default_mappings()
      require('leap').init_highlight(true)
    end,
  },
  {
    'rcarriga/nvim-notify',
    config = function(plugin, opts)
      require("notify").setup({
        background_colour = "#000000"
      })
      require("plugins.configs.notify")(plugin, opts)
    end,
  },
  {
    'fatih/vim-go'
  },
}
