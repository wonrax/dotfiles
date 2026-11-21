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

-- Scroll mode rides on Rex's copy mode, which only exists while a terminal is
-- in it. Queue pane.copy_mode.exit last: it is unavailable once copy mode is
-- already gone, and nothing queued after it should depend on it.
local function enter(name, leaving_scroll)
  local id = "zellij_enter_" .. name .. (leaving_scroll and "_from_scroll" or "")
  return action(id, "Enter " .. name .. " mode", function()
    rex.client.queue("client.mode.exit_all")
    rex.client.queue("client.mode.enter", { name = name })
    if name == "scroll" then rex.client.queue("pane.copy_mode.enter") end
    if leaving_scroll then rex.client.queue("pane.copy_mode.exit") end
  end)
end

local function leave_scroll(name, args)
  local id = "zellij_leave_scroll" .. (name and "_" .. name:gsub("%.", "_") or "")
  return action(id, "Leave scroll mode" .. (name and " and run " .. name or ""), function()
    rex.client.queue("client.mode.exit_all")
    if name then
      rex.client.queue("pane.copy_mode.exit")
      rex.client.queue(name, args)
    else
      rex.client.queue("pane.copy_mode.exit")
    end
  end)
end

local enter_mode = {}
for _, mode in ipairs(modes) do
  -- Scroll stays non-exclusive so copy mode's own vim keys (v, y, w, b, g, /...)
  -- reach it; only the zellij-specific keys are bound below.
  rex.mode(mode, { exclusive = mode ~= "scroll" })
  enter_mode[mode] = enter(mode)
  bind({ mode .. "/escape", mode .. "/enter" }, mode == "scroll" and leave_scroll() or "client.mode.exit_all")
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

local terminal = "com.superlogical.terminal"

local function focused_block(ctx)
  if ctx and ctx.block_id then return ctx.block_id end
  local view = rex.session.view {}
  local window = view and active_window(view)
  return window and window.focused_block_id
end

local function in_vim(ctx)
  local block_id = focused_block(ctx)
  if not block_id then return false end
  local process = rex.block.call(terminal, "process", { block_id = block_id })
  local fg = process and process.foreground
  if not fg then return false end
  for _, name in ipairs({ fg.name, fg.argv0, fg.path }) do
    if name and name:match("[^/]*$"):match("^%.?n?vim") then return true end
  end
  return false
end

local grow, shrink = resize(), resize(nil, true)
everywhere("alt+shift+=", grow)
everywhere("alt+=", grow)
everywhere("alt+-", shrink)
bind({ "resize/shift+=", "resize/=" }, grow)
bind("resize/-", shrink)

-- MoveFocus the zellij way: tiled and floating panes are separate planes, and
-- focus only moves within the plane it's on. Rex's own focus_direction mixes
-- them, jumping from a float to the tiled pane under it and back.
local function plane_blocks(window, block_id)
  local planes = { tiled = {}, floating = {} }
  local plane, kind
  local function walk(node, list)
    if node.block_id then
      local r = node.rect
      table.insert(list, { id = node.block_id, x = r[1], y = r[2], w = r[3], h = r[4] })
    elseif node.split then
      walk(node.split.before, list)
      walk(node.split.after, list)
    end
  end
  for _, layer in ipairs(window.layers or {}) do
    local list = layer.kind == "tiled" and planes.tiled or planes.floating
    if layer.layout and layer.state ~= "minimized" then
      local start = #list
      walk(layer.layout, list)
      for i = start + 1, #list do
        if list[i].id == block_id then plane, kind = list, layer.kind == "tiled" and "tiled" or "floating" end
      end
    end
  end
  return plane or {}, kind
end

local function overlap(a1, a2, b1, b2) return math.min(a2, b2) - math.max(a1, b1) end

