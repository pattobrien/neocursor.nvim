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

local ui = require("neocursor.ui")
local preview = require("neocursor.preview")
local ns = preview.namespace()

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
local seed = { "local alpha = 1", "local beta = 2", "local gamma = 3", "local delta = 4" }

local function reseed(lines)
  preview.clear(bufnr)
  preview.clear_prediction(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or seed)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function flat(chunks)
  local s = ""
  for _, c in ipairs(chunks or {}) do s = s .. c[1] end
  return s
end

local function marks()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    local d = m[4]
    local vl = {}
    for _, line in ipairs(d.virt_lines or {}) do vl[#vl + 1] = flat(line) end
    out[#out + 1] = { row = m[2], col = m[3], text = flat(d.virt_text), vlines = vl, d = d }
  end
  return out
end

local function is_label(s)
  return s:find("⇥", 1, true) ~= nil and s:find("dismiss", 1, true) ~= nil
end

local function labels()
  local out = {}
  for _, m in ipairs(marks()) do
    if is_label(m.text) then
      out[#out + 1] = { where = m.d.virt_text_pos, row = m.row }
    end
    for i, l in ipairs(m.vlines) do
      if is_label(l) then
        out[#out + 1] = { where = m.d.virt_lines_above and "above" or "below", row = m.row, index = i, of = #m.vlines }
      end
    end
  end
  return out
end

local function body()
  local struck, added = {}, {}
  for _, m in ipairs(marks()) do
    if m.d.hl_group == ui.groups.delete then struck[#struck + 1] = m.row end
    for _, l in ipairs(m.vlines) do
      if not is_label(l) then added[#added + 1] = l end
    end
  end
  return { struck = struck, added = added }
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
  end
  return out
end

local accept = ui.label("accept", ui.normalize(nil))
local old2 = { "local alpha = 1", "local beta = 2" }
local new2 = { "local alpha = 1", "local beta = 22", "local extra = 5" }

check("default label: unicode keycaps, accept + dismiss", accept, {
  { "⇥", "NeocursorKeycap" }, { " accept", "NeocursorLabel" }, { " · ", "NeocursorLabel" },
  { "⎋", "NeocursorKeycap" }, { " dismiss", "NeocursorLabel" },
})
check("jump verb", flat(ui.label("jump", ui.normalize(nil))), "⇥ jump · ⎋ dismiss")
check("prediction label", ui.label("prediction", ui.normalize(nil), "L42"),
  { { "⇥", "NeocursorKeycap" }, { " → L42", "NeocursorLabel" } })
check("nerd preset", flat(ui.label("accept", ui.normalize({ keycaps = "nerd" }))), "󰌒 accept · 󱊷 dismiss")
check("text preset", flat(ui.label("jump", ui.normalize({ keycaps = "text" }))), "Tab jump · Esc dismiss")
check("table keycaps", flat(ui.label("accept", ui.normalize({ keycaps = { tab = "[T]", esc = "[E]" } }))),
  "[T] accept · [E] dismiss")
check("no neocursor prefix or brackets", flat(accept):find("neocursor") == nil and flat(accept):find("⟪") == nil, true)

local d = ui.normalize(nil)
check("default elevation", d.elevation, { type = "inline", pos = "end" })
check("default identifier", d.identifier, { enabled = true, underline = false })
check("window defaults", ui.normalize({ elevation = { type = "window" } }).elevation,
  { type = "window", offset = 2 })
check("identifier = false disables it", ui.normalize({ identifier = false }).identifier,
  { enabled = false, underline = false })
check("bad pos fails loudly", pcall(ui.normalize, { elevation = { pos = "middle" } }), false)
check("bad type fails loudly", pcall(ui.normalize, { elevation = { type = "popup" } }), false)
check("bad underline fails loudly", pcall(ui.normalize, { identifier = { underline = "wavy" } }), false)
check("unknown hl key fails loudly", pcall(ui.normalize, { hl = { lable = "Comment" } }), false)

local function inline(pos)
  return ui.normalize({ elevation = { type = "inline", pos = pos } })
end

reseed()
preview.diff(bufnr, 0, old2, new2, accept, inline("end"))
local body_ref = body()
check("end: label at eol of the edit's first line", labels(), { { where = "eol", row = 0 } })
check("end: body struck the changed line", body_ref.struck, { 1 })
check("end: body adds the new lines", body_ref.added, { "local beta = 22", "local extra = 5" })

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local beta = 2", "local x = 0", "local y = 0" }, accept, inline("end"))
check("end: label row follows start0", labels(), { { where = "eol", row = 1 } })

reseed()
preview.diff(bufnr, 0, old2, new2, accept, inline("header"))
check("header: label is a virt_line above the first line", labels(), { { where = "above", row = 0, index = 1, of = 1 } })
check("header: body unchanged", body(), body_ref)

reseed()
preview.diff(bufnr, 0, old2, new2, accept, inline("footer"))
check("footer: label is the last line of the additions block", labels(),
  { { where = "below", row = 1, index = 3, of = 3 } })
check("footer: body unchanged", body(), body_ref)

reseed()
preview.diff(bufnr, 0, { "local alpha = 1", "local beta = 2", "local gamma = 3" },
  { "local alpha = 1", "local beta = 2" }, accept, inline("footer"))
check("footer without additions: own virt_lines mark below the region", labels(),
  { { where = "below", row = 2, index = 1, of = 1 } })

reseed()
preview.diff(bufnr, 1, {}, { "local new = 0" }, accept, inline("footer"))
check("footer on a pure insertion joins the inserted block", labels(),
  { { where = "above", row = 1, index = 2, of = 2 } })

reseed()
preview.diff(bufnr, 1, {}, { "local new = 0" }, accept, inline("header"))
check("header on a pure insertion leads the inserted block", labels(),
  { { where = "above", row = 1, index = 1, of = 2 } })

for _, pos in ipairs({ "end", "header", "footer" }) do
  reseed()
  preview.diff(bufnr, 0, old2, new2, nil, inline(pos))
  check(pos .. ": no label without chunks", labels(), {})
  check(pos .. ": body kept without the label", body(), body_ref)
end

check("identifier_hunk: one token swapped", ui.identifier_hunk("local beta = 2", "local gamma = 2"),
  { col = 6, end_col = 10, old = "beta", new = "gamma" })
check("identifier_hunk: two hunks", ui.identifier_hunk("local beta = 2", "local gamma = 3"), nil)
check("identifier_hunk: multi-token insertion", ui.identifier_hunk("f(x)", "f(x, y)"), nil)
check("identifier_hunk: pure insertion", ui.identifier_hunk("ab", "ab cd"), nil)
check("identifier_hunk: $ and _ are word characters", ui.identifier_hunk("$a_b + 1", "$c_d + 1"),
  { col = 0, end_col = 4, old = "$a_b", new = "$c_d" })

local function ident_marks()
  local old, new, line_hl, vlines = {}, {}, 0, 0
  for _, m in ipairs(marks()) do
    if m.d.hl_group == ui.groups.identifier_old then old[#old + 1] = { m.row, m.col, m.d.end_col } end
    if m.d.virt_text_pos == "inline" then
      new[#new + 1] = { m.row, m.col, m.d.virt_text[1][1], m.d.virt_text[1][2] }
    end
    if m.d.line_hl_group then line_hl = line_hl + 1 end
    if m.d.virt_lines then vlines = vlines + 1 end
  end
  return { old = old, new = new, line_hl = line_hl, vlines = vlines }
end

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 2" }, accept, inline("end"))
check("identifier: old token marked, new token inline after it, no tint, no virt_lines", ident_marks(), {
  old = { { 1, 6, 10 } }, new = { { 1, 10, "gamma", "NeocursorIdentifierNew" } }, line_hl = 0, vlines = 0,
})
check("identifier: label still follows elevation", labels(), { { where = "eol", row = 1 } })

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 2" }, accept, inline("footer"))
check("identifier: footer label below the line", labels(), { { where = "below", row = 1, index = 1, of = 1 } })

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 3" }, accept, inline("end"))
local m = ident_marks()
check("identifier: multi-hunk falls back to whole-line", { #m.old, #m.new, m.line_hl > 0, m.vlines > 0 },
  { 0, 0, true, true })

reseed()
preview.diff(bufnr, 1, { "local beta = 2", "local gamma = 3" }, { "local beta = 9", "local gamma = 3" }, accept,
  inline("end"))
m = ident_marks()
check("identifier: multi-line falls back to whole-line", { #m.old, #m.new, m.line_hl > 0 }, { 0, 0, true })

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 2" }, accept, ui.normalize({ identifier = { enabled = false } }))
m = ident_marks()
check("identifier.enabled=false: whole-line", { #m.old, #m.new, m.line_hl > 0, m.vlines > 0 }, { 0, 0, true, true })

local function get(name) return vim.api.nvim_get_hl(0, { name = name }) end
local dd = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })

ui.apply_hl(ui.normalize(nil))
check("identifier_old default links NeocursorDelete", get("NeocursorIdentifierOld").link, "NeocursorDelete")
check("identifier_new default links NeocursorAdd", get("NeocursorIdentifierNew").link, "NeocursorAdd")
check("delete default: DiffDelete colours + strikethrough",
  { get("NeocursorDelete").fg, get("NeocursorDelete").strikethrough }, { dd.fg, true })

for _, style in ipairs({ "undercurl", "underline", "underdouble" }) do
  ui.apply_hl(ui.normalize({ identifier = { underline = style } }))
  local h = get("NeocursorIdentifierOld")
  check("underline=" .. style .. " lands on NeocursorIdentifierOld",
    { h[style], h.sp, h.strikethrough, h.fg }, { true, dd.fg, true, dd.fg })
end

ui.apply_hl(ui.normalize({ hl = { label = "Comment", add = { fg = 0xff0000, bold = true }, keycap = { bg = 0x333333 } } }))
check("hl string override links", get("NeocursorLabel").link, "Comment")
check("hl table override is passed through", { get("NeocursorAdd").fg, get("NeocursorAdd").bold }, { 0xff0000, true })
check("keycap bg override", get("NeocursorKeycap").bg, 0x333333)
check("unset entries keep defaults", get("NeocursorFloat").link, "NormalFloat")
vim.cmd("doautocmd ColorScheme")
check("ColorScheme re-applies the last config", get("NeocursorLabel").link, "Comment")
ui.apply_hl(ui.normalize(nil))
check("defaults link DiagnosticHint", { get("NeocursorLabel").link, get("NeocursorKeycap").link },
  { "DiagnosticHint", "DiagnosticHint" })

local function window(extra)
  return ui.normalize({ elevation = vim.tbl_extend("force", { type = "window" }, extra or {}) })
end
local function float_lines(w)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end
local function float_marks(w)
  return vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(w), -1, 0, -1, { details = true })
end
local function float_label(w)
  for _, mk in ipairs(float_marks(w)) do
    local t = flat(mk[4].virt_text)
    if is_label(t) then return { row = mk[2], win_col = mk[4].virt_text_win_col, text = t } end
  end
end
local function leftcol(w)
  return vim.api.nvim_win_call(w, function() return vim.fn.winsaveview().leftcol end)
end
local function ellipses(w)
  local rows = {}
  for _, mk in ipairs(float_marks(w)) do
    if flat(mk[4].virt_text) == "…" then rows[#rows + 1] = { mk[2], mk[4].virt_text_win_col } end
  end
  return rows
end

reseed()
preview.diff(bufnr, 0, old2, new2, accept, window())
local fl = floats()
check("window: exactly one float", #fl, 1)
local fw = fl[1]
local fc = vim.api.nvim_win_get_config(fw)
check("window: float is non-focusable, relative to the window, zindex 50",
  { fc.focusable, fc.relative, fc.zindex, fc.win }, { false, "win", 50, vim.api.nvim_get_current_win() })
check("window: float holds old, new and an empty label row", float_lines(fw),
  { "local beta = 2", "local beta = 22", "local extra = 5", "" })
check("window: label pinned to the last row at window column 0", float_label(fw),
  { row = 3, win_col = 0, text = "⇥ accept · ⎋ dismiss" })
check("window: anchored beside the first changed line, one row up for the border",
  { fc.bufpos, fc.row, fc.col }, { { 1, 0 }, -1, #"local beta = 2" + 2 })
check("window: winhighlight", vim.wo[fw].winhighlight, "Normal:NeocursorFloat,FloatBorder:NeocursorFloatBorder")
check("window: default border is rounded when winborder is empty", fc.border[1], "╭")
check("window: real buffer gets no strike and no virt_lines", body(), { struck = {}, added = {} })
check("window: no label in the real buffer", labels(), {})
check("window: float is the one preview reports", preview.float_win(), fw)

preview.clear(bufnr)
check("window: clear closes the float", #floats(), 0)
check("window: float handle dropped on clear", preview.float_win(), nil)

reseed()
vim.o.winborder = "single"
preview.diff(bufnr, 0, old2, new2, accept, window())
check("window: winborder is honoured when set", vim.api.nvim_win_get_config(floats()[1]).border[1], "┌")
preview.diff(bufnr, 0, old2, new2, accept, window({ border = "double" }))
check("window: explicit border wins over winborder", vim.api.nvim_win_get_config(floats()[1]).border[1], "╔")
check("window: re-render replaces, never stacks", #floats(), 1)
vim.o.winborder = ""
preview.diff(bufnr, 0, old2, new2, accept, window({ border = "none" }))
check("window: no border keeps row 0", vim.api.nvim_win_get_config(floats()[1]).row, 0)

reseed()
preview.diff(bufnr, 0, old2, new2, nil, window())
check("window: show_hints off drops the label row", float_lines(floats()[1]),
  { "local beta = 2", "local beta = 22", "local extra = 5" })
check("window: show_hints off leaves no label mark", float_label(floats()[1]), nil)

reseed({ "x", "y" })
local long = string.rep("w", 200)
preview.diff(bufnr, 0, { "x" }, { long }, accept, window())
local winw = vim.api.nvim_win_get_width(0)
local lc = vim.api.nvim_win_get_config(floats()[1])
check("window: width clamped to the space left of the window edge", lc.width, winw - lc.col - 2)
preview.diff(bufnr, 0, { "x" }, { long }, accept, window({ max_width = 120 }))
check("window: max_width overrides the clamp", vim.api.nvim_win_get_config(floats()[1]).width, 120)

reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 2" }, accept, window())
local iw = floats()[1]
local fbuf = vim.api.nvim_win_get_buf(iw)
local inner = {}
for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, -1, 0, -1, { details = true })) do
  if mk[4].hl_group == "NeocursorIdentifierOld" or mk[4].hl_group == "NeocursorIdentifierNew" then
    inner[#inner + 1] = { mk[2], mk[3], mk[4].end_col, mk[4].hl_group }
  end
end
check("window + identifier: token marks inside the float", inner,
  { { 0, 6, 10, "NeocursorIdentifierOld" }, { 1, 6, 11, "NeocursorIdentifierNew" } })
check("window + identifier: only the old-token mark on the real line", ident_marks(), {
  old = { { 1, 6, 10 } }, new = {}, line_hl = 0, vlines = 0,
})
check("window + identifier: float sits offset past the real line", vim.api.nvim_win_get_config(iw).col,
  #"local beta = 2" + 2)

local prefix = "local r = f(" .. string.rep("arg, ", 6)
local tail = ", more, stuff)"
reseed({ prefix .. "oldName" .. tail, "after" })
preview.diff(bufnr, 0, { prefix .. "oldName" .. tail }, { prefix .. "newName" .. tail }, accept, window())
local nf = floats()[1]
local nfc = vim.api.nvim_win_get_config(nf)
local lcol = leftcol(nf)
local token_at = #prefix
check("window, line does not fit: width still clamped to the window edge", nfc.width,
  vim.api.nvim_win_get_width(0) - nfc.col - 2)
check("window, line does not fit: view scrolled right", lcol > 0, true)
check("window, line does not fit: changed identifier inside the view",
  token_at >= lcol and token_at + #"newName" <= lcol + nfc.width, true)
check("window, line does not fit: a few cells of context before the identifier", token_at - lcol, 4)
check("window, line does not fit: dim ellipsis pinned on both scrolled rows", ellipses(nf), { { 0, 0 }, { 1, 0 } })
check("window, line does not fit: label row stays pinned", float_label(nf),
  { row = 2, win_col = 0, text = "⇥ accept · ⎋ dismiss" })

reseed()
preview.diff(bufnr, 0, old2, new2, accept, window())
check("window, line fits: no horizontal scroll", { leftcol(floats()[1]), ellipses(floats()[1]) }, { 0, {} })

vim.bo[bufnr].filetype = "lua"
reseed()
preview.diff(bufnr, 1, { "local beta = 2" }, { "local gamma = 2" }, accept, window())
local tsb = vim.api.nvim_win_get_buf(floats()[1])
check("window: treesitter highlights the float in the source language",
  vim.treesitter.highlighter.active[tsb] ~= nil and vim.treesitter.get_parser(tsb):lang(), "lua")
local prio = {}
for _, mk in ipairs(float_marks(floats()[1])) do
  if mk[4].hl_group == "NeocursorIdentifierOld" or mk[4].hl_group == "NeocursorIdentifierNew" then
    prio[#prio + 1] = mk[4].priority
  end
end
check("window: identifier marks sit above treesitter (priority 200)", prio, { 200, 200 })
vim.bo[bufnr].filetype = ""

local many = {}
for i = 1, 200 do many[i] = "line " .. i end
reseed(many)
preview.diff(bufnr, 4, { "line 5" }, { "line 5 changed", "line 5b" }, accept, window())
local sw = floats()[1]
local function hidden() return vim.api.nvim_win_get_config(sw).hide end
check("window: visible while the anchor is on screen", hidden(), false)
vim.cmd("normal! 100\5")
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(vim.api.nvim_get_current_win()) })
check("window: hidden once the anchor scrolls out of view", hidden(), true)
vim.cmd("normal! gg")
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(vim.api.nvim_get_current_win()) })
check("window: shown again when the anchor is back", hidden(), false)
preview.clear(bufnr)
check("window: scrolled float closes on clear", #floats(), 0)

reseed()
preview.prediction(bufnr, 2, ui.label("prediction", ui.normalize(nil), "L3"))
local pm = vim.api.nvim_buf_get_extmarks(bufnr, preview.prediction_namespace(), 0, -1, { details = true })
check("prediction pill: one eol mark with the composed label", { #pm, pm[1][2], flat(pm[1][4].virt_text) },
  { 1, 2, "  ⇥ → L3" })

io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
vim.cmd(failed == 0 and "qall!" or "cquit!")
