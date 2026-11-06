-- Request-shape spec: the diff history the client sends is in Cursor's own
-- trajectory format ("N-|old" / "N+|new" / "N |unchanged", 1-indexed), which
-- is what Cursor's backend parses. Unified-diff hunks made some requests fail
-- with `unavailable` every time.
--   nvim --headless -u NONE -c "luafile test/request_shape_spec.lua"
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

local request_file = vim.fn.tempname()
vim.env.NEOCURSOR_FAKE_REQUEST_FILE = request_file

local nc = require("neocursor")
nc.setup({
  debounce = 30,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.cmd.cd(dir)

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

local function sent_diffs(name, content)
  local found
  for _, l in ipairs(vim.fn.readfile(request_file)) do
    local req = vim.json.decode(l)
    if req.content == content then found = req end
  end
  for _, h in ipairs(found and found.file_diff_histories or {}) do
    if h.file_name == name then return h.diff_history end
  end
end

local function open(name, lines)
  vim.fn.writefile(lines, name)
  vim.cmd.edit(name)
end

local function set(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local steps = {
  function(next)
    open("scratch.ts", {})
    set({ "const foo = 'bar';", "const baz = " })
    request(next)
  end,
  function(next)
    check("typing into an empty file sends added lines numbered from 1",
      sent_diffs("scratch.ts", "const foo = 'bar';\nconst baz = "),
      { "1-|\n1+|const foo = 'bar';\n2+|const baz = \n" })
    next()
  end,
  function(next)
    open("edit.ts", { "a", "b", "c", "d" })
    set({ "a", "B", "c", "d", "e" })
    request(next)
  end,
  function(next)
    check("a replacement and an append keep old and new line numbers, unchanged lines between",
      sent_diffs("edit.ts", "a\nB\nc\nd\ne"),
      { "2-|b\n2+|B\n3 |c\n4 |d\n5+|e\n" })
    next()
  end,
}

local function run(i)
  if i > #steps then
    io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
    vim.cmd(failed == 0 and "qall!" or "cquit!")
    return
  end
  steps[i](function() vim.defer_fn(function() run(i + 1) end, 20) end)
end

vim.defer_fn(function() run(1) end, 200)
