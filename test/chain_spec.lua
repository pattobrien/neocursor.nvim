-- Chain-coordinate spec: where each edit of a multi-edit chain lands.
--   nvim --headless -u NONE -c "luafile test/chain_spec.lua"
--
-- The backend numbers every edit in a chain against the buffer as it stands
-- after the edits before it (a range like L18-17 arrives for a 16-line file),
-- so accepting one edit must not shift the ones queued behind it. And an
-- insertion one line past the end has no line to land on: the jump parks on
-- the last line, and that has to count as "at" the edit or <Tab> jumps forever.
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

local edits_file = vim.fn.tempname()
vim.env.NEOCURSOR_FAKE_EDITS_FILE = edits_file
local function chain(edits) vim.fn.writefile({ vim.json.encode(edits) }, edits_file) end
local function edit(start1, end1, text) return { text = text, range = { start = start1, endInclusive = end1 } } end

local nc = require("neocursor")
nc.setup({
  debounce = 30,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

vim.cmd("edit " .. root .. "/test/spec_scratch.py")
local seed = { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x!", false)
end
local function input(keys) vim.api.nvim_input(keys) end
local function later(ms, fn) vim.defer_fn(fn, ms) end
local function poll(cond, timeout_ms, on_ok, on_fail)
  local waited = 0
  local function tick()
    if cond() then return on_ok() end
    waited = waited + 20
    if waited >= timeout_ms then return on_fail() end
    later(20, tick)
  end
  tick()
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function row() return vim.api.nvim_win_get_cursor(0)[1] end

local function round(name, body)
  poll(nc.has_suggestion, 3000, body, function()
    check("suggestion arrives (" .. name .. ")", false, true)
    input("<Esc>")
  end)
end

local function run(edits, typed, body)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  chain(edits)
  later(50, body)
  feed("A" .. typed) -- blocks until the round's <Esc>
end

-- an append one line past the end, alone: Tab jumps, then Tab accepts
run({ edit(6, 5, "line6 = 6") }, "x", function()
  round("append past the end", function()
    input("<Tab>")
    later(120, function()
      check("jump parks on the last line", row(), 5)
      input("<Tab>")
      later(120, function()
        check("Tab from the jump accepts the append", lines(),
          { "line1 = 1x", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5", "line6 = 6" })
        check("the chain is drained", nc.has_suggestion(), false)
        input("<Esc>")
      end)
    end)
  end)
end)

-- the field shape: the first accept adds a line, and the append behind it is
-- already numbered against the longer buffer
run({ edit(1, 1, "line1 = 1x\nline1b"), edit(7, 6, "line6 = 6") }, "x", function()
  round("append after a growing accept", function()
    input("<Tab>")
    later(120, function()
      check("first accept adds its line", #lines(), 6)
      input("<Tab>")
      later(120, function()
        check("jump parks on the new last line", row(), 6)
        input("<Tab>")
        later(120, function()
          check("Tab from the jump accepts the append", lines(),
            { "line1 = 1x", "line1b", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5", "line6 = 6" })
          check("the chain is drained", nc.has_suggestion(), false)
          input("<Esc>")
        end)
      end)
    end)
  end)
end)

local stacked = { edit(1, 1, "line1 = 1x\nline1b"), edit(3, 2, "line1c") }
local stacked_want = { "line1 = 1x", "line1b", "line1c", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }

-- consecutive inserts inside the buffer: each lands right under the last
run(stacked, "x", function()
  round("stacked inserts via Tab", function()
    input("<Tab>")
    later(120, function()
      input("<Tab>")
      later(120, function()
        input("<Tab>")
        later(120, function()
          check("Tab lands the second insert under the first", lines(), stacked_want)
          input("<Esc>")
        end)
      end)
    end)
  end)
end)

-- the same chain with the multi-line ghost accepted a word at a time
run(stacked, "x", function()
  round("stacked inserts via partial accept", function()
    input("<M-Right>")
    later(120, function()
      input("<M-Right>")
      later(120, function()
        input("<Tab>")
        later(120, function()
          input("<Tab>")
          later(120, function()
            check("partial accept lands the second insert under the first", lines(), stacked_want)
            input("<Esc>")
          end)
        end)
      end)
    end)
  end)
end)

-- and typed out by hand
run(stacked, "x", function()
  round("stacked inserts via typing through", function()
    input("<CR>line1b")
    later(120, function()
      input("<Tab>")
      later(120, function()
        input("<Tab>")
        later(120, function()
          check("typing through lands the second insert under the first", lines(), stacked_want)
          input("<Esc>")
        end)
      end)
    end)
  end)
end)

io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
vim.cmd(failed == 0 and "qall!" or "cquit!")
