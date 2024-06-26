return {
  {
    'rmagatti/auto-session',
    config = function()
      -- Fix a bug where a single buffer out of many buffers is not being
      -- highlighted unless running :e on auto-session restoration
      -- https://stackoverflow.com/a/60875369/11129119
      vim.cmd 'set sessionoptions+=localoptions'

      require('auto-session').setup {
        log_level = vim.log.levels.WARN,
        auto_session_enable_last_session = true,
        auto_session_root_dir = vim.fn.stdpath 'data' .. '/sessions/',
        auto_session_enabled = true,
        auto_save_enabled = true,
        auto_restore_enabled = false,
        auto_session_suppress_dirs = nil,
        auto_session_use_git_branch = nil,
        -- the configs below are lua only
        bypass_session_save_file_types = nil,
        pre_save_cmds = {
          -- 'Neotree close'
          function()
            vim.api.nvim_exec_autocmds('User', {
              -- TODO: move the user events to shared global variables
              pattern = 'AutoSession::PreSessionSave',
            })
          end,
        },
        post_restore_cmds = {
          -- 'Neotree show position=left'
          function()
            vim.api.nvim_exec_autocmds('User', {
              -- TODO: move the user events to shared global variables
              pattern = 'AutoSession::SessionRestored',
            })
          end,
        },
      }

      vim.api.nvim_create_autocmd('VimEnter', {
        callback = function()
          local args = vim.fn.argv()

          -- if there are more than one argument, then we don't want to restore
          -- the session
          if #args > 1 then
            return
          end

          -- show the session picker if no arg is provided
          if #args == 0 then
            require('auto-session.session-lens').search_session()
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
      vim.api.nvim_create_autocmd('VimLeavePre', {
        callback = function()
          require('neo-tree.command').execute { action = 'close' }
          require('auto-session').SaveSession(nil, false)
        end,
      })

      vim.keymap.set('n', '<leader>s', require('auto-session.session-lens').search_session, {
        noremap = true,
        desc = 'Search sessions',
      })
    end,
    lazy = false,
  },
}
