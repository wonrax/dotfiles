local vscode = require('vscode-neovim')

vim.keymap.set("v", "<C-c>", [["+y]], { noremap = true, silent = true })
vim.keymap.set("n", "j", "gj", { remap = true })
vim.keymap.set("n", "k", "gk", { remap = true })
vim.keymap.set("n", "gH", function()
    vscode.call("editor.action.goToImplementation")
  end, { noremap = true })

vim.opt.ignorecase = true
vim.opt.smartcase = true

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
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
  },
})

