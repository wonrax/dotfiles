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

      local events = require('events').auto_session

      require('auto-session').setup {
        enabled = true, -- Enables/disables auto creating, saving and restoring
        root_dir = vim.fn.stdpath 'data' .. '/sessions/', -- Root dir where sessions will be stored
        auto_save = true, -- Enables/disables auto saving session on exit
        auto_restore = true, -- Enables/disables auto restoring session on start
        auto_create = true, -- Enables/disables auto creating new session files. Can take a function that should return true/false if a new session file should be created or not
        suppressed_dirs = nil, -- Suppress session restore/create in certain directories
        allowed_dirs = nil, -- Allow session restore/create in certain directories
        auto_restore_last_session = true, -- On startup, loads the last saved session if session for cwd does not exist
        use_git_branch = false, -- Include git branch name in session name
        lazy_support = true, -- Automatically detect if Lazy.nvim is being used and wait until Lazy is done to make sure session is restored correctly. Does nothing if Lazy isn't being used. Can be disabled if a problem is suspected or for debugging
        bypass_save_filetypes = nil, -- List of file types to bypass auto save when the only buffer open is one of the file types listed, useful to ignore dashboards
        close_unsupported_windows = true, -- Close windows that aren't backed by normal file before autosaving a session
        args_allow_single_directory = true, -- Follow normal sesion save/load logic if launched with a single directory as the only argument
        args_allow_files_auto_save = false, -- Allow saving a session even when launched with a file argument (or multiple files/dirs). It does not load any existing session first. While you can just set this to true, you probably want to set it to a function that decides when to save a session when launched with file args. See documentation for more detail
        continue_restore_on_error = true, -- Keep loading the session even if there's an error
        cwd_change_handling = true, -- Follow cwd changes, saving a session before change and restoring after
        log_level = vim.log.levels.ERROR, -- Sets the log level of the plugin (debug, info, warn, error).

        pre_save_cmds = {
          -- 'Neotree close'
          function()
            vim.api.nvim_exec_autocmds('User', {
              pattern = events.pre_session_save,
            })
          end,
        },
        post_restore_cmds = {
          -- 'Neotree show position=left'
          function()
            vim.api.nvim_exec_autocmds('User', {
              pattern = events.session_restored,
            })
          end,
        },
        no_restore_cmds = {
          function()
            vim.api.nvim_exec_autocmds('User', {
              pattern = events.no_session_restored,
            })
          end,
        },
      }

      vim.keymap.set('n', '<leader>s', require('auto-session.session-lens').search_session, {
        noremap = true,
        desc = 'Search sessions',
      })

      -- https://vi.stackexchange.com/a/44625/51174
      vim.api.nvim_create_autocmd('User', {
        pattern = events.session_restored,
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