local function focus_in_plane(ctx, direction)
  local window = active_window(check(rex.session.view {}))
  if not window then return false end
  local block_id = ctx.block_id or window.focused_block_id
  local blocks, kind = plane_blocks(window, block_id)
  local current
  for _, b in ipairs(blocks) do if b.id == block_id then current = b end end
  if not current then return false end
  local horizontal = direction == "left" or direction == "right"
  local sign = (direction == "left" or direction == "up") and -1 or 1
  local function center(b) return b.x + b.w / 2, b.y + b.h / 2 end
  local cx, cy = center(current)
  local best, best_score
  for _, b in ipairs(blocks) do
    if b.id ~= block_id then
      local bx, by = center(b)
      local along = ((horizontal and bx - cx) or (by - cy)) * sign
      -- Edge distance keeps tiled neighbours adjacent; floats may overlap, so
      -- they only need their centre past ours.
      local gap = horizontal
        and (sign > 0 and b.x - (current.x + current.w) or current.x - (b.x + b.w))
        or (sign > 0 and b.y - (current.y + current.h) or current.y - (b.y + b.h))
      local shared = horizontal and overlap(b.y, b.y + b.h, current.y, current.y + current.h)
        or overlap(b.x, b.x + b.w, current.x, current.x + current.w)
      if along > 1e-6 and (kind == "floating" or gap > -1e-3) then
        local perp = horizontal and math.abs(by - cy) or math.abs(bx - cx)
        local score = math.max(gap, 0) * 4 + along + (shared > 0 and 0 or 1 + perp)
        if not best_score or score < best_score then best, best_score = b, score end
      end
    end
  end
  if not best then return false end
  check(rex.session.focus_block { block_id = best.id })
  return true
end

for _, item in ipairs({ { "h", "left" }, { "j", "down" }, { "k", "up" }, { "l", "right" } }) do
  local key, direction = item[1], item[2]
  local focus_action = action("zellij_focus_" .. direction, "Focus pane " .. direction, function(ctx)
    focus_in_plane(ctx, direction)
  end, true)
  everywhere("alt+" .. key, focus_action)
  everywhere("ctrl+alt+" .. key, resize(direction, false, true))
  bind({ "pane/" .. key, "pane/" .. direction }, focus_action)
  bind({ "tmux/" .. key, "tmux/" .. direction }, action("zellij_finish_focus_" .. direction,
    "Focus pane " .. direction .. " and leave mode", function(ctx)
      rex.client.queue("client.mode.exit_all")
      focus_in_plane(ctx, direction)
    end))
  bind({ "move/" .. key, "move/" .. direction }, "pane.move", { direction = direction })
  bind({ "resize/" .. key, "resize/" .. direction }, resize(direction))
  bind("resize/shift+" .. key, resize(direction, true))
  -- vim-zellij-navigator: hand alt+hjkl and ctrl+alt+hjkl to (n)vim so
  -- smart-splits moves between its own splits and calls back into Rex at the
  -- edge. Function bindings can't live in modes, so modes keep the plain action.
  rex.bind("alt+" .. key, function(ctx)
    if in_vim(ctx) then return false end
    focus_in_plane(ctx, direction)
    return true
  end)
  local divider = resize(direction, false, true)
  rex.bind("ctrl+alt+" .. key, function(ctx)
    if in_vim(ctx) then return false end
    rex.invoke(divider)
    return true
  end)
  local focus = focus_action
  if direction == "left" or direction == "right" then
    focus = action("zellij_focus_or_tab_" .. direction, "Focus pane or tab " .. direction, function(ctx)
      if not focus_in_plane(ctx, direction) then
        rex.client.queue(direction == "left" and "client.tab.previous" or "client.tab.next")
      end
    end, true)
  end
  everywhere("alt+" .. direction, focus)
end

