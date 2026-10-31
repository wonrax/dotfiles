local modes = { "tmux", "pane", "tab", "resize", "move", "scroll", "session" }

local function check(value, err)
  if err then error(err, 0) end
  return value
end

local function active_window(view)
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then return window end
  end
end

local actions = {}
local function action(name, title, run, repeats)
  name = name:gsub("[^a-z0-9_]", "_")
  if actions[name] then return name end
  actions[name] = true
  rex.action { name = name, title = title, run = run, repeats = repeats, category = "Zellij bindings" }
  return name
end

local function bind(keys, name, args)
  if type(keys) == "string" then keys = { keys } end
  for _, key in ipairs(keys) do rex.bind(key, name, args) end
end

local function finish(name, args)
  local id = "zellij_finish_" .. name:gsub("%.", "_")
  if args then
    for key, value in pairs(args) do id = id .. "_" .. key .. "_" .. tostring(value) end
  end
  return action(id, "Run " .. name .. " and leave mode", function()
    rex.client.queue("client.mode.exit_all")
    rex.client.queue(name, args)
  end)
end

local function enter(name)
  return action("zellij_enter_" .. name, "Enter " .. name .. " mode", function()
    rex.client.queue("client.mode.exit_all")
    rex.client.queue("client.mode.enter", { name = name })
  end)
end

local enter_mode = {}
for _, mode in ipairs(modes) do
  rex.mode(mode, { exclusive = true })
  enter_mode[mode] = enter(mode)
  bind({ mode .. "/escape", mode .. "/enter" }, "client.mode.exit_all")
end

local function everywhere(key, name, args)
  bind(key, name, args)
  for _, mode in ipairs(modes) do bind(mode .. "/" .. key, name, args) end
end

local function leaf(node)
  if node.block_id then return node.block_id end
  if node.split then return leaf(node.split.before) or leaf(node.split.after) end
end

local function contains(node, block_id)
  if node.block_id == block_id then return true end
  return node.split and (contains(node.split.before, block_id) or contains(node.split.after, block_id))
end

local function resize_border(node, block_id, direction, shrink, divider_delta)
  local split = node.split
  if not split then return false end
  local before = contains(split.before, block_id)
  local child = before and split.before or split.after
  if resize_border(child, block_id, direction, shrink, divider_delta) then return true end
  local horizontal = direction == "left" or direction == "right"
  local edge_before = direction == "left" or direction == "up"
  if split.direction ~= (horizontal and "horizontal" or "vertical") or before == edge_before then
    return false
  end
  local delta = divider_delta or (before and 0.05 or -0.05) * (shrink and -1 or 1)
  check(rex.session.resize_pane {
    before_block_id = leaf(split.before), after_block_id = leaf(split.after),
    direction = split.direction, ratio = math.max(0.05, math.min(0.95, split.ratio + delta)),
  })
  return true
end

local function resize(direction, shrink, divider)
  local suffix = direction or "auto"
  if shrink then suffix = suffix .. "_shrink" end
  if divider then suffix = suffix .. "_divider" end
  return action("zellij_resize_" .. suffix, "Resize pane " .. suffix, function(ctx)
    local window = active_window(check(rex.session.view {}))
    if not window then return end
    local block_id = ctx.block_id or window.focused_block_id
    for _, layer in ipairs(window.layers or {}) do
      if layer.layout and contains(layer.layout, block_id) then
        local directions = direction and { direction } or { "right", "down", "left", "up" }
        local delta
        if divider then
          local opposite = { left = "right", right = "left", up = "down", down = "up" }
          directions = { direction, opposite[direction] }
          delta = (direction == "left" or direction == "up") and -0.05 or 0.05
        end
        for _, edge in ipairs(directions) do
          if resize_border(layer.layout, block_id, edge, shrink, delta) then return end
        end
      end
    end
  end, true)
end

local grow, shrink = resize(), resize(nil, true)
everywhere("alt+shift+=", grow)
everywhere("alt+=", grow)
everywhere("alt+-", shrink)
bind({ "resize/shift+=", "resize/=" }, grow)
bind("resize/-", shrink)

for _, item in ipairs({ { "h", "left" }, { "j", "down" }, { "k", "up" }, { "l", "right" } }) do
  local key, direction = item[1], item[2]
  everywhere("alt+" .. key, "pane.focus", { direction = direction, wrap = false })
  everywhere("ctrl+alt+" .. key, resize(direction, false, true))
  bind({ "pane/" .. key, "pane/" .. direction }, "pane.focus", { direction = direction, wrap = false })
  bind({ "tmux/" .. key, "tmux/" .. direction }, finish("pane.focus", { direction = direction, wrap = false }))
  bind({ "move/" .. key, "move/" .. direction }, "pane.move", { direction = direction })
  bind({ "resize/" .. key, "resize/" .. direction }, resize(direction))
  bind("resize/shift+" .. key, resize(direction, true))
  local focus = "pane.focus"
  if direction == "left" or direction == "right" then
    focus = action("zellij_focus_or_tab_" .. direction, "Focus pane or tab " .. direction, function()
      local before = active_window(check(rex.session.view {}))
      if not before then return end
      check(rex.session.focus_direction { direction = direction, wrap = false })
      local after = active_window(check(rex.session.view {}))
      if after and after.focused_block_id == before.focused_block_id then
        rex.client.queue(direction == "left" and "client.tab.previous" or "client.tab.next")
      end
    end, true)
  end
  everywhere("alt+" .. direction, focus, focus == "pane.focus" and { direction = direction, wrap = false } or nil)
