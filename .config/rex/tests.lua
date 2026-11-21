-- Run from the repository root: nix develop -c nvim --headless -u NONE -l .config/rex/tests.lua
local bindings, actions, modes, queued = {}, {}, {}, {}
local view
local resized
local definitions = {}
local foreground = "zsh"
local focused_dir
local current_ctx
rex = {
  bind = function(key, name, args) bindings[key] = { name = name, args = args } end,
  unbind = function(key) bindings[key] = nil end,
  bindings = function()
    local result = {}
    for key in pairs(bindings) do
      if not key:find("/") then table.insert(result, { key = key }) end
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
  end,
  action = function(a)
    assert(not actions[a.name], a.name)
    actions[a.name] = a.run
    definitions[a.name] = a
  end,
  mode = function(name, options) modes[name] = options or {} end,
  client = { queue = function(name, args) table.insert(queued, { name = name, args = args }) end },
  invoke = function(name, args) return actions[name](current_ctx, args or {}) end,
  block = { call = function(_, method)
    if method == "process" then return { foreground = { name = foreground } } end
  end },
  session = {
    view = function() return view end,
    resize_pane = function(args) resized = args; return {} end,
    focus_direction = function(args) focused_dir = args.direction; return {} end,
  },
}
dofile(".config/rex/init.lua")
for key, binding in pairs(bindings) do
  if type(binding.name) == "function" then
    assert(not key:find("/"), key .. ": function bindings can't live in a mode")
  else
    assert(binding.name:find("%.") or actions[binding.name], key .. ": " .. binding.name)
  end
end
for _, key in ipairs({ "alt+=", "alt+-", "pane/ctrl+alt+h", "pane/ctrl+alt+l", "resize/h", "resize/shift+h", "alt+left", "move/n" }) do
  assert(definitions[bindings[key].name].repeats, key .. " must support held-key repeat")
end
assert(not definitions[bindings["ctrl+q"].name].repeats)
local function press(key, block_id)
  queued = {}
  local b = assert(bindings[key], key)
  local ctx = { block_id = block_id or "b", session_id = "s" }
  current_ctx = ctx
  if type(b.name) == "function" then
    if not b.name(ctx, { keybinding = key }) then table.insert(queued, { name = "<terminal>" }) end
  elseif actions[b.name] then actions[b.name](ctx, b.args or {})
  else rex.client.queue(b.name, b.args) end
  return queued
end

local q = press("tmux/v")
assert(q[1].name == "client.mode.exit_all")
assert(q[2].name == "pane.split" and q[2].args.direction == "right")
q = press("ctrl+t")
assert(q[1].name == "client.mode.exit_all" and q[2].args.name == "tab")
assert(press("pane/h")[1].name == "pane.focus")
assert(press("tmux/o")[1].name == "pane.focus_next")
assert(press("locked/alt+h")[1].args.key == "alt+h")
assert(press("locked/ctrl+q")[1].args.key == "ctrl+q")
assert(press("locked/alt+f")[1].args.key == "alt+f")
assert(press("tmux/ctrl+;")[2].args.key == "ctrl+b")
for key in pairs(bindings) do assert(not key:find("cmd+", 1, true), key) end
for _, name in ipairs({ "tmux", "pane", "tab", "resize", "move", "scroll", "session" }) do
  assert(modes[name].exclusive == (name ~= "scroll"), name)
  assert(bindings[name .. "/escape"] and bindings[name .. "/enter"])
end

-- scroll mode is copy mode underneath; anything leaving it must drop copy mode last
q = press("ctrl+enter")
assert(q[2].args.name == "scroll" and q[3].name == "pane.copy_mode.enter")
for _, key in ipairs({ "scroll/escape", "scroll/ctrl+c", "scroll/ctrl+p", "scroll/ctrl+g" }) do
  q = press(key)
  assert(q[1].name == "client.mode.exit_all" and q[#q].name == "pane.copy_mode.exit", key)
end
assert(press("scroll/j")[1].args.to == "down")
assert(press("scroll/h")[1].args.to == "page_up")
assert(press("scroll/n")[1].name == "pane.copy_mode.search_again")
q = press("scroll/ctrl+enter")
assert(q[#q].args.key == "ctrl+b")

assert(press("tab/tab")[1].name == "client.tab.recent.in_session")
assert(press("tmux/tab")[2].name == "client.tab.recent.in_session")
assert(press("pane/c")[2].name == "pane.rename")
assert(press("pane/z")[2].name == "client.setting.interface.panes.headers")

local function layout(focused)
  view = { active_window_id = "w", windows = {
    { window_id = "w", focused_block_id = focused, layers = {
      { kind = "tiled", layout = { split = { direction = "horizontal", ratio = 0.5,
        before = { block_id = "a" }, after = { block_id = "b" } } } },
    } },
  } }
end
-- ToggleFloatingPanes / TogglePaneEmbedOrFloating
layout("b")
assert(press("alt+f")[1].name == "pane.new_floating")
assert(press("pane/w")[2].name == "pane.new_floating")
assert(press("pane/e")[2].name == "pane.float")
table.insert(view.windows[1].layers, { kind = "floating", blocks = { { block_id = "f" } } })
assert(press("alt+f")[1].name == "pane.minimize_all_floating")
local moved
rex.session.move_block = function(args) moved = args; return {} end
rex.session.focus_block = function() return {} end
press("pane/e", "f")
assert(moved.block_id == "f" and moved.anchor_block_id == "a")

-- vim-zellij-navigator: alt+hjkl falls through to (n)vim, otherwise focuses
layout("b")
focused_dir = nil
assert(#press("alt+h") == 0 and focused_dir == "left")
foreground = "nvim"
assert(press("alt+h")[1].name == "<terminal>")
resized = nil
assert(press("ctrl+alt+h")[1].name == "<terminal>" and not resized)
foreground = "zsh"
press("ctrl+alt+h")
assert(resized.ratio == 0.45)

layout("b")
press("resize/h")
assert(resized.ratio == 0.45 and resized.before_block_id == "a" and resized.after_block_id == "b")
press("resize/shift+h")
assert(resized.ratio == 0.55)
press("alt+=")
assert(resized.ratio == 0.45)
for _, block_id in ipairs({ "a", "b" }) do
  layout(block_id)
  press("ctrl+alt+h", block_id)
  assert(resized.ratio == 0.45, "h must move the divider left from either pane")
  press("ctrl+alt+l", block_id)
  assert(resized.ratio == 0.55, "l must move the divider right from either pane")
  view.windows[1].layers[1].layout.split.direction = "vertical"
  press("ctrl+alt+k", block_id)
  assert(resized.ratio == 0.45)
  press("ctrl+alt+j", block_id)
  assert(resized.ratio == 0.55)
end

print("Rex bindings: modes, scroll/copy mode, floating toggles, vim navigator, and resize checks passed")