-- NewPane: like zellij, a new pane joins the floating panes when one of them
-- has focus, and splits the tiled layout otherwise.
local function new_pane(leave_mode)
  return action("zellij_new_pane" .. (leave_mode and "_and_leave" or ""), "New pane", function(ctx)
    if leave_mode then rex.client.queue("client.mode.exit_all") end
    local window = active_window(check(rex.session.view {}))
    local block_id = window and (ctx.block_id or window.focused_block_id)
    for _, layer in ipairs(window and window.layers or {}) do
      if layer.kind ~= "tiled" then
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == block_id then
            rex.client.queue("pane.new_floating")
            return
          end
        end
      end
    end
    rex.client.queue("pane.split", { direction = "auto" })
  end)
end
everywhere("alt+n", new_pane())
-- ToggleFloatingPanes: open one when there are none, otherwise hide/show them all.
local function toggle_floating()
  local window = active_window(check(rex.session.view {}))
  if not window then return end
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind ~= "tiled" then
      rex.client.queue("pane.minimize_all_floating")
      return
    end
  end
  rex.client.queue("pane.new_floating")
end
everywhere("alt+f", action("zellij_toggle_floating", "Toggle floating panes", toggle_floating))
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
bind("tmux/ctrl+;", finish("pane.send_key", { key = "ctrl+b" }))

rex.mode("locked")
local lock = enter("locked")
everywhere("ctrl+g", lock)
bind("locked/ctrl+g", "client.mode.exit_all")
bind("locked/ctrl+;", enter_mode.tmux)
local forwarded = {}
for _, binding in ipairs(rex.bindings()) do
  if not binding.mode and binding.key ~= "ctrl+g" and binding.key ~= "ctrl+;" and not forwarded[binding.key] then
    forwarded[binding.key] = true
    bind("locked/" .. binding.key, "pane.send_key", { key = binding.key })
  end
end

bind({ "pane/d", "tmux/s", "tmux/shift+'" }, finish("pane.split", { direction = "down" }))
bind({ "pane/r", "tmux/v", "tmux/shift+5" }, finish("pane.split", { direction = "right" }))
bind("pane/n", new_pane(true))
bind({ "pane/f", "tmux/z" }, finish("pane.zoom"))
bind("pane/e", action("zellij_toggle_embed", "Toggle pane embedded or floating", function(ctx)
  rex.client.queue("client.mode.exit_all")
  local window = active_window(check(rex.session.view {}))
  if not window then return end
  local block_id = ctx.block_id or window.focused_block_id
  local tiled, floating
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == "tiled" then tiled = layer end
    for _, block in ipairs(layer.blocks or {}) do
      if block.block_id == block_id and layer.kind ~= "tiled" then floating = true end
    end
  end
  if not floating then
    rex.client.queue("pane.float")
    return
  end
  local anchor = tiled and tiled.layout and leaf(tiled.layout)
  if anchor then
    check(rex.session.move_block { block_id = block_id, anchor_block_id = anchor })
    check(rex.session.focus_block { block_id = block_id })
  end
end))
bind("pane/w", action("zellij_finish_toggle_floating", "Toggle floating panes and leave mode", function()
  rex.client.queue("client.mode.exit_all")
  toggle_floating()
end))
bind("pane/c", finish("pane.rename"))
bind("pane/z", finish("client.setting.interface.panes.headers"))
-- CloseFocus: Rex keeps a session alive with no panes left, so closing the
-- last pane of a tab closes the tab, and the last pane of the session closes
-- the session, the way zellij exits.
bind({ "pane/x", "tmux/x" }, action("zellij_close_focus", "Close pane, tab, or session", function(ctx)
  rex.client.queue("client.mode.exit_all")
  local view = check(rex.session.view {})
  local window = active_window(view)
  if not window then return end
  local block_id = ctx.block_id or window.focused_block_id
  local in_window = 0
  for _, layer in ipairs(window.layers or {}) do in_window = in_window + #(layer.blocks or {}) end
  if in_window > 1 then
    rex.client.queue("pane.close")
  elseif #(view.windows or {}) > 1 then
    check(rex.session.close_window { window_id = window.window_id })
  else
    check(rex.call("session.destroy", { session_id = ctx.session_id or view.session_id }))
  end
end))
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
bind("tab/tab", "client.tab.recent.in_session")
bind("tmux/tab", finish("client.tab.recent.in_session"))
bind("tmux/n", finish("client.tab.next"))
bind("tmux/p", finish("client.tab.previous"))
for index = 1, 9 do
  bind({ "tab/" .. index, "tmux/" .. index }, finish("client.tab.goto", { index = index }))
