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
for _, key in ipairs({ "alt+=", "alt+-", "pane/ctrl+alt+h", "pane/ctrl+alt+l", "pane/alt+h", "pane/h", "resize/h", "resize/shift+h", "alt+left", "move/n" }) do
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
assert(bindings["pane/h"].name == "zellij_focus_left")
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
      { kind = "tiled", blocks = { { block_id = "a" }, { block_id = "b" } }, layout = { split = { direction = "horizontal", ratio = 0.5,
        before = { block_id = "a", rect = { 0, 0, 0.5, 1 } }, after = { block_id = "b", rect = { 0.5, 0, 0.5, 1 } } } } },
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
assert(press("alt+n", "b")[1].name == "pane.split")
assert(press("alt+n", "f")[1].name == "pane.new_floating")
q = press("pane/n", "f")
assert(q[1].name == "client.mode.exit_all" and q[2].name == "pane.new_floating")
assert(press("locked/alt+n")[1].args.key == "alt+n")
local moved
rex.session.move_block = function(args) moved = args; return {} end
rex.session.focus_block = function() return {} end
press("pane/e", "f")
assert(moved.block_id == "f" and moved.anchor_block_id == "a")

-- CloseFocus escalates to the tab, then the session
local closed_window, destroyed
rex.session.close_window = function(args) closed_window = args.window_id; return {} end
rex.call = function(method, args) if method == "session.destroy" then destroyed = args.session_id end return {} end
layout("b")
q = press("tmux/x")
assert(q[1].name == "client.mode.exit_all" and q[2].name == "pane.close")
view.windows[1].layers = { { kind = "tiled", blocks = { { block_id = "b" } }, layout = { block_id = "b" } } }
q = press("pane/x")
assert(#q == 1 and destroyed == "s" and not closed_window)
destroyed = nil
table.insert(view.windows, { window_id = "w2", layers = {} })
press("tmux/x")
assert(closed_window == "w" and not destroyed)

-- MoveFocus stays within its plane: tiled panes or visible floating panes
local focused_block
rex.session.focus_block = function(args) focused_block = args.block_id; return {} end
view = { active_window_id = "w", windows = { { window_id = "w", layers = {
  { kind = "tiled", blocks = { { block_id = "a" }, { block_id = "b" } }, layout = { rect = { 0, 0, 1, 1 }, split = {
    direction = "horizontal", ratio = 0.5,
    before = { block_id = "a", rect = { 0, 0, 0.5, 1 } }, after = { block_id = "b", rect = { 0.5, 0, 0.5, 1 } } } } },
  { kind = "floating", blocks = { { block_id = "f1" } }, layout = { block_id = "f1", rect = { 0.05, 0.1, 0.3, 0.3 } } },
  { kind = "floating", blocks = { { block_id = "f2" } }, layout = { block_id = "f2", rect = { 0.6, 0.1, 0.3, 0.3 } } },
} } } }
local function focus_from(key, from)
  focused_block = nil
  view.windows[1].focused_block_id = from
  return press(key, from), focused_block
end
local _, to = focus_from("pane/l", "f1"); assert(to == "f2", tostring(to))
_, to = focus_from("pane/h", "f2"); assert(to == "f1")
_, to = focus_from("pane/h", "f1"); assert(to == nil, "no float left of f1, and tiled a must not be picked")
_, to = focus_from("pane/h", "b"); assert(to == "a", "tiled focus must skip floats")
_, to = focus_from("pane/l", "a"); assert(to == "b")
view.windows[1].layers[3].state = "minimized"
_, to = focus_from("pane/l", "f1"); assert(to == nil, "minimized floats are out of reach")
q, to = focus_from("alt+right", "b"); assert(to == nil and q[1].name == "client.tab.next")
_, to = focus_from("alt+left", "b"); assert(to == "a")

-- vim-zellij-navigator: alt+hjkl falls through to (n)vim, otherwise focuses
layout("b")
focused_dir = nil
focused_block = nil
assert(#press("alt+h") == 0 and focused_block == "a")
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
