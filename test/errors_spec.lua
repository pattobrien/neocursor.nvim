-- Error-reply spec: a backend rejection reaches the user once, not per request.
--   nvim --headless -u NONE -c "luafile test/errors_spec.lua"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
io.stdout:setvbuf("no")

local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or ("  got=" .. vim.inspect(got) .. "  want=" .. vim.inspect(want))))
end

local error_file = vim.fn.tempname()
vim.env.NEOCURSOR_FAKE_ERROR_FILE = error_file
local function backend_error(msg)
  if msg then
    vim.fn.writefile({ msg }, error_file)
  else
    vim.fn.delete(error_file)
  end
end

local notified = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then table.insert(notified, msg) end
end

local nc = require("neocursor")
nc.setup({
  debounce = 30,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})
vim.cmd("edit " .. root .. "/test/spec_scratch.py")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4" })

local function replies()
  local n = 0
  for _, l in ipairs(nc._log_lines()) do
    if l:find("ERR     #", 1, true) or l:find("RES     #", 1, true) then n = n + 1 end
  end
  return n
end

local function request(done)
  local before = replies()
  nc.suggest()
  local waited = 0
  local function tick()
    if replies() > before then return done() end
    waited = waited + 20
    if waited >= 5000 then
      check("reply arrives", false, true)
      return done()
    end
    vim.defer_fn(tick, 20)
  end
  tick()
end

local unauth = "unauthenticated: ERROR_NOT_LOGGED_IN"
local steps = {
  function(next) backend_error(unauth); request(next) end,
  function(next) request(next) end,
  function(next) request(next) end,
  function(next)
    check("same error notifies once across three requests", #notified, 1)
    check("notification names the backend error", notified[1], "neocursor: " .. unauth)
    backend_error(nil); request(next)
  end,
  function(next) backend_error(unauth); request(next) end,
  function(next)
    check("error after a success notifies again", #notified, 2)
    backend_error("permission_denied: ERROR_USAGE_LIMIT"); request(next)
  end,
  function(next)
    check("a different error notifies", #notified, 3)
    next()
  end,
}

local function run(i)
  if i > #steps then
    backend_error(nil)
    io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
    vim.cmd(failed == 0 and "qall!" or "cquit!")
    return
  end
  steps[i](function() vim.defer_fn(function() run(i + 1) end, 20) end)
end

vim.defer_fn(function() run(1) end, 200)
