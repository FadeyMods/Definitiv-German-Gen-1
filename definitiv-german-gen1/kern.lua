-- Definitiv German Gen 1 – Kern: deutsche ROM lesen, mit dem Extraktor des Ports auslesen, Ergebnis übernehmen.
--
-- Der Port liest beim Import die englische ROM über eine Symboltabelle (Name → Bank/Adresse).  Das Rezept dieser
-- Edition (rezept_<edition>.lua) enthält dieselben Symbole mit ihren Adressen in der DEUTSCHEN ROM.  Damit läuft
-- der unveränderte Extraktor des Ports über die deutsche ROM des Spielers – Texte, Namen und Grafiken entstehen
-- genau so, wie Bryan sie aus einer deutschen ROM gewonnen hätte.  Übernommen werden nur Anzeigeinhalte (Texte,
-- Namen, Pokédex, Schrift, Bilder mit Schrift); Spieldaten bleiben, wie sie sind.
--
-- Das Ergebnis wird im Mod-Cache gespeichert (Schlüssel: MD5 der DE-ROM, Mod-, Rezept- und Port-Version) und
-- beim nächsten Start nur noch geladen.
return function(mod, MODVERSION)
  local GameVersion = require("src.core.GameVersion")
  local Data = require("src.core.Data")
  local RomExtractor = require("src.import.RomExtractor")
  local ImageWriter = require("src.import.ImageWriter")
  local Assets = require("src.render.Assets")
  local Version = require("src.core.Version")

  -- Gemeinsame Bausteine aller drei Mods (Prüfsumme, Katalog, Kontexte, Port-Texte aus der ROM, Cache, Bilder)
  local G = assert(load(mod:read("gemeinsam.lua"), "@gemeinsam.lua"))()(mod)
  local K = { G = G }
  local pruefsumme, datei, kopie = G.pruefsumme, G.datei, G.kopie
  K.pruefsumme, K.datei = pruefsumme, datei

  local IMPORT = { red = "rot_de", blue = "blau_de", yellow = "gelb_de" }
  -- Stufen des Port-Extraktors mit Anzeigeinhalten (src/import/RomExtractor.lua); die übrigen liefern nur Spiel-
  -- daten, Karten, Töne – die bleiben aus der englischen ROM des Ports
  local STUFEN = { "extractFont", "extractMoves", "extractItems", "extractTypeChart", "extractPokemon",
    "extractTrainers", "extractText", "extractField", "extractTilesets" }

  -- ---------------------------------------------------------------- deutsches Manifest
  local function manifest(edition, rezept, Z)
    local m = G.rom_manifest(edition)
    local syms = {}
    for name, ort in pairs(m.symbols) do
      -- RAM-Symbole (≥ $8000) bleiben; ROM-Symbole nur mit belegter DE-Adresse
      if ort[2] >= 0x8000 then syms[name] = ort end
    end
    for name, ort in pairs(rezept.s) do syms[name] = { ort[1], ort[2] } end
    m.symbols = syms
    if m.text then
      m.text.dynamic = kopie(rezept.d)
    end
    Z.anwenden(m)
    return m
  end

  -- Gen-1-Pokédex der deutschen Editionen: Kategorie@, Größe (1 Byte, Dezimeter), Gewicht (2 Byte, Hektogramm),
  -- text_far.  Der Port zeigt metrische Werte über dexEntry.heightM / weightKg (src/ui/DexEntryMenu.lua).
  local function dexEntryDe(self, index, species)
    local tab = self:symbol("PokedexEntryPointers")
    local adr = self.rom:word(tab.bank, tab.address + (index - 1) * 2)
    local kind, n = self.rom:readString(tab.bank, adr, self.manifest.charmap, 0x50, 32)
    adr = adr + n
    local dm = self.rom:byte(tab.bank, adr)
    local hg = self.rom:word(tab.bank, adr + 1)
    adr = adr + 3
    assert(self.rom:byte(tab.bank, adr) == 0x17, "dex entry " .. index .. " has no TX_FAR command")
    return {
      kind = kind, heightM = dm / 10, weightKg = hg / 10,
      text = self.manifest.dexEntryLabels[species]
        or ("_DexEntry_%02X_%04X"):format(self.rom:byte(tab.bank, adr + 3), self.rom:word(tab.bank, adr + 1)),
    }
  end

  -- Gelb: der deutsche Titel des Surf-Minispiels ist EINE bildschirmfüllende Tilemap (20×18), nicht vier Teile
  -- (Handbeleg in Test/werkzeug/handbelege/yellow.json).  Zusammensetzen wie im Port (RomExtractor
  -- extractSurfingPikachuTitleArt), nur aus dieser Tilemap.
  local function surfTitelDe(ersatz)
    return function(self)
      local t = ersatz and ersatz.SurfingMinigame_DeTitelTilemap
      if not t or not self.symbols["SurfingPikachu1Graphics3"] then return end
      local screen = self.rom:bytes(t[1], t[2], t[3])
      local gfx3 = self:symbol("SurfingPikachu1Graphics3")
      local raw = self.rom:bytes(gfx3.bank, gfx3.address, 144 * 16)
      local tiles = {}
      for tile = 0, 143 do
        local eins = {}
        for j = 1, 16 do eins[j] = raw[tile * 16 + j] end
        tiles[tile + 1] = ImageWriter.decode2bpp(eins, 8, 8, false)
      end
      local leer = ImageWriter.blank(8, 8, 1, 1, 1, 1)
      local bild = ImageWriter.blank(160, 144, 1, 1, 1, 1)
      for r = 0, 17 do
        for c = 0, 19 do
          local id = screen[r * 20 + c + 1]
          -- $FF ist hier eine echte Kachel (das „k“ in „Steuerkreuz!“, Zeile 9); leer ist $B6
          local kachel = leer
          local idx = id >= 0x80 and (id - 0x80 + 1) or (128 + id + 1)
          if idx >= 1 and idx <= 144 then kachel = tiles[idx] end
          ImageWriter.blit(bild, kachel, c * 8, r * 8)
        end
      end
      self:save(bild, "minigame/title_bg.png")
    end
  end

  local anders_als_en = G.anders_als_en

  -- Titelbildschirm: Versions-Schriftzug und Copyright-Zeile setzt die deutsche ROM anders zusammen als die englische
  -- (andere Kachelfolge, andere Spalte, zusätzliche Kacheln).  Beide Zeilen werden genau nach dem DE-Titelcode als
  -- 160×8-Bild aufgebaut (Rezept: titel.version / titel.copyright / titel.laden, aus Test/werkzeug/gb_titel.py).
  local function titelbilder(ex, titel, bilder)
    if not titel then return end
    if titel.copyright and titel.laden then
      local zeile = ImageWriter.blank(160, 8, 1, 1, 1, 0)
      for i, code in ipairs(titel.copyright.kacheln) do
        for _, l in ipairs(titel.laden) do
          if code >= l[1] and code < l[1] + l[4] then
            local raw = ex.rom:bytes(l[2], l[3] + (code - l[1]) * 16, 16)
            ImageWriter.blit(zeile, ImageWriter.decode2bpp(raw, 8, 8, false), (titel.copyright.spalte + i - 1) * 8, 0)
            break
          end
        end
      end
      bilder["title/de_copyright_zeile.png"] = zeile
    end
    local band = bilder["title/red_version.png"]
    if titel.version and band then
      local zeile = ImageWriter.blank(160, 8, 1, 1, 1, 0)
      for i, code in ipairs(titel.version.kacheln) do
        local k = code - 0x60
        if k >= 0 and (k + 1) * 8 <= band:getWidth() then
          ImageWriter.blit(zeile, band, (titel.version.spalte + i - 1) * 8, 0, k * 8, 0, 8, 8)
        end
      end
      bilder["title/de_versionsband.png"] = zeile
    end
  end

  -- ---------------------------------------------------------------- Extraktion
  local romtext, ohne_ende = G.romtext, G.ohne_ende

  -- Namenseingabe: Buchstabentafeln der DE-ROM (5 Zeilen à 9 Zeichen, dann die Umschalt-Beschriftung bis @).
  -- Sonderzeichen als Zellnamen des Ports (src/ui/NamingScreen.lua GRID_UPPER).
  local ZELLE = { [0xE1] = "<PK>", [0xE2] = "<MN>", [0xF2] = "<DOT>", [0xF0] = "ED", [0xF1] = "×", [0x7F] = " " }
  local function alphabet(ex, a, charmap)
    if not a then return nil end
    local function tafel(ort)
      local raster, adr = {}, ort[2]
      for r = 1, 5 do
        local zeile = {}
        for c = 1, 9 do
          local x = ex.rom:byte(ort[1], adr)
          adr = adr + 1
          zeile[c] = ZELLE[x] or charmap[tostring(x)] or "?"
        end
        raster[r] = zeile
      end
      local t = {}
      for _ = 1, 30 do
        local x = ex.rom:byte(ort[1], adr)
        adr = adr + 1
        if x == 0x50 then break end
        t[#t + 1] = charmap[tostring(x)] or ""
      end
      raster[6] = { table.concat(t) }
      return raster
    end
    return { gross = tafel(a.gross), klein = tafel(a.klein) }
  end

  -- Namen aus der DE-ROM: Tausch-Spitznamen (TradeMons: 3 Bytes Kopf + Name, Abstand 14) und Namensvorschläge
  -- (DefaultNamesPlayer/Rival: „NAME\nROT\nASH\nJACK@“, erste Zeile ist der Menüpunkt für einen eigenen Namen)
  local function namen(ex, n, charmap)
    if not n then return nil end
    local erg = { tausch = {} }
    if n.tausch then
      local b, a, anzahl, abstand = n.tausch[1], n.tausch[2], n.tausch[3], n.tausch[4]
      for i = 1, anzahl do
        erg.tausch[i] = romtext(ex, charmap, b, a + (i - 1) * abstand + 3, 1, 0, 0)
      end
    end
    for _, wer in ipairs({ "spieler", "rivale" }) do
      if n[wer] then
        local t = romtext(ex, charmap, n[wer][1], n[wer][2], 1, 0, 0)
        local liste = {}
        for z in ((t or "") .. "\n"):gmatch("(.-)\n") do liste[#liste + 1] = z end
        table.remove(liste, 1)
        if #liste > 0 then erg[wer] = liste end
      end
    end
    return erg
  end

  -- Abspann wie engine/movie/credits.asm Credits: Befehlsbytes $FF–$FC beenden einen Bildschirm (Einblenden /
  -- Pokémon danach), $FB Copyright, $FA Ende; sonst Index in CreditsTextPointers → Spaltenversatz (ab Spalte 9) +
  -- Zeichenkette, jede Zeile zwei Kachelzeilen tiefer.  Ergebnis im Format von field.credits.screens.
  local CRED = { [0xFF] = { true, true }, [0xFE] = { false, true }, [0xFD] = { true, false },
    [0xFC] = { false, false } }
  local function abspann(ex, a, charmap)
    if not a then return nil end
    local screens, cur = {}, { lines = {} }
    local o = a.order
    for _ = 1, 2000 do
      local c = ex.rom:byte(a.bank, o)
      o = o + 1
      if CRED[c] then
        cur.fade, cur.mon = CRED[c][1], CRED[c][2] or nil
        screens[#screens + 1] = cur
        cur = { lines = {} }
      elseif c == 0xFB then
        cur.copyright = true
      elseif c == 0xFA then
        return screens
      else
        local s = ex.rom:word(a.bank, a.zeiger + 2 * c)
        local v = ex.rom:byte(a.bank, s)
        local spalte = 9 + (v >= 0x80 and v - 256 or v)
        s = s + 1
        local zeile = {}
        for _ = 1, 40 do
          local x = ex.rom:byte(a.bank, s)
          s = s + 1
          if x == 0x50 then break end
          if x == 0x4E or x == 0x4F then
            cur.lines[#cur.lines + 1] = { column = spalte, text = table.concat(zeile) }
            zeile = {}
          elseif x == 0x54 then
            zeile[#zeile + 1] = "POKé"
          else
            zeile[#zeile + 1] = charmap[tostring(x)] or ""
          end
        end
        cur.lines[#cur.lines + 1] = { column = spalte, text = table.concat(zeile) }
      end
    end
    return nil
  end

  -- Urkunde (Rot/Blau): Texte und Kachelpositionen der deutschen Tabelle; Zeilen getrennt, Kreis-Kachel ($70) als \1
  local function diplom(ex, d, charmap)
    if not d then return nil end
    local texte = {}
    for _, e in ipairs(d.texte) do
      local zeilen, zeile, adr = {}, {}, e[2]
      for _ = 1, 200 do
        local x = ex.rom:byte(e[1], adr)
        adr = adr + 1
        if x == 0x50 then break end
        if x == 0x4E or x == 0x4F then
          zeilen[#zeilen + 1] = table.concat(zeile)
          zeile = {}
        elseif x == (d.kreis or 0x70) then
          zeile[#zeile + 1] = "\1"
        elseif x == 0x54 then
          zeile[#zeile + 1] = "POKé"
        else
          zeile[#zeile + 1] = charmap[tostring(x)] or ""
        end
      end
      zeilen[#zeilen + 1] = table.concat(zeile)
      texte[#texte + 1] = { x = e[3], y = e[4], zeilen = zeilen }
    end
    return { name = { x = d.name[1], y = d.name[2] }, texte = texte }
  end

  local function extrahieren(edition, rom, rezept, Z)
    local m = manifest(edition, rezept, Z)
    local ex = RomExtractor.new(rom, m)
    local daten, bilder, fehler = {}, {}, {}
    ex.write = function(_, name, wert) daten[name] = wert end
    ex.save = function(_, bild, rel) bilder[rel] = bild end
    ex.dexEntry = dexEntryDe
    if edition == "yellow" then ex.extractSurfingPikachuTitleArt = surfTitelDe(rezept.e) end
    for _, stufe in ipairs(STUFEN) do
      local ok, err = pcall(ex[stufe], ex)
      if not ok then fehler[#fehler + 1] = stufe .. ": " .. tostring(err) end
    end
    titelbilder(ex, rezept.titel, bilder)
    daten.porttexte, daten.portkontexte = G.porttexte_lesen(ex, rezept, m.charmap, daten)
    daten.romliterale = G.romliterale_lesen(ex, rezept, m.charmap)
    daten.diplom = diplom(ex, rezept.diplom, m.charmap)
    daten.alphabet = alphabet(ex, rezept.alphabet, m.charmap)
    daten.abspann = abspann(ex, rezept.abspann, m.charmap)
    daten.namen = namen(ex, rezept.namen, m.charmap)
    -- Arena-Statuen: Stadt- und Leitername je Arena (scripts/*Gym.asm .CityName/.LeaderName der DE-ROM)
    if rezept.arenen then
      daten.arenen = {}
      for karte, a in pairs(rezept.arenen) do
        daten.arenen[karte] = { stadt = romtext(ex, m.charmap, a[1], a[2], 1, 0, 0),
          leiter = romtext(ex, m.charmap, a[1], a[3], 1, 0, 0) }
      end
    end
    -- Geist im PKMN-TURM: Name aus den Sofortwerten „ld a, n / ld [hli], a“ der DE-ROM (core.asm .isGhost)
    if rezept.geist then
      local b, adr, t = rezept.geist[1], rezept.geist[2], {}
      for _ = 1, 10 do
        if ex.rom:byte(b, adr) ~= 0x3E or ex.rom:byte(b, adr + 2) ~= 0x22 then break end
        t[#t + 1] = m.charmap[tostring(ex.rom:byte(b, adr + 1))] or ""
        adr = adr + 3
      end
      if #t > 0 then daten.geist = table.concat(t) end
    end
    -- Statuskürzel: fünf Blöcke „3E x 22 3E y 22 36 z C9“ (PrintStatusAilment), Reihenfolge SLP PSN BRN FRZ PAR
    if rezept.status then
      local b, adr, s = rezept.status[1], rezept.status[2], {}
      for _, id in ipairs({ "SLP", "PSN", "BRN", "FRZ", "PAR" }) do
        local r = ex.rom
        if r:byte(b, adr) ~= 0x3E or r:byte(b, adr + 2) ~= 0x22 or r:byte(b, adr + 3) ~= 0x3E
            or r:byte(b, adr + 5) ~= 0x22 or r:byte(b, adr + 6) ~= 0x36 or r:byte(b, adr + 8) ~= 0xC9 then
          s = nil
          break
        end
        s[id] = (m.charmap[tostring(r:byte(b, adr + 1))] or "") .. (m.charmap[tostring(r:byte(b, adr + 4))] or "")
          .. (m.charmap[tostring(r:byte(b, adr + 7))] or "")
        adr = adr + 9
      end
      daten.status = s
    end
    -- Kampfmenü: Layout aus dem Rezept, Zeichen als Codes der DE-Zeichenkette (Zeilen an $4E/$4F)
    local km = rezept.kampfmenue
    if km then
      local codes, zeile, adr = {}, {}, km.zeichen[2]
      for _ = 1, 60 do
        local x = ex.rom:byte(km.zeichen[1], adr)
        adr = adr + 1
        if x == 0x50 then break end
        if x == 0x4E or x == 0x4F then
          codes[#codes + 1] = zeile
          zeile = {}
        else
          zeile[#zeile + 1] = x
        end
      end
      codes[#codes + 1] = zeile
      daten.kampfmenue = { box = km.box, text = km.text, cursor = km.cursor, codes = codes }
    end
    -- nur Bilder behalten, die sich vom englischen Import unterscheiden (Schrift, Schilder, Titel …)
    for rel, bild in pairs(bilder) do
      if not anders_als_en(rel, bild) then bilder[rel] = nil end
    end
    return daten, bilder, fehler
  end

  -- ---------------------------------------------------------------- Cache
  local cache_lesen, cache_schreiben = G.cache_lesen, G.cache_schreiben

  -- ---------------------------------------------------------------- Namenseingabe
  function K.alphabet_einhaengen(a)
    if not (mod.hooks and mod.hooks.wrap) then return end
    mod.hooks:wrap("ui.naming.grid", function(_weiter, _base, ctx)
      return (ctx and ctx.lower) and a.klein or a.gross
    end)
  end

  -- ---------------------------------------------------------------- Zeilentausch
  -- Bildschirme, die ROM-Dialogzeilen als feste englische Literale zeichnen (ohne Strings()): während die genannte
  -- Funktion läuft, wird jede Zeile, die genau einer Zeile des englischen Labels entspricht, durch dieselbe Zeile des
  -- deutschen Labels ersetzt.  Quelle bleibt die ROM (Data.text-Label).
  local ZEILENTAUSCH = {
    { "src.ui.SlotMachine", "drawBottom",                        -- engine/slots/slot_machine.asm
      { "_BetHowManySlotMachineText", "_OneMoreGoSlotMachineText", "_StartSlotMachineText", "_YeahText" } },
  }
  local function zeilen_von(t)
    local z = {}
    for zeile in (ohne_ende(t):gsub("[\v\f]", "\n") .. "\n"):gmatch("(.-)\n") do
      zeile = zeile:gsub("^%s+", ""):gsub("%s+$", "")
      if zeile ~= "" then z[#z + 1] = zeile end
    end
    return z
  end
  function K.zeilentausch_einhaengen(daten)
    local Font = require("src.render.Font")
    for _, e in ipairs(ZEILENTAUSCH) do
      local ok, M = pcall(require, e[1])
      local tausch = {}
      for _, lab in ipairs(e[3]) do
        local en_t, de_t = K.en_text[lab], daten.text and daten.text[lab]
        if en_t and de_t then
          local en_z, de_z = zeilen_von(en_t), zeilen_von(de_t)
          -- mehr deutsche als englische Zeilen: die Textbox hat nach dem Weiterrollen die letzten Zeilen stehen
          -- („Wie viele Münzen / möchtest Du / setzen?“ → „möchtest Du / setzen?“)
          local versatz = math.max(0, #de_z - #en_z)
          for i, z in ipairs(en_z) do
            if de_z[i + versatz] then tausch[z] = de_z[i + versatz] end
          end
        end
      end
      if ok and type(M) == "table" and type(M[e[2]]) == "function" and next(tausch) then
        local original = M[e[2]]
        M[e[2]] = function(...)
          local fd = Font.draw
          Font.draw = function(text, x, y, ...)
            if type(text) == "string" then
              local t = tausch[(text:gsub("^%s+", ""):gsub("%s+$", ""))]
              if t then return fd(t, x, y, ...) end
            end
            return fd(text, x, y, ...)
          end
          local ok2, r1, r2, r3 = pcall(original, ...)
          Font.draw = fd
          if not ok2 then error(r1, 0) end
          return r1, r2, r3
        end
      end
    end
  end

  -- ---------------------------------------------------------------- Kampfmenü
  -- Die DE-ROM setzt das Kampfmenü breiter (Kasten ab Spalte 6, Text ab Spalte 8, Cursor-Spalten 7/12); der Port
  -- zeichnet fest das englische Layout (Kasten ab 8).  Während drawTextArea im Menü: englischen Kasten und Menü-
  -- Glyphen abfangen, danach Kasten, Zeichen (Codes der DE-Zeichenkette BattleMenuText) und Cursor nach DE setzen.
  function K.kampfmenue_einhaengen(km)
    local ok, BS = pcall(require, "src.battle.BattleState")
    if not ok or type(BS) ~= "table" or type(BS.drawTextArea) ~= "function" then return end
    local Font = require("src.render.Font")
    local original = BS.drawTextArea
    BS.drawTextArea = function(self, ...)
      if not (self.phase == "menu" and not self.safari) or self.game and self.game.save
          and self.game.save.generation == 2 then
        return original(self, ...)
      end
      local db, dc = Font.drawBox, Font.drawCode
      local kasten = false
      Font.drawBox = function(tx, ty, tw, th, ...)
        kasten = true
        local r
        if tx == 8 and ty == 12 and tw == 12 and th == 6 then
          r = db(km.box[1], km.box[2], km.box[3] - km.box[1] + 1, km.box[4] - km.box[2] + 1, ...)
        else
          r = db(tx, ty, tw, th, ...)
        end
        kasten = false
        return r
      end
      Font.drawCode = function(code, x, y, ...)
        -- englische Menüzeilen und Cursor (alles rechts der Spalte 8 in den Menüzeilen, auch übergelaufene
        -- Zeichen des englisch platzierten „FLUCHT“); Kastenrahmen bleiben
        if not kasten and (y == 112 or y == 128) and x >= 72 then return end
        return dc(code, x, y, ...)
      end
      local ok2, err = pcall(original, self, ...)
      Font.drawBox, Font.drawCode = db, dc
      if not ok2 then error(err, 0) end
      love.graphics.setColor(0, 0, 0, 1)
      for i, zeile in ipairs(km.codes) do
        for j, code in ipairs(zeile) do
          if code ~= 0x7F then dc(code, (km.text[1] + j - 1) * 8, (km.text[2] + (i - 1) * 2) * 8) end
        end
      end
      local spalte, reihe
      if self.demo then
        spalte, reihe = 0, ((self.demoTimer or 0) <= self:demoDelays()) and 0 or 1
      else
        spalte, reihe = (self.menuIndex - 1) % 2, math.floor((self.menuIndex - 1) / 2)
      end
      dc(0xED, km.cursor[spalte + 1] * 8, 112 + reihe * 16)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  -- ---------------------------------------------------------------- Trainerpass-Banner
  -- TrainerInfo_BadgesText ist in beiden ROMs ein Stück „●<Wort>●“ ab Spalte 6, Zeile 9 (start_sub_menus.asm,
  -- hlcoord 6, 9).  Der Port setzt den rechten Kreis fest auf Spalte 13 (nach „BADGES“); bei „ORDEN“ steht er in
  -- der DE-ROM direkt hinter dem Wort.
  function K.trainerpass_einhaengen()
    local ok, TC = pcall(require, "src.ui.TrainerCard")
    if not ok or type(TC) ~= "table" or type(TC.draw) ~= "function" then return end
    local Font = require("src.render.Font")
    local Strings = require("src.core.Strings")
    local original = TC.draw
    TC.draw = function(self, ...)
      local r1, r2 = original(self, ...)
      local n = Font.glyphCount(Strings("BADGES"))
      if self.circle and n and n ~= 6 then
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 104, 72, 8, 8)
        love.graphics.draw(self.circle, 56 + n * 8, 72)
        love.graphics.setColor(r, g, b, a)
      end
      return r1, r2
    end
  end

  -- ---------------------------------------------------------------- Urkunde
  -- Rot/Blau: Diploma.render setzt die englischen Zeilen an feste Stellen.  Während render werden diese Font.draw-
  -- Aufrufe abgefangen: an der Titelstelle (6,2 → 48,16) der deutsche Titel mit seinen Kreis-Kacheln, an der
  -- Stelle „Player“ (24,32) alle übrigen deutschen Texte und der Name an den Kacheln der deutschen Tabelle; die
  -- restlichen englischen Zeilen entfallen.  Der Weg über Font.draw erreicht auch die Text-Ebene über dem
  -- Spielerbild (textOverlay), so liegt die Schrift wie im Original vor der Figur.
  local EN_DIPLOM = { ["80,32"] = true, ["16,48"] = true, ["16,64"] = true, ["16,80"] = true, ["16,96"] = true,
    ["16,112"] = true, ["72,128"] = true }
  function K.diplom_einhaengen(d)
    local ok, Diploma = pcall(require, "src.ui.Diploma")
    if not ok or type(Diploma) ~= "table" or not Diploma.render then return end
    local Font = require("src.render.Font")
    local function zeile_zeichnen(fd, text, x, y)
      local spalte = x
      -- Stücke zwischen Kreis-Kacheln (\1); \2 markiert das Ende (Lua-5.1-Muster vertragen kein \0)
      for teil, kreis in (text .. "\2"):gmatch("([^\1\2]*)([\1\2])") do
        if teil ~= "" then
          fd(teil, spalte * 8, y * 8)
          spalte = spalte + Font.glyphCount(teil)
        end
        if kreis == "\1" then
          local r, g, b, a = love.graphics.getColor()
          love.graphics.setColor(1, 1, 1, 1)
          if K.diplom_gelb then
            -- Gelb: Kreis-Kachel $10 aus den Urkunden-Kacheln (diploma2.asm CIRCLE_TILE_ID)
            local TileAtlas = require("src.render.TileAtlas")
            pcall(TileAtlas.draw, TileAtlas.image(K.diplom_gelb.tiles), 0x10, spalte * 8, y * 8)
          else
            local okb, bild = pcall(Assets.image, "assets/generated/trainer_card/circle_tile.png")
            if okb and bild then love.graphics.draw(bild, spalte * 8, y * 8) end
          end
          love.graphics.setColor(r, g, b, a)
          spalte = spalte + 1
        end
      end
    end
    local function eintrag(fd, e)
      local y = e.y
      for _, z in ipairs(e.zeilen) do
        zeile_zeichnen(fd, z, e.x, y)
        y = y + 2
      end
    end
    local original = Diploma.render
    Diploma.render = function(game, ...)
      -- Gelb: renderYellowTop setzt dieselben Stellen (diploma2.asm), mit Rahmen und Kacheln der Gelb-Urkunde
      local felder = GameVersion.isYellow and GameVersion.isYellow() and game.data and game.data.field
      K.diplom_gelb = felder and felder.yellowPages and felder.yellowPages.diploma or nil
      local fd = Font.draw
      Font.draw = function(text, x, y, ...)
        if x == 48 and y == 16 then
          -- Titelzeile leeren (englische Kreis-Kacheln) und deutsch neu setzen
          local r, g, b, a = love.graphics.getColor()
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.rectangle("fill", 8, 16, 144, 8)
          love.graphics.setColor(r, g, b, a)
          for _, e in ipairs(d.texte) do
            if e.y == 2 then eintrag(fd, e) end
          end
          return
        end
        if x == 24 and y == 32 then
          for _, e in ipairs(d.texte) do
            if e.y ~= 2 then eintrag(fd, e) end
          end
          local name = (game.save and game.save.player and game.save.player.name) or "RED"
          fd(name, d.name.x * 8, d.name.y * 8)
          return
        end
        if EN_DIPLOM[x .. "," .. y] then return end
        return fd(text, x, y, ...)
      end
      local ok2, err = pcall(original, game, ...)
      Font.draw = fd
      if not ok2 then error(err, 0) end
    end
  end

  -- ---------------------------------------------------------------- Anwenden
  local function anwenden(daten, bilder, bericht, schluessel)
    local c = mod.content
    -- englische Fassung der Labels, die der Zeilentausch braucht (bevor die deutschen Texte eingehängt werden)
    K.en_text = {}
    for _, e in ipairs(ZEILENTAUSCH) do
      for _, lab in ipairs(e[3]) do K.en_text[lab] = Data.text and Data.text[lab] end
    end
    -- Texte (Data.text, Schlüssel = pokered-Labels)
    local n = 0
    for label, text in pairs(daten.text or {}) do
      c.text:override(label, text)
      n = n + 1
    end
    bericht.texte = n
    -- Namen
    n = 0
    for id, p in pairs(daten.pokemon or {}) do
      local alt = Data.pokemon and Data.pokemon[id]
      if alt then
        local eintrag = { name = p.name }
        if p.dexEntry and alt.dexEntry then
          local d = kopie(alt.dexEntry)
          d.kind, d.heightM, d.weightKg = p.dexEntry.kind, p.dexEntry.heightM, p.dexEntry.weightKg
          d.text = p.dexEntry.text or d.text
          eintrag.dexEntry = d
        end
        c.pokemon:patch(id, eintrag)
        n = n + 1
      end
    end
    bericht.pokemon = n
    for id, mv in pairs(daten.moves or {}) do
      if Data.moves and Data.moves[id] then c.moves:patch(id, { name = mv.name }) end
    end
    for id, it in pairs(daten.items or {}) do
      if Data.items and Data.items[id] then c.items:patch(id, { name = it.name }) end
    end
    for id, tr in pairs(daten.trainers or {}) do
      if type(tr) == "table" and tr.name and Data.trainers and Data.trainers[id] then
        c.trainers:patch(id, { name = tr.name })
      end
    end
    -- Statuskürzel (Kampf-HUD, Team, Statusbildschirm): der Port zeichnet das Label der Status-Registry ohne Strings()
    -- (Status.hudLabelFor) → Label aus den Sofortwerten der DE-ROM (PrintStatusAilment, Rezept status)
    if type(daten.status) == "table" and c.statuses then
      for id, label in pairs(daten.status) do
        pcall(function() c.statuses:patch(id, { label = label }) end)
      end
    end
    -- Typnamen: Reihenfolge der ROM-Liste; Zuordnung zur Typ-ID über die englischen Namen derselben Liste
    local en_namen = Data.type_chart and Data.type_chart.names
    local de_namen = daten.type_chart and daten.type_chart.names
    if en_namen and de_namen then
      local TypeChart = require("src.battle.TypeChart")
      for i, en in ipairs(en_namen) do
        for id, rec in pairs(TypeChart.TYPES) do
          if rec.name == en and de_namen[i] then
            c.type_chart:patch(id, { name = de_namen[i] })
          end
        end
      end
    end
    -- Zeichensatz: Zuordnung Folge → Code direkt im Datensatz (die englischen Ligaturen müssen weg; die Registry
    -- kann nur ergänzen)
    if daten.font and daten.font.charmap and Data.font then
      Data.font.charmap = daten.font.charmap
    end
    -- Port-Texte: Prüfsumme → deutscher Text (ROM vor Port-Zusätzen), eingehängt beim Laden der Mods
    bericht.porttexte = G.porttexte_einhaengen(daten.porttexte, daten.portkontexte, daten.text)
    G.romliterale_einhaengen(daten.romliterale)
    G.mengen_einhaengen(K.rezept and K.rezept.mg)
    -- Trainerklasse des Port-Bonuskampfs (OPP_CHIEF): im Original unbenutzt, die DE-ROM führt sie unübersetzt als
    -- „CHIEF“; Nutzerentscheidung 15.10.2026 „CHEF“ → Name aus dem Port-Zusatz, wenn der Katalog ihn als Zusatz führt
    for id, tr in pairs(Data.trainers or {}) do
      local name = type(tr) == "table" and (daten.trainers and daten.trainers[id] and daten.trainers[id].name or tr.name)
      if type(name) == "string" then
        local chk = G.pruefsumme(name)
        local w = G.katalog and G.katalog[chk]
        if type(w) == "string" and G.katalog_quelle and G.katalog_quelle[chk] == "zusatz" then
          c.trainers:patch(id, { name = w })
        end
      end
    end
    if daten.diplom then K.diplom_einhaengen(daten.diplom) end
    K.trainerpass_einhaengen()
    if daten.alphabet then K.alphabet_einhaengen(daten.alphabet) end
    if daten.kampfmenue then K.kampfmenue_einhaengen(daten.kampfmenue) end
    -- Namen: Tausch-Spitznamen und Namensvorschläge der DE-ROM (field.trades / field.boot.namePresets)
    local nm = daten.namen
    if nm and Data.field then
      for i, t in ipairs(Data.field.trades or {}) do
        if nm.tausch and nm.tausch[i] then t.nickname = nm.tausch[i] end
      end
      local boot = Data.field.boot
      if boot and nm.spieler and nm.rivale then
        boot.namePresets = { player = nm.spieler, rival = nm.rivale }
      end
    end
    -- Arena-Statuen: der Port setzt {RAM:wGymCityName}/{RAM:wGymLeaderName} aus data/scripts/gyms.lua ein (englische
    -- Namen) – wie im Original kommen sie aus dem Arena-Skript der DE-ROM (OverworldController.lua:3043, nur Anzeige)
    if daten.arenen then
      local ok, gyms = pcall(require, "data.scripts.gyms")
      if ok and type(gyms) == "table" then
        for karte, a in pairs(daten.arenen) do
          local g = gyms[karte]
          if type(g) == "table" then
            if a.stadt then g.city = a.stadt end
            if a.leiter then g.leader = a.leiter end
          end
        end
      end
    end
    -- Pokémon-Namen in Skripttexten: Port-Skripte setzen {RAM:…} mit dem Artschlüssel ein (data/scripts/oaks_lab.lua
    -- „{ RAM = species }“, src/script/Commands.lua _GotMonText), das Original kopiert den Namen der Art (GetMonName,
    -- deutsch aus der DE-ROM) in wNameBuffer → Schlüssel durch den Namen aus Data.pokemon ersetzen
    local okC, Commands = pcall(require, "src.script.Commands")
    if okC and type(Commands) == "table" and type(Commands.show_text) == "function" then
      local alt_show = Commands.show_text
      Commands.show_text = function(ctx, textId, subs, ...)
        -- give_pokemon setzt ctx.pendingPokemonName (Artschlüssel), das Original nimmt ihn vor subs.RAM
        -- („RED erhält MAGIKARP!“, Karpador-Verkäufer; Detektor union_gen1_flow 22.10.)
        if type(ctx) == "table" and type(ctx.pendingPokemonName) == "string" then
          local arten = (ctx.game and ctx.game.data and ctx.game.data.pokemon) or Data.pokemon or {}
          local art = arten[ctx.pendingPokemonName]
          if type(art) == "table" and type(art.name) == "string" then ctx.pendingPokemonName = art.name end
        end
        if type(subs) == "table" then
          local arten = (ctx and ctx.game and ctx.game.data and ctx.game.data.pokemon) or Data.pokemon or {}
          local neu
          for k, v in pairs(subs) do
            local art = type(v) == "string" and arten[v]
            if type(art) == "table" and type(art.name) == "string" and art.name ~= v then
              neu = neu or {}
              neu[k] = art.name
            end
          end
          if neu then
            local kopie = {}
            for k, v in pairs(subs) do kopie[k] = neu[k] or v end
            subs = kopie
          end
        end
        return alt_show(ctx, textId, subs, ...)
      end
    end
    -- Pokédex-Eintrag, metrisch: die DE-ROM schreibt „0.6m“/„8.5kg“ mit dem Dezimalpunkt der Schrift; der Port wandelt
    -- den Punkt nach dem Formatieren in ein Komma (src/ui/DexEntryMenu.lua render, gsub) → während render die Ziffer-
    -- Komma-Ziffer-Folge als <DOT> zeichnen (gleiche Kachel wie die Zoll-Anzeige des Ports, pokered PrintNumber)
    pcall(function()
      local Dex = require("src.ui.DexEntryMenu")
      local Font = require("src.render.Font")
      local alt_render = Dex.render
      Dex.render = function(...)
        local fd = Font.draw
        Font.draw = function(text, ...)
          if type(text) == "string" and text:find("%d,%d") then text = text:gsub("(%d),(%d)", "%1<DOT>%2") end
          return fd(text, ...)
        end
        local ok, r1, r2 = pcall(alt_render, ...)
        Font.draw = fd
        if not ok then error(r1, 0) end
        return r1, r2
      end
    end)
    -- Statusseite 2: EN setzt vor die AP-Werte zweimal die Kachel $72 („PP“, status_screen.asm PrintPP über die
    -- Routine EN 04:6CCB), die DE-ROM die Schriftzeichen $80 $8F „AP“ (eigene Routine DE 04:6CD6, Gelb 04:5879:
    -- ld a,$80 / ld [hli],a / ld a,$8F / ld [hld],a).  Der Port übernimmt die EN-Kacheln (SummaryMenu.lua) → hier
    -- während der Statusseite die beiden $72-Kacheln durch die DE-Zeichen ersetzen
    pcall(function()
      local SM = require("src.ui.SummaryMenu")
      local Hud = require("src.render.HudTiles")
      local Font = require("src.render.Font")
      local alt_draw = SM.draw
      SM.draw = function(self, ...)
        local st = Hud.statusTile
        Hud.statusTile = function(id, x, y, ...)
          if id == 0x72 and (x == 88 or x == 96) then
            love.graphics.setColor(0, 0, 0, 1)
            return Font.drawCode(x == 88 and 0x80 or 0x8F, x, y)
          end
          return st(id, x, y, ...)
        end
        local ok, r1 = pcall(alt_draw, self, ...)
        Hud.statusTile = st
        if not ok then error(r1, 0) end
        return r1
      end
    end)
    -- Spielstand-Fenster beim SICHERN (StartMenu.lua: Rahmen 4,0 Breite 16, Beschriftungen Spalte 5): die DE-ROM setzt
    -- Rahmen und Beschriftungen eine Spalte weiter links und den Rahmen breiter (save.asm, „SPIELER RED“) – Werte aus
    -- dem Rezept; erkannt am Rahmenaufruf des Fensters, die Beschriftungen danach bis zum nächsten Rahmen
    local sf = K.rezept and K.rezept.speicherfenster
    if type(sf) == "table" and type(sf.en) == "table" and type(sf.de) == "table" then
      pcall(function()
        local Font = require("src.render.Font")
        local e, d = sf.en, sf.de
        local box, draw, aktiv = Font.drawBox, Font.draw, false
        Font.drawBox = function(tx, ty, tw, th, ...)
          aktiv = tx == e[1] and ty == 0 and tw == e[2] + 2 and th == 10
          if aktiv then return box(d[1], ty, d[2] + 2, th, ...) end
          return box(tx, ty, tw, th, ...)
        end
        Font.draw = function(text, x, y, ...)
          if aktiv and x == e[3] * 8 and (y == 16 or y == 32 or y == 48 or y == 64) then x = d[3] * 8 end
          return draw(text, x, y, ...)
        end
      end)
    end
    -- JA/NEIN-Fenster: die DE-ROM schreibt „NEIN“ (Menü YES_NO 5 statt 4 Zeichen breit, TwoOptionMenuStrings) und
    -- setzt das Standardfenster eine Spalte weiter links (InitYesNoTextBoxParameters hlcoord 13,7 statt 14,7).  Der
    -- Port hat die EN-Maße fest im Theme → aus dem Rezept anpassen (Fenster mit EN-Breite des JA/NEIN-Menüs)
    local zo = K.rezept and K.rezept.zwei_optionen
    if type(zo) == "table" and type(zo.ja_nein) == "table" then
      pcall(function()
        local Theme = require("src.ui.Theme")
        local mehr = zo.ja_nein[2] - zo.ja_nein[1]
        for _, name in ipairs({ "choiceBox", "saveBox", "trainerSwitchBox", "useNextMonBox" }) do
          local b = Theme[name]
          if type(b) == "table" and b.tw == zo.ja_nein[1] + 2 then
            b.tw = b.tw + mehr
            for _, f in ipairs(zo.fenster or {}) do
              if b.tx == f[1] and b.ty == f[2] then b.tx, b.ty = f[3], f[4] break end
            end
          end
        end
      end)
    end
    -- Ladebericht (Port-Zusatz, src/ui/QuarantineReport.lua, nur Gen 1 zeigt ihn): erscheint einmal nach dem Laden,
    -- wenn sich die aktiven Mods geändert haben oder Daten aussortiert wurden – z. B. beim ersten Laden eines alten
    -- Spielstands mit Definitiv German.  Überschriften und Hinweis sind dort feste Literale (kein Strings()) → die
    -- Zeilen hier aus denselben Berichtsfeldern deutsch aufbauen, Arten/Items mit ihrem deutschen Namen
    pcall(function()
      local SaveData = require("src.core.SaveData")
      local function mod_zahl(n) return n == 1 and "1 Mod" or (n .. " Mods") end
      SaveData.modsDiffNotice = function(diff, meta)
        if type(diff) ~= "table" then return nil end
        local weg, anders, neu = #(diff.removed or {}), #(diff.changed or {}), #(diff.added or {})
        if weg == 0 and anders == 0 and neu == 0 then return nil end
        local mit = #((type(meta) == "table" and meta.mods) or {})
        local teile = {}
        if weg > 0 then teile[#teile + 1] = weg .. " nicht mehr aktiv" end
        if anders > 0 then teile[#teile + 1] = anders .. " in anderer Version" end
        if neu > 0 then teile[#teile + 1] = neu .. " neu aktiv" end
        return ("Dieser Spielstand entstand mit %s; %s."):format(mod_zahl(mit), table.concat(teile, ", "))
      end
      local QR = require("src.ui.QuarantineReport")
      local alt_new = QR.new
      local BREITE = 18
      local function laenge(t) return #(t:gsub("[\128-\191]", "")) end
      local function kurz(t)
        t = tostring(t)
        local aus, n = {}, 0
        for z in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          n = n + 1
          if n > BREITE then break end
          aus[n] = z
        end
        return table.concat(aus)
      end
      local ORT = { party = "TEAM", daycare = "PENSION", inventory = "ITEMS", pcItems = "PC" }
      local function ort(w)
        if type(w) ~= "string" then return "?" end
        local b = w:match("^box (%d+)$")
        return b and ("BOX " .. b) or ORT[w] or w
      end
      local function art(sp) local e = sp and Data.pokemon and Data.pokemon[sp]; return e and e.name or tostring(sp or "?") end
      local function item(id) local e = id and Data.items and Data.items[id]; return e and e.name or tostring(id or "?") end
      QR.new = function(game, report, ...)
        local self = alt_new(game, report, ...)
        local r = self.report or {}
        local z = {}
        local function abschnitt(kopf, zeilen)
          if #zeilen == 0 then return end
          if #z > 0 then z[#z + 1] = "" end
          z[#z + 1] = kopf
          for _, s in ipairs(zeilen) do z[#z + 1] = kurz(" " .. s) end
        end
        if r.recovered then
          z[#z + 1] = "Spielstand aus der"
          z[#z + 1] = kurz(" Kopie ." .. tostring(r.recovered))
          z[#z + 1] = " geladen."
        end
        local zl = {}
        for _, m in ipairs(r.lostMons or {}) do zl[#zl + 1] = ("%s (%s)"):format(art(m.species), ort(m.from)) end
        abschnitt("In Verwahrung:", zl)
        zl = {}
        for _, i in ipairs(r.lostItems or {}) do zl[#zl + 1] = ("%s ×%d"):format(item(i.id), i.count or 1) end
        abschnitt("Items entfernt:", zl)
        zl = {}
        for _, m in ipairs(r.remappedMaps or {}) do
          zl[#zl + 1] = m.to and ("%s>%s"):format(m.id or "?", m.to) or ("%s (%s)"):format(m.id or "?", m.field or "?")
        end
        abschnitt("Ort zurückgesetzt:", zl)
        zl = {}
        for _, m in ipairs(r.restoredMons or {}) do zl[#zl + 1] = ("%s in BOX %d"):format(art(m.species), m.box or 0) end
        for _, i in ipairs(r.restoredItems or {}) do zl[#zl + 1] = ("%s ×%d"):format(item(i.id), i.count or 1) end
        abschnitt("Zurückgeholt:", zl)
        local hinweis = SaveData.modsDiffNotice(r.modsDiff, game and game.save and game.save.meta)
        if hinweis then
          if #z > 0 then z[#z + 1] = "" end
          for wort in hinweis:gmatch("%S+") do
            local letzte = z[#z]
            if letzte and letzte ~= "" and laenge(letzte) + laenge(wort) + 1 <= BREITE then z[#z] = letzte .. " " .. wort
            else z[#z + 1] = wort end
          end
        end
        self.lines = z
        return self
      end
    end)
    -- Abspann: deutsche Bildschirme; die Pokémon der MON-Bildschirme in der Reihenfolge von CreditsMons (gleich
    -- viele MON-Bildschirme in EN und DE, Test/werkzeug/gb_abspann.py)
    local cr = Data.field and Data.field.credits
    if daten.abspann and type(cr) == "table" and type(cr.mons) == "table" then
      local neu, i = {}, 0
      for _, s in ipairs(daten.abspann) do
        local e = { fade = s.fade, lines = s.lines, copyright = s.copyright }
        if s.mon then
          i = i + 1
          e.mon = cr.mons[i]
        end
        neu[#neu + 1] = e
      end
      if i == #cr.mons then cr.screens = neu end
    end
    K.zeilentausch_einhaengen(daten)
    -- Geist im PKMN-TURM: disguiseAsGhost setzt das Literal "GHOST" als Gegnernamen → Name aus der DE-ROM
    if daten.geist then
      local ok, BS = pcall(require, "src.battle.BattleState")
      for _, fn in ipairs({ "makeGhost", "makeUnveiledGhost" }) do
        if ok and type(BS) == "table" and type(BS[fn]) == "function" then
          local original = BS[fn]
          BS[fn] = function(self, ...)
            local r = original(self, ...)
            if self.enemy and self.enemy.name == "GHOST" then self.enemy.name = daten.geist end
            return r
          end
        end
      end
    end
    -- Spielautomat: resolveLose setzt das englische Literal von NotThisTimeText (slot_machine.asm) → DE-ROM-Text
    do
      local ok, SM = pcall(require, "src.ui.SlotMachine")
      local de_t = daten.text and daten.text._NotThisTimeText
      if ok and type(SM) == "table" and type(SM.resolveLose) == "function" and de_t then
        local original = SM.resolveLose
        SM.resolveLose = function(self, ...)
          local r = original(self, ...)
          if type(self.message) == "string" and G.pruefsumme(self.message) == "~66be2676000e" then
            self.message = require("src.render.TextBox").strip(de_t)
          end
          return r
        end
      end
    end
    -- Bilder mit deutscher Schrift (Mod-Cache, Assets.resolve; Feldpfade direkt an newImage umgebogen)
    n = G.bilder_einhaengen(bilder, schluessel, { Data.field })
    -- Titel: deutscher Schriftzug als durchgehendes Band (field.boot.title.versionRibbon wird als ganzes Bild
    -- gezeichnet, 160 px breit = genau an den DE-Spalten), Copyright-Zeile als eigenes Bild
    if bilder["title/de_versionsband.png"] and Data.field then
      Data.field.boot = Data.field.boot or {}
      Data.field.boot.title = Data.field.boot.title or {}
      Data.field.boot.title.versionRibbon = "assets/generated/title/de_versionsband.png"
    end
    if bilder["title/de_copyright_zeile.png"] then
      local TitleState = require("src.ui.TitleState")
      local original = TitleState.drawCopyright
      local bild
      TitleState.drawCopyright = function(self, y)
        if not self.title.copyrightText then
          bild = bild or Assets.image("assets/generated/title/de_copyright_zeile.png")
          if bild then
            love.graphics.draw(bild, 0, y)
            return
          end
        end
        return original(self, y)
      end
    end
    bericht.bilder = n
  end

  -- ---------------------------------------------------------------- Start
  function K.start()
    local edition = GameVersion.get()
    local id = IMPORT[edition]
    if not id then return end
    local info, err = mod.imports:info(id)
    if not info then
      mod.log:warn("Definitiv German: deutsche ROM für %s nicht importiert (%s) – das Spiel bleibt englisch. "
        .. "Im Launcher unter MODS die deutsche ROM importieren.", edition, tostring(err))
      return
    end
    local Z = assert(datei("zeichen.lua"))
    local rezept, rerr = datei("rezept_" .. edition .. ".lua")
    K.rezept = rezept
    if not rezept then
      mod.log:warn("Definitiv German: Rezept fehlt: %s", tostring(rerr))
      return
    end
    local rezept_text = mod:read("rezept_" .. edition .. ".lua") or ""
    -- Cache gilt nur für genau diesen Mod-Stand: Rezept, Kern und gemeinsame Bausteine über ihre Prüfsumme
    local stand = pruefsumme(rezept_text .. (mod:read("kern.lua") or "") .. (mod:read("gemeinsam.lua") or ""))
    local schluessel = ("v6/%s/%s/%s-%s/%s-%s"):format(edition, info.md5 or "?", MODVERSION, stand:sub(2),
      Version.engine or "?", Version.cache or "?")
    local bericht = {}
    local daten, bilder = cache_lesen(schluessel)
    if daten then
      bericht.quelle = "Cache"
    else
      local rom, rerr2 = mod.imports:read(id, 0, info.size)
      if not rom then
        mod.log:warn("Definitiv German: deutsche ROM nicht lesbar: %s", tostring(rerr2))
        return
      end
      local t0 = love.timer and love.timer.getTime() or 0
      local fehler
      daten, bilder, fehler = extrahieren(edition, rom, rezept, Z)
      for _, f in ipairs(fehler) do mod.log:warn("Definitiv German: %s", f) end
      bericht.quelle = ("DE-ROM (%.1f s)"):format((love.timer and love.timer.getTime() or 0) - t0)
      if #fehler == 0 then cache_schreiben(schluessel, daten, bilder) end
    end
    anwenden(daten, bilder, bericht, schluessel)
    mod.log:info("Definitiv German Gen 1 (%s): %d Texte, %d Pokémon, %d Bilder – aus %s", edition,
      bericht.texte or 0, bericht.pokemon or 0, bericht.bilder or 0, bericht.quelle)
    mod.log:info("Definitiv German Gen 1: %d Port-Texte aus der ROM", bericht.porttexte or 0)
    K.daten = daten
    K.aktiv = true
    return true
  end

  return K
end
