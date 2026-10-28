-- Definitiv German Gen 1 – Kern: deutsche ROM mit dem Extraktor des Ports auslesen und das Ergebnis übernehmen.
--
-- Der Port liest beim Import die englische ROM über eine Symboltabelle (Name → Bank/Adresse).  Das Rezept der
-- Edition (rezept_<edition>.lua) enthält dieselben Symbole mit ihren Adressen in der DEUTSCHEN ROM.  Damit läuft der
-- unveränderte Extraktor des Ports über die deutsche ROM des Spielers; Texte, Namen und Grafiken entstehen so, wie
-- der Port sie aus einer deutschen ROM gewinnen würde.  Übernommen werden nur Anzeigeinhalte (Texte, Namen, Pokédex,
-- Schrift, Bilder mit Schrift); Spieldaten bleiben unverändert.  Wo der Port eine feste englische Lage oder ein
-- festes Literal zeichnet, setzen die Haken unten Lage bzw. Text aus der DE-ROM.
--
-- Das Ergebnis liegt im Mod-Cache (Schlüssel: MD5 der DE-ROM, Mod-Version, Prüfsumme von Rezept/Kern/gemeinsam.lua,
-- Port-Version) und wird beim nächsten Start nur noch geladen.
--
-- Gliederung: Hilfen · Extraktion · Haken (Menüs, Kampf, Fenster und Lagen, Bildschirme, Bilder) · Anwenden · Start
return function(mod, MODVERSION)
  local GameVersion = require("src.core.GameVersion")
  local Data = require("src.core.Data")
  local RomExtractor = require("src.import.RomExtractor")
  local ImageWriter = require("src.import.ImageWriter")
  local Assets = require("src.render.Assets")
  local Version = require("src.core.Version")

  -- Gemeinsame Bausteine aller drei Mods (Prüfsumme, Katalog, Kontexte, Port-Texte aus der ROM, Cache, Bilder)
  local G = assert(load(mod:read("gemeinsam.lua"), "@gemeinsam.lua"))()(mod)
  local pruefsumme, datei, kopie, romtext, ohne_ende = G.pruefsumme, G.datei, G.kopie, G.romtext, G.ohne_ende
  local K = {}

  local IMPORT = { red = "rot_de", blue = "blau_de", yellow = "gelb_de" }
  -- Stufen des Port-Extraktors mit Anzeigeinhalten (src/import/RomExtractor.lua); die übrigen liefern nur
  -- Spieldaten, Karten und Töne, die aus der englischen ROM des Ports bleiben
  local STUFEN = { "extractFont", "extractMoves", "extractItems", "extractTypeChart", "extractPokemon",
    "extractTrainers", "extractText", "extractField", "extractTilesets" }

  -- ================================================================ Hilfen

  -- fn(...) aufrufen, während Felder ersetzt sind ({ { Tabelle, Feld, neuer Wert }, … }); danach in jedem Fall
  -- zurücksetzen und Fehler weiterreichen
  local function zurueck(alt, ok, ...)
    for i = #alt, 1, -1 do alt[i][1][alt[i][2]] = alt[i][3] end
    if not ok then error((...), 0) end
    return ...
  end
  local function ersetzt(felder, fn, ...)
    local alt = {}
    for i, f in ipairs(felder) do
      alt[i] = { f[1], f[2], f[1][f[2]] }
      f[1][f[2]] = f[3]
    end
    return zurueck(alt, pcall(fn, ...))
  end

  -- fn(...) mit weißer Zeichenfarbe (Kacheln und Bilder), danach die vorige Farbe
  local function weiss(fn, ...)
    local r, g, b, a = love.graphics.getColor()
    love.graphics.setColor(1, 1, 1, 1)
    fn(...)
    love.graphics.setColor(r, g, b, a)
  end

  -- UTF-8: Zeichenzahl und auf n Zeichen kürzen
  local function laenge(t) return #(t:gsub("[\128-\191]", "")) end
  local function kuerzen(t, n)
    local aus, i = {}, 0
    for z in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      i = i + 1
      if i > n then break end
      aus[i] = z
    end
    return table.concat(aus)
  end

  -- Codes ab Bank/Adresse bis zum Endzeichen $50 (höchstens max)
  local function codes_lesen(ex, bank, adr, max)
    local t = {}
    for _ = 1, max do
      local x = ex.rom:byte(bank, adr)
      adr = adr + 1
      if x == 0x50 then break end
      t[#t + 1] = x
    end
    return t, adr
  end

  -- Codes in Textzeilen (Umbruch an $4E/$4F; $54 = „POKé“; extra: Code → eigene Zeichenfolge)
  local function zeilen_aus_codes(codes, charmap, extra)
    local zeilen, zeile = {}, {}
    for _, x in ipairs(codes) do
      if x == 0x4E or x == 0x4F then
        zeilen[#zeilen + 1] = table.concat(zeile)
        zeile = {}
      elseif extra and extra[x] then
        zeile[#zeile + 1] = extra[x]
      elseif x == 0x54 then
        zeile[#zeile + 1] = "POKé"
      else
        zeile[#zeile + 1] = charmap[tostring(x)] or ""
      end
    end
    zeilen[#zeilen + 1] = table.concat(zeile)
    return zeilen
  end

  -- ================================================================ Extraktion

  -- Manifest des Ports mit den DE-Adressen des Rezepts und dem deutschen Zeichensatz
  local function manifest(edition, rezept, Z)
    local m = G.rom_manifest(edition)
    local syms = {}
    for name, ort in pairs(m.symbols) do
      -- RAM-Symbole (≥ $8000) bleiben; ROM-Symbole nur mit belegter DE-Adresse
      if ort[2] >= 0x8000 then syms[name] = ort end
    end
    for name, ort in pairs(rezept.s) do syms[name] = { ort[1], ort[2] } end
    m.symbols = syms
    if m.text then m.text.dynamic = kopie(rezept.d) end
    Z.anwenden(m)
    return m
  end

  -- Pokédex der deutschen Editionen: Kategorie@, Größe (1 Byte, Dezimeter), Gewicht (2 Byte, Hektogramm), text_far.
  -- Der Port zeigt metrische Werte über dexEntry.heightM / weightKg (src/ui/DexEntryMenu.lua).
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

  -- Gelb: der deutsche Titel des Surf-Minispiels ist EINE bildschirmfüllende Tilemap (20×18, Rezept e), nicht vier
  -- Teile.  Zusammengesetzt wie im Port (RomExtractor extractSurfingPikachuTitleArt), nur aus dieser Tilemap.
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

  -- Titelbildschirm: Versions-Schriftzug und Copyright-Zeile setzt die DE-ROM anders zusammen als die englische
  -- (andere Kachelfolge, andere Spalte, zusätzliche Kacheln).  Beide Zeilen genau nach dem DE-Titelcode als
  -- 160×8-Bild (Rezept titel: version / copyright / laden).
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

  -- Copyright-Tafel vor dem Intro (LoadCopyrightTiles, intro.asm): die DE-ROM lädt ab Kachel $60 andere bzw. mehr
  -- Kacheln (R/B 29 statt 28) und schreibt CopyrightTextString mit anderer Jahresfolge.  Der Port legt die EN-Folge
  -- fest auf das Kachelblatt (IntroMovie.lua COPY_PREFIX_*) → die drei Zeilen nach dem DE-Code als Bild (160×40,
  -- Zeilen im Abstand von zwei Kachelzeilen; Rezept copyrightkarte: Kacheln Bank/Adresse/Anzahl, Text, Spalte)
  local function copyrightkarte(ex, k, bilder)
    if not (k and k.kacheln and k.text) then return end
    local b, adr, anzahl = k.kacheln[1], k.kacheln[2], k.kacheln[3]
    local bild = ImageWriter.blank(160, 40, 1, 1, 1, 0)
    local spalte, zeile = k.spalte or 2, 0
    for _, code in ipairs((codes_lesen(ex, k.text[1], k.text[2], 80))) do
      if code == 0x4E or code == 0x4F then
        spalte, zeile = k.spalte or 2, zeile + 2
      else
        local i = code - 0x60
        if code ~= 0x7F and i >= 0 and i < anzahl then
          local raw = ex.rom:bytes(b, adr + i * 16, 16)
          ImageWriter.blit(bild, ImageWriter.decode2bpp(raw, 8, 8, false), spalte * 8, zeile * 8)
        end
        spalte = spalte + 1
      end
    end
    bilder["title/de_copyright_karte.png"] = bild
  end

  -- Maschinen: der Port setzt die Namen fest als „HM%02d“/„TM%02d“ (RomExtractor extractItems); im Original setzt
  -- GetMachineName das Kürzel aus TechnicalPrefix/HiddenPrefix davor, DE „TM“/„VM“ (Rezept maschinen)
  local function maschinen_kuerzel(ex, ma, charmap, items)
    if not ma or type(items) ~= "table" then return end
    local function kuerzel(i)
      return (charmap[tostring(ex.rom:byte(ma[1], ma[2] + i))] or "")
        .. (charmap[tostring(ex.rom:byte(ma[1], ma[2] + i + 1))] or "")
    end
    local tm, vm = kuerzel(0), kuerzel(2)
    for _, it in pairs(items) do
      if type(it) == "table" and type(it.machine) == "table" and type(it.name) == "string" then
        local k = it.machine.kind == "HM" and vm or tm
        if #k == 2 then it.name = k .. it.name:sub(3) end
      end
    end
  end

  -- Gelb, Surf-Minispiel: die Ergebnistafel schreibt das Original mit Kacheln des Minispiel-Blatts (Kachelfolgen im
  -- Code, DE „Rest-KP“ … „Pkt“); Rezept surfergebnis = { x, y (Port-Pixel; false = jede Zeile), Bank, Adresse,
  -- Anzahl, Schritt (1 = Folge, 3 = Operanden von „ld [hl], n / inc hl“) }
  local function surfergebnis(ex, se)
    if not se then return nil end
    local t = {}
    for _, e in ipairs(se) do
      local ids = {}
      for i = 1, e[5] do ids[i] = ex.rom:byte(e[3], e[4] + (i - 1) * e[6]) end
      t[#t + 1] = { x = e[1], y = e[2] or false, kacheln = ids }
    end
    return t
  end

  -- Safari-Kampfmenü: Spalte der rechten Wörter aus der DE-Vorlage (SAFARI_BATTLE_MENU_TEMPLATE ab Spalte 2, erstes
  -- Wort nach der Lücke) und Cursor-Spalte rechts (DisplayBattleMenu .safariRightColumn „ld b, n“)
  local function safarimenue(ex, sm)
    if not sm then return nil end
    local adr, i, luecke, spalte = sm.zeichen[2], 0, false, nil
    for _ = 1, 30 do
      local x = ex.rom:byte(sm.zeichen[1], adr + i)
      if x == 0x50 or x == 0x4E then break end
      if x == 0x7F then luecke = true elseif luecke then spalte = 2 + i break end
      i = i + 1
    end
    local cursor = ex.rom:byte(sm.cursor[1], sm.cursor[2])
    if spalte and cursor and cursor < 20 then return { text = spalte, cursor = cursor } end
  end

  -- Weitere Lagen (Rezept lage): hlcoord-Operanden → Spalte/Zeile, Cursor- und Breitenbytes, Kachelfolge von „ENDE“
  -- (TheEndTextString: Buchstabenspalten $60 + 2·n, $7F leer), Gelb: Spalten des Surf-Rekords
  -- (Printer_PrepareSurfingMinigameHighScoreTileMap)
  local function lage(ex, la)
    if not la then return nil end
    local function feld(ort)
      if not ort then return nil end
      local w = ex.rom:word(ort[1], ort[2]) - 0xC3A0
      if w < 0 or w >= 360 then return nil end
      return { x = w % 20, y = math.floor(w / 20) }
    end
    local function byte(ort, max)
      local b = ort and ex.rom:byte(ort[1], ort[2])
      if b and b < max then return b end
    end
    local l = { muenzen = feld(la.muenzen), unentschieden = feld(la.unentschieden) }
    if la.automat then
      local k, c = feld(la.automat.kasten), byte(la.automat.cursor, 20)
      if k and c then l.automat = { x = k.x, y = k.y, cursor = c } end
    end
    local ab = byte(la.abbrechen, 19)
    if ab then l.abbrechen = ab + 2 end
    if la.ende then
      local ort, muster = feld(la.ende.ort), {}
      for _, x in ipairs((codes_lesen(ex, la.ende.text[1], la.ende.text[2], 20))) do
        if x == 0x7F then
          muster[#muster + 1] = -1
        elseif x >= 0x60 and x < 0x6A and x % 2 == 0 then
          muster[#muster + 1] = (x - 0x60) / 2
        else
          muster = nil
          break
        end
      end
      if ort and muster and #muster > 0 then l.ende = { x = ort.x, muster = muster } end
    end
    if la.surfrekord then
      local n, t = feld(la.surfrekord.name), feld(la.surfrekord.text)
      if n and t then l.surfrekord = { name = n.x, text = t.x } end
    end
    return l
  end

  -- Urkunde (Rot/Blau): Texte und Kachelpositionen der deutschen Tabelle; Zeilen getrennt, Kreis-Kachel als \1
  local function diplom(ex, d, charmap)
    if not d then return nil end
    local texte = {}
    for _, e in ipairs(d.texte) do
      local zeilen = zeilen_aus_codes((codes_lesen(ex, e[1], e[2], 200)), charmap, { [d.kreis or 0x70] = "\1" })
      texte[#texte + 1] = { x = e[3], y = e[4], zeilen = zeilen }
    end
    return { name = { x = d.name[1], y = d.name[2] }, texte = texte }
  end

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
      for _, x in ipairs((codes_lesen(ex, ort[1], adr, 30))) do t[#t + 1] = charmap[tostring(x)] or "" end
      raster[6] = { table.concat(t) }
      return raster
    end
    return { gross = tafel(a.gross), klein = tafel(a.klein) }
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
        for _, z in ipairs(zeilen_aus_codes((codes_lesen(ex, a.bank, s + 1, 40)), charmap)) do
          cur.lines[#cur.lines + 1] = { column = spalte, text = z }
        end
      end
    end
    return nil
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

  -- Arena-Statuen: Stadt- und Leitername je Arena (scripts/*Gym.asm .CityName/.LeaderName)
  local function arenen(ex, ar, charmap)
    if not ar then return nil end
    local t = {}
    for karte, a in pairs(ar) do
      t[karte] = { stadt = romtext(ex, charmap, a[1], a[2], 1, 0, 0), leiter = romtext(ex, charmap, a[1], a[3], 1, 0, 0) }
    end
    return t
  end

  -- Geist im PKMN-TURM: Name aus den Sofortwerten „ld a, n / ld [hli], a“ (core.asm .isGhost)
  local function geist(ex, ort, charmap)
    if not ort then return nil end
    local b, adr, t = ort[1], ort[2], {}
    for _ = 1, 10 do
      if ex.rom:byte(b, adr) ~= 0x3E or ex.rom:byte(b, adr + 2) ~= 0x22 then break end
      t[#t + 1] = charmap[tostring(ex.rom:byte(b, adr + 1))] or ""
      adr = adr + 3
    end
    if #t > 0 then return table.concat(t) end
  end

  -- Statuskürzel: fünf Blöcke „3E x 22 3E y 22 36 z C9“ (PrintStatusAilment), Reihenfolge SLP PSN BRN FRZ PAR
  local function status(ex, ort, charmap)
    if not ort then return nil end
    local r, b, adr, s = ex.rom, ort[1], ort[2], {}
    for _, id in ipairs({ "SLP", "PSN", "BRN", "FRZ", "PAR" }) do
      if r:byte(b, adr) ~= 0x3E or r:byte(b, adr + 2) ~= 0x22 or r:byte(b, adr + 3) ~= 0x3E
          or r:byte(b, adr + 5) ~= 0x22 or r:byte(b, adr + 6) ~= 0x36 or r:byte(b, adr + 8) ~= 0xC9 then
        return nil
      end
      s[id] = (charmap[tostring(r:byte(b, adr + 1))] or "") .. (charmap[tostring(r:byte(b, adr + 4))] or "")
        .. (charmap[tostring(r:byte(b, adr + 7))] or "")
      adr = adr + 9
    end
    return s
  end

  -- Kampfmenü: Layout aus dem Rezept, Zeichen als Codes der DE-Zeichenkette BattleMenuText (Zeilen an $4E/$4F)
  local function kampfmenue(ex, km)
    if not km then return nil end
    local codes, zeile = {}, {}
    for _, x in ipairs((codes_lesen(ex, km.zeichen[1], km.zeichen[2], 60))) do
      if x == 0x4E or x == 0x4F then
        codes[#codes + 1] = zeile
        zeile = {}
      else
        zeile[#zeile + 1] = x
      end
    end
    codes[#codes + 1] = zeile
    return { box = km.box, text = km.text, cursor = km.cursor, codes = codes }
  end

  local function extrahieren(edition, rom, rezept, Z)
    local m = manifest(edition, rezept, Z)
    local cm = m.charmap
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
    copyrightkarte(ex, rezept.copyrightkarte, bilder)
    maschinen_kuerzel(ex, rezept.maschinen, cm, daten.items)
    daten.surfergebnis = surfergebnis(ex, rezept.surfergebnis)
    daten.safarimenue = safarimenue(ex, rezept.safarimenue)
    daten.lage = lage(ex, rezept.lage)
    daten.porttexte, daten.portkontexte = G.porttexte_lesen(ex, rezept, cm, daten)
    daten.romliterale = G.romliterale_lesen(ex, rezept, cm)
    daten.diplom = diplom(ex, rezept.diplom, cm)
    daten.alphabet = alphabet(ex, rezept.alphabet, cm)
    daten.abspann = abspann(ex, rezept.abspann, cm)
    daten.namen = namen(ex, rezept.namen, cm)
    daten.arenen = arenen(ex, rezept.arenen, cm)
    daten.geist = geist(ex, rezept.geist, cm)
    daten.status = status(ex, rezept.status, cm)
    daten.kampfmenue = kampfmenue(ex, rezept.kampfmenue)
    -- nur Bilder behalten, die sich vom englischen Import unterscheiden (Schrift, Schilder, Titel …)
    for rel, bild in pairs(bilder) do
      if not G.anders_als_en(rel, bild) then bilder[rel] = nil end
    end
    return daten, bilder, fehler
  end

  -- ================================================================ Haken: Menüs

  -- Start- und Hauptmenü wie im Original.  Der Port hängt an das START-Menü „MODS“ und „BEENDEN“ (StartMenu.lua,
  -- statt „ZURÜCK“ = CloseStartMenu im Original) und an das Hauptmenü „SPIEL BEENDEN“ (TitleState.lua openMenu).
  -- Mit der Mod-Option ORIGINAL-MENÜS (Standard an) über die Hooks ui.start_menu.items / ui.title_menu.items wie im
  -- Original: START-Menü endet mit „ZURÜCK“ (schließt nur das Menü), Hauptmenü ohne SPIEL BEENDEN.  Erreichbar
  -- bleibt alles: Mod-Verwaltung über OPTION → MODS oder im Launcher, Titelbild mit A+B+SELECT+START, Beenden über
  -- das Fenster.
  local function original_menues()
    local ok, wert = pcall(function() return mod.options:get("originalmenues") end)
    return not ok or wert ~= false
  end
  -- Die Hooks bekommen die Zeilen des Ports; sie werden vor weiter() an ihrer festen Stelle gemerkt und danach über
  -- ihre Tabelle gefunden, Zeilen anderer Mods bleiben unberührt
  local function menues_einhaengen()
    if not (mod.hooks and mod.hooks.wrap) then return end
    local Strings = require("src.core.Strings")
    mod.hooks:wrap("ui.start_menu.items", function(weiter, game, items)
      local quit, mods
      if type(items) == "table" and original_menues() then
        -- StartMenu.lua: … OPTION, [MODS, wenn Mods vorhanden], QUIT als letzte Zeile
        local st = game and game.modStatus
        quit = items[#items]
        if st and #(st.available or {}) > 0 then mods = items[#items - 1] end
      end
      local liste = weiter(game, items)
      if type(liste) ~= "table" or not quit then return liste end
      local neu = {}
      for _, it in ipairs(liste) do
        if it == quit then
          neu[#neu + 1] = { label = Strings("EXIT"), onSelect = function() end }
        elseif it ~= mods then
          neu[#neu + 1] = it
        end
      end
      return neu
    end, 0)
    mod.hooks:wrap("ui.title_menu.items", function(weiter, game, items)
      -- TitleState.lua: [WEITER], NEUES SPIEL, OPTION, SPIEL BEENDEN als letzte Zeile
      local ende = type(items) == "table" and #items >= 3 and original_menues() and items[#items] or nil
      local liste = weiter(game, items)
      if type(liste) ~= "table" or not ende then return liste end
      local neu = {}
      for _, it in ipairs(liste) do
        if it ~= ende then neu[#neu + 1] = it end
      end
      return neu
    end, 0)
  end

  -- Mod-Verwaltung (Port-Zusatz ManagerState) kürzt Zeilen vor dem Zeichnen auf 15 bzw. 17 Zeichen; der Literal-
  -- tausch beim Zeichnen (zusatz.l) sähe dann nur den gekürzten englischen Text.  Deshalb hier schon Zeilenmodelle,
  -- Hinweise und Rückfragen übersetzen (dieselbe Tabelle) und Status-/Kategoriezeile der Detailseite deutsch setzen.
  local DATEI_MV = "src/mods/ManagerState.lua"
  local PROFIL = { content = "INHALT", overhaul = "UMBAU", total_conversion = "KOMPLETT" }
  local function verwaltung_einhaengen()
    local ok, MS = G.port_modul("src.mods.ManagerState")
    if not ok or type(MS) ~= "table" or type(MS.rowsForScreen) ~= "function" then return end
    local Font = require("src.render.Font")
    local function de(t)
      local e = G.literale and G.literale[DATEI_MV]
      if type(t) ~= "string" or not (e and G.tauschen) then return t end
      return G.tauschen(t, e)
    end
    -- Kategorien schreiben die Manifeste verschieden („Translation“, „GRAPHICS“): auch in Großbuchstaben nachschlagen
    local function kategorie(t)
      if type(t) ~= "string" then return t end
      local w = de(t)
      if w == t and de(t:upper()) ~= t:upper() then w = de(t:upper()) end
      return w
    end
    local alt_rows = MS.rowsForScreen
    MS.rowsForScreen = function(self, ...)
      local rows = alt_rows(self, ...)
      if type(rows) ~= "table" then return rows end
      for _, r in ipairs(rows) do
        if type(r) == "table" and type(r.label) == "string" and not r.mod and not r.profile then
          if r.header and self.screen == "list" and self.tab == 1 then
            r.label = kategorie(r.label)
          else
            r.label = de(r.label)
          end
        end
      end
      return rows
    end
    -- Ladereihenfolge („< LOAD #2/4 >“, „LOAD #1 OF 1“): Zahlen aus der Zeile, Text deutsch
    if type(MS.orderRows) == "function" then
      local alt_order = MS.orderRows
      MS.orderRows = function(self, m, ...)
        local rows = alt_order(self, m, ...)
        for _, r in ipairs(type(rows) == "table" and rows or {}) do
          local a, n
          if type(r.label) == "string" then a, n = r.label:match("(%d+)%D+(%d+)") end
          if a then r.label = r.adjust and ("PLATZ %s/%s"):format(a, n) or ("PLATZ %s VON %s"):format(a, n) end
        end
        return rows
      end
    end
    if type(MS.notify) == "function" then
      local alt_notify = MS.notify
      MS.notify = function(self, text, ...) return alt_notify(self, de(text), ...) end
    end
    if type(MS.drawOverlay) == "function" then
      local alt_overlay = MS.drawOverlay
      MS.drawOverlay = function(self, ...)
        local o = self.overlay
        if type(o) ~= "table" or type(o.lines) ~= "table" then return alt_overlay(self, ...) end
        local neu = {}
        for i, z in ipairs(o.lines) do neu[i] = de(z) end
        ersetzt({ { o, "lines", neu } }, alt_overlay, self, ...)
      end
    end
    if type(MS.drawDetail) == "function" then
      local alt_detail = MS.drawDetail
      MS.drawDetail = function(self, ...)
        local m = self.currentMod
        if type(m) ~= "table" then return alt_detail(self, ...) end
        local zustand = m.enabled and "AN" or "AUS"
        local okr, hier = pcall(self.runsHere, self, m)
        if m.state == "wrong_generation" or (okr and not hier) then
          zustand = zustand .. " (NICHT HIER)"
        elseif m.state == "blocked_dependency" then
          zustand = zustand .. " ?"
        elseif m.error then
          zustand = zustand .. " !"
        end
        local oks, vorgemerkt = pcall(self.isStaged, self, m)
        if oks and vorgemerkt then
          -- beides passt nicht in 17 Spalten: dann „vorgemerkt“ zeigen, warum nicht hier, sagt die Beschreibung
          if laenge(zustand .. " (VORGEMERKT)") > 17 then zustand = (m.enabled and "AN" or "AUS") end
          zustand = zustand .. " (VORGEMERKT)"
        end
        local kat, prof = kategorie(m.category or "OTHER"), PROFIL[m.profile or "content"] or tostring(m.profile)
        local zeile = kat .. " / " .. prof
        if laenge(zeile) > 17 then zeile = kat .. "/" .. prof end
        if laenge(zeile) > 17 then zeile = kat end
        local fd = Font.draw
        ersetzt({ { Font, "draw", function(text, x, y, ...)
          if x == 16 and y == 24 then text = kuerzen(zustand, 17)
          elseif x == 16 and y == 32 then text = kuerzen(zeile, 17) end
          return fd(text, x, y, ...)
        end } }, alt_detail, self, ...)
      end
    end
  end

  -- Namenseingabe: Buchstabentafeln der DE-ROM
  local function alphabet_einhaengen(a)
    if not (mod.hooks and mod.hooks.wrap) then return end
    mod.hooks:wrap("ui.naming.grid", function(_weiter, _base, ctx)
      return (ctx and ctx.lower) and a.klein or a.gross
    end)
  end

  -- ================================================================ Haken: Kampf

  -- Die DE-ROM setzt das Kampfmenü breiter (Kasten ab Spalte 6, Text ab Spalte 8, Cursor-Spalten 7/12); der Port
  -- zeichnet fest das englische Layout (Kasten ab 8).  Während drawTextArea im Menü: englischen Kasten und Menü-
  -- Glyphen abfangen, danach Kasten, Zeichen (Codes der DE-Zeichenkette) und Cursor nach DE setzen.
  local function kampfmenue_einhaengen(km)
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
      ersetzt({
        { Font, "drawBox", function(tx, ty, tw, th, ...)
          kasten = true
          local r
          if tx == 8 and ty == 12 and tw == 12 and th == 6 then
            r = db(km.box[1], km.box[2], km.box[3] - km.box[1] + 1, km.box[4] - km.box[2] + 1, ...)
          else
            r = db(tx, ty, tw, th, ...)
          end
          kasten = false
          return r
        end },
        { Font, "drawCode", function(code, x, y, ...)
          -- englische Menüzeilen und Cursor (alles rechts der Spalte 8 in den Menüzeilen, auch übergelaufene Zeichen
          -- des englisch platzierten „FLUCHT“); Kastenrahmen bleiben
          if not kasten and (y == 112 or y == 128) and x >= 72 then return end
          return dc(code, x, y, ...)
        end },
      }, original, self, ...)
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

  -- Safari-Kampfmenü: der Port setzt „KÖDER“/„FLUCHT“ fest in Spalte 14 und den rechten Cursor in Spalte 13
  -- (BattleState drawTextArea, englische Vorlage); die DE-ROM eine Spalte weiter links.  Während drawTextArea im
  -- Safari-Menü die Glyphen der rechten Spalte verschieben.
  local function safari_einhaengen(sm)
    local ok, BS = pcall(require, "src.battle.BattleState")
    if not ok or type(BS) ~= "table" or type(BS.drawTextArea) ~= "function" then return end
    local Font = require("src.render.Font")
    local versatz, cursor = (14 - sm.text) * 8, sm.cursor * 8
    if versatz == 0 and cursor == 104 then return end
    local original = BS.drawTextArea
    BS.drawTextArea = function(self, ...)
      if not (self.phase == "menu" and self.safari and not self.demo) then return original(self, ...) end
      local db, dc = Font.drawBox, Font.drawCode
      local kasten = false
      ersetzt({
        { Font, "drawBox", function(...)
          kasten = true
          local ok3, r = pcall(db, ...)
          kasten = false
          if not ok3 then error(r, 0) end
          return r
        end },
        { Font, "drawCode", function(code, x, y, ...)
          if not kasten and (y == 112 or y == 128) then
            if code == 0xED and x == 104 then x = cursor
            elseif x >= 112 and x < 160 then x = x - versatz end
          end
          return dc(code, x, y, ...)
        end },
      }, original, self, ...)
    end
  end

  -- Geist im PKMN-TURM: disguiseAsGhost setzt das Literal "GHOST" als Gegnernamen → Name aus der DE-ROM
  local function geist_einhaengen(name)
    local ok, BS = pcall(require, "src.battle.BattleState")
    for _, fn in ipairs({ "makeGhost", "makeUnveiledGhost" }) do
      if ok and type(BS) == "table" and type(BS[fn]) == "function" then
        local original = BS[fn]
        BS[fn] = function(self, ...)
          local r = original(self, ...)
          if self.enemy and self.enemy.name == "GHOST" then self.enemy.name = name end
          return r
        end
      end
    end
  end

  -- ================================================================ Haken: Fenster und Lagen

  -- Stellen mit fester EN-Lage im Port (Werte aus der DE-ROM, Extraktion lage): Münzfenster „MÜNZEN“
  -- (PrizeCounter.drawWindow, EN „COIN“ ab Spalte 12), Geldfenster „GELD“, Link-Ergebnis „UNENTSCHIEDEN“
  -- (LinkState.versus, EN „  DRAW“ ab Spalte 6), JA/NEIN „Noch eine Runde?“ am Spielautomaten (SlotMachine
  -- drawBottom, EN-Kasten 14,12, Cursor-Spalte 15), ABBRECHEN-Kasten im Handelscenter (CableFrame.box 0,15 Breite 11),
  -- Gelb: Surf-Rekord (SurfHiScore.render) und „ENDE“ im Abspann (field.credits.theEnd, Buchstabenfolge ab Spalte 4)
  local function lage_einhaengen(l, rezept)
    local Font = require("src.render.Font")
    local m = l.muenzen
    if m then
      pcall(function()
        local PC = require("src.ui.PrizeCounter")
        local original = PC.drawWindow
        if type(original) ~= "function" then return end
        local Strings = require("src.core.Strings")
        PC.drawWindow = function(...)
          -- der Port leert vier Rahmenkacheln ab Spalte 12 für „COIN“; das Original überschreibt nur die Kacheln
          -- unter dem Wort (PlaceString) → die Lücke auf das deutsche Wort an seiner Spalte legen
          local fd, rect = Font.draw, love.graphics.rectangle
          return ersetzt({
            { love.graphics, "rectangle", function(art, x, y, w, h, ...)
              if art == "fill" and x == 96 and y == 0 and w == 32 and h == 8 then
                x, w = m.x * 8, (Font.width(Strings("COIN")) or w)
              end
              return rect(art, x, y, w, h, ...)
            end },
            { Font, "draw", function(text, x, y, ...)
              if x == 96 and y == 0 then x = m.x * 8 end
              return fd(text, x, y, ...)
            end },
          }, original, ...)
        end
      end)
    end
    -- Geldfenster (MONEY_BOX, „GELD“ ab Spalte 13 auf dem oberen Rahmen): der Port leert dort fest fünf Kacheln für
    -- „MONEY“ (ShopMenu drawClerk, TextBox:draw); das Original überschreibt nur die Kacheln des Worts → während
    -- dieser Zeichnungen die Lücke auf die Breite des deutschen Worts setzen
    pcall(function()
      local Strings = require("src.core.Strings")
      local function luecke(fn)
        return function(...)
          local rect = love.graphics.rectangle
          return ersetzt({ { love.graphics, "rectangle", function(art, x, y, w, h, ...)
            if art == "fill" and x == 104 and y == 0 and w == 40 and h == 8 then
              local b = Font.width(Strings("MONEY"))
              if type(b) == "number" and b > 0 and b < 40 then w = b end
            end
            return rect(art, x, y, w, h, ...)
          end } }, fn, ...)
        end
      end
      local TB = require("src.render.TextBox")
      if type(TB.draw) == "function" then TB.draw = luecke(TB.draw) end
      local Shop = require("src.ui.ShopMenu")
      local alt_new = Shop.new
      if type(alt_new) == "function" then
        Shop.new = function(...)
          local menu = alt_new(...)
          if type(menu) == "table" and type(menu.draw) == "function" then menu.draw = luecke(menu.draw) end
          return menu
        end
      end
    end)
    local u = l.unentschieden
    if u then
      pcall(function()
        local LS = require("src.link.LinkState")
        local original = LS.versus
        if type(original) ~= "function" then return end
        LS.versus = function(game, battle, result, ...)
          local screen = original(game, battle, result, ...)
          local draw = type(screen) == "table" and screen.draw
          if result ~= "draw" or type(draw) ~= "function" then return screen end
          screen.draw = function(self, ...)
            local fd = Font.draw
            ersetzt({ { Font, "draw", function(text, x, y, ...)
              if x == 48 and y == 64 then x, y = u.x * 8, u.y * 8 end
              return fd(text, x, y, ...)
            end } }, draw, self, ...)
          end
          return screen
        end
      end)
    end
    local a = l.automat
    if a then
      pcall(function()
        local SM = require("src.ui.SlotMachine")
        local original = SM.drawBottom
        if type(original) ~= "function" then return end
        local zo = rezept.zwei_optionen
        local breiter = (type(zo) == "table" and type(zo.ja_nein) == "table") and (zo.ja_nein[2] - zo.ja_nein[1]) or 0
        SM.drawBottom = function(self, ...)
          if self.stage ~= "onemore" then return original(self, ...) end
          local db, fd, dc = Font.drawBox, Font.draw, Font.drawCode
          ersetzt({
            { Font, "drawBox", function(tx, ty, tw, th, ...)
              if tx == 14 and ty == 12 and tw == 6 and th == 5 then return db(a.x, a.y, tw + breiter, th, ...) end
              return db(tx, ty, tw, th, ...)
            end },
            { Font, "draw", function(text, x, y, ...)
              if x == 128 and (y == 104 or y == 120) then x = (a.cursor + 1) * 8 end
              return fd(text, x, y, ...)
            end },
            { Font, "drawCode", function(code, x, y, ...)
              if code == 0xED and x == 120 and (y == 104 or y == 120) then x = a.cursor * 8 end
              return dc(code, x, y, ...)
            end },
          }, original, self, ...)
        end
      end)
    end
    local ab = l.abbrechen
    if ab and ab ~= 11 then
      pcall(function()
        local CF = require("src.render.CableFrame")
        local original = CF.box
        if type(original) ~= "function" then return end
        CF.box = function(tx, ty, tw, th, ...)
          if tx == 0 and ty == 15 and tw == 11 and th == 3 then tw = ab end
          return original(tx, ty, tw, th, ...)
        end
      end)
    end
    -- Surf-Rekord (Gelb): der Port setzt den Namen ab Spalte 2 und HiScoreString fest ab Spalte 9; die DE-ROM beide
    -- an eigene Spalten.  render zeichnet auch die Druckseite (Printer.save) → gilt für Anzeige und Druck
    local sr = l.surfrekord
    if sr then
      pcall(function()
        local SH = require("src.ui.SurfHiScore")
        local original = SH.render
        if type(original) ~= "function" then return end
        SH.render = function(game, ...)
          local fd = Font.draw
          return ersetzt({ { Font, "draw", function(text, x, y, ...)
            if y == 32 and x == 72 then
              x = sr.text * 8
            elseif y == 32 and type(x) == "number" and x < 72 then
              x = x + (sr.name - 2) * 8
            end
            return fd(text, x, y, ...)
          end } }, original, game, ...)
        end
      end)
    end
    local e = l.ende
    local te = e and Data.field and Data.field.credits and Data.field.credits.theEnd
    if type(te) == "table" and e.x >= 4 then
      local muster = {}
      for _ = 1, e.x - 4 do muster[#muster + 1] = -1 end
      for _, n in ipairs(e.muster) do muster[#muster + 1] = n end
      te.pattern = muster
    end
  end

  -- Spielstand-Fenster beim SICHERN (StartMenu.lua: Rahmen 4,0 Breite 16, Beschriftungen Spalte 5): die DE-ROM setzt
  -- Rahmen und Beschriftungen eine Spalte weiter links und den Rahmen breiter (save.asm, „SPIELER RED“); erkannt am
  -- Rahmenaufruf des Fensters, die Beschriftungen danach bis zum nächsten Rahmen.  Dasselbe Fenster zeigt WEITER im
  -- Hauptmenü (TitleState ContinueInfo, Rahmen 4,7; DE DisplayContinueGameInfo 3,7 Breite 15); dort setzt der Port
  -- den Namen hinter die Beschriftung (mindestens Spalte 12) → mit der Beschriftung eine Spalte nach links, wie im
  -- Original auf Spalte 12.  Rezept speicherfenster: Rahmen x/Breite und Spalte der Beschriftungen EN → DE.
  local function speicherfenster_einhaengen(sf)
    if type(sf) ~= "table" or type(sf.en) ~= "table" or type(sf.de) ~= "table" then return end
    pcall(function()
      local Font = require("src.render.Font")
      local e, d = sf.en, sf.de
      local box, draw, aktiv = Font.drawBox, Font.draw, nil
      Font.drawBox = function(tx, ty, tw, th, ...)
        aktiv = (tx == e[1] and (ty == 0 or ty == 7) and tw == e[2] + 2 and th == 10) and ty or nil
        if aktiv then return box(d[1], ty, d[2] + 2, th, ...) end
        return box(tx, ty, tw, th, ...)
      end
      Font.draw = function(text, x, y, ...)
        if aktiv then
          local z = y / 8 - aktiv
          if x == e[3] * 8 and (z == 2 or z == 4 or z == 6 or z == 8) then
            x = d[3] * 8
          elseif aktiv == 7 and z == 2 and x > 96 then
            x = math.max(96, x - (e[3] - d[3]) * 8)
          end
        end
        return draw(text, x, y, ...)
      end
    end)
  end

  -- Weitere Kästen, die die DE-ROM breiter bzw. weiter links setzt (Rezept kaesten, TextBoxBorder-Aufrufe EN/DE):
  -- Menüs über ihre Maße beim Anlegen (Menu.new; Beschriftung und Cursor folgen dem Kasten wie im Original zwei
  -- Spalten dahinter), feste Kästen beim Zeichnen.  „still“: Menü ohne Tastenton (die PC-Menüs), „zeile“: itemY des
  -- Menüs, damit gleich große Menüs anderer Stellen unberührt bleiben.
  local function kaesten_einhaengen(ks)
    if type(ks) ~= "table" or #ks == 0 then return end
    pcall(function()
      local Menu = require("src.ui.Menu")
      local Font = require("src.render.Font")
      local function passt(r, tx, ty, tw, th)
        return r.en[1] == tx and r.en[2] == ty and r.en[3] == tw and (not r.en[4] or r.en[4] == th)
      end
      local alt_new = Menu.new
      Menu.new = function(game, items, opts, ...)
        if type(opts) == "table" then
          for _, r in ipairs(ks) do
            if r.art == "menue" and passt(r, opts.tx, opts.ty, opts.tw, opts.th)
                and (not r.still or opts.noSound == true) and (not r.zeile or opts.itemY == r.zeile) then
              local neu = {}
              for k, v in pairs(opts) do neu[k] = v end
              neu.tx, neu.ty, neu.tw = r.de[1], r.de[2], r.de[3]
              if r.de[4] then neu.th = r.de[4] end
              opts = neu
              break
            end
          end
        end
        return alt_new(game, items, opts, ...)
      end
      local box = Font.drawBox
      Font.drawBox = function(tx, ty, tw, th, ...)
        for _, r in ipairs(ks) do
          if r.art == "kasten" and passt(r, tx, ty, tw, th) then
            return box(r.de[1], r.de[2], r.de[3], r.de[4] or th, ...)
          end
        end
        return box(tx, ty, tw, th, ...)
      end
      -- Kabel-Club-Rahmen (CableClub_TextBoxBorder): PrintWaitingText setzt im Tausch dieselben Maße wie im Kampf
      -- (print_waiting_text.asm, ein ld c für beide Rahmen); der Port zeichnet ihn über CableFrame.box an
      -- Font.drawBox vorbei
      local CF = require("src.render.CableFrame")
      local cbox = CF.box
      if type(cbox) == "function" then
        CF.box = function(tx, ty, tw, th, ...)
          for _, r in ipairs(ks) do
            if r.art == "kasten" and passt(r, tx, ty, tw, th) then
              return cbox(r.de[1], r.de[2], r.de[3], r.de[4] or th, ...)
            end
          end
          return cbox(tx, ty, tw, th, ...)
        end
      end
    end)
  end

  -- JA/NEIN-Fenster: die DE-ROM schreibt „NEIN“ (Menü YES_NO 5 statt 4 Zeichen breit, TwoOptionMenuStrings) und
  -- setzt das Standardfenster eine Spalte weiter links (InitYesNoTextBoxParameters hlcoord 13,7 statt 14,7).  Der
  -- Port hat die EN-Maße fest im Theme → aus dem Rezept anpassen (Fenster mit EN-Breite des JA/NEIN-Menüs)
  local function zwei_optionen_einhaengen(zo)
    if type(zo) ~= "table" or type(zo.ja_nein) ~= "table" then return end
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

  -- ================================================================ Haken: Bildschirme

  -- Trainerpass: TrainerInfo_BadgesText ist in beiden ROMs „●<Wort>●“ ab Spalte 6, Zeile 9 (start_sub_menus.asm).
  -- Der Port setzt den rechten Kreis fest auf Spalte 13 (nach „BADGES“); bei „ORDEN“ steht er direkt hinter dem Wort.
  local function trainerpass_einhaengen()
    local ok, TC = pcall(require, "src.ui.TrainerCard")
    if not ok or type(TC) ~= "table" or type(TC.draw) ~= "function" then return end
    local Font = require("src.render.Font")
    local Strings = require("src.core.Strings")
    local original = TC.draw
    TC.draw = function(self, ...)
      local r1, r2 = original(self, ...)
      local n = Font.glyphCount(Strings("BADGES"))
      if self.circle and n and n ~= 6 then
        weiss(function()
          love.graphics.rectangle("fill", 104, 72, 8, 8)
          love.graphics.draw(self.circle, 56 + n * 8, 72)
        end)
      end
      return r1, r2
    end
  end

  -- Urkunde: Diploma.render setzt die englischen Zeilen an feste Stellen.  Während render werden diese Font.draw-
  -- Aufrufe abgefangen: an der Titelstelle (6,2 → 48,16) der deutsche Titel mit seinen Kreis-Kacheln, an der Stelle
  -- „Player“ (24,32) alle übrigen deutschen Texte und der Name an den Kacheln der deutschen Tabelle; die restlichen
  -- englischen Zeilen entfallen.  Über Font.draw wird auch die Text-Ebene über dem Spielerbild (textOverlay)
  -- erreicht, so liegt die Schrift wie im Original vor der Figur.  Gelb: renderYellowTop setzt dieselben Stellen
  -- (diploma2.asm), mit Rahmen und Kacheln der Gelb-Urkunde.
  local EN_DIPLOM = { ["80,32"] = true, ["16,48"] = true, ["16,64"] = true, ["16,80"] = true, ["16,96"] = true,
    ["16,112"] = true, ["72,128"] = true }
  local function diplom_einhaengen(d)
    local ok, Diploma = pcall(require, "src.ui.Diploma")
    if not ok or type(Diploma) ~= "table" or not Diploma.render then return end
    local Font = require("src.render.Font")
    local gelb  -- Kacheln der Gelb-Urkunde während render
    local function kreis(x, y)
      if gelb then
        -- Gelb: Kreis-Kachel $10 aus den Urkunden-Kacheln (diploma2.asm CIRCLE_TILE_ID)
        local TileAtlas = require("src.render.TileAtlas")
        pcall(TileAtlas.draw, TileAtlas.image(gelb.tiles), 0x10, x, y)
      else
        local okb, bild = pcall(Assets.image, "assets/generated/trainer_card/circle_tile.png")
        if okb and bild then love.graphics.draw(bild, x, y) end
      end
    end
    local function zeile_zeichnen(fd, text, x, y)
      local spalte = x
      -- Stücke zwischen Kreis-Kacheln (\1); \2 markiert das Ende (Lua-5.1-Muster vertragen kein \0)
      for teil, k in (text .. "\2"):gmatch("([^\1\2]*)([\1\2])") do
        if teil ~= "" then
          fd(teil, spalte * 8, y * 8)
          spalte = spalte + Font.glyphCount(teil)
        end
        if k == "\1" then
          weiss(kreis, spalte * 8, y * 8)
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
      local felder = GameVersion.isYellow and GameVersion.isYellow() and game.data and game.data.field
      gelb = felder and felder.yellowPages and felder.yellowPages.diploma or nil
      local fd = Font.draw
      ersetzt({ { Font, "draw", function(text, x, y, ...)
        if x == 48 and y == 16 then
          -- Titelzeile leeren (englische Kreis-Kacheln) und deutsch neu setzen
          weiss(love.graphics.rectangle, "fill", 8, 16, 144, 8)
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
      end } }, original, game, ...)
    end
  end

  -- Pokémon-Namen in Skripttexten: Port-Skripte setzen {RAM:…} mit dem Artschlüssel ein (data/scripts/oaks_lab.lua
  -- „{ RAM = species }“, src/script/Commands.lua _GotMonText); das Original kopiert den Namen der Art (GetMonName)
  -- nach wNameBuffer → Schlüssel durch den Namen aus Data.pokemon ersetzen
  local function skriptnamen_einhaengen()
    local okC, Commands = pcall(require, "src.script.Commands")
    if not (okC and type(Commands) == "table" and type(Commands.show_text) == "function") then return end
    local alt_show = Commands.show_text
    Commands.show_text = function(ctx, textId, subs, ...)
      -- give_pokemon setzt ctx.pendingPokemonName (Artschlüssel), das Original nimmt den Namen
      -- („RED erhält KARPADOR!“, Karpador-Verkäufer)
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
          local kopie_subs = {}
          for k, v in pairs(subs) do kopie_subs[k] = neu[k] or v end
          subs = kopie_subs
        end
      end
      return alt_show(ctx, textId, subs, ...)
    end
  end

  -- Pokédex-Eintrag, metrisch: die DE-ROM schreibt „0.6m“/„8.5kg“ mit dem Dezimalpunkt der Schrift; der Port wandelt
  -- den Punkt nach dem Formatieren in ein Komma (src/ui/DexEntryMenu.lua render) → während render die Ziffer-Komma-
  -- Ziffer-Folge als <DOT> zeichnen.  Einheiten: die DE-ROM setzt „m“ und „kg“ als Kacheln des Pokédex-Blatts ($60
  -- bzw. $61 $62), der Port schreibt sie mit der Schrift → Text ohne Einheit, die Kacheln dahinter.
  local EINHEIT = { { "^(GR%..-)m$", { 0x60 } }, { "^(GEW.-)kg$", { 0x61, 0x62 } } }
  local function pokedex_einhaengen()
    pcall(function()
      local Dex = require("src.ui.DexEntryMenu")
      local Font = require("src.render.Font")
      local alt_render = Dex.render
      Dex.render = function(game, ...)
        local fd = Font.draw
        return ersetzt({ { Font, "draw", function(text, x, y, ...)
          if type(text) == "string" and text:find("%d,%d") then text = text:gsub("(%d),(%d)", "%1<DOT>%2") end
          if type(text) == "string" and type(Dex.tile) == "function" and type(x) == "number" and type(y) == "number"
              and x % 8 == 0 and y % 8 == 0 then
            for _, e in ipairs(EINHEIT) do
              local vorn = text:match(e[1])
              local n = vorn and Font.glyphCount(vorn)
              if n then
                local r1 = fd(vorn, x, y, ...)
                weiss(function()
                  for i, code in ipairs(e[2]) do pcall(Dex.tile, game, code, x / 8 + n + i - 1, y / 8) end
                end)
                return r1
              end
            end
          end
          return fd(text, x, y, ...)
        end } }, alt_render, game, ...)
      end
    end)
  end

  -- Statusseite 2: EN setzt vor die AP-Werte zweimal die Kachel $72 („PP“, status_screen.asm PrintPP), die DE-ROM
  -- die Schriftzeichen $80 $8F „AP“ (ld a,$80 / ld [hli],a / ld a,$8F / ld [hld],a).  Der Port übernimmt die
  -- EN-Kacheln (SummaryMenu.lua) → während der Statusseite die beiden $72-Kacheln durch die DE-Zeichen ersetzen
  local function statusseite_einhaengen()
    pcall(function()
      local SM = require("src.ui.SummaryMenu")
      local Hud = require("src.render.HudTiles")
      local Font = require("src.render.Font")
      local alt_draw = SM.draw
      SM.draw = function(self, ...)
        local st = Hud.statusTile
        return ersetzt({ { Hud, "statusTile", function(id, x, y, ...)
          if id == 0x72 and (x == 88 or x == 96) then
            love.graphics.setColor(0, 0, 0, 1)
            return Font.drawCode(x == 88 and 0x80 or 0x8F, x, y)
          end
          return st(id, x, y, ...)
        end } }, alt_draw, self, ...)
      end
    end)
  end

  -- Ladebericht (Port-Zusatz, src/ui/QuarantineReport.lua, nur Gen 1 zeigt ihn): erscheint einmal nach dem Laden,
  -- wenn sich die aktiven Mods geändert haben oder Daten aussortiert wurden.  Überschriften und Hinweis sind dort
  -- feste Literale (kein Strings()) → die Zeilen aus denselben Berichtsfeldern deutsch aufbauen, Arten/Items mit
  -- ihrem deutschen Namen
  local function ladebericht_einhaengen()
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
      local function kurz(t) return kuerzen(tostring(t), BREITE) end
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
  end

  -- Spielautomat: drawBottom zeichnet ROM-Dialogzeilen als feste englische Literale (ohne Strings()).  Während
  -- drawBottom wird jede Zeile, die genau einer Zeile eines dieser Labels entspricht, durch dieselbe Zeile des
  -- deutschen Labels ersetzt (engine/slots/slot_machine.asm); Quelle bleibt die ROM.
  local AUTOMAT_TEXTE = { "_BetHowManySlotMachineText", "_OneMoreGoSlotMachineText", "_StartSlotMachineText",
    "_YeahText" }
  local function zeilen_von(t)
    local z = {}
    for zeile in (ohne_ende(t):gsub("[\v\f]", "\n") .. "\n"):gmatch("(.-)\n") do
      zeile = zeile:gsub("^%s+", ""):gsub("%s+$", "")
      if zeile ~= "" then z[#z + 1] = zeile end
    end
    return z
  end
  local function automat_zeilen_einhaengen(en_text, de_text)
    local Font = require("src.render.Font")
    local ok, SM = pcall(require, "src.ui.SlotMachine")
    local tausch = {}
    for _, lab in ipairs(AUTOMAT_TEXTE) do
      local en_t, de_t = en_text[lab], de_text and de_text[lab]
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
    if not (ok and type(SM) == "table" and type(SM.drawBottom) == "function" and next(tausch)) then return end
    local original = SM.drawBottom
    SM.drawBottom = function(...)
      local fd = Font.draw
      return ersetzt({ { Font, "draw", function(text, x, y, ...)
        if type(text) == "string" then
          local t = tausch[(text:gsub("^%s+", ""):gsub("%s+$", ""))]
          if t then return fd(t, x, y, ...) end
        end
        return fd(text, x, y, ...)
      end } }, original, ...)
    end
  end

  -- Spielautomat: resolveLose setzt das englische Literal von NotThisTimeText (slot_machine.asm) → DE-ROM-Text
  local function automat_verloren_einhaengen(de_t)
    local ok, SM = pcall(require, "src.ui.SlotMachine")
    if not (ok and type(SM) == "table" and type(SM.resolveLose) == "function" and de_t) then return end
    local original = SM.resolveLose
    SM.resolveLose = function(self, ...)
      local r = original(self, ...)
      if type(self.message) == "string" and pruefsumme(self.message) == "~66be2676000e" then
        self.message = require("src.render.TextBox").strip(de_t)
      end
      return r
    end
  end

  -- BLITZ: die Gelbe DE-ROM schreibt „{RAM:wNameBuffer}\nsetzt BLITZ ein.“ (_FlashLightsAreaText); im Original steht
  -- dort das Pokémon aus dem Team-Menü (StartMenu_Pokemon kopiert seinen Namen nach wNameBuffer).  Der Port füllt
  -- game.stringBuffer dafür nicht (OverworldController useFlashFieldMove) → vorher den Namen des gewählten Pokémon
  -- (bzw. des ersten, das BLITZ kann) eintragen
  local function blitz_einhaengen(blitz)
    if type(blitz) ~= "string" or not blitz:find("{RAM:wNameBuffer}", 1, true) then return end
    pcall(function()
      local OW = require("src.world.OverworldController")
      local original = OW.useFlashFieldMove
      if type(original) ~= "function" then return end
      OW.useFlashFieldMove = function(self, ...)
        local game = require("src.core.Game")
        local party = game and game.save and game.save.party or {}
        local top = game and game.stack and game.stack:top()
        local okm, PM = pcall(require, "src.ui.PartyMenu")
        local mon = okm and type(top) == "table" and getmetatable(top) == PM and type(top.index) == "number"
          and party[top.index] or nil
        if type(mon) ~= "table" or not mon.species then
          local okp, m = pcall(self.partyKnows, self, "FLASH")
          mon = okp and type(m) == "table" and m or nil
        end
        if mon then
          local art = game.data and game.data.pokemon and game.data.pokemon[mon.species]
          game.stringBuffer = mon.nickname or (art and art.name) or game.stringBuffer
        end
        return original(self, ...)
      end
    end)
  end

  -- ================================================================ Haken: Bilder

  -- Titel: deutscher Schriftzug als durchgehendes Band (field.boot.title.versionRibbon wird als ganzes Bild
  -- gezeichnet, 160 px breit = genau an den DE-Spalten), Copyright-Zeile als eigenes Bild.  Copyright-Tafel vor dem
  -- Intro (IntroMovie drawCopyright, hlcoord 2,7 = y 56; eigene Studio-Tafeln anderer Mods bleiben) und im Abspann
  -- ($FB, Credits drawCopyright): die drei Zeilen der DE-ROM statt der EN-Kachelfolge auf dem deutschen Blatt.
  local function titel_einhaengen(bilder)
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
    if not bilder["title/de_copyright_karte.png"] then return end
    local karte
    local function copyrightbild()
      if karte == nil then
        local ok, b = pcall(Assets.image, "assets/generated/title/de_copyright_karte.png")
        karte = ok and b or false
      end
      return karte or nil
    end
    pcall(function()
      local IM = require("src.ui.IntroMovie")
      local original = IM.drawCopyright
      IM.drawCopyright = function(self, ...)
        if not (self.studio and (self.studio.card or self.studio.credit)) then
          local bild = copyrightbild()
          if bild then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(bild, 0, 56)
            return
          end
        end
        return original(self, ...)
      end
    end)
    pcall(function()
      local C = require("src.ui.Credits")
      local original = C.drawCopyright
      if type(original) ~= "function" then return end
      C.drawCopyright = function(self, xoff, ...)
        local bild = copyrightbild()
        if not bild then return original(self, xoff, ...) end
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(bild, xoff or 0, 56)
      end
    end)
  end

  -- Gelb, Surf-Minispiel: SurfingMinigame.new lädt seine Blätter selbst mit love.graphics.newImage (an Assets.resolve
  -- vorbei) → während new die Pfade der deutschen Blätter (minigame/*) auf die Bilder des Mods umbiegen.
  -- Ergebnistafel: die Port-Wörter („HP Left“, „Pts“ …) an ihren Stellen durch die Kacheln der DE-ROM ersetzen.
  local function surf_einhaengen(bilder, se)
    local ok, SM = pcall(require, "src.ui.SurfingMinigame")
    if not (ok and type(SM) == "table") then return end
    local hat = false
    for rel in pairs(bilder) do if rel:find("^minigame/") then hat = true end end
    if type(SM.new) == "function" and hat then
      local original = SM.new
      SM.new = function(...)
        local ni, drin = love.graphics.newImage, false
        return ersetzt({ { love.graphics, "newImage", function(pfad, ...)
          local name = not drin and type(pfad) == "string" and pfad:match("minigame/([^/]+%.png)$")
          if name and bilder["minigame/" .. name] then
            drin = true
            local okb, b = pcall(Assets.image, "assets/generated/minigame/" .. name)
            drin = false
            if okb and b then return b end
          end
          return ni(pfad, ...)
        end } }, original, ...)
      end
    end
    if type(SM.drawResultsOutro) == "function" and type(se) == "table" then
      local Font = require("src.render.Font")
      local original = SM.drawResultsOutro
      SM.drawResultsOutro = function(self, ...)
        if not (self.bg and self.tq) then return original(self, ...) end
        local fd = Font.draw
        ersetzt({ { Font, "draw", function(text, x, y, ...)
          for _, e in ipairs(se) do
            if e.x == x and (e.y == y or (e.y == false and (y == 16 or y == 32 or y == 48))) then
              weiss(function()
                for i, id in ipairs(e.kacheln) do
                  if self.tq[id] then love.graphics.draw(self.bg, self.tq[id], x + (i - 1) * 8, y) end
                end
              end)
              return
            end
          end
          return fd(text, x, y, ...)
        end } }, original, self, ...)
      end
    end
  end

  -- ================================================================ Anwenden

  -- Daten ins Spiel übernehmen und die Haken einhängen.  Die Reihenfolge ist fest: mehrere Haken umhüllen dieselbe
  -- Port-Funktion (BattleState.drawTextArea, SlotMachine.drawBottom, Font.drawBox).
  local function anwenden(daten, bilder, bericht, schluessel, rezept)
    local c = mod.content
    -- englische Fassung der Labels, die der Spielautomat-Zeilentausch braucht (vor dem Einhängen der deutschen)
    local en_text = {}
    for _, lab in ipairs(AUTOMAT_TEXTE) do en_text[lab] = Data.text and Data.text[lab] end
    -- Texte (Data.text, Schlüssel = pokered-Labels)
    local n = 0
    for label, text in pairs(daten.text or {}) do
      c.text:override(label, text)
      n = n + 1
    end
    bericht.texte = n
    -- Namen; Pokédex: Kategorie, Größe, Gewicht, Text
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
    -- Statuskürzel (Kampf-HUD, Team, Statusbildschirm): der Port zeichnet das Label der Status-Registry ohne
    -- Strings() (Status.hudLabelFor) → Label aus der DE-ROM
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
          if rec.name == en and de_namen[i] then c.type_chart:patch(id, { name = de_namen[i] }) end
        end
      end
    end
    -- Zeichensatz: Zuordnung Folge → Code direkt im Datensatz (die englischen Ligaturen müssen weg; die Registry kann
    -- nur ergänzen)
    if daten.font and daten.font.charmap and Data.font then Data.font.charmap = daten.font.charmap end
    -- Port-Texte: Prüfsumme → deutscher Text (ROM vor Port-Zusätzen aus zusatz.lua), eingehängt beim Laden der Mods;
    -- gezählt nach Herkunft
    G.porttexte_einhaengen(daten.porttexte, daten.portkontexte, daten.text)
    bericht.porttexte, bericht.zusatz = 0, 0
    for _, q in pairs(G.katalog_quelle or {}) do
      if q == "zusatz" then bericht.zusatz = bericht.zusatz + 1 else bericht.porttexte = bericht.porttexte + 1 end
    end
    G.romliterale_einhaengen(daten.romliterale)
    -- Trainerklasse des Port-Bonuskampfs (OPP_CHIEF): im Original unbenutzt, die DE-ROM führt sie unübersetzt als
    -- „CHIEF“ → Name aus dem Port-Zusatz, wenn der Katalog ihn als Zusatz führt
    for id, tr in pairs(Data.trainers or {}) do
      local name = type(tr) == "table" and (daten.trainers and daten.trainers[id] and daten.trainers[id].name or tr.name)
      if type(name) == "string" then
        local chk = pruefsumme(name)
        local w = G.katalog and G.katalog[chk]
        if type(w) == "string" and G.katalog_quelle and G.katalog_quelle[chk] == "zusatz" then
          c.trainers:patch(id, { name = w })
        end
      end
    end
    if daten.diplom then diplom_einhaengen(daten.diplom) end
    trainerpass_einhaengen()
    if daten.alphabet then alphabet_einhaengen(daten.alphabet) end
    if daten.kampfmenue then kampfmenue_einhaengen(daten.kampfmenue) end
    if daten.safarimenue then safari_einhaengen(daten.safarimenue) end
    if daten.lage then lage_einhaengen(daten.lage, rezept) end
    verwaltung_einhaengen()
    menues_einhaengen()
    -- Namen: Tausch-Spitznamen und Namensvorschläge der DE-ROM (field.trades / field.boot.namePresets)
    local nm = daten.namen
    if nm and Data.field then
      for i, t in ipairs(Data.field.trades or {}) do
        if nm.tausch and nm.tausch[i] then t.nickname = nm.tausch[i] end
      end
      local boot = Data.field.boot
      if boot and nm.spieler and nm.rivale then boot.namePresets = { player = nm.spieler, rival = nm.rivale } end
    end
    -- Arena-Statuen: der Port setzt {RAM:wGymCityName}/{RAM:wGymLeaderName} aus data/scripts/gyms.lua ein (englische
    -- Namen); wie im Original kommen sie aus dem Arena-Skript der DE-ROM (nur Anzeige)
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
    skriptnamen_einhaengen()
    pokedex_einhaengen()
    statusseite_einhaengen()
    speicherfenster_einhaengen(rezept.speicherfenster)
    kaesten_einhaengen(rezept.kaesten)
    zwei_optionen_einhaengen(rezept.zwei_optionen)
    ladebericht_einhaengen()
    -- Abspann: deutsche Bildschirme; die Pokémon der MON-Bildschirme in der Reihenfolge von CreditsMons (gleich viele
    -- MON-Bildschirme in EN und DE)
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
    automat_zeilen_einhaengen(en_text, daten.text)
    if daten.geist then geist_einhaengen(daten.geist) end
    blitz_einhaengen(daten.text and daten.text._FlashLightsAreaText)
    automat_verloren_einhaengen(daten.text and daten.text._NotThisTimeText)
    -- Bilder mit deutscher Schrift (Mod-Cache, Assets.resolve; Feldpfade direkt an newImage umgebogen)
    bericht.bilder = G.bilder_einhaengen(bilder, schluessel, { Data.field })
    titel_einhaengen(bilder)
    surf_einhaengen(bilder, daten.surfergebnis)
  end

  -- ================================================================ Start

  function K.start()
    -- Mod-Option: Start- und Hauptmenü wie im Original (siehe menues_einhaengen)
    pcall(function()
      mod.options:define({ { key = "originalmenues", type = "toggle", label = "ORIGINAL-MENÜS", default = true } })
    end)
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
    if not rezept then
      mod.log:warn("Definitiv German: Rezept fehlt: %s", tostring(rerr))
      return
    end
    -- Cache gilt nur für genau diesen Mod-Stand: Rezept, Kern und gemeinsame Bausteine über ihre Prüfsumme
    local stand = pruefsumme((mod:read("rezept_" .. edition .. ".lua") or "") .. (mod:read("kern.lua") or "")
      .. (mod:read("gemeinsam.lua") or ""))
    local schluessel = ("v6/%s/%s/%s-%s/%s-%s"):format(edition, info.md5 or "?", MODVERSION, stand:sub(2),
      Version.engine or "?", Version.cache or "?")
    local bericht = {}
    local daten, bilder = G.cache_lesen(schluessel)
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
      if #fehler == 0 then G.cache_schreiben(schluessel, daten, bilder) end
    end
    anwenden(daten, bilder, bericht, schluessel, rezept)
    mod.log:info("Definitiv German Gen 1 (%s): %d Texte, %d Pokémon, %d Bilder – aus %s", edition,
      bericht.texte or 0, bericht.pokemon or 0, bericht.bilder or 0, bericht.quelle)
    mod.log:info("Definitiv German Gen 1: %d Port-Texte aus der ROM, %d eigene Ergänzungen (zusatz.lua)",
      bericht.porttexte or 0, bericht.zusatz or 0)
    K.aktiv = true
    return true
  end

  return K
end
