-- Run from the repository root: nix develop -c nvim --headless -u NONE -l .config/rex/tests.lua
local bindings, actions, modes, queued = {}, {}, {}, {}
local view
local resized
local definitions = {}
rex = {
  bind = function(key, name, args) bindings[key] = { name = name, args = args } end,
  unbind = function(key) bindings[key] = nil end,
  bindings = function()
    local result = {}
    for key in pairs(bindings) do
      if not key:find("/") then table.insert(result, { key = key }) end
    end
    return result
  end,
  action = function(a)
    assert(not actions[a.name], a.name)
    actions[a.name] = a.run
    definitions[a.name] = a
  end,
  mode = function(name, options) modes[name] = options or {} end,
  client = { queue = function(name, args) table.insert(queued, { name = name, args = args }) end },
  session = {
    view = function() return view end,
    resize_pane = function(args) resized = args; return {} end,
  },
}
dofile(".config/rex/init.lua")
for key, binding in pairs(bindings) do
  assert(binding.name:find("%.") or actions[binding.name], key .. ": " .. binding.name)
end
for _, key in ipairs({ "alt+=", "alt+-", "ctrl+alt+h", "ctrl+alt+l", "resize/h", "resize/shift+h", "alt+left", "move/n" }) do
  assert(definitions[bindings[key].name].repeats, key .. " must support held-key repeat")
end
assert(not definitions[bindings["ctrl+q"].name].repeats)
local function press(key, block_id)
  queued = {}
  local b = assert(bindings[key], key)
  if actions[b.name] then actions[b.name]({ block_id = block_id or "b", session_id = "s" }, b.args or {})
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
assert(press("alt+f")[1].name == "pane.float")
assert(press("pane/e")[2].name == "pane.float")
assert(press("locked/alt+f")[1].args.key == "alt+f")
assert(not bindings["tmux/ctrl+;"])
for key in pairs(bindings) do assert(not key:find("cmd+", 1, true), key) end
for _, name in ipairs({ "tmux", "pane", "tab", "resize", "move", "scroll", "session" }) do
  assert(modes[name].exclusive)
  assert(bindings[name .. "/escape"] and bindings[name .. "/enter"])
end

local function layout(focused)
  view = { active_window_id = "w", windows = {
    { window_id = "w", focused_block_id = focused, layers = {
      { layout = { split = { direction = "horizontal", ratio = 0.5,
        before = { block_id = "a" }, after = { block_id = "b" } } } },
    } },
  } }
end
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

assert(not bindings["tmux/tab"] and not bindings["tab/tab"])
print("Rex bindings: modes, floating aliases, and directional resize checks passed")
