local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.showmode = false
io.stdout:setvbuf("no")

local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or ("  got=" .. vim.inspect(got) .. "  want=" .. vim.inspect(want))))
end

local sl = require("neocursor.statusline")

check("defaults", sl.normalize(nil), {
  keycaps = { tab = "⇥", esc = "⎋" },
  show = { edit = true, prediction = true, request = true },
})
check("nerd keycaps", sl.normalize({ keycaps = "nerd" }).keycaps, { tab = "󰌒", esc = "󱊷" })
check("text keycaps", sl.normalize({ keycaps = "text" }).keycaps, { tab = "Tab", esc = "Esc" })
check("table keycaps fill the missing key", sl.normalize({ keycaps = { tab = "T" } }).keycaps, { tab = "T", esc = "⎋" })
check("show toggles are per key", sl.normalize({ show = { request = false } }).show,
  { edit = true, prediction = true, request = false })

local cfg = sl.normalize()
local function render(status, opts) return sl.render(status, opts and sl.normalize(opts) or cfg) end
local at = { mode = "diff", line = 3, at_cursor = true }
local away = { mode = "diff", line = 14, at_cursor = false }
local pred = { line = 42 }
local xpred = { line = 42, path = "src/a.py" }

check("idle, nothing queued", render({ state = "idle" }), "")
check("pending", render({ state = "pending" }), "…")
check("disabled", render({ state = "disabled", reason = "filetype" }), "off")
check("edit at cursor", render({ state = "idle", suggestion = at }), "⇥ accept")
check("inline edit at cursor", render({ state = "idle", suggestion = { mode = "inline", line = 1, at_cursor = true } }), "⇥ accept")
check("edit elsewhere", render({ state = "idle", suggestion = away }), "⇥ jump L14")
check("same-file prediction", render({ state = "idle", prediction = pred }), "⇥ → L42")
check("cross-file prediction", render({ state = "idle", prediction = xpred }), "⇥ → src/a.py:42")
check("an edit hides the prediction", render({ state = "idle", suggestion = away, prediction = pred }), "⇥ jump L14")
check("edit and pending join with two spaces", render({ state = "pending", suggestion = away }), "⇥ jump L14  …")
check("prediction and pending", render({ state = "pending", prediction = pred }), "⇥ → L42  …")
check("text keycaps", render({ state = "idle", suggestion = at }, { keycaps = "text" }), "Tab accept")
check("table keycaps", render({ state = "idle", prediction = pred }, { keycaps = { tab = "<Tab>" } }), "<Tab> → L42")
check("show.edit=false", render({ state = "idle", suggestion = away }, { show = { edit = false } }), "")
check("show.edit=false still hides the prediction behind a painted edit",
  render({ state = "idle", suggestion = away, prediction = pred }, { show = { edit = false } }), "")
check("show.prediction=false", render({ state = "idle", prediction = pred }, { show = { prediction = false } }), "")
check("show.request=false hides pending", render({ state = "pending", suggestion = at }, { show = { request = false } }), "⇥ accept")
check("show.request=false hides off", render({ state = "disabled", reason = "stopped" }, { show = { request = false } }), "")

local comp = sl.component()
check("component is lualine-shaped", { type(comp[1]), type(comp.cond) }, { "function", "function" })

local nc = require("neocursor")
check("statusline() before setup", nc.statusline(), "off")
check("component before setup", { comp[1](), comp.cond() }, { "off", true })

local events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "NeocursorStatus",
  callback = function(args) events[#events + 1] = args.data end,
})
local function since(n) return vim.list_slice(events, n + 1) end

nc.setup({
  debounce = 30,
  filetypes = { "python" },
  statusline = { keycaps = "text" },
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

local scratch = root .. "/test/statusline_scratch.py"
vim.cmd("edit " .. scratch)
vim.bo.filetype = "python"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check("idle buffer renders nothing", nc.statusline(), "")
check("component hidden when empty", comp.cond(), false)

local function input(keys) vim.api.nvim_input(keys) end
local function later(ms, fn) vim.defer_fn(fn, ms) end
local function poll(cond, timeout_ms, on_ok, on_fail)
  local waited = 0
  local function tick()
    if cond() then return on_ok() end
    waited = waited + 10
    if waited >= timeout_ms then return on_fail() end
    later(10, tick)
  end
  tick()
end

local P2 = { line = 2 }
local rounds = {
  {
    desc = "reply paints the first edit",
    keys = "A1",
    want = {
      { state = "pending" },
      { state = "idle", suggestion = { mode = "diff", line = 1, at_cursor = true }, prediction = P2 },
    },
    text = "Tab accept",
  },
  {
    desc = "accept advances the chain to the next edit",
    keys = "<Tab>",
    want = { { state = "idle", suggestion = { mode = "diff", line = 4, at_cursor = false }, prediction = P2 } },
    text = "Tab jump L4",
  },
  {
    desc = "jump lands on the edit",
    keys = "<Tab>",
    want = { { state = "idle", suggestion = { mode = "diff", line = 4, at_cursor = true }, prediction = P2 } },
    text = "Tab accept",
  },
  {
    desc = "accepting the last edit hands over to the prediction",
    keys = "<Tab>",
    want = { { state = "idle", prediction = P2 } },
    text = "Tab → L2",
    after = function()
      local other = root .. "/test/statusline_other.py"
      vim.cmd("keepalt file " .. vim.fn.fnameescape(other))
      local rel = vim.fn.fnamemodify(scratch, ":.")
      check("prediction from another file names its path", nc.status().prediction, { line = 2, path = rel })
      check("cross-file statusline", nc.statusline(), "Tab → " .. rel .. ":2")
      vim.cmd("keepalt file " .. vim.fn.fnameescape(scratch))
      check("same file again drops the path", nc.status().prediction, P2)
    end,
  },
  {
    desc = "dismiss rejects the prediction",
    keys = "<C-]>",
    want = { { state = "idle" } },
    text = "",
  },
  {
    desc = "a reply that extends the typed text paints an inline ghost",
    keys = "<BS>",
    want = {
      { state = "pending" },
      { state = "idle", suggestion = { mode = "inline", line = 4, at_cursor = true }, prediction = P2 },
    },
    text = "Tab accept",
  },
  {
    desc = "typing off the ghost replaces it with the next reply",
    keys = "x",
    want = {
      { state = "pending", prediction = P2 },
      { state = "idle", suggestion = { mode = "diff", line = 4, at_cursor = true }, prediction = P2 },
    },
    text = "Tab accept",
  },
  {
    desc = "first dismiss clears the edit and keeps the prediction",
    keys = "<C-]>",
    want = { { state = "idle", prediction = P2 } },
    text = "Tab → L2",
  },
  {
    desc = "second dismiss rejects the prediction",
    keys = "<C-]>",
    want = { { state = "idle" } },
    text = "",
  },
}

local function finish()
  input("<Esc>")
  later(50, function()
    io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
    vim.cmd(failed == 0 and "qall!" or "cquit!")
  end)
end

local function run(i)
  local r = rounds[i]
  if not r then return finish() end
  local mark = #events
  input(r.keys)
  local function settle()
    later(150, function()
      check(r.desc .. ": NeocursorStatus fires once per transition", since(mark), r.want)
      check(r.desc .. ": statusline()", nc.statusline(), r.text)
      check(r.desc .. ": status() matches the last event", nc.status(), r.want[#r.want])
      if r.after then r.after() end
      later(30, function() run(i + 1) end)
    end)
  end
  poll(function() return #since(mark) >= #r.want end, 3000, settle, settle)
end

later(50, function() run(1) end)
