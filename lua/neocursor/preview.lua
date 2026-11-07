-- Ghost-text + diff renderer for neocursor.nvim.
--
-- Inline-suggestion technique adapted from supermaven-nvim / copilot.lua (NOTICE):
-- one extmark, first line as `virt_text`, rest as `virt_lines`.
--
-- The diff renderer uses Neovim's built-in `vim.text.diff` to line-diff the region
-- being replaced against the suggestion, then paints deletions in place (struck
-- through, DiffDelete tint) and additions as DiffAdd `virt_lines` beside them.

local ui = require("neocursor.ui")

local M = {}

local ns = vim.api.nvim_create_namespace("neocursor")
-- own namespace so suggestion clears never kill a pending prediction hint
local ns_pred = vim.api.nvim_create_namespace("neocursor_pred")
local ns_float = vim.api.nvim_create_namespace("neocursor_float")
local HL = "Comment"
local G = ui.groups
local HAS_INLINE = vim.fn.has("nvim-0.10") == 1
local PAD = { "  " }

ui.apply_hl(ui.normalize(nil))

local float = nil

function M.namespace()
  return ns
end

function M.prediction_namespace()
  return ns_pred
end

function M.float_win()
  return float and float.win
end

local function close_float()
  if not float then return end
  local f = float
  float = nil
  pcall(vim.api.nvim_del_augroup_by_id, f.augroup)
  pcall(vim.api.nvim_win_close, f.win, true)
end

local function resolve_buf(bufnr)
  if bufnr == nil or bufnr == 0 then return vim.api.nvim_get_current_buf() end
  return bufnr
end

function M.clear(bufnr)
  bufnr = resolve_buf(bufnr)
  -- diff mode paints many extmarks, so clear the whole namespace, not one id
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  if float and float.bufnr == bufnr then close_float() end
end

local function with_pad(chunks)
  local out = { PAD }
  vim.list_extend(out, chunks)
  return out
end

function M.prediction(bufnr, row0, chunks)
  M.clear_prediction(bufnr)
  vim.api.nvim_buf_set_extmark(bufnr, ns_pred, row0, 0, {
    virt_text = with_pad(chunks),
    virt_text_pos = "eol",
  })
end

function M.clear_prediction(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr or 0, ns_pred, 0, -1)
end

---@return string first, table rest  -- rest = virt_lines chunks
local function split_first(text)
  local lines = vim.split(text, "\n", { plain = true })
  local first = table.remove(lines, 1) or ""
  local rest = {}
  for _, l in ipairs(lines) do
    rest[#rest + 1] = { { l == "" and " " or l, HL } }
  end
  return first, rest
end

--- Inline ghost text anchored at the cursor (clean append case).
function M.inline(bufnr, row0, col0, ghost)
  M.clear(bufnr)
  local first, rest = split_first(ghost)
  local opts = { hl_mode = "combine" }
  if first ~= "" then
    opts.virt_text = { { first, HL } }
    opts.virt_text_pos = (HAS_INLINE and first:find("%c") == nil) and "inline" or "eol"
  end
  if #rest > 0 then
    opts.virt_lines = rest
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, row0, col0, opts)
end

local function joined(lines)
  return #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
end

local function line_hunks(old_lines, new_lines)
  return vim.text.diff(joined(old_lines), joined(new_lines), { result_type = "indices" }) or {}
end

local function identifier_of(old_lines, new_lines, cfg)
  if not cfg.identifier.enabled or #old_lines ~= 1 or #new_lines ~= 1 then return nil end
  return ui.identifier_hunk(old_lines[1], new_lines[1])
end

local function paint_identifier(bufnr, row0, id, with_new)
  vim.api.nvim_buf_set_extmark(bufnr, ns, row0, id.col, {
    end_row = row0,
    end_col = id.end_col,
    hl_group = G.identifier_old,
  })
  if not with_new then return end
  vim.api.nvim_buf_set_extmark(bufnr, ns, row0, id.end_col, {
    virt_text = { { id.new, G.identifier_new } },
    virt_text_pos = "inline",
  })
end

