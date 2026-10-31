local function check(value, err)
  if err then error(err, 0) end
  return value
end
local function terminal()
  return rex.layout.block {
    flavor = "com.superlogical.terminal.shell",
    options = { shell = "none", command = { "/bin/sleep", "300" } },
  }
end
local session = check(rex.call("session.create", {
  label = "rex-keybind-integration-test",
  initial_windows = {
    { layout = rex.layout.horizontal(0.5, terminal(), terminal()) },
    { layout = rex.layout.vertical(0.5, terminal(), terminal()) },
  },
}))
local session_id = session.session_id
local function perform(name, block_id, args)
  return check(rex.call("client.action", {
    session_id = session_id, block_id = block_id, action = name, args = args,
  }))
end
local function view()
  return check(rex.session.view { session_id = session_id })
end
local ok, err = pcall(function()
  check(rex.session.attach { session_id = session_id })
  for index, directions in ipairs({ { "left", "right" }, { "up", "down" } }) do
    local window = session.initial_windows[index]
    check(rex.session.focus_window { session_id = session_id, window_id = window.window_id })
    for _, block_id in ipairs(window.block_ids) do
      check(rex.session.focus_block { session_id = session_id, block_id = block_id })
      perform("zellij_resize_" .. directions[1] .. "_divider", block_id)
      assert(math.abs(view().windows[index].layers[1].layout.split.ratio - 0.45) < 0.001)
      perform("zellij_resize_" .. directions[2] .. "_divider", block_id)
      assert(math.abs(view().windows[index].layers[1].layout.split.ratio - 0.5) < 0.001)
    end
  end
end)
check(rex.call("session.destroy", { session_id = session_id }))
if not ok then error(err, 0) end
print("Live Rex integration: directional resize passed; test session removed")
