-- Namen und Daten aus der DE-ROM ueber die Daten-Schnittstellen des Ports:
-- Pokemon (Name, Pokedex-Kategorie, Groesse/Gewicht), Attacken, Items (auch VM01-VM05), Trainerklassen,
-- Typen, Ortsnamen, Abspann, Spitznamen der Tausch-Pokemon, Namensvorschlaege.
return function(W)
  local mod, R, T, rom = W.mod, W.R, W.T, W.rom
  local byte = string.byte

  W.apply("pokemon", R.pokemon, function(k, v)
    local p = { name = T(v.name) }
    if v.kind then
      local h = v.hw
      p.dexEntry = { kind = T(v.kind), heightM = byte(rom, h + 1) / 10,
                     weightKg = (byte(rom, h + 2) + byte(rom, h + 3) * 256) / 10 }
    end
    mod.content.pokemon:patch(k, p)
  end)
  W.apply("moves", R.moves, function(k, v) mod.content.moves:patch(k, { name = T(v) }) end)
  W.apply("items", R.items, function(k, v) mod.content.items:patch(k, { name = T(v) }) end)
  -- Versteckte Maschinen: der Port setzt "HM" + Nummer zusammen, die DE-ROM schreibt "VM" (HiddenPrefix)
  W.apply("vm_namen", R.hmNamen, function(k, v) mod.content.items:patch(k, { name = T(v) }) end)
  W.apply("trainers", R.trainers, function(k, v) mod.content.trainers:patch(k, { name = T(v) }) end)
  -- Typnamen (Statusseite, Attackenauswahl, Ruhmeshalle)
  W.apply("typen", R.types, function(k, v) mod.content.type_chart:patch(k, { name = T(v) }) end)
  -- Statuskuerzel (Kampf, Team, Statusseite): die DE-ROM schreibt SLF/GIF/BRT/GFR/PAR einzeln per Code
  -- (PrintStatusAilment: ld a,"G" / ld [hli],a ...); das Rezept nennt die drei Buchstaben-Bytes
  W.apply("status", R.statusNamen, function(k, v) mod.content.statuses:patch(k, { label = T(v) }) end)
  -- Schultafel Vertania City: der Port schreibt die sechs Kuerzel fest in data/scripts/flavor/
  -- viridian_school_house.lua (BOARD_LABELS, ohne Strings()).  Das Tafel-Menue zeigt auf genau diese Tabelle
  -- (board.labels) -> beim Aufschlagen des Menues die sechs Eintraege durch die DE-ROM-Texte ersetzen.
  if R.schultafel then
    local de = {}
    for i, v in ipairs(R.schultafel) do de[i] = T(v) end
    pcall(function()
      local Stack = require("src.core.StateStack")
      Stack._deutschPush = Stack._deutschPush or Stack.push
      Stack.push = function(self, state, ...)
        local l = type(state) == "table" and rawget(state, "labels")
        -- erkannt an den Pruefsummen von " SLP" (erster) und " QUIT" (letzter Eintrag)
        if type(l) == "table" and #l == 6 and #de == 6 and type(l[1]) == "string" and type(l[6]) == "string"
            and W.pruefsumme(l[1]) == "~33bd50d80004" and W.pruefsumme(l[6]) == "~eec1b1280005" then
          for i = 1, 6 do l[i] = de[i] end
        end
        return Stack._deutschPush(self, state, ...)
      end
    end)
  end
  -- Ortsnamen der Karte / Fliegen-Menue: der Port zeigt Strings(loc.name)
  W.apply("orte", R.mapNames, function(k, v) mod.content.strings:override(k, T(v)) end)

  -- Arena-Schilder ("MARMORIA CITY  POKeMON-ARENA  LEITER: ROCKO"): der Port setzt Stadt und Leiter aus
  -- seiner Tabelle data/scripts/gyms.lua ein -- dort stehen sie englisch; DE aus den Arena-Skripten der ROM
  if R.arenen then
    local ok, gyms = pcall(require, "data.scripts.gyms")
    W.apply("arenen", R.arenen, function(id, v)
      assert(ok and type(gyms) == "table" and type(gyms[id]) == "table", "Arena fehlt im Port")
      gyms[id].city, gyms[id].leader = T(v.city), T(v.leader)
    end)
  end

  -- Abspann (DE-Reihenfolge, DE-Namen, DE-Spalten) und "E N D E" an der DE-Spalte
  if R.credits then
    local screens = {}
    for i, s in ipairs(R.credits) do
      local lines = {}
      for j, l in ipairs(s.lines) do lines[j] = { column = l.column, text = T(l.text) } end
      screens[i] = { lines = lines, fade = s.fade, mon = s.mon, copyright = s.copyright }
    end
    pcall(function()
      mod.events:on("mods.loaded", function(ev)
        local d = ev and ev.data
        local c = d and d.field and d.field.credits
        if not c then return end
        c.screens = screens
        if R.theEnd then
          -- aeltere Importe (Blau/Gelb) haben keinen theEnd-Datensatz, nur the_end.png (T,H,E,N,D)
          c.theEnd = c.theEnd or { path = "assets/generated/credits/the_end.png", letters = "THEND",
                                   letterWidth = 8, letterHeight = 16, width = 40, height = 16 }
          c.theEnd.pattern = R.theEnd
          c.theEnd.display = "E N D E"
        end
      end)
    end)
  end

  -- Spitznamen der Tausch-Pokemon (TradeMons): der Port liest sie beim Import aus der EN-ROM
  -- (field.trades[i].nickname); Werte aus der DE-ROM (R.trades, gleiche Reihenfolge)
  if R.trades then
    pcall(function()
      mod.events:on("mods.loaded", function(ev)
        local d = ev and ev.data
        local tr = d and d.field and d.field.trades
        if type(tr) ~= "table" then return end
        for i, parts in ipairs(R.trades) do
          if type(tr[i]) == "table" then tr[i].nickname = T(parts) end
        end
      end)
    end)
  end

  -- Namensvorschlaege (DefaultNamesPlayer/Rival: ROT/ASH/JACK, BLAU/GARY/JOHN in der DE-Fassung)
  if R.namePresets then
    local presets = {}
    for who, list in pairs(R.namePresets) do
      presets[who] = {}
      for i, parts in ipairs(list) do presets[who][i] = T(parts) end
    end
    pcall(function()
      mod.events:on("mods.loaded", function(ev)
        local d = ev and ev.data
        local f = d and d.field
        if not f then return end
        f.presetNames = f.presetNames or {}
        f.boot = f.boot or {}
        f.boot.namePresets = f.boot.namePresets or {}
        for who, list in pairs(presets) do
          f.presetNames[who] = list
          f.boot.namePresets[who] = list
        end
      end)
    end)
  end
end
