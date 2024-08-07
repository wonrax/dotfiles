return {
  {
    'rmagatti/auto-session',
    dependencies = {
      -- so that autocmd are registered before the auto-session events are
      -- fired
      'nvim-neo-tree/neo-tree.nvim',
    },
    config = function()
      -- Fix a bug where a single buffer out of many buffers is not being
      -- highlighted unless running :e on auto-session restoration
      -- https://stackoverflow.com/a/60875369/11129119
      vim.cmd 'set sessionoptions+=localoptions'

      require('auto-session').setup {
        log_level = vim.log.levels.WARN,
        auto_session_enable_last_session = false,
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
          local current_file = vim.fn.expand '%'

          -- if there are more than one argument, then we don't want to restore
          -- the session
          if #args > 1 then
            return
          end

          -- If there's a file specified (either existing or new), don't restore the session
          if current_file ~= '' then
            print('Current file is ' .. current_file)
            return
          end

          if #args == 0 then
            local latest_session = require('auto-session.lib').get_latest_session(require('auto-session').get_root_dir())
            if latest_session then
              require('auto-session').RestoreSession(latest_session)
            else
              vim.api.nvim_exec_autocmds('User', {
                -- TODO: move the user events to shared global variables
                pattern = 'AutoSession::NoSessionRestored',
              })
            end
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

              vim.api.nvim_set_current_dir(arg)
              if require('auto-session').session_exists_for_cwd() then
                require('auto-session').RestoreSession(arg)
                return
              end
            end
          end

          vim.api.nvim_exec_autocmds('User', {
            -- TODO: move the user events to shared global variables
            pattern = 'AutoSession::NoSessionRestored',
          })
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

      -- https://vi.stackexchange.com/a/44625/51174
      vim.api.nvim_create_autocmd('User', {
        pattern = 'AutoSession::SessionRestored',
        desc = 'Close empty buffers',
        callback = function()
          -- Get a list of all buffers
          local buffers = vim.api.nvim_list_bufs()

          -- Iterate over each buffer
          for _, bufnr in ipairs(buffers) do
            -- Check if the buffer is empty and doesn't have a name
            if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == '' and vim.api.nvim_buf_get_option(bufnr, 'buftype') == '' then
              -- Get all lines in the buffer
              local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

              -- Initialize a variable to store the total number of characters
              local total_characters = 0

              -- Iterate over each line and calculate the number of characters
              for _, line in ipairs(lines) do
                total_characters = total_characters + #line
              end

              -- Close the buffer if it's empty:
              if total_characters == 0 then
                vim.api.nvim_buf_delete(bufnr, {
                  force = true,
                })
              end
            end
          end
        end,
      })
    end,
    lazy = false,
  },
}
