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

local nc = require("neocursor")
check("before setup: disabled/stopped", nc.status(), { state = "disabled", reason = "stopped" })

local events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "NeocursorStatus",
  callback = function(args) events[#events + 1] = args.data end,
})
local function since(n)
  return vim.list_slice(events, n + 1)
end

nc.setup({
  debounce = 30,
  map_tab = false,
  filetypes = { "python" },
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})
check("after setup, no buffer: disabled/filetype", nc.status(), { state = "disabled", reason = "filetype" })

vim.cmd("edit " .. root .. "/test/spec_scratch.py")
vim.bo.filetype = "python"
check("python buffer: idle", nc.status(), { state = "idle" })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

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
local function is(s) return function() return nc.status().state == s end end
local function logged(pat)
  for _, l in ipairs(nc._log_lines()) do
    if l:find(pat, 1, true) then return true end
  end
  return false
end

local landed = {
  state = "idle",
  suggestion = { mode = "diff", line = 1, at_cursor = true },
  prediction = { line = 2 },
}

local function round_request(done)
  local mark = #events
  input("A1")
  poll(is("pending"), 2000, function()
    check("typing: pending", nc.status(), { state = "pending" })
    poll(function() return logged("REQ") end, 2000, function()
      check("request in flight: still pending", nc.status().state, "pending")
      poll(function() return is("idle")() and nc.has_suggestion() and #since(mark) >= 2 end, 3000, function()
        check("reply landed: idle with suggestion", { nc.status().state, nc.has_suggestion() }, { "idle", true })
        check("one pending and one idle event, no flicker at the debounce edge", since(mark), {
          { state = "pending" }, landed,
        })
        done()
      end, function()
        check("reply landed: idle with suggestion", { nc.status().state, nc.has_suggestion(), since(mark) }, { "idle", true, { { state = "pending" }, landed } })
        done()
      end)
    end, function()
      check("request sent", logged("REQ"), true)
      done()
    end)
  end, function()
    check("typing: pending", nc.status().state, "pending")
    done()
  end)
end

local function round_dismiss(done)
  input("<Esc>")
  poll(function() return vim.api.nvim_get_mode().mode == "n" end, 2000, function()
    check("after <Esc>: idle", nc.status(), { state = "idle" })
    done()
  end, function()
    check("after <Esc>: normal mode", vim.api.nvim_get_mode().mode, "n")
    done()
  end)
end

local function round_buffers(done)
  local mark = #events
  local py = vim.api.nvim_get_current_buf()
  vim.cmd("enew")
  check("buffer outside the allow-list: disabled/filetype", nc.status(), { state = "disabled", reason = "filetype" })
  later(20, function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
    check("nofile buffer: disabled/buftype", nc.status(), { state = "disabled", reason = "buftype" })
    input("ihello")
    later(100, function()
      check("typing in a nofile buffer never goes pending", nc.status(), { state = "disabled", reason = "buftype" })
      input("<Esc>")
      vim.api.nvim_set_current_buf(py)
      check("back in the python buffer: idle", nc.status(), { state = "idle" })
      local want = {
        { state = "disabled", reason = "filetype" },
        { state = "disabled", reason = "buftype" },
        { state = "idle" },
      }
      poll(function() return #since(mark) == #want end, 2000, function()
        check("events track buffer switches, including a reason-only change", since(mark), want)
        done()
      end, function()
        check("events track buffer switches, including a reason-only change", since(mark), want)
        done()
      end)
    end)
  end)
end

local function round_stop(done)
  local mark = #events
  nc.stop()
  check("after stop(): disabled/stopped", nc.status(), { state = "disabled", reason = "stopped" })
  input("A2")
  later(100, function()
    check("typing while stopped stays disabled", nc.status(), { state = "disabled", reason = "stopped" })
    input("<Esc>")
    poll(function() return #since(mark) >= 1 end, 2000, function()
      check("stop() fires one disabled event", since(mark), { { state = "disabled", reason = "stopped" } })
      done()
    end, function()
      check("stop() fires one disabled event", since(mark), { { state = "disabled", reason = "stopped" } })
      done()
    end)
  end)
end

local function finish()
  io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
  vim.cmd(failed == 0 and "qall!" or "cquit!")
end

later(50, function()
  round_request(function()
    later(50, function()
      round_dismiss(function()
        later(50, function()
          round_buffers(function()
            later(50, function()
              round_stop(finish)
            end)
          end)
        end)
      end)
    end)
  end)
end)
