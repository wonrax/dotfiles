-- Function to check if we're running inside zellij
local function is_in_zellij()
  return vim.env.ZELLIJ ~= nil
end

-- Function to update zellij window name
local function update_zellij_tab_name()
  if not is_in_zellij() then
    return
  end

  local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  local window_name = ''

  window_name = 'code:' .. project_name

  pcall(function()
    vim.fn.system('zellij action rename-tab "' .. window_name .. '"')
  end)
end

if is_in_zellij() then
  -- Set up autocommands
  local zellij_group = vim.api.nvim_create_augroup('ZellijTabName', { clear = true })

  vim.api.nvim_create_autocmd({
    'VimEnter',
    'DirChanged',
    'FocusGained',
  }, {
    group = zellij_group,
    callback = update_zellij_tab_name,
  })

  -- Restore original window name when Neovim exits
  vim.api.nvim_create_autocmd('VimLeave', {
    group = zellij_group,
    callback = function()
      pcall(function()
        vim.fn.system 'zellij action undo-rename-tab'
      end)
    end,
  })

  update_zellij_tab_name()
end

-- Create a command to manually update the window name
vim.api.nvim_create_user_command('ZellijTabName', function()
  update_zellij_tab_name()
end, {})
