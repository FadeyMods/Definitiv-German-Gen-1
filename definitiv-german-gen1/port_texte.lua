-- Feste Texte des Ports, mit der deutschen Fassung aus der DE-ROM:
--   * Uebersetzungs-Katalog des Ports (mod.content.strings: Schluessel = englischer Text im Port-Code)
--   * Menues, die der Port ohne Katalog beschriftet (Titel-, Start-, Laden-, Optionsmenue, Link-Kabel-Hilfe)
--   * Namenseingabe (DE-Tastatur), Spielautomat, Pokedex-Satzende
return function(W)
  local mod, R, T, rom, remapped = W.mod, W.R, W.T, W.rom, W.remapped
  local byte = string.byte

  W.apply("strings", R.strings, function(k, v) mod.content.strings:override(k, T(v)) end)

  -- Titelmenue (DE-ROM: "OPTIONEN") und Startmenue (Port-QUIT -> "BEENDEN")
  local function relabel(hook, map)
    if not map then return end
    local m = {}
    for k, v in pairs(map) do m[k] = T(v) end
    pcall(function()
      mod.hooks:wrap(hook, function(nxt, game, items)
        local out = nxt(game, items)
        for _, it in ipairs(out or {}) do
          local de = W.nachText(m, it.label)
          if de then it.label = de end
        end
        return out
      end)
    end)
  end
  relabel("ui.title_menu.items", R.titleMenu)
  relabel("ui.start_menu.items", R.startMenu)

  -- Menues mit festem englischem Eintrag (Link-Kabel-Hilfe im Pokemon-Center: HOW TO LINK, COLOSSEUM,
  -- TRADE CENTER, STOP READING -> DE-ROM HowToLinkText).  Der Port beschriftet sie ohne Katalog.
  if R.menuLabels then
    local m = {}
    for en, teile in pairs(R.menuLabels) do m[en] = T(teile) end
    W.menuHaken[#W.menuHaken + 1] = function(items)
      if type(items) ~= "table" then return end
      for _, it in ipairs(items) do
        local de = type(it) == "table" and W.nachText(m, it.label)
        if de then it.label = de end
      end
    end
  end

  -- Laden: dritter Eintrag heisst in der DE-ROM "TSCHUESS!"
  if R.shopQuit then
    local shopQ = {}
    for i, v in ipairs(R.shopQuit) do shopQ[i] = T(v) end
    W.menuHaken[#W.menuHaken + 1] = function(items)
      if type(items) == "table" and #items == 3 and items[1].label == shopQ[1]
          and items[2].label == shopQ[2] and items[3].label == shopQ[3] then
        items[3].label = shopQ[4]
      end
    end
  end

  -- Optionsmenue: Gruppe "SPEED" ist hier das Spieltempo (im Kampf heisst der Statuswert INIT)
  if R.optionGroups then
    local g = {}
    for k, v in pairs(R.optionGroups) do g[k] = T(v) end
    pcall(function()
      local O = require("src.ui.OptionsMenu")
      O._deutschNew = O._deutschNew or O.new
      local Strings = require("src.core.Strings")
      -- Werte, die der Port ohne Strings() liefert (MUSIKFILTER, NEIGUNG, RANDFUELLUNG, Lautstaerke 0 ...)
      local function wrapValue(row)
        if row.value and not row._deutschValue then
          row._deutschValue = row.value
          row.value = function(...)
            local v = row._deutschValue(...)
            if type(v) == "string" then return Strings(v) end
            return v
          end
        end
      end
      O.new = function(game, opts, ...)
        local self = O._deutschNew(game, opts, ...)
        for _, list in ipairs({ (self and self.rows) or {}, (self and self.view) or {} }) do
          for _, row in ipairs(list) do
            if row.id and g[row.id] then row.label = g[row.id] end
            wrapValue(row)
          end
        end
        return self
      end
    end)
  end

  -- Optionen: VIDEOMODUS und ORIGINALFORMAT gibt der Port ohne Strings() aus -> hier nachreichen
  pcall(function()
    local Strings = require("src.core.Strings")
    for _, m in ipairs({ { "src.core.VideoMode", "modeLabel" }, { "src.core.FaithfulRes", "label" } }) do
      local M = require(m[1])
      local orig = M["_deutsch_" .. m[2]] or M[m[2]]
      if orig then
        M["_deutsch_" .. m[2]] = orig
        M[m[2]] = function(...)
          local v = orig(...)
          if type(v) == "string" then return Strings(v) end
          return v
        end
      end
    end
  end)

  -- Pokedex-Beschreibung: der Port haengt an den letzten Satz immer "." an (EN <DEXEND>); zwei
  -- DE-Texte (Gelb SLEIMA, SMOGON) enden mit "!" und $57 -- dort kein Punkt dahinter
  pcall(function()
    local DM = require("src.ui.DexEntryMenu")
    local Font = require("src.render.Font")
    DM._deutschOhnePunkt = DM._deutschOhnePunkt or DM.render
    DM.render = function(...)
      local fd = Font.draw
      Font.draw = function(t, ...)
        if type(t) == "string" and t:sub(-2) == "!." then t = t:sub(1, -2) end
        return fd(t, ...)
      end
      local ok, e = pcall(DM._deutschOhnePunkt, ...)
      Font.draw = fd
      if not ok then error(e, 0) end
      return e
    end
  end)

  -- Namenseingabe: DE-Tastatur (Upper/LowerCaseAlphabet: AeOeUe, "kleinbuchstaben"/"GROSSBUCHSTABEN")
  if R.namingGrid then
    local CM = W.CM
    local SPECIAL = { [0xE1] = "<PK>", [0xE2] = "<MN>", [0x7F] = " " }
    local grids = {}
    for key, g in pairs(R.namingGrid) do
      local rows = {}
      for r = 0, 4 do
        local row = {}
        for c = 0, 8 do
          local b = byte(rom, g.off + r * 9 + c + 1)
          row[c + 1] = SPECIAL[b] or CM[b] or "?"
        end
        rows[r + 1] = row
      end
      rows[5][9] = "ED"
      rows[6] = { T(g.label) }
      grids[key] = rows
    end
    pcall(function()
      mod.hooks:wrap("ui.naming.grid", function(nxt, base, info)
        local out = nxt(base, info)
        if out ~= base then return out end       -- ein anderer Mod hat die Tastatur ersetzt
        return (info and info.lower) and grids.lower or grids.upper
      end)
    end)
  end

  -- Spielautomat: der Port schreibt diese Zeilen fest auf Englisch; die DE-Zeilen kommen aus den
  -- (von dialoge.lua aus der ROM gesetzten) Texten derselben Labels
  pcall(function()
    local SM = require("src.ui.SlotMachine")
    local TB = require("src.render.TextBox")
    -- Pruefsummen der englischen Port-Zeilen (Zeile 1, Zeile 2) -> DE-Label
    local MAP = {
      { "~88dd0a39000c", "~c2ae05960006", "_BetHowManySlotMachineText" },
      { "~d868d5980008", "~8d1c0b9c0003", "_OneMoreGoSlotMachineText" },
      { "~1d529ff10005", nil, "_YeahText" },
      { "~8946befa0006", nil, "_StartSlotMachineText" },
      { "~66be2676000e", nil, "_NotThisTimeText" },
    }
    SM._deutschBottom = SM._deutschBottom or SM.drawBottom
    SM.drawBottom = function(self, ...)
      local text = (self.game and self.game.data and self.game.data.text) or {}
      local repl = {}
      for _, m in ipairs(MAP) do
        local de = text[m[3]]
        if de then
          local lines = {}
          local plain = TB.strip(de):gsub("[\f\v]", "\n")
          for l in (plain .. "\n"):gmatch("(.-)\n") do
            if l:match("%S") then lines[#lines + 1] = l end
          end
          repl[m[1]] = lines[1]
          if m[2] then repl[m[2]] = lines[2] or "" end
        end
      end
      return remapped({
        text = function(t, x, y) return x, y, type(t) == "string" and repl[W.pruefsumme(t)] or nil end,
      }, SM._deutschBottom, self, ...)
    end
  end)
end
