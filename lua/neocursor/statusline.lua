local keycaps = require("neocursor.keycaps")

local M = {}

function M.normalize(v)
  v = v or {}
  local show = v.show or {}
  return {
    keycaps = keycaps.normalize(v.keycaps),
    show = {
      edit = show.edit ~= false,
      prediction = show.prediction ~= false,
      request = show.request ~= false,
    },
  }
end

local function target(tab, p)
  if p.path then return ("%s → %s:%d"):format(tab, p.path, p.line) end
  return ("%s → L%d"):format(tab, p.line)
end

function M.render(status, cfg)
  cfg = cfg or M.normalize()
  local tab, show = cfg.keycaps.tab, cfg.show
  local s, p = status.suggestion, status.prediction
  local parts = {}
  if s then
    if show.edit then
      parts[#parts + 1] = s.at_cursor and (tab .. " accept") or ("%s jump L%d"):format(tab, s.line)
    end
  elseif p and show.prediction then
    parts[#parts + 1] = target(tab, p)
  end
  if show.request then
    if status.state == "pending" then
      parts[#parts + 1] = "…"
    elseif status.state == "disabled" then
      parts[#parts + 1] = "off"
    end
  end
  return table.concat(parts, "  ")
end

function M.component()
  local nc = require("neocursor")
  return {
    function() return nc.statusline() end,
    cond = function() return nc.statusline() ~= "" end,
  }
end

return M