local function paint_lines(bufnr, start0, old_lines, new_lines, nbuf)
  local blocks = {}
  for _, h in ipairs(line_hunks(old_lines, new_lines)) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]

    for i = 0, ca - 1 do
      local lnum = start0 + (sa - 1) + i
      if lnum >= 0 and lnum < nbuf then
        local content = old_lines[sa + i] or ""
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
          end_row = lnum,
          end_col = #content,
          hl_group = G.delete,
          line_hl_group = G.delete_line,
          hl_mode = "combine",
        })
      end
    end

    if cb > 0 then
      local vlines = {}
      for i = 0, cb - 1 do
        local l = new_lines[sb + i] or ""
        vlines[#vlines + 1] = { { l == "" and " " or l, G.add } }
      end
      local anchor, above
      if ca > 0 then
        anchor, above = start0 + (sa - 1) + (ca - 1), false -- below last deleted line
      elseif sa == 0 then
        anchor, above = start0, true -- pure insert before region start
      else
        anchor, above = start0 + (sa - 1), false -- pure insert after line sa
      end
      anchor = math.max(0, math.min(anchor, nbuf - 1))
      blocks[#blocks + 1] = { anchor = anchor, above = above, lines = vlines }
    end
  end
  return blocks
end

local function visual_key(row, above)
  return row * 2 + (above and 0 or 1)
end

local function place_label(blocks, label, pos, first0, last0, nbuf)
  if pos == "end" then return { row = first0, label = label } end
  if pos == "header" then
    for _, b in ipairs(blocks) do
      if b.anchor == first0 and b.above then
        table.insert(b.lines, 1, label)
        return nil
      end
    end
    blocks[#blocks + 1] = { anchor = first0, above = true, lines = { label } }
    return nil
  end
  local bottom = nil
  for _, b in ipairs(blocks) do
    if not bottom or visual_key(b.anchor, b.above) > visual_key(bottom.anchor, bottom.above) then
      bottom = b
    end
  end
  if bottom and visual_key(bottom.anchor, bottom.above) >= visual_key(last0, false) then
    bottom.lines[#bottom.lines + 1] = label
  else
    blocks[#blocks + 1] = { anchor = math.max(0, math.min(last0, nbuf - 1)), above = false, lines = { label } }
  end
  return nil
end

local function clamp(row, nbuf)
  return math.max(0, math.min(row, nbuf - 1))
end

local function render_inline(bufnr, start0, old_lines, new_lines, label, cfg, id, nbuf)
  local blocks = id and {} or paint_lines(bufnr, start0, old_lines, new_lines, nbuf)
  local eol = nil
  if label then
    local first0 = clamp(start0, nbuf)
    local last0 = math.min(start0 + #old_lines - 1, nbuf - 1)
    eol = place_label(blocks, label, cfg.elevation.pos, first0, last0, nbuf)
  end
  for _, b in ipairs(blocks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, b.anchor, 0, {
      virt_lines = b.lines,
      virt_lines_above = b.above,
    })
  end
  if eol then
    vim.api.nvim_buf_set_extmark(bufnr, ns, eol.row, 0, {
      virt_text = with_pad(eol.label),
      virt_text_pos = "eol",
    })
  end
end

local function unified_rows(old_lines, new_lines)
  local rows, a = {}, 1
  local function ctx(upto)
    while a <= upto do
      rows[#rows + 1] = { text = old_lines[a], kind = "ctx", old = a }
      a = a + 1
    end
  end
  for _, h in ipairs(line_hunks(old_lines, new_lines)) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    ctx(ca > 0 and sa - 1 or sa)
    for i = 0, ca - 1 do
      rows[#rows + 1] = { text = old_lines[sa + i], kind = "del", old = sa + i }
    end
    a = math.max(a, sa + ca)
    for i = 0, cb - 1 do
      rows[#rows + 1] = { text = new_lines[sb + i], kind = "add", old = (ca > 0 and sa + ca or sa + 1) }
    end
  end
  while rows[1] and rows[1].kind == "ctx" do table.remove(rows, 1) end
  while rows[#rows] and rows[#rows].kind == "ctx" do table.remove(rows) end
  return rows, rows[1] and rows[1].old - 1 or 0
end

local function window_for(bufnr)
  if vim.api.nvim_win_get_buf(0) == bufnr then return vim.api.nvim_get_current_win() end
  local win = vim.fn.bufwinid(bufnr)
  return win ~= -1 and win or nil
end

local function border_of(cfg)
  local b = cfg.elevation.border
  if b == nil then b = vim.o.winborder ~= "" and vim.o.winborder or "rounded" end
  return b, not (b == "none" or b == "")
end

local function sync_float_visibility()
  local f = float
  if not (f and vim.api.nvim_win_is_valid(f.win) and vim.api.nvim_win_is_valid(f.anchor_win)) then return end
  local top = vim.fn.line("w0", f.anchor_win)
  local bot = vim.fn.line("w$", f.anchor_win)
  local hide = f.row0 + 1 < top or f.row0 + 1 > bot
  if hide ~= f.hidden then
    f.hidden = hide
    vim.api.nvim_win_set_config(f.win, { hide = hide })
  end
end

local LEAD = 4

local function focus_of(rows, id)
  local del, add
  for i, r in ipairs(rows) do
    if r.kind == "del" and not del then del = i end
    if r.kind == "add" and not add then add = i end
  end
  if id then return add, id.col end
  if not (del and add) then return del or add or 1, 0 end
  local a, b, p = rows[del].text, rows[add].text, 0
  while p < #a and p < #b and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
  return add, p
end

local function start_highlighter(fbuf, bufnr)
  local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
  if lang and vim.treesitter.language.add(lang) then vim.treesitter.start(fbuf, lang) end
end

local function render_window(bufnr, start0, old_lines, new_lines, label, cfg, id, nbuf)
  local win = window_for(bufnr)
  if not win then return end

  local rows, first_old
  if id then
    rows = { { text = old_lines[1], kind = "del" }, { text = new_lines[1], kind = "add" } }
    first_old = 0
  else
    rows, first_old = unified_rows(old_lines, new_lines)
  end
  if #rows == 0 and not label then return end
  local row0 = clamp(start0 + first_old, nbuf)

  local text, text_w = {}, 0
  for i, r in ipairs(rows) do
    text[i] = r.text
    text_w = math.max(text_w, vim.fn.strdisplaywidth(r.text))
  end
  local content = math.max(text_w, 1)
  if label then
    local s = ""
    for _, c in ipairs(label) do s = s .. c[1] end
    text[#text + 1] = ""
    content = math.max(content, vim.fn.strdisplaywidth(s))
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, text)
  start_highlighter(fbuf, bufnr)
  for i, r in ipairs(rows) do
    local l = i - 1
    if r.kind == "del" then
      if id then
        vim.api.nvim_buf_set_extmark(fbuf, ns_float, l, id.col,
          { end_row = l, end_col = id.end_col, hl_group = G.identifier_old, priority = 200 })
      else
        vim.api.nvim_buf_set_extmark(fbuf, ns_float, l, 0,
          { end_row = l, end_col = #r.text, hl_group = G.delete, line_hl_group = G.delete_line, priority = 200 })
      end
    elseif r.kind == "add" then
      if id then
        vim.api.nvim_buf_set_extmark(fbuf, ns_float, l, id.col,
          { end_row = l, end_col = id.col + #id.new, hl_group = G.identifier_new, priority = 200 })
      else
        vim.api.nvim_buf_set_extmark(fbuf, ns_float, l, 0,
          { end_row = l, end_col = #r.text, hl_group = G.add, line_hl_group = G.add, priority = 200 })
      end
    end
  end
  if label then
    vim.api.nvim_buf_set_extmark(fbuf, ns_float, #text - 1, 0, { virt_text = label, virt_text_win_col = 0 })
  end

  local anchor_text = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  local col = vim.fn.strdisplaywidth(anchor_text) + cfg.elevation.offset

  local border, framed = border_of(cfg)
  local frame = framed and 2 or 0
  local info = vim.fn.getwininfo(win)[1]
  local width
  if cfg.elevation.max_width then
    width = math.min(content, cfg.elevation.max_width)
  else
    width = math.min(content, info.width - info.textoff - col - frame)
  end
  width = math.max(width, 1)

  local leftcol, focus_row, focus_byte = 0, focus_of(rows, id)
  if text_w > width and rows[focus_row] then
    local fdisp = vim.fn.strdisplaywidth(rows[focus_row].text:sub(1, focus_byte))
    leftcol = math.max(0, math.min(text_w - width, fdisp - LEAD))
  end
  if leftcol > 0 then
    for i, r in ipairs(rows) do
      if vim.fn.strdisplaywidth(r.text) > leftcol then
        vim.api.nvim_buf_set_extmark(fbuf, ns_float, i - 1, 0,
          { virt_text = { { "…", "NonText" } }, virt_text_win_col = 0, priority = 300 })
      end
    end
  end

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative = "win",
    win = win,
    bufpos = { row0, 0 },
    row = framed and -1 or 0,
    col = col,
    width = width,
    height = #text,
    focusable = false,
    noautocmd = true,
    style = "minimal",
    zindex = 50,
    border = border,
  })
  vim.wo[fwin].winhighlight = ("Normal:%s,FloatBorder:%s"):format(G.float, G.border)
  vim.wo[fwin].wrap = false
  vim.wo[fwin].sidescrolloff = 0
  if leftcol > 0 then
    vim.api.nvim_win_call(fwin, function()
      vim.api.nvim_win_set_cursor(fwin, { focus_row, focus_byte })
      vim.fn.winrestview({ leftcol = leftcol })
    end)
  end

  local augroup = vim.api.nvim_create_augroup("neocursor_float", { clear = true })
  float = { win = fwin, buf = fbuf, bufnr = bufnr, anchor_win = win, row0 = row0, augroup = augroup, hidden = false }
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = sync_float_visibility,
  })
  sync_float_visibility()
end

--- Diff overlay for edits that replace existing lines (overrides / rewrites).
--- old_lines = current content of [start0, start0+#old_lines); new_lines = suggestion.
function M.diff(bufnr, start0, old_lines, new_lines, label, cfg)
  M.clear(bufnr)
  cfg = cfg or ui.normalize(nil)
  local nbuf = vim.api.nvim_buf_line_count(bufnr)
  local id = identifier_of(old_lines, new_lines, cfg)
  local windowed = cfg.elevation.type == "window"
  if id then paint_identifier(bufnr, clamp(start0, nbuf), id, not windowed) end
  if windowed then
    render_window(bufnr, start0, old_lines, new_lines, label, cfg, id, nbuf)
  else
    render_inline(bufnr, start0, old_lines, new_lines, label, cfg, id, nbuf)
  end
end

return M
