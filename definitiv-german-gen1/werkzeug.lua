-- Gemeinsame Helfer aller Bausteine.  Gibt W zurueck (oder nil, wenn die deutsche ROM fehlt).
--   W.R          Rezept (alle Bausteine zusammen)
--   W.T(teile)   Text aus dem Rezept: Literal (Steuerzeichen, Ziffern) oder {Adresse, Anzahl Bytes} der DE-ROM
--   W.apply      Abschnitt anwenden, Fehler je Eintrag zaehlen (landen im Bericht)
--   W.remapped   zeichnet mit umgelegten Koordinaten (nur innerhalb eines Aufrufs)
--   W.menuHaken  Liste von function(items, opts) -- laufen in einem gemeinsamen Menu.new-Wrapper
return function(mod)
  local GameVersion = require("src.core.GameVersion")
  local log = mod.log
  local ver = GameVersion.get()
  -- Regel: jede Edition holt alles nur aus ihrem deutschen Gegenstueck
  local IMPORT = { red = "rot_de", blue = "blau_de", yellow = "gelb_de" }
  local importId = IMPORT[ver]
  if not importId then
    log:warn("Deutsch Gen 1: unbekannte Edition %s", tostring(ver))
    return nil
  end
  local info, ierr = mod.imports:info(importId)
  if not info then
    log:warn("Deutsch Gen 1: deutsche ROM fuer %s fehlt (%s)", ver, tostring(ierr))
    return nil
  end
  local rom, rerr = mod.imports:read(importId, 0, info.size)
  if not rom then
    log:warn("Deutsch Gen 1: ROM nicht lesbar: %s", tostring(rerr))
    return nil
  end

  local W = { mod = mod, log = log, ver = ver, rom = rom, info = info, R = {}, menuHaken = {} }
  local byte, concat = string.byte, table.concat

  -- ------------------------------------------------------------ Rezepte (ein Teil je Baustein)
  W.ladeRezept = function(baustein)
    local name = "rezept_" .. ver .. "_" .. baustein .. ".lua"
    local src = mod:read(name)
    if not src then return {} end
    local chunk, cerr = (loadstring or load)(src, "@" .. name)
    if not chunk then
      log:warn("Deutsch Gen 1: Rezept fehlerhaft (%s): %s", name, tostring(cerr))
      return {}
    end
    local teil = chunk() or {}
    for k, v in pairs(teil) do W.R[k] = v end
    return teil
  end

  -- ------------------------------------------------------------ Text aus der DE-ROM
  -- W.CM wird von zeichen.lua gesetzt (Zeichentabelle + Sonderzeichen-Woerter der DE-ROM)
  W.CM = {}
  W.T = function(parts)
    local out, CM = {}, W.CM
    for i = 1, #parts do
      local p = parts[i]
      if type(p) == "string" then
        out[#out + 1] = p
      else
        for k = p[1] + 1, p[1] + p[2] do out[#out + 1] = CM[byte(rom, k)] end
      end
    end
    return concat(out)
  end

  -- ------------------------------------------------------------ Abschnitte anwenden, zaehlen
  local counts, failed, firstErr = {}, {}, {}
  W.apply = function(section, tbl, fn)
    local n, f = 0, 0
    for k, v in pairs(tbl or {}) do
      local ok, e = pcall(fn, k, v)
      if ok then n = n + 1 else
        f = f + 1
        if not firstErr[section] then firstErr[section] = tostring(k) .. ": " .. tostring(e) end
      end
    end
    counts[section], failed[section] = n, f
  end

  -- ------------------------------------------------------------ Zeichnen mit umgelegten Koordinaten
  local Font = require("src.render.Font")
  W.remapped = function(rules, fn, ...)
    local fd, fb, fc = Font.draw, Font.drawBox, Font.drawCode
    if rules.text then
      Font.draw = function(t, x, y, ...)
        local nx, ny, nt = rules.text(t, x, y)
        return fd(nt or t, nx, ny, ...)
      end
    end
    if rules.box then
      Font.drawBox = function(x, y, w, h, ...) x, y, w, h = rules.box(x, y, w, h); return fb(x, y, w, h, ...) end
    end
    if rules.code then
      Font.drawCode = function(c, x, y, ...) x, y = rules.code(c, x, y); return fc(c, x, y, ...) end
    end
    local ok, e = pcall(fn, ...)
    Font.draw, Font.drawBox, Font.drawCode = fd, fb, fc
    if not ok then error(e, 0) end
    return e
  end

  -- ------------------------------------------------------------ ein gemeinsamer Menu.new-Wrapper
  -- (ruft immer das Engine-Original; Bausteine haengen ihre Haken an W.menuHaken)
  pcall(function()
    local Menu = require("src.ui.Menu")
    Menu._deutschNew = Menu._deutschNew or Menu.new
    Menu.new = function(game, items, opts, ...)
      for _, f in ipairs(W.menuHaken) do f(items, opts) end
      return Menu._deutschNew(game, items, opts, ...)
    end
  end)

  -- ------------------------------------------------------------ Bausteine
  W.baustein = function(name)
    W.ladeRezept(name)
    local src = mod:read(name .. ".lua")
    local fn, err = (loadstring or load)(src or "", "@" .. name .. ".lua")
    if not fn then
      log:warn("Deutsch Gen 1: %s fehlerhaft: %s", name, tostring(err))
      return
    end
    local ok, e = pcall(function() fn()(W) end)
    if not ok then log:warn("Deutsch Gen 1: %s: %s", name, tostring(e)) end
  end

  W.bericht = function()
    for section, n in pairs(counts) do
      log:info("Deutsch Gen 1 [%s] %s: %d uebernommen, %d abgelehnt%s", ver, section, n,
        failed[section] or 0, firstErr[section] and (" (z.B. " .. firstErr[section] .. ")") or "")
    end
  end
  W.zaehler = function() return counts, failed, firstErr end

  return W
end
