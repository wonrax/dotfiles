-- TODO: There's a bug where after exitting neovim, the tmux-window-name does
-- not work anymore, that is when changing dir the window name is not being
-- updated. Not sure why and what is causing this.

-- Function to check if we're running inside tmux
local function is_in_tmux()
  return vim.env.TMUX ~= nil
end

-- Save the original window name when Neovim starts (if in tmux)
local original_window_name = ''
if is_in_tmux() then
  original_window_name = vim.fn.system('tmux display-message -p "#W"'):gsub('\n', '')
end

-- Function to update tmux window name
local function update_tmux_window_name()
  if not is_in_tmux() then
    return
  end

  local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  local window_name = ''

  window_name = 'code:' .. project_name

  pcall(function()
    vim.fn.system('tmux rename-window "' .. window_name .. '"')
  end)
end

if is_in_tmux() then
  -- Set up autocommands
  local tmux_group = vim.api.nvim_create_augroup('TmuxWindowName', { clear = true })

  vim.api.nvim_create_autocmd({
    'VimEnter',
    'DirChanged',
    'VimResized',
  }, {
    group = tmux_group,
    callback = update_tmux_window_name,
  })

  -- Restore original window name when Neovim exits
  vim.api.nvim_create_autocmd('VimLeave', {
    group = tmux_group,
    callback = function()
      pcall(function()
        vim.fn.system('tmux rename-window "' .. original_window_name .. '"')
      end)
    end,
  })

  update_tmux_window_name()
end

-- Create a command to manually update the window name
vim.api.nvim_create_user_command('TmuxWindowName', function()
  update_tmux_window_name()
end, {})
