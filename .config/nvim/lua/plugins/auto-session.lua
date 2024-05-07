return {
  {
    'rmagatti/auto-session',
    config = function()
      require('auto-session').setup {
        log_level = 'info',
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
          local current_dir = vim.fn.getcwd()
          require('auto-session').RestoreSessionFromFile(current_dir)
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
