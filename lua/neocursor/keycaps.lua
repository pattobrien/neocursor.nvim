local M = {}

M.presets = {
  unicode = { tab = "⇥", esc = "⎋" },
  nerd = { tab = "󰌒", esc = "󱊷" },
  text = { tab = "Tab", esc = "Esc" },
}

function M.normalize(v)
  if type(v) == "table" then
    return { tab = v.tab or M.presets.unicode.tab, esc = v.esc or M.presets.unicode.esc }
  end
  local preset = M.presets[v or "unicode"] or M.presets.unicode
  return { tab = preset.tab, esc = preset.esc }
end

return M
