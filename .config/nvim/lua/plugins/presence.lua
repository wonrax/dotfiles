return {
  {
    'andweeb/presence.nvim',
    lazy = false,
    opts = {
      buttons = false,
    },
    config = function(opts)
      local io = require 'io'

      -- Open the file
      local file = io.open(os.getenv 'HOME' .. '/.discord-presence', 'r')

      -- Initialize an empty table for the blacklist
      local blacklist = {}

      if file ~= nil then
        -- Iterate over each line in the file
        for line in file:lines() do
          line = line:gsub('\n', '')
          -- must check for empty string otherwise it will match everything
          if line ~= '' then
            table.insert(blacklist, line)
          end
        end

        -- Close the file
        file:close()
      end

      require('presence').setup(vim.tbl_extend('force', opts, {
        blacklist = blacklist,
      }))
    end,
  },
}