end

bind("tmux/[", enter_mode.scroll)
bind("move/ctrl+h", "client.mode.exit_all")
for key, target in pairs(mode_keys) do
  if target ~= "scroll" then bind("scroll/" .. key, enter(target, true)) end
end
bind("scroll/ctrl+g", enter("locked", true))
bind({ "scroll/ctrl+c", "scroll/q" }, leave_scroll())
bind("scroll/ctrl+enter", leave_scroll("pane.send_key", { key = "ctrl+b" }))
local scroll_moves = {
  j = "down", down = "down", k = "up", up = "up",
  d = "half_page_down", u = "half_page_up",
  l = "page_down", right = "page_down", pagedown = "page_down", ["ctrl+f"] = "page_down",
  h = "page_up", left = "page_up", pageup = "page_up",
}
for key, to in pairs(scroll_moves) do bind("scroll/" .. key, "pane.copy_mode.move", { to = to }) end
-- Starting at the bottom of the scrollback, so search upward; n keeps going, p reverses.
bind("scroll/s", "pane.copy_mode.search", { direction = "backward" })
bind("scroll/n", "pane.copy_mode.search_again", { direction = "same" })
bind("scroll/p", "pane.copy_mode.search_again", { direction = "opposite" })
bind("scroll/y", finish("pane.copy_mode.yank"))
-- EditScrollback. Queued actions only run after this returns, so the editor
-- can't be focused here without stealing pane.copy_mode.exit from the source
-- pane; the editor's own shell focuses itself once copy mode is gone.
bind("scroll/e", action("zellij_edit_scrollback", "Edit scrollback in nvim", function(ctx)
  rex.client.queue("client.mode.exit_all")
  rex.client.queue("pane.copy_mode.exit")
  local window = active_window(check(rex.session.view {}))
  if not window then return end
  local block_id = ctx.block_id or window.focused_block_id
  local r = check(rex.block.call(terminal, "format", {
    block_id = block_id, format = "text", unwrap = true, trim = true, max_bytes = 983040,
  }))
  local parts, offset = { r.content }, #r.content
  while r.id and not r.eof do
    r = check(rex.block.call(terminal, "blob_read", { block_id = block_id, id = r.id, offset = offset }))
    table.insert(parts, r.data)
    offset = offset + #r.data
  end
  local file = check(rex.exec({ "/bin/sh", "-c", 'f=$(mktemp -t rex-scrollback) && cat >"$f" && printf %s "$f"' },
    { stdin = table.concat(parts) }))
  if not file.ok then error(file.stderr, 0) end
  check(rex.session.new_layer {
    window_id = window.window_id, bounds = { 0.05, 0.05, 0.9, 0.9 },
    layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell",
      options = {
        shell = "none",
        command = { "/bin/zsh", "-lc",
          'sleep 0.2; "$REX_BIN_DIR/rex" focus "$REX_BLOCK" >/dev/null 2>&1; nvim +"normal G" -- "$1"; rm -f -- "$1"',
          "rex-scrollback", file.stdout },
      },
    },
  })
end))
bind("session/ctrl+s", finish("pane.send_key", { key = "ctrl+b" }))
bind("session/w", finish("session.switch"))
bind("session/c", finish("client.settings"))

bind("tmux/ctrl+b", finish("pane.send_key", { key = "ctrl+b" }))
bind({ "session/d", "tmux/d" }, finish("client.window.close"))
local quit = finish("session.close")
everywhere("ctrl+q", quit)
bind("locked/ctrl+q", "pane.send_key", { key = "ctrl+q" })
