local keycaps = require("neocursor.keycaps")

local M = {}

M.groups = {
  label = "NeocursorLabel",
  keycap = "NeocursorKeycap",
  delete = "NeocursorDelete",
  delete_line = "NeocursorDeleteLine",
  add = "NeocursorAdd",
  identifier_old = "NeocursorIdentifierOld",
  identifier_new = "NeocursorIdentifierNew",
  float = "NeocursorFloat",
  border = "NeocursorFloatBorder",
  title = "NeocursorFloatTitle",
}

local HL_DEFAULTS = {
  label = "DiagnosticHint",
  keycap = "DiagnosticHint",
  delete_line = "DiffDelete",
  add = "DiffAdd",
  identifier_old = "NeocursorDelete",
  identifier_new = "NeocursorAdd",
  float = "NormalFloat",
  border = "FloatBorder",
  title = "FloatTitle",
}

local HL_ORDER = {
  "label", "keycap", "delete", "delete_line", "add",
  "identifier_old", "identifier_new", "float", "border", "title",
}

local POSITIONS = { ["end"] = true, header = true, footer = true }

M.underlines = {
  underline = true, undercurl = true, underdotted = true, underdashed = true, underdouble = true,
}

local function elevation(e)
  e = e or {}
  if type(e) ~= "table" then
    error("neocursor: ui.elevation must be a table, got " .. vim.inspect(e))
  end
  local kind = e.type or "inline"
  if kind == "window" then
    return { type = "window", border = e.border, max_width = e.max_width, offset = e.offset or 2 }
  end
  if kind ~= "inline" then
    error("neocursor: ui.elevation.type must be \"inline\" or \"window\", got " .. vim.inspect(kind))
  end
  local pos = e.pos or "end"
  if not POSITIONS[pos] then
    error("neocursor: ui.elevation.pos must be \"end\", \"header\" or \"footer\", got " .. vim.inspect(pos))
  end
  return { type = "inline", pos = pos }
end

local function identifier(v)
  if v == false then return { enabled = false, underline = false } end
  v = v or {}
  local underline = v.underline or false
  if underline ~= false and not M.underlines[underline] then
    error("neocursor: ui.identifier.underline must be false or one of underline, undercurl, "
      .. "underdotted, underdashed, underdouble, got " .. vim.inspect(underline))
  end
  return { enabled = v.enabled ~= false, underline = underline }
end

function M.normalize(o)
  o = o or {}
  local hl = vim.deepcopy(HL_DEFAULTS)
  for k, v in pairs(o.hl or {}) do
    if not M.groups[k] then error("neocursor: unknown ui.hl key " .. vim.inspect(k)) end
    hl[k] = v
  end
  return {
    elevation = elevation(o.elevation),
    keycaps = keycaps.normalize(o.keycaps),
    identifier = identifier(o.identifier),
    hl = hl,
  }
end

local function resolve(spec)
  if type(spec) == "string" then
    return vim.api.nvim_get_hl(0, { name = spec, link = false })
  end
  return vim.deepcopy(spec)
end

local function hl_value(key, cfg)
  local spec = cfg.hl[key]
  if key == "delete" and spec == nil then
    local del = resolve("DiffDelete")
    del.strikethrough = true
    return del
  end
  if key == "identifier_old" and cfg.identifier.underline then
    local v = resolve(spec)
    v[cfg.identifier.underline] = true
    v.sp = v.sp or resolve("DiffDelete").fg
    return v
  end
  if type(spec) == "string" then return { link = spec } end
  return vim.deepcopy(spec)
end

local applied = nil

function M.apply_hl(cfg)
  applied = cfg
  for _, key in ipairs(HL_ORDER) do
    vim.api.nvim_set_hl(0, M.groups[key], hl_value(key, cfg))
  end
end

function M.setup(o)
  local cfg = M.normalize(o)
  M.apply_hl(cfg)
  return cfg
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("neocursor_ui", { clear = true }),
  callback = function() M.apply_hl(applied or M.normalize(nil)) end,
  desc = "neocursor highlights",
})

local SEP = " · "

function M.label(kind, cfg, target)
  cfg = cfg or M.normalize(nil)
  local kc, g = cfg.keycaps, M.groups
  if kind == "prediction" then
    return { { kc.tab, g.keycap }, { " → " .. target, g.label } }
  end
  if kind ~= "accept" and kind ~= "jump" then
    error("neocursor: unknown label kind " .. vim.inspect(kind))
  end
  return {
    { kc.tab, g.keycap }, { " " .. kind, g.label }, { SEP, g.label },
    { kc.esc, g.keycap }, { " dismiss", g.label },
  }
end

local function tokens(line)
  local out, i = {}, 1
  while i <= #line do
    local s, e = line:find("^[%w_$]+", i)
    if not s then s, e = line:find("^[^%w_$]+", i) end
    out[#out + 1] = line:sub(s, e)
    i = e + 1
  end
  return out
end

local function byte_start(toks, idx)
  local n = 0
  for i = 1, idx - 1 do n = n + #toks[i] end
  return n
end

function M.identifier_hunk(old_line, new_line)
  local a, b = tokens(old_line), tokens(new_line)
  local hunks = vim.text.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n",
    { result_type = "indices" })
  if #hunks ~= 1 then return nil end
  local sa, ca, sb, cb = unpack(hunks[1])
  if ca ~= 1 or cb ~= 1 then return nil end
  local col = byte_start(a, sa)
  return { col = col, end_col = col + #a[sa], old = a[sa], new = b[sb] }
end

return M
