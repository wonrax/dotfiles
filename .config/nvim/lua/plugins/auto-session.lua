return {
  {
    'rmagatti/auto-session',
    config = function()
      require('auto-session').setup {
        log_level = vim.log.levels.WARN,
        auto_session_enable_last_session = true,
        auto_session_root_dir = vim.fn.stdpath 'data' .. '/sessions/',
        auto_session_enabled = true,
        auto_save_enabled = true,
        auto_restore_enabled = true,
        auto_session_suppress_dirs = nil,
        auto_session_use_git_branch = nil,
        -- the configs below are lua only
        bypass_session_save_file_types = nil,
        pre_save_cmds = { 'Neotree close' },
        -- post_restore_cmds = { 'Neotree filesystem show' },
      }

      vim.api.nvim_create_autocmd('VimEnter', {
        callback = function()
          local args = vim.fn.argv()

          -- don't do anything if either argc > 1 or argc == 0 because
          -- auto-session will restore the last session by default
          if #args > 1 or #args == 0 then
            return
          end

          local arg = args[1]

          -- check if the arg is file or directory
          local stat = vim.loop.fs_stat(arg)

          if stat then
            if stat.type == 'directory' then
              -- expand to absolute path
              arg = vim.fn.expand(vim.fn.fnamemodify(arg, ':p'))

              -- Remove trailing slash if it exists
              if arg:sub(-1) == '/' then
                arg = arg:sub(1, -2)
              end

              require('auto-session').RestoreSessionFromFile(arg)
            end
          end
        end,
      })

      -- currently auto save doesn't work so we need to save the session manually
      vim.api.nvim_create_autocmd('ExitPre', {
        callback = function()
          require('auto-session').SaveSession(nil, false)
        end,
      })

      vim.keymap.set('n', '<leader>s', require('auto-session.session-lens').search_session, {
        noremap = true,
      })
    end,
    lazy = false,
  },
}
