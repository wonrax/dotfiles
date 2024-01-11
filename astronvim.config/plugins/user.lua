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
    'github/copilot.vim',
    lazy = false
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
  {
    "f-person/auto-dark-mode.nvim",
    config = function()
        require("auto-dark-mode").setup({
          update_interval = 1000,
          set_dark_mode = function()
            vim.cmd("colorscheme github_dark")
          end,
          set_light_mode = function()
            vim.cmd("colorscheme github_light")
          end,
      })
    end,
    lazy = false
  },
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    ---@type Flash.Config
    opts = {
      search = {
        mode = "search",
      },
      modes = {
        char = {
          keys = { "F", "t", "T", ";", "," },
        }
      }
    },
    -- stylua: ignore
    keys = {
      { "f", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash" },
      { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
      { "r", mode = "o", function() require("flash").remote() end, desc = "Remote Flash" },
      { "R", mode = { "o", "x" }, function() require("flash").treesitter_search() end, desc = "Treesitter Search" },
      { "<c-s>", mode = { "c" }, function() require("flash").toggle() end, desc = "Toggle Flash Search" },
    },
  },
  {
    "tpope/vim-surround",
    lazy = false
  },
}
