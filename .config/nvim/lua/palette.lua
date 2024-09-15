local M = {}

---@return Palette
function M.load_current_theme_palette()
  local palette = require('nightfox.palette').load(vim.g.colors_name or 'dayfox')
  if type(palette) == 'table' then
    return palette
  end

  error('Theme not loaded properly', 2)
end

return M
