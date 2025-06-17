return {
  {
    'folke/flash.nvim',
    event = 'VeryLazy',
    opts = {
      search = {
        mode = 'search',
      },
      modes = {
        char = {
          keys = { 'F', 't', 'T', ';', ',' },
        },
      },
      label = {
        -- TODO: experimenting with this, if it does not feel better change it
        -- back to false
        uppercase = false,

        rainbow = {
          enabled = true,
        },
      },
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
}