end

everywhere("alt+n", "pane.split", { direction = "auto" })
everywhere("alt+f", "pane.float")
everywhere("alt+i", "client.tab.move", { direction = "backward" })
everywhere("alt+o", "client.tab.move", { direction = "forward" })

local mode_keys = {
  ["ctrl+;"] = "tmux", ["ctrl+p"] = "pane", ["ctrl+t"] = "tab",
  ["ctrl+n"] = "resize", ["ctrl+m"] = "move", ["ctrl+enter"] = "scroll", ["ctrl+s"] = "session",
}
for key, target in pairs(mode_keys) do
  everywhere(key, enter_mode[target])
  if target ~= "tmux" then bind(target .. "/" .. key, "client.mode.exit_all") end
end
rex.unbind("tmux/ctrl+;")

rex.mode("locked")
local lock = enter("locked")
everywhere("ctrl+g", lock)
bind("locked/ctrl+g", "client.mode.exit_all")
bind("locked/ctrl+;", enter_mode.tmux)
for _, binding in ipairs(rex.bindings()) do
  if not binding.mode and binding.key ~= "ctrl+g" and binding.key ~= "ctrl+;" then
    bind("locked/" .. binding.key, "pane.send_key", { key = binding.key })
  end
end

bind({ "pane/d", "tmux/s", "tmux/shift+'" }, finish("pane.split", { direction = "down" }))
bind({ "pane/r", "tmux/v", "tmux/shift+5" }, finish("pane.split", { direction = "right" }))
bind("pane/n", finish("pane.split", { direction = "auto" }))
bind({ "pane/f", "tmux/z" }, finish("pane.zoom"))
bind("pane/e", finish("pane.float"))
bind({ "pane/x", "tmux/x" }, finish("pane.close"))
bind({ "pane/p", "tmux/o" }, "pane.focus_next")

for _, item in ipairs({ { "n", 1 }, { "p", -1 }, { "tab", 1 } }) do
  local key, offset = item[1], item[2]
  bind("move/" .. key, action("zellij_swap_" .. (offset == 1 and "next" or "previous"),
    "Swap pane " .. (offset == 1 and "next" or "previous"), function(ctx)
      local window = active_window(check(rex.session.view {}))
      if not window then return end
      local block_id = ctx.block_id or window.focused_block_id
      for _, layer in ipairs(window.layers or {}) do
        local blocks = layer.blocks or {}
        for index, block in ipairs(blocks) do
          if block.block_id == block_id and #blocks > 1 then
            local other = blocks[(index - 1 + offset) % #blocks + 1]
            check(rex.session.swap_blocks { block_id = block_id, other_block_id = other.block_id })
            return
          end
        end
      end
    end, true))
end

bind({ "tab/n", "tmux/c" }, finish("client.tab.new"))
bind({ "tab/x", "tmux/shift+x" }, finish("client.tab.close"))
bind({ "tab/r", "tmux/," }, finish("client.tab.rename"))
bind("tab/b", finish("pane.move_to_new_tab"))
for _, item in ipairs({ { "[", -1 }, { "]", 1 } }) do
  local key, offset = item[1], item[2]
  bind("tab/" .. key, action("zellij_break_" .. (offset == -1 and "left" or "right"),
    "Move pane to adjacent tab", function(ctx)
      local view = check(rex.session.view {})
      for index, window in ipairs(view.windows or {}) do
        if window.window_id == view.active_window_id then
          local target = view.windows[index + offset]
          if not target or not target.focused_block_id then return end
          check(rex.session.move_block {
            block_id = ctx.block_id or window.focused_block_id,
            anchor_block_id = target.focused_block_id,
          })
          check(rex.session.focus_window { window_id = target.window_id })
          rex.client.queue("client.mode.exit_all")
          return
        end
      end
    end))
end
for _, key in ipairs({ "left", "up", "h", "k" }) do bind("tab/" .. key, "client.tab.previous") end
for _, key in ipairs({ "right", "down", "l", "j" }) do bind("tab/" .. key, "client.tab.next") end
bind("tmux/n", finish("client.tab.next"))
bind("tmux/p", finish("client.tab.previous"))
for index = 1, 9 do
  bind({ "tab/" .. index, "tmux/" .. index }, finish("client.tab.goto", { index = index }))
end

bind("tmux/[", enter_mode.scroll)
bind("move/ctrl+h", "client.mode.exit_all")
bind("scroll/ctrl+c", "client.mode.exit_all")
bind("scroll/s", finish("client.find.open"))
bind("scroll/n", "client.find.next")
bind("scroll/p", "client.find.previous")
bind("scroll/ctrl+enter", finish("pane.send_key", { key = "ctrl+b" }))
bind("session/ctrl+s", finish("pane.send_key", { key = "ctrl+b" }))
bind("session/w", finish("session.switch"))
bind("session/c", finish("client.settings"))

bind("tmux/ctrl+b", finish("pane.send_key", { key = "ctrl+b" }))
bind({ "session/d", "tmux/d" }, finish("client.window.close"))
local quit = finish("session.close")
everywhere("ctrl+q", quit)
bind("locked/ctrl+q", "pane.send_key", { key = "ctrl+q" })
