-- Port-Zusaetze, die es in keiner ROM gibt (MODS-Verwaltung, Link-Kabel-Menue des Ports, Steuerung, Farben,
-- Port-Optionen, Online-Bereich).  Gleiche Datei in allen drei Definitiv-German-Mods (Gen 1, 2, 3).
-- Die Texte stehen in port_extras_daten.lua (erzeugt von Test/werkzeug/port_extras_quelle.py; Schluessel =
-- Pruefsumme des englischen Port-Texts).  Hier nur, wie sie eingesetzt werden:
--   * katalog:   Uebersetzungs-Katalog (mod.content.strings); greift nur, wo das Rezept den Text nicht schon
--                aus der DE-ROM belegt (ausser erzwingenGen3)
--   * texteGen1: Klartext-Saetze der Gen-1-Port-Skripte (show_text)
--   * anzeige/kategorie/profil + MUSTER: Texte, die der Port ohne Strings() zeichnet (MODS-Verwaltung,
--                Link-Kabel-Menue Gen 1); ersetzt nur beim Zeichnen dieser Bildschirme
return function(W)
  local mod, H = W.mod, W.pruefsumme
  local gen = require("src.core.GameVersion").generation()

  local D
  do
    local src = mod:read("port_extras_daten.lua")
    local chunk = src and (loadstring or load)(src, "@port_extras_daten.lua")
    local ok, t = pcall(function() return chunk and chunk() end)
    if not (ok and type(t) == "table") then
      if W.log then W.log:warn("Deutsch: port_extras_daten.lua nicht lesbar") end
      return
    end
    D = t
  end

  -- ------------------------------------------------ Katalog
  local R = W.R or {}
  local vorhanden = R.strings or {}
  local n = 0
  local function setze(h, v, immer)
    if (immer or vorhanden[h] == nil) and pcall(function() mod.content.strings:override(h, v) end) then n = n + 1 end
  end
  for h, v in pairs(D.katalog or {}) do setze(h, v) end
  if gen == 3 then
    for h, v in pairs(D.katalogGen3 or {}) do setze(h, v) end
    for h, v in pairs(D.erzwingenGen3 or {}) do setze(h, v, true) end
  end
  if gen == 1 then
    for h, v in pairs(D.katalogGen1 or {}) do setze(h, v) end
    -- Bonuskampf des Ports im Haus des Rocket-Chefs (Prismania City): Klasse OPP_CHIEF
    pcall(function() mod.content.trainers:patch("OPP_CHIEF", { name = "CHEF" }) end)
    -- Klartext-Saetze der Port-Skripte: der Port sucht den englischen Satz in data.text (show_text,
    -- Kampftexte); dort steht der deutsche Satz unter seiner Pruefsumme (Zugriff ueber W.pruefsumme)
    for h, v in pairs(D.texteGen1 or {}) do
      if not pcall(function() mod.content.text:override(h, v) end) and W.log then
        W.log:warn("Deutsch Gen 1: Port-Satz %s nicht gesetzt", h)
      end
    end
  end

  -- Gen 2: Abspann des Ports (src/ui/gen2/Credits.lua) -- eigene Port-Zeilen; die deutsche ROM fuehrt ihren
  -- Abspann mit deutschen Ueberschriften.  Namen sowie die Copyright-/Herkunftszeilen (Pflichtnennung des
  -- Ports) bleiben unveraendert; Ueberschriften werden in 20 Spalten neu zentriert wie im Original.
  if gen == 2 then
    pcall(function()
      local C = require("src.ui.gen2.Credits")
      local S, ID = C.STRINGS, C.ID
      if type(S) ~= "table" or type(ID) ~= "table" then return end
      local function mitte(t)
        local z = 0
        for _ in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do z = z + 1 end
        return string.rep(" ", math.max(0, math.floor((20 - z) / 2))) .. t
      end
      local UEBER = {
        DIRECTOR = "LEITUNG", PROGRAMMING = "PROGRAMMIERUNG", ENGINE_DESIGN = "ENGINE-DESIGN",
        BATTLE_ENGINE = "KAMPF-ENGINE", SCRIPT_ENGINE = "SKRIPT-ENGINE", WORLD_ENGINE = "WELT-ENGINE",
        AUDIO_ENGINE = "AUDIO-ENGINE", GRAPHICS = "GRAFIK", USER_INTERFACE = "OBERFLÄCHE",
        ROM_IMPORTER = "ROM-IMPORT", SAVE_EDITOR = "SPIELSTAND-EDITOR", TOOLS = "WERKZEUGE", TESTING = "TESTS",
        BUILT_WITH = "ERSTELLT MIT", BASED_ON = "BASIERT AUF", SPECIAL_THANKS = "BESONDERER DANK",
        PRODUCER = "PRODUZENT", EVERY_TESTER = "ALLE TESTER", AND_YOU = "UND DIR",
      }
      for name, de in pairs(UEBER) do
        if ID[name] and type(S[ID[name]]) == "string" then S[ID[name]] = mitte(de) end
      end
      local EDITION = { gold = "GOLDENE EDITION", silver = "SILBERNE EDITION", crystal = "KRISTALL-EDITION" }
      if ID.STAFF then
        S[ID.STAFF] = function()
          local v = require("src.core.GameVersion").get()
          return { mitte("#MON"), mitte(EDITION[v] or EDITION.gold), mitte("PORT-TEAM") }
        end
      end
    end)
  end

  -- ------------------------------------------------ Union-Kampf-Vorbereitung (Online-Bereich)
  -- Die Texte stehen im Port in BattlePrepModel.TEXT (ohne Strings()).  Statt das Online-Modul selbst zu laden
  -- (wuerde Netzwerk-Module nachziehen), werden die Eintraege per Schluessel ersetzt, wenn der Port den
  -- Bildschirm mit seinem Modell oeffnet (Gen 1/2: StateStack, Gen 3: game3-Stack).
  -- Union-Tausch genauso: OpenTrade.TEXT; der Bildschirm traegt den Tausch-Controller (ctl), das Modul ist dann
  -- schon geladen (require liefert es nur aus dem Speicher)
  local UNION, TAUSCH = D.unionKampf or {}, D.unionTausch or {}
  -- Gen 1/2 zeigen diese Bildschirme in Grossbuchstaben (string.upper laesst Umlaute klein) -> selbst gross
  -- schreiben; "é" bleibt klein wie in POKéMON
  local function gross(s)
    return (s:upper():gsub("ä", "Ä"):gsub("ö", "Ö"):gsub("ü", "Ü"))
  end
  local function ersetze(T, neu)
    for k, v in pairs(neu) do
      if T[k] ~= nil then T[k] = (gen == 3) and v or gross(v) end
    end
  end
  -- Meldungen der generationsuebergreifenden Pruefung (src/online/xgen/Messages.lua): Vorlagen je Code deutsch,
  -- Platzhalter wie im Port; Gen 1/2 (Stil "gb") in Grossbuchstaben mit AeOeUe
  local XT, XC, XF, XS = D.xgenText or {}, D.xgenChange or {}, D.xgenField or {}, D.xgenSonst or {}
  if next(XT) then
    pcall(function()
      local M = require("src.online.xgen.Messages")
      if M._deutsch then return end
      M._deutsch = true
      local function fuelle(vorlage, detail, names)
        detail, names = detail or {}, names or {}
        return (vorlage:gsub("{(%w+)}", function(key)
          local value = detail[key]
          if key == "species" then
            local n = detail.national or detail.species
            value = names.species and names.species(n) or (n and (XS.nr .. tostring(n))) or XS.es
          elseif key == "move" and detail.move ~= nil then
            value = names.move and names.move(detail.move) or (XS.attacke .. tostring(detail.move))
          elseif key == "item" and detail.item ~= nil then
            value = names.item and names.item(detail.item) or tostring(detail.item)
          elseif key == "need" and type(value) == "table" then
            value = XS.anderes_spiel
          end
          return value ~= nil and tostring(value) or ""
        end))
      end
      local altFormat = M.format
      M.text = function(code, detail, names)
        return fuelle(XT[code] or XS.unbekannt, detail, names)
      end
      M.about = function(name, code, detail, names)
        local t = XT[code] or XS.unbekannt
        if not t:find("{species}", 1, true) then return tostring(name) .. ": " .. fuelle(t, detail, names) end
        local own = {}
        for k, v in pairs(names or {}) do own[k] = v end
        own.species = function() return name end
        return fuelle(t, detail, own)
      end
      M.change = function(row, gen)
        local t = XC[row.kind] or XC.change
        local feld = XF[row.field] or XF[(tostring(row.field):match("^(%a+)"))] or XS.daten
        return M.format(fuelle(t, { field = feld }), gen)
      end
      M.format = function(text, gen)
        if type(text) == "string" and M.style(gen) == "gb" then text = gross(text) end
        return altFormat(text, gen)
      end
    end)
  end
  -- Union-Tausch, Ablehnungsgruende: Tabelle im Port nicht erreichbar -> an den Controller-Methoden ersetzen
  local GRUND, GRUNDSATZ = D.tauschGrund or {}, D.tauschGrundSatz or {}
  local function grundDeutsch(Open)
    local C = type(Open.Controller) == "table" and Open.Controller
    if not C or rawget(C, "_deutschGrund") then return end
    rawset(C, "_deutschGrund", true)
    local altGrund, altBlock, altWahl = C.reasonText, C.blockLines, C.pagePick
    local function satz(s)
      return type(s) == "string" and GRUNDSATZ[H(s)] or nil
    end
    C.reasonText = function(self, code, ...)
      return GRUND[code] or altGrund(self, code, ...)
    end
    C.blockLines = function(self, ...)
      local zeilen = altBlock(self, ...)
      for i, z in ipairs(zeilen or {}) do
        local de = satz(type(z) == "string" and z:match("^%- (.*)$"))
        if de then zeilen[i] = "- " .. de end
      end
      return zeilen
    end
    C.pagePick = function(self, ...)
      local seite = altWahl(self, ...)
      for _, it in ipairs(type(seite) == "table" and seite.items or {}) do
        for i, d in pairs(type(it.detail) == "table" and it.detail or {}) do
          local de = satz(d)
          if de then it.detail[i] = de end
        end
      end
      return seite
    end
  end
  local tauschFertig = false
  local function deutscherBildschirm(screen)
    local model = rawget(screen, "model")
    local mt = type(model) == "table" and getmetatable(model)
    local T = type(mt) == "table" and rawget(mt, "TEXT")
    if type(T) == "table" and not rawget(mt, "_deutschTexte") then
      ersetze(T, UNION)
      rawset(mt, "_deutschTexte", true)
    end
    if not tauschFertig and type(rawget(screen, "ctl")) == "table" then
      local ok, Open = pcall(require, "src.ui.union.prep.OpenTrade")
      if ok and type(Open) == "table" and type(Open.TEXT) == "table" then
        ersetze(Open.TEXT, TAUSCH)
        grundDeutsch(Open)
        tauschFertig = true
      end
    end
  end
  if next(UNION) or next(TAUSCH) then
    pcall(function()
      local SS = require("src.core.StateStack")
      SS._deutschUnion = SS._deutschUnion or SS.push
      SS.push = function(self, state, ...)
        if type(state) == "table" then pcall(deutscherBildschirm, state) end
        return SS._deutschUnion(self, state, ...)
      end
    end)
    if gen == 3 then
      pcall(function()
        local St = require("src.ui.game3.stack")
        St._deutschUnion = St._deutschUnion or St.push
        St.push = function(id, screen, ...)
          if type(screen) == "table" then pcall(deutscherBildschirm, screen) end
          return St._deutschUnion(id, screen, ...)
        end
      end)
    end
  end

  -- ------------------------------------------------ fest gezeichnete Texte (MODS-Verwaltung, Link-Menue)
  local ANZEIGE, KATEGORIE, PROFIL = D.anzeige or {}, D.kategorie or {}, D.profil or {}
  -- zusammengesetzte Zeilen der MODS-Verwaltung (Muster der Port-Oberflaeche)
  local MUSTER = {
    { "^ENABLED", "AKTIV" }, { "^DISABLED", "INAKTIV" },
    { " %(NOT THIS GAME%)", " (NICHT HIER)" }, { " %(NOT THIS", " (NICHT HIER" }, { " %(STAGED%)", " (VORGEMERKT)" },
    { "^FOR ", "FÜR " }, { "^FAILED: ", "FEHLER: " }, { "^SKIPPED: ", "ÜBERSPRUNGEN: " },
    { "^LOAD #(%S+) OF (%d+)$", "LADEN #%1 VON %2" }, { "LOAD #", "LADEN #" }, { " ON RESTART$", " BEIM NEUSTART" },
    { "^PROFILE (%d+)$", "PROFIL %1" },
  }
  local function uebersetze(t)
    if type(t) ~= "string" or t == "" then return t end
    local e = ANZEIGE[H(t)]
    if e then return e end
    -- Detailzeile "Kategorie / Profil"
    local kat, sep, prof = t:match("^(%S+)(%s*/%s*)(%S*)$")
    if kat then
      local k, p = KATEGORIE[H(kat)], prof ~= "" and PROFIL[H(prof)] or nil
      if k or p then return (k or kat) .. sep .. (p or prof) end
    end
    for _, m in ipairs(MUSTER) do t = t:gsub(m[1], m[2]) end
    return t
  end
  -- Gen 1/2: feste 8-Pixel-Schrift, Zeilen ab Spalte 2 -> hoechstens 17 Zeichen (laenger nur, wenn das
  -- Englische schon laenger war); Gen 3 hat eine Proportionalschrift und kuerzt selbst
  local function kuerze(neu, alt)
    if gen == 3 or type(neu) ~= "string" or neu == alt then return neu end
    local max = math.max(17, #(alt or ""))
    local zeichen, aus = 0, {}
    for c in neu:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      zeichen = zeichen + 1
      if zeichen > max then break end
      aus[#aus + 1] = c
    end
    return table.concat(aus)
  end
  local function waehrend(feld, ziel, fn)
    -- ruft fn auf, waehrend ziel[feld] uebersetzt; Original immer zuruecksetzen
    local orig = ziel[feld]
    ziel[feld] = function(text, ...) return orig(kuerze(uebersetze(text), text), ...) end
    local ok, e = pcall(fn)
    ziel[feld] = orig
    if not ok then error(e, 0) end
  end
  -- Bildschirme, deren feste Texte beim Zeichnen ersetzt werden (Gen 1/2: Font.draw)
  -- (LinkState nur in Gen 1: dort ist es das Link-Kabel-Menue; in Gen 2/3 wuerde das Laden eine
  -- Netzwerk-Berechtigungswarnung ausloesen)
  for _, modul in ipairs(gen == 1 and { "src.mods.ManagerState", "src.link.LinkState" } or { "src.mods.ManagerState" }) do
    pcall(function()
      local MS = require(modul)
      local Font = require("src.render.Font")
      if type(MS.draw) ~= "function" or MS._deutschDraw then return end
      MS._deutschDraw = MS.draw
      MS.draw = function(self, ...)
        local args = { ... }
        return waehrend("draw", Font, function() MS._deutschDraw(self, unpack(args)) end)
      end
    end)
  end
  if gen == 3 then
    pcall(function()
      local MM = require("src.ui.game3.mod_manager")
      local Window = require("src.ui.game3.window")
      MM._deutschDraw = MM._deutschDraw or MM.draw
      MM.draw = function(...)
        local args = { ... }
        return waehrend("printPx", Window, function() MM._deutschDraw(unpack(args)) end)
      end
    end)
  end
  if W.log and W.log.info then
    W.log:info("Deutsch Gen %d: Port-Zusaetze %d Texte", gen, n)
  end
end
