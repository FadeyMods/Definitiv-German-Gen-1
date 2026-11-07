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

  -- Drei Zeichen aus den Sofortwerten „3E x 22 3E y 22 36 z“ (ld a, x / ld [hli], a / ld a, y / ld [hli], a /
  -- ld [hl], z) ab Bank/Adresse; nil, wenn dort kein solcher Block steht
  local function drei_zeichen(ex, b, adr, charmap)
    local r = ex.rom
    if r:byte(b, adr) ~= 0x3E or r:byte(b, adr + 2) ~= 0x22 or r:byte(b, adr + 3) ~= 0x3E
        or r:byte(b, adr + 5) ~= 0x22 or r:byte(b, adr + 6) ~= 0x36 then
      return nil
    end
    return (charmap[tostring(r:byte(b, adr + 1))] or "") .. (charmap[tostring(r:byte(b, adr + 4))] or "")
      .. (charmap[tostring(r:byte(b, adr + 7))] or "")
  end

  -- Statuskürzel: fünf Blöcke „3E x 22 3E y 22 36 z C9“ (PrintStatusAilment), Reihenfolge SLP PSN BRN FRZ PAR
  local function status(ex, ort, charmap)
    if not ort then return nil end
    local b, adr, s = ort[1], ort[2], {}
    for _, id in ipairs({ "SLP", "PSN", "BRN", "FRZ", "PAR" }) do
      s[id] = ex.rom:byte(b, adr + 8) == 0xC9 and drei_zeichen(ex, b, adr, charmap) or nil
      if not s[id] then return nil end
      adr = adr + 9
    end
    return s
  end

  -- Kürzel für kampfunfähig (PrintStatusCondition bei KP 0): ein Block wie oben, DE „BSG“ (Rezept kampfunfaehig);
  -- im Port der Katalogeintrag mit dieser Prüfsumme
  local KUERZEL_FNT = "~f3cfdf930003"
  local function kampfunfaehig(ex, ort, charmap)
    return ort and drei_zeichen(ex, ort[1], ort[2], charmap) or nil
  end

  -- Feldattacken im Team-Menü: FieldMoveDisplayData (je Eintrag Attacke, Namensnummer, linkeste Kachel des Namens;
  -- Ende $FF) → Spalte je Aktion des Port-Untermenüs (src/ui/PartyMenu.lua: action bzw. move)
  local FELDAKTION = { [0x0F] = "cut", [0x13] = "fly", [0x39] = "surf", [0x46] = "strength", [0x94] = "flash",
    [0x5B] = "DIG", [0x64] = "TELEPORT", [0x87] = "softboiled" }
  local function feldattacken(ex, ort)
    if not ort then return nil end
    local t, adr = {}, ort[2]
    for _ = 1, 16 do
      local id = ex.rom:byte(ort[1], adr)
      if id == 0xFF then break end
      if FELDAKTION[id] then t[FELDAKTION[id]] = ex.rom:byte(ort[1], adr + 2) end
      adr = adr + 3
    end
    if next(t) then return t end
  end

  -- Stockwerke der Aufzüge: im Original die Namen FLOOR_B2F … FLOOR_B4F in ItemNames (Index $54–$61, DE „UG2“,
  -- „UG1“, „EG“, „S1“ … „S10“, „UG4“).  Ergebnis: Index → Name
  local function stockwerke(ex, charmap)
    if not ex.symbols["ItemNames"] then return nil end
    local tab = ex:symbol("ItemNames")
    local adr, t = tab.address, {}
    for i = 1, 0x61 do
      local name, n = ex.rom:readString(tab.bank, adr, charmap, 0x50, 20)
      if i >= 0x54 then t[i] = name end
      adr = adr + n
    end
    return t
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

  -- Gelb, PIKACHU-Schreie: Länge jeder PCM-Aufnahme in Bytes (PikachuCriesPointerTable → dba, dort dw Länge).
  -- PlayPikachuPCM spielt je Byte 8 Samples in 360 Takten bei gesperrten Interrupts (17556 Takte je Frame)
  local function pikaschreie(ex)
    if not ex.symbols["PikachuCriesPointerTable"] then return nil end
    local tab = ex:symbol("PikachuCriesPointerTable")
    local t = {}
    for i = 0, 41 do
      local bank = ex.rom:byte(tab.bank, tab.address + i * 3)
      t[i + 1] = ex.rom:word(bank, ex.rom:word(tab.bank, tab.address + i * 3 + 1))
    end
    return t
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
    -- Teamliste: Strings("FNT") (src/ui/PartyMenu.lua) zeigt das Kürzel, das PrintStatusCondition schreibt
    local fnt = kampfunfaehig(ex, rezept.kampfunfaehig, cm)
    if fnt then daten.porttexte[KUERZEL_FNT] = fnt end
    daten.stockwerke = stockwerke(ex, cm)
    daten.feldattacken = feldattacken(ex, rezept.feldattacken)
    daten.romliterale = G.romliterale_lesen(ex, rezept, cm)
    daten.diplom = diplom(ex, rezept.diplom, cm)
    daten.alphabet = alphabet(ex, rezept.alphabet, cm)
    daten.abspann = abspann(ex, rezept.abspann, cm)
    daten.namen = namen(ex, rezept.namen, cm)
    daten.arenen = arenen(ex, rezept.arenen, cm)
    daten.geist = geist(ex, rezept.geist, cm)
    daten.status = status(ex, rezept.status, cm)
    daten.kampfmenue = kampfmenue(ex, rezept.kampfmenue)
    if edition == "yellow" then daten.pikaschreie = pikaschreie(ex) end
    -- nur Bilder behalten, die sich vom englischen Import unterscheiden (Schrift, Schilder, Titel …)
    for rel, bild in pairs(bilder) do
      if not G.anders_als_en(rel, bild) then bilder[rel] = nil end
    end
    return daten, bilder, fehler
  end

  -- ================================================================ Haken: Menüs

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

  -- Aufzüge: der Port beschriftet die Stockwerksliste mit dem Kürzel aus der Karten-ID (data/scripts/story3.lua
  -- elevatorFloors, „1F“, „B2F“); das Original druckt die Namen FLOOR_* aus ItemNames (DisplayElevatorFloorMenu) →
  -- Kürzel auf ihren Index abbilden (B2F $54, B1F $55, nF $55 + n, B4F $61) und den Namen der DE-ROM setzen
  local function aufzug_index(kuerzel)
    if kuerzel == "B2F" then return 0x54 elseif kuerzel == "B1F" then return 0x55 elseif kuerzel == "B4F" then
      return 0x61
    end
    local n = tonumber(kuerzel:match("^(%d+)F$") or "")
    return n and 0x55 + n
  end
  local function aufzug_einhaengen(namen)
    local ok, LM = pcall(require, "src.ui.ListMenu")
    if not (ok and type(LM) == "table" and type(LM.new) == "function") then return end
    local original = LM.new
    LM.new = function(game, title, items, opts, ...)
      if type(opts) == "table" and opts.kind == "elevator_floors" and type(items) == "table" then
        for _, it in ipairs(items) do
          local f = type(it) == "table" and it.value
          local i = type(f) == "table" and type(f.token) == "string" and aufzug_index(f.token)
          if i and namen[i] then it.label = namen[i] end
        end
      end
      return original(game, title, items, opts, ...)
    end
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

  -- Geist im PKMN-TURM: disguiseAsGhost setzt ein englisches Literal als Gegnernamen und baut damit schon den
  -- Erscheinungstext (_EnemyAppearedText) → Name aus der DE-ROM, Text mit diesem Namen neu (wie InitWildBattle
  -- .isGhost, das den Namen vor dem Text setzt)
  local function geist_einhaengen(name)
    local ok, BS = pcall(require, "src.battle.BattleState")
    for _, fn in ipairs({ "makeGhost", "makeUnveiledGhost" }) do
      if ok and type(BS) == "table" and type(BS[fn]) == "function" then
        local original = BS[fn]
        BS[fn] = function(self, ...)
          local r = original(self, ...)
          if self.enemy and self.ghostReal then
            self.enemy.name = name
            self.introText = self:romText("_EnemyAppearedText", self.introText, name)
          end
          return r
        end
      end
    end
  end

  -- Kampftexte mit {SCROLL} (Gelb: _GreatlyRoseText/_GreatlyFellText bestehen in der DE-ROM nur aus <SCROLL>, „VERT
  -- sinkt!“ rollt eine Zeile hoch, ohne zu warten).  Der Port kennt das Zeichen nicht und druckt das Wort.  Im
  -- Kampftext rollt jede weitere Zeile ohne Warten ins zweizeilige Fenster (BattleState:startMessage, nur \v wartet)
  -- → {SCROLL} als neue Zeile
  local function kampftext_rollen_einhaengen()
    local ok, BS = pcall(require, "src.battle.BattleState")
    if not (ok and type(BS) == "table" and type(BS.startMessage) == "function") then return end
    local original = BS.startMessage
    BS.startMessage = function(self, item, ...)
      if type(item) == "table" and type(item.text) == "string" and item.text:find("{SCROLL}", 1, true) then
        local neu = {}
        for k, v in pairs(item) do neu[k] = v end
        neu.text = item.text:gsub("%s*{SCROLL}", "\n")
        item = neu
      end
      return original(self, item, ...)
    end
  end

  -- Kampf, Statusattacken (Stärke 0), die fehlschlagen oder nicht treffen („Nichts geschieht!“, „Die Attacke /
  -- schlug fehl!“, „… / blieb unversehrt!“): das Original überspringt die Animation und hält vor der Meldung
  -- (PlayerCheckIfFlyOrChargeEffect `ld c, 30 / call DelayFrames`, wie bei einem Fehlschuss); in der DE-ROM steht
  -- „… / ben. …!“ deshalb jedes Mal über 20 Frames.  Der Port druckt die Meldung sofort (performMove, reine
  -- Statusattacken: cancelMoveAnim, dann der Text) → nach dem Wegfall der Animation dieselbe Pause wie beim Fehlschuss
  local function statusattacke_einhaengen()
    local ok, BS = pcall(require, "src.battle.BattleState")
    local okT, Timing = pcall(require, "src.core.Timing")
    if not (ok and okT and type(BS) == "table" and type(BS.performMove) == "function"
        and type(BS.cancelMoveAnim) == "function" and type(BS.waitNext) == "function") then return end
    local original, abbrechen = BS.performMove, BS.cancelMoveAnim
    local function halt(self, ...)
      local zeile = self.moveAnimRow
      local r = abbrechen(self, ...)
      if zeile then self:waitNext(Timing.MOVE_STATUS_OR_MISS or 30) end
      return r
    end
    BS.performMove = function(self, user, target, moveInst, ...)
      local okm, move = pcall(self.moveDef, self, moveInst)
      local rec = okm and type(move) == "table" and self:effectRecord(move.effect)
      if not (type(rec) == "table" and move.power == 0 and rec.kind == "primary") then
        return original(self, user, target, moveInst, ...)
      end
      return ersetzt({ { self, "cancelMoveAnim", halt } }, original, self, user, target, moveInst, ...)
    end
  end

  -- Gelb, Fang-Vorführung (simulierte Eingabe, Vertania City und Eichs Fang): im Beutel steht „▶POKéBALL“ 20 Frames,
  -- dann schließt er.  Der Port setzt danach wie Rot/Blau noch rund 7 Frames den hohlen Pfeil (BattleState
  -- openOldManBag, hollowIndex nach home/list_menu.asm:91), die Gelbe DE-ROM nicht → in Gelb ohne diese Stufe schließen
  local function fangvorfuehrung_einhaengen()
    if not (GameVersion.isYellow and GameVersion.isYellow()) then return end
    local ok, BS = pcall(require, "src.battle.BattleState")
    if not (ok and type(BS) == "table" and type(BS.openOldManBag) == "function" and type(BS.ui) == "function") then
      return
    end
    local original, ui = BS.openOldManBag, BS.ui
    BS.openOldManBag = function(self, ...)
      return ersetzt({ { self, "ui", function(s, fabrik, ...)
        return ui(s, function(...)
          local list = fabrik(...)
          local skript = type(list) == "table" and list.script
          if type(skript) == "function" then
            list.script = function(l, ...)
              local r = skript(l, ...)
              if l.hollowIndex then
                l.hollowIndex = nil
                l.scriptTimer = math.huge  -- nächster Schritt des Skripts schließt den Beutel
              end
              return r
            end
          end
          return list
        end, ...)
      end } }, original, self, ...)
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

  -- Level-Aufstieg, Fenster der Statuswerte (PrintStatsBox, Rahmen ab Spalte 9): die Zahlen stehen rechtsbündig mit
  -- einem Feld Abstand zum rechten Rahmen (dreistellig ab Spalte 15).  Der Port setzt sie ab Spalte 16 direkt an den
  -- Rahmen (BattleState StatBox:draw, x = 128; auch ohne Mod) → eine Spalte nach links
  local function statusfenster_einhaengen()
    local ok, BS = pcall(require, "src.battle.BattleState")
    local SB = ok and type(BS) == "table" and BS.StatBox
    if not (type(SB) == "table" and type(SB.draw) == "function") then return end
    local Font = require("src.render.Font")
    local original = SB.draw
    SB.draw = function(self, ...)
      local fd = Font.draw
      return ersetzt({ { Font, "draw", function(text, x, y, ...)
        if x == 128 then x = 120 end
        return fd(text, x, y, ...)
      end } }, original, self, ...)
    end
  end

  -- Außerhalb der Außenkarten zeigt das Original den Randblock der Karte (Kartenkopf, je Karte festgelegt).  Der
  -- Port füllt dort nach seiner Option RANDFÜLLUNG (Bäume, Wasser, Schwarz; src/render/TileRenderer.lua
  -- borderBlockFor) → weitere Wahl ORIGINAL mit dem Randblock der Karte, als Vorgabe
  local function randfuellung_einhaengen()
    local ok, TR = pcall(require, "src.render.TileRenderer")
    if not (ok and type(TR) == "table" and type(TR.VOID_FILLS) == "table" and type(TR.ensureBorderFill) == "function"
        and type(TR.voidFillLabel) == "function") then return end
    table.insert(TR.VOID_FILLS, 1, "original")
    local alt_label = TR.voidFillLabel
    TR.voidFillLabel = function(mode, ...)
      if (mode or TR.voidFill) == "original" then return "ORIGINAL" end
      return alt_label(mode, ...)
    end
    -- borderBlockFor nimmt für andere Kachelsätze den Randblock der Karte: während des Aufbaus der Füllung die Karte
    -- nicht als OVERWORLD ausweisen
    local alt_fill = TR.ensureBorderFill
    TR.ensureBorderFill = function(self, ...)
      local def = self.map and self.map.def
      if TR.voidFill == "original" and type(def) == "table" and def.tileset == "OVERWORLD" and def.borderBlock then
        return ersetzt({ { def, "tileset", "ORIGINAL" } }, alt_fill, self, ...)
      end
      return alt_fill(self, ...)
    end
    local okS, SaveData = pcall(require, "src.core.SaveData")
    if okS and type(SaveData.defaultOptions) == "function" then
      local alt_def = SaveData.defaultOptions
      SaveData.defaultOptions = function(...)
        local o = alt_def(...)
        if type(o) == "table" and o.voidFill == "trees" then o.voidFill = "original" end
        return o
      end
    end
  end

  -- Farben „OG RED“ (Port-Option FARBEN, Game Boy Color ohne eigenen Code): das Original zeigt auf dem GBC die feste
  -- Palette der Boot-ROM für POKEMON RED.  Der Port legt dafür eine weichere eigene Abstufung an
  -- (src/render/PaletteFX.lua OG_RED_SOFT_BG/_OBJ, „display correction“), die Werte der Boot-ROM stehen daneben
  -- (GBC_BG/GBC_OBJ) → die weiche Abstufung mit den Werten der Boot-ROM füllen.  Spielautomat: die Walzensymbole
  -- sind Sprites und stehen in der Objektpalette (grün); der Port zeichnet sie als Bild in der Hintergrundpalette
  -- (SlotMachine drawReels) → wie die Sprites anderer Bildschirme in der Objektpalette nachzeichnen.
  local function og_farben_einhaengen()
    local ok, P = pcall(require, "src.render.PaletteFX")
    if not (ok and type(P) == "table") then return end
    if GameVersion.get() == "red" then
      for _, paar in ipairs({ { P.OG_RED_SOFT_BG, P.GBC_BG }, { P.OG_RED_SOFT_OBJ, P.GBC_OBJ } }) do
        local weich, boot = paar[1], paar[2]
        if type(weich) == "table" and type(boot) == "table" then
          -- die Farbtabellen selbst füllen: PaletteFX legt beim Laden weitere Tabellen an, die auf dieselben
          -- Einträge zeigen (OG_OBJ_NORMAL für die Figuren der Karte)
          for i, c in ipairs(boot) do
            if type(weich[i]) == "table" then weich[i][1], weich[i][2], weich[i][3] = c[1], c[2], c[3] end
          end
        end
      end
    end
    -- Gelb, Farben „OG YELLOW“ (CGBBasePalettes): die Pokédex-Liste steht in der DE-ROM in der Palette MEWMON
    -- (gefangene Bälle rot/gelb), der Port setzt BROWNMON (PokedexMenu:sgbPalettes, Ball braun)
    local okD, PD = pcall(require, "src.ui.PokedexMenu")
    if GameVersion.isYellow() and okD and type(PD) == "table" and type(PD.sgbPalettes) == "function" then
      local alt_pal = PD.sgbPalettes
      PD.sgbPalettes = function(self, game, ...)
        if P.usesYellowCgb() then return P.wholeNamed(game.data, "MEWMON") end
        return alt_pal(self, game, ...)
      end
    end
    -- Gelb, „OG YELLOW“, Kampfbeginn: solange Trainer- bzw. Rückenbild stehen, sendet SetPal_Battle für diese Seite
    -- MonsterPalettes[0] = PAL_MEWMON aus CGBBasePalettes (DE-ROM: #181818/#F8F8F8).  Der Port nimmt dort MEWMON aus
    -- seiner eigenen GBC-Tabelle (BattleState:sgbBattlePals, #313131/#FFFFF7) → MEWMON aus CGBBasePalettes; die
    -- Team-Bälle des Gegners in GREENBAR
    local okB, BS = pcall(require, "src.battle.BattleState")
    if GameVersion.isYellow() and okB and type(BS) == "table" and type(BS.sgbBattlePals) == "function" then
      local alt_pals = BS.sgbBattlePals
      BS.sgbBattlePals = function(self, ...)
        local t = alt_pals(self, ...)
        if type(t) == "table" and P.usesYellowCgb() and not self.blackedOut then
          local mew = P.pal(self.data, "MEWMON")
          if mew then
            if self.showPlayerBack or self.safari or self.demo then t[2] = mew end
            if self.showEnemyTrainer then t[3] = mew end
          end
          -- solange in der Zeile der Gegner-KP die Team-Bälle stehen (Trainerbild beim Kampfbeginn, ReplaceFaintedEnemyMon
          -- mit GetBattleHealthBarColor für volle KP), ist sie grün; der Port nimmt die KP-Anzeige des Pokémon davor
          local gruen = (self.showEnemyTrainer or self.showEnemyBalls) and P.pal(self.data, "GREENBAR")
          if gruen then t[1] = gruen end
        end
        return t
      end
    end
    -- Heilmaschine im Pokémon-Center (Farben „OG RED“/„OG BLUE“): die Bälle und der Monitor sind Sprites mit OBP1;
    -- die Boot-ROM des Game Boy Color legt auf OBP1 die Hintergrundpalette (DE-ROM: Bälle blau bzw. rot).  Der Port
    -- färbt sie mit der Objektpalette OBP0 (OverworldController healMachineShader: PaletteFX.ogObj, umgestellt mit
    -- der OBP1-Tabelle der Maschine) → bei diesen beiden Umstellungen die Hintergrundpalette nehmen
    local alt_permute = P.permute
    local function maschine(map)
      return type(map) == "table" and map[0] == 0 and map[3] == 3
        and ((map[1] == 0 and map[2] == 2) or (map[1] == 2 and map[2] == 0))
    end
    P.permute = function(colors, map, ...)
      if P.usesSpriteObp() and maschine(map) and colors == P.ogObj() then colors = P.ogBg() end
      return alt_permute(colors, map, ...)
    end
    local okS, SM = pcall(require, "src.ui.SlotMachine")
    local okR, SR = pcall(require, "src.render.SpriteRenderer")
    if not (okS and okR and type(SM) == "table" and type(SM.drawReels) == "function"
        and type(SR.obpImage) == "function" and type(P.markUiSpriteRedraw) == "function") then return end
    local original = SM.drawReels
    SM.drawReels = function(self, art, ...)
      if not (P.usesSpriteObp() and type(art) == "table" and art.sheet and self.symbolImg) then
        return original(self, art, ...)
      end
      local blau = GameVersion.isBlue and GameVersion.isBlue()
      local obj = SR.obpImage(art.sheet, blau and P.GBC_OBJ_BLUE or P.ogObjBase(), blau and "slotobj_blue" or "slotobj")
      local zeichne = love.graphics.draw
      return ersetzt({ { love.graphics, "draw", function(bild, quad, x, y, ...)
        local r = zeichne(bild, quad, x, y, ...)
        if bild == self.symbolImg and obj then P.markUiSpriteRedraw(obj, quad, x, y) end
        return r
      end } }, original, self, art, ...)
    end
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

  -- Länge eines Schreis in Frames (PlayCry → WaitForSoundToFinish): Dauer der Tonquelle des Ports, an der DE-ROM
  -- geprüft (GLURAK 55 Frames: A nach 52 Frames noch ohne Wirkung, nach 56 angenommen)
  local function schrei_frames(src)
    local okd, dauer = pcall(src.getDuration, src)
    local okp, hoehe = pcall(src.getPitch, src)
    if not okd or type(dauer) ~= "number" or dauer <= 0 then return 0 end
    if okp and type(hoehe) == "number" and hoehe > 0 then dauer = dauer / hoehe end
    return math.floor(dauer * 60)
  end

  -- Pokédex-Eintrag: Größe, Gewicht und Text erscheinen, wenn der Schrei verklungen ist (PlayCry →
  -- WaitForSoundToFinish, an der DE-ROM gemessen rund 81 Frames nach dem Öffnen bei BISASAM).  Der Port fragt dafür
  -- das Abspielgerät (DexEntryMenu:crying, Source:isPlaying), das an der Wiedergabe in Echtzeit hängt → die Länge des
  -- Schreis in Frames zählen
  local function pokedex_schrei_einhaengen()
    local ok, Dex = pcall(require, "src.ui.DexEntryMenu")
    if not (ok and type(Dex) == "table" and type(Dex.crying) == "function" and type(Dex.update) == "function") then
      return
    end
    local alt_update = Dex.update
    Dex.update = function(self, ...)
      local vorher = self.crySrc
      local r = alt_update(self, ...)
      if self.crySrc and self.crySrc ~= vorher then self.dgmSchrei = schrei_frames(self.crySrc) end
      if (self.dgmSchrei or 0) > 0 then self.dgmSchrei = self.dgmSchrei - 1 end
      return r
    end
    Dex.crying = function(self)
      if not self.crySrc then return false end
      if (self.dgmSchrei or 0) > 0 then return true end
      self.crySrc = nil
      return false
    end
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

  -- Team-Menü, Untermenü der Feldattacken: das Original setzt den Kasten nach der linkesten Kachel der Attacken-
  -- namen (FieldMoveDisplayData, Spalte je Attacke; DE z. B. ZERSCHNEIDER ab Spalte 6), der Port nach der EN-Tabelle
  -- (src/ui/PartyMenu.lua FIELD_MOVE_X) → Kasten, Zeilen und Cursor auf die DE-Spalte.  Wird eine Feldattacke
  -- gewählt, stellt StartMenu_Pokemon vorher die Teamliste wieder her (LoadScreenTilesFromBuffer1), auch wenn sie
  -- dann abgelehnt wird (z. B. „Hier kann nicht … SURFER“; danach .loop zurück zur Teamliste).  Der Port lässt das
  -- Untermenü hinter der Meldung offen → Untermenü schließen, Cursor hohl, bis die Meldung weg ist.
  local function teammenue_einhaengen(spalten)
    local ok, PM = pcall(require, "src.ui.PartyMenu")
    if not (ok and type(PM) == "table" and type(PM.draw) == "function" and type(PM.update) == "function") then
      return
    end
    local Font = require("src.render.Font")
    local function feld(entry)
      return type(entry) == "table" and spalten[entry.move or entry.action] and true or false
    end
    local alt_draw = PM.draw
    PM.draw = function(self, ...)
      if not (self.submenu and type(self.subItems) == "table") then return alt_draw(self, ...) end
      local lx = 12
      for _, e in ipairs(self.subItems) do
        local s = type(e) == "table" and spalten[e.move or e.action]
        if s and s < lx then lx = s end
      end
      local n = #self.subItems
      local oben = n > 3 and math.max(0, 16 - n * 2) or 11
      -- nach dem Kasten zeichnet draw nur noch Zeilen und Cursor des Untermenüs (Font.draw über Font.drawCode)
      local db, dc, schub = Font.drawBox, Font.drawCode, nil
      return ersetzt({
        { Font, "drawBox", function(tx, ty, tw, th, ...)
          if ty == oben and tx + tw == 20 and ty + th == 18 then
            local r = db(lx - 1, ty, 21 - lx, th, ...)
            schub = (lx - tx - 1) * 8
            return r
          end
          return db(tx, ty, tw, th, ...)
        end },
        { Font, "drawCode", function(code, x, y, ...)
          if schub then x = x + schub end
          return dc(code, x, y, ...)
        end },
      }, alt_draw, self, ...)
    end
    local alt_update = PM.update
    PM.update = function(self, ...)
      local gewaehlt = self.submenu and type(self.subItems) == "table" and self.subItems[self.subIndex]
      local r = alt_update(self, ...)
      local top = self.game.stack:top()
      if feld(gewaehlt) and self.submenu and top ~= self and type(top) == "table" and top.pages then
        self.submenu, self.subIndex, self.chosenHollow = nil, 1, true
        local fertig = top.onDone
        top.onDone = function(...)
          self.chosenHollow = nil
          if fertig then return fertig(...) end
        end
      end
      return r
    end
  end

  -- Fliegen-Karte: vor dem Ortsnamen steht ToText; die DE-ROM schreibt dort Code $70, im Original die Kachel $70 der
  -- Kampf-/Statuskacheln (HpBarAndStatusGraphics ab $62, DE ein Pfeil „➔“).  Der Port zeichnet den Code mit der Schrift
  -- (dort ein Anführungszeichen) → in der Kopfzeile der Fliegen-Karte die Kachel aus font_battle_extra
  local function flugkarte_einhaengen()
    local ok, TM = pcall(require, "src.ui.TownMap")
    if not (ok and type(TM) == "table" and type(TM.draw) == "function") then return end
    local Font = require("src.render.Font")
    local Hud = require("src.render.HudTiles")
    local original = TM.draw
    TM.draw = function(self, ...)
      if not self.fly then return original(self, ...) end
      local dc = Font.drawCode
      return ersetzt({ { Font, "drawCode", function(code, x, y, ...)
        if code == 0x70 and y == 0 then return weiss(Hud.namingTile, code, x, y) end
        return dc(code, x, y, ...)
      end } }, original, self, ...)
    end
  end

  -- PC, Ruhmeshalle (LeaguePCShowMon): je Eintrag blendet das Original weiß aus (GBPalWhiteOutWithDelay3,
  -- ClearScreen, Bild laden; an der DE-ROM gemessen 56 Frames), zeigt dann den Eintrag, spielt den Schrei und wartet,
  -- bis er verklungen ist (PlayCry → WaitForSoundToFinish); erst danach nimmt es A an (WaitForTextScrollButtonPress).
  -- Der Port zeigt mit jedem A sofort den nächsten Eintrag (src/ui/LeaguePC.lua update) → Weißblende, Schrei danach,
  -- Tasten erst nach dem Schrei
  local RUHMESHALLE_WEISS = 56
  local function ruhmeshalle_pc_einhaengen()
    local ok, LP = pcall(require, "src.ui.LeaguePC")
    if not (ok and type(LP) == "table" and type(LP.loadMon) == "function" and type(LP.update) == "function"
        and type(LP.draw) == "function") then return end
    local Sound = require("src.core.Sound")
    local alt_load, alt_update, alt_draw = LP.loadMon, LP.update, LP.draw
    LP.loadMon = function(self, ...)
      local schrei
      local r = ersetzt({ { Sound, "playCry", function(...) schrei = { ... } end } }, alt_load, self, ...)
      self.dgmWeiss, self.dgmSchrei, self.dgmArt = RUHMESHALLE_WEISS, nil, schrei
      return r
    end
    LP.update = function(self, ...)
      if (self.dgmWeiss or 0) > 0 then
        self.dgmWeiss = self.dgmWeiss - 1
        if self.dgmWeiss == 0 and self.dgmArt then
          local src = Sound.playCry(unpack(self.dgmArt))
          self.dgmSchrei = src and schrei_frames(src) or 0
        end
        return
      end
      if (self.dgmSchrei or 0) > 0 then
        self.dgmSchrei = self.dgmSchrei - 1
        return
      end
      return alt_update(self, ...)
    end
    LP.draw = function(self, ...)
      if (self.dgmWeiss or 0) <= 0 then return alt_draw(self, ...) end
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, 160, 144)
    end
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

  -- Gelb, PIKACHU hinter dem Spieler: eine Richtung zu PIKACHU dreht zunächst nur, erst wenn sie lange genug gehalten
  -- wird, tauscht der Spieler den Platz (wPikachuCollisionCounter, home/overworld.asm).  An der DE-ROM gemessen
  -- beginnt der Schritt nach 19 Frames Halten (12 Frames: nur drehen); der Port setzt den Zähler auf 8 (PikachuFollower
  -- tickCollisionCounter) und läuft schon nach rund 10 Frames → Startwert so, dass er wie die ROM nach 19 Frames läuft
  local PIKACHU_HALTEN = 18
  local function pikachu_halten_einhaengen()
    if not (GameVersion.isYellow and GameVersion.isYellow()) then return end
    local ok, PF = pcall(require, "src.world.PikachuFollower")
    if not (ok and type(PF) == "table" and type(PF.update) == "function") then return end
    local original = PF.update
    PF.update = function(game, ow, ...)
      local vorher = type(ow) == "table" and ow.pikachuCollisionCounter
      local r = original(game, ow, ...)
      if type(ow) == "table" and ow.pikachuCollisionCounter == 8 and vorher ~= 8 then
        ow.pikachuCollisionCounter = PIKACHU_HALTEN
      end
      return r
    end
  end

  -- Gelb, PIKACHU und Textfenster: PIKACHU ist ein Sprite mit eigener Verwaltung (pikachu_follow.asm), das das
  -- Original beim Textfenster nicht ausblendet; es ragt über Fenster und Rahmen.  Der Port zeichnet die Figuren der
  -- Karte unter die Oberfläche → nach einem Textfenster direkt über der Karte PIKACHU noch einmal darüber zeichnen
  local function pikachu_vorn_einhaengen()
    if not (GameVersion.isYellow and GameVersion.isYellow()) then return end
    local TextBox = require("src.render.TextBox")
    local original = TextBox.draw
    TextBox.draw = function(self, ...)
      local r = original(self, ...)
      local game = self.game
      local ow = type(game) == "table" and game.overworld
      local rd = type(game) == "table" and game.renderer
      if not (type(ow) == "table" and ow.camera and rd and rd.worldViewSize and game.stack) then return r end
      -- nur ein Textfenster direkt über der Karte (nicht über Menüs, Beutel oder Kampf)
      local st = game.stack.states or {}
      local unter
      for i, s in ipairs(st) do
        if s == self then unter = st[i - 1] end
      end
      if unter ~= ow then return r end
      -- die Kartenansicht ist um den Bildschirm von 160×144 zentriert (größer, wenn das Fenster mehr Karte zeigt)
      local vw, vh = rd:worldViewSize()
      local cx = ow.camera.x + ((vw or 160) - 160) / 2
      local cy = ow.camera.y + ((vh or 144) - 144) / 2
      for _, e in ipairs(ow.entities or {}) do
        if type(e) == "table" and e.pikachuFollower and type(e.draw) == "function" then
          love.graphics.setColor(1, 1, 1, 1)
          pcall(e.draw, e, cx, cy)
        end
      end
      return r
    end
  end

  -- Gelb, PIKACHU ansprechen (TalkToPikachu, engine/pikachu/pikachu_emotions.asm und pikachu_pic_animation.asm): der
  -- Port spielt die Emotion sofort, wartet beim Schrei so lange, wie die WAV-Datei dauert (ohne Tonausgabe gar nicht),
  -- und zeigt Kasten und Bild im selben Frame.  An der DE-ROM gemessen (PyBoy, alle 32 Emotionen über einen Hook auf
  -- LoadPikachuExpression erzwungen, Station 13):
  --   DisplayTextID bis zum ersten Befehl der Emotion 20 Frames; Schrei (pcm): 3 × DelayFrame, dann die PCM-Aufnahme
  --   bei gesperrten Interrupts (Bytes · 360 / 17556 Frames, Bild steht); Sprechblase 60 + 2 Frames;
  --   LoadPikachuSpriteIntoVRAM (Unterbefehl 0) 6 Frames; Bild (pikapic): 5 Frames bis der Rahmen steht
  --   (PlacePikapicTextBoxBorder), dann leerer Kasten, bis die Grafik entpackt ist (je Bildskript, Tabelle unten),
  --   Bild 3 · Dauer + 3 Frames, mit Schrei im Bildskript stattdessen 5 Frames Bild, Schrei, dann 3 · Dauer;
  --   danach 2 Frames leerer Kasten.  Nach dem Schließen fehlt PIKACHU 17 Frames (seine Kacheln hat das Bild
  --   überschrieben, CloseTextDisplay lädt sie neu), außer die Emotion lädt sie selbst (Unterbefehl 2): 1 Frame
  local PIKA_ANSPRECHEN, PIKA_PCM_VOR, PIKA_BLASE_NACH, PIKA_SPRITES = 20, 3, 2, 6
  local PIKA_RAHMEN, PIKA_BILD_VOR_SCHREI, PIKA_NACH_LEER, PIKA_VERBORGEN = 5, 5, 2, 17
  -- Emotionen aus Kartenskripten (Fanclub, Bills Haus) laufen in der ROM ebenso über DisplayTextID und CloseTextDisplay:
  -- 20 Frames Pause davor; danach fehlt der Spieler (seine Kacheln hat das Bild überschrieben), PIKACHU bleibt neben dem
  -- Kasten zu sehen.  Im Fanclub gemessen (DE-ROM, Station 78 mit Skript 0, wShadowOAM): Pause 21, Spieler wieder da
  -- 22 Frames nach dem leeren Kasten; in Bills Haus lädt Unterbefehl 2 die Kacheln gleich wieder (1 Frame)
  local PIKA_VERBORGEN_FANCLUB = 20
  local PIKA_AUFBAU_STANDARD = 41
  local PIKA_AUFBAU = {
    [1] = 39, [2] = 40, [3] = 42, [4] = 41, [5] = 41, [6] = 38, [7] = 42, [8] = 43, [9] = 41, [10] = 45,
    [11] = 41, [12] = 42, [13] = 45, [14] = 42, [15] = 42, [16] = 42, [17] = 44, [18] = 21, [19] = 42, [20] = 42,
    [21] = 57, [22] = 24, [23] = 21, [24] = 24, [25] = 45, [26] = 49, [27] = 41, [28] = 41,
  }
  local function pikachu_bild_einhaengen(schreie)
    if not (GameVersion.isYellow and GameVersion.isYellow() and type(schreie) == "table") then return end
    local okp, PF = pcall(require, "src.world.PikachuFollower")
    local oko, OW = pcall(require, "src.world.OverworldController")
    if not (okp and oko and type(PF.talk) == "function" and type(OW.update) == "function") then return end
    local Sound = require("src.core.Sound")
    local gesehen = setmetatable({}, { __mode = "k" })
    local schrei, emotion   -- letzter Schrei aus PikachuFollower, zuletzt gelesene Emotion
    local im_gespraech      -- PF.talk läuft (sonst kommt eine neue Emotion aus einem Kartenskript)
    local skript_emotion    -- eben gelesene Emotion eines Kartenskripts, ihr erster Abschnitt folgt im selben Schritt
    local info = {}         -- je Emotion: zeigt sie ein Bild, lädt sie die Kacheln danach selbst?
    local bild_id = {}      -- Bildpfad → Nummer des Bildskripts

    local function pcm_frames(n) return (schreie[n] or 0) * 360 / 17556 end
    local function ton(src, was)
      local ok, f = pcall(function() return src[was] end)
      if ok and type(f) == "function" then pcall(f, src) end
    end
    local function stufe(ow, npc, frames, bild, weiter, leer)
      local t = { npc = npc, frames = frames, bubble = false, pikaPic = bild,
                  pikaBlankAt = leer and math.huge or nil, onDone = weiter }
      gesehen[t] = true
      return t
    end
    local function folge(ow, ziel) return function() ow.emote = ziel end end
    -- PIKACHU bzw. der Spieler unsichtbar (die Bildgrafik belegt die Kacheln) bzw. wieder sichtbar
    local function verbergen(npc)
      if npc.dgmZeichnen ~= nil then return end
      npc.dgmZeichnen = rawget(npc, "draw") or false
      npc.draw = function() end
    end
    local function zeigen(npc)
      if npc.dgmZeichnen == nil then return end
      npc.draw = npc.dgmZeichnen or nil
      npc.dgmZeichnen = nil
    end

    -- Skripte der Emotionen einmal nach der ROM ergänzen; die Leseschnittstelle merkt sich, welche gerade beginnt
    local function vorbereiten()
      local Game = require("src.core.Game")
      local field = type(Game) == "table" and Game.data and Game.data.field
      local pd = field and field.pikachu
      if type(pd) ~= "table" or pd.dgmVorbereitet or type(pd.emotions) ~= "table" then return end
      pd.dgmVorbereitet = true
      for id, p in pairs(pd.pics or {}) do
        if type(p) == "table" and p.image then bild_id[p.image] = id end
      end
      local echt = pd.emotions
      for id, skript in pairs(echt) do
        local neu, bild, neuladen = {}, false, false
        for _, s in ipairs(skript) do
          if s.op == "subcmd" and s.sub == 0 then
            neu[#neu + 1] = { op = "delay", frames = PIKA_SPRITES }
          else
            neu[#neu + 1] = s
            if s.op == "bubble" then neu[#neu + 1] = { op = "delay", frames = PIKA_BLASE_NACH } end
            if s.op == "pikapic" then bild = true end
            if s.op == "subcmd" and s.sub == 2 and bild then neuladen = true end
          end
        end
        echt[id] = neu
        info[id] = { bild = bild, neuladen = neuladen }
      end
      pd.emotions = setmetatable({}, { __index = function(_, k)
        emotion = k
        if not im_gespraech then skript_emotion = k end
        return echt[k]
      end })
    end

    -- neuer Abschnitt einer Emotion (ow.emote): Zeiten wie die ROM
    local function neu(ow, e, s)
      gesehen[e] = true
      local npc = e.npc
      if not (type(npc) == "table" and npc.pikachuFollower) then return end
      if e.pikaPic then
        local aufbau = PIKA_AUFBAU[bild_id[e.pikaPic]] or PIKA_AUFBAU_STANDARD
        local function vorlauf(ziel)
          ow.emote = stufe(ow, npc, PIKA_RAHMEN, nil, function()
            ow.emote = stufe(ow, npc, aufbau, e.pikaPic, folge(ow, ziel), true)
          end)
        end
        if e.pikaSeq then
          -- das Bild läuft; nach dem Ende 2 Frames leerer Kasten; bei einem Kartenskript fehlt danach noch der Spieler
          -- (CloseTextDisplay), beim Ansprechen PIKACHU (PF.talk)
          local fertig = e.onDone
          local function weiter() if fertig then return fertig() end end
          e.onDone = function()
            ow.emote = stufe(ow, npc, PIKA_NACH_LEER, e.pikaPic, function()
              local sk = ow.dgmSkript
              ow.dgmSkript = nil
              local spieler = ow.player
              if not (sk and spieler) then return weiter() end
              local inf = info[sk.id] or {}
              local n = inf.neuladen and 1 or (sk.karte == "POKEMON_FAN_CLUB" and PIKA_VERBORGEN_FANCLUB or PIKA_VERBORGEN)
              verbergen(spieler)
              ow.emote = stufe(ow, npc, n, nil, function()
                zeigen(spieler)
                return weiter()
              end)
            end, true)
          end
          if ow.dgmBildSchrei == e.pikaPic then
            ow.dgmBildSchrei = nil
          else
            e.frames, e.pikaTotal = e.frames + 3, (e.pikaTotal or e.frames) + 3
            vorlauf(e)
          end
        else
          -- Schrei im Bildskript: erst Rahmen und Aufbau, 5 Frames Bild, dann der Schrei
          ow.dgmBildSchrei = e.pikaPic
          if s then
            ton(s.src, "stop")
            e.frames = math.ceil(pcm_frames(s.n)) + 1
            e.dgmSpielen = s.src
          end
          vorlauf(stufe(ow, npc, PIKA_BILD_VOR_SCHREI, e.pikaPic, folge(ow, e)))
        end
      elseif s and e.bubble == false then
        e.frames = PIKA_PCM_VOR + math.floor(pcm_frames(s.n))
      end
    end

    -- erster Abschnitt einer Emotion: davor die 20 Frames von DisplayTextID; ein Schrei als erster Befehl erklingt erst
    -- danach
    local function vorspann(ow, erst, s)
      neu(ow, erst, s)
      local kopf = ow.emote
      if s and kopf == erst and not erst.pikaPic then
        ton(s.src, "stop")
        erst.dgmSpielen = s.src
      end
      ow.emote = stufe(ow, erst.npc, PIKA_ANSPRECHEN, nil, folge(ow, kopf))
    end

    -- Schreie auf der Karte merken (der nächste neue Abschnitt einer Emotion gehört dazu); ohne Tonausgabe gibt der
    -- Port nil zurück und überspringt die Pause, die ROM wartet trotzdem → dann eine stumme Ersatzquelle
    local in_karte = 0
    local STUMM = setmetatable({}, { __index = function() return function() return false end end })
    local alt_schrei = Sound.playPikaCry
    Sound.playPikaCry = function(data, n, ...)
      local src = alt_schrei(data, n, ...)
      if in_karte <= 0 then return src end
      if src == nil then src = setmetatable({}, getmetatable(STUMM)) end
      schrei = { n = n, src = src }
      return src
    end
    local function auf_karte(f, ...)
      in_karte = in_karte + 1
      local ok, r = pcall(f, ...)
      in_karte = in_karte - 1
      if not ok then error(r, 0) end
      return r
    end

    -- vor und nach jedem Schritt der Karte: ein neuer Abschnitt wird umgestellt, bevor er gezeichnet wird
    local function pruefen(ow)
      local e = ow.emote
      if type(e) == "table" and e ~= ow.dgmEmoteAktiv then
        if not gesehen[e] then
          if skript_emotion and type(e.npc) == "table" and e.npc.pikachuFollower then
            ow.dgmSkript = { id = skript_emotion, karte = ow.map and ow.map.id }
            vorspann(ow, e, schrei)
          else
            neu(ow, e, schrei)
          end
          e = ow.emote
        end
        ow.dgmEmoteAktiv = e
        if e.dgmSpielen then ton(e.dgmSpielen, "play"); e.dgmSpielen = nil end
      end
      schrei, skript_emotion = nil, nil
    end
    -- Sprünge in einer Emotion (engine/pikachu/pikachu_movement.asm): die ROM setzt die Höhe in die Spritedaten, nachdem
    -- die OAM für diesen Frame schon gebaut ist → PIKACHU steht einen Frame später auf der neuen Höhe; der Schatten
    -- (eigenes OAM-Sprite) erscheint sofort und verschwindet erst mit der Landung.  Gemessen an der DE-ROM (wShadowOAM,
    -- Emotion 4): Schatten ab Frame 29, Höhe ab 30 (Port 29), wieder unten und ohne Schatten bei 60 (Port 59)
    local function sprung_merken(ow)
      local npc = type(PF.current) == "function" and PF.current(ow)
      local e = ow.emote
      if not (npc and type(e) == "table" and e.npc == npc) then
        ow.dgmSprungVor, ow.dgmSprungZeige = nil, nil
        return
      end
      local vor = ow.dgmSprungVor
      ow.dgmSprungVor = { py = npc.py, schatten = npc.hopShadowY }
      ow.dgmSprungZeige = vor and { npc = npc, py = vor.py, schatten = npc.hopShadowY or vor.schatten } or nil
    end
    local alt_update = OW.update
    OW.update = function(self, ...)
      vorbereiten()
      pruefen(self)
      local r = auf_karte(alt_update, self, ...)
      pruefen(self)
      sprung_merken(self)
      return r
    end
    if type(OW.draw) == "function" then
      local alt_draw = OW.draw
      OW.draw = function(self, ...)
        local z = self.dgmSprungZeige
        if not z then return alt_draw(self, ...) end
        local npc = z.npc
        local py, schatten = npc.py, npc.hopShadowY
        npc.py, npc.hopShadowY = z.py, z.schatten
        local ok, r = pcall(alt_draw, self, ...)
        npc.py, npc.hopShadowY = py, schatten
        if not ok then error(r, 0) end
        return r
      end
    end

    local alt_talk = PF.talk
    PF.talk = function(game, ow, npc, done, ...)
      vorbereiten()
      schrei, emotion = nil, nil
      ow.dgmSkript = nil
      local id
      local function ende()
        local inf = info[id]
        if not (inf and inf.bild) then
          if done then return done() end
          return
        end
        verbergen(npc)
        ow.emote = stufe(ow, npc, inf.neuladen and 1 or PIKA_VERBORGEN, nil, function()
          zeigen(npc)
          if done then return done() end
        end)
      end
      im_gespraech = true
      local ok, r = pcall(auf_karte, alt_talk, game, ow, npc, ende, ...)
      im_gespraech = false
      if not ok then error(r, 0) end
      id = emotion
      local erst = ow.emote
      if type(erst) ~= "table" or gesehen[erst] then return r end
      local s = schrei
      schrei = nil
      vorspann(ow, erst, s)
      return r
    end
  end

  -- Gelb, Pokémon-Fanclub (scripts/PokemonFanClub.asm): nach der ersten PIKACHU-Szene steht
  -- wPokemonFanClubCurScript auf SCRIPT1, und PokemonFanClubScript1 startet sie beim Betreten nur noch, wenn
  -- Random < 10 percent ist (DE-ROM: „cp $19“, 25 von 256).  Der Port kennt den Skriptzustand nicht und spielt die
  -- Szene jedes Mal (PikachuFollower.onFanClubEntered).  Zustand im Spielstand (dgmFanclubSkript); bei importierten
  -- Spielständen aus dem SRAM-Abbild (sMainData + 771, DE wram $D5FE − $D2FB) gelesen und beim Export zurückgeschrieben
  local FANCLUB_SKRIPT, FANCLUB_ZUFALL = 771, 25
  local function fanclub_einhaengen()
    if not (GameVersion.isYellow and GameVersion.isYellow()) then return end
    local okp, PF = pcall(require, "src.world.PikachuFollower")
    local okg, GenSave = pcall(require, "src.save_convert.GenSave")
    if not (okp and okg and type(PF.onFanClubEntered) == "function" and GenSave.OFFSETS) then return end
    local stelle = GenSave.OFFSETS.mainData + FANCLUB_SKRIPT
    local function skript(save)
      if save.dgmFanclubSkript ~= nil then return save.dgmFanclubSkript end
      local roh = save.rawImport
      if type(roh) == "string" and #roh == GenSave.SAVE_SIZE then return roh:byte(stelle + 1) == 1 and 1 or 0 end
      return 0
    end
    local alt = PF.onFanClubEntered
    PF.onFanClubEntered = function(game, ow, ...)
      local save = game and game.save
      if type(save) == "table" and ow and ow.map and ow.map.id == "POKEMON_FAN_CLUB"
          and not save.pikachuMapScriptActive and skript(save) == 1
          and love.math.random(0, 255) >= FANCLUB_ZUFALL then
        save.pikachuMapScriptActive = true
        return
      end
      local r = alt(game, ow, ...)
      if type(save) == "table" and ow and ow.pikachuFanClubScene then save.dgmFanclubSkript = 1 end
      return r
    end
    local alt_encode = GenSave.encode
    GenSave.encode = function(save, data, template, ...)
      local wert = type(save) == "table" and save.dgmFanclubSkript
      local quelle = template or (type(save) == "table" and save.rawImport)
      if wert and type(quelle) == "string" and #quelle == GenSave.SAVE_SIZE then
        template = quelle:sub(1, stelle) .. string.char(wert) .. quelle:sub(stelle + 2)
      end
      return alt_encode(save, data, template, ...)
    end
  end

  -- Gelb, PIKACHU nach WEITER (engine/pikachu/pikachu_follow.asm): Spritedaten (Platz 15) und Folgepuffer
  -- (wPikachuFollowCommandBuffer, in sMainData) kommen aus dem Spielstand; die ROM lässt PIKACHU an der gesicherten
  -- Stelle mit dem gesicherten Blick.  Der Port setzt es auf das Feld des Spielers.  Beim Sichern steht im Puffer
  -- ein Befehl von PIKACHU zum Spieler (RefreshPikachuFollow im Startmenü, ComputePikachuFollowCommand: Zeile vor
  -- Spalte, ab 2 Feldern Abstand ein Doppelschritt) oder nichts, wenn es auf dem Spielerfeld steht.  Jeder Schritt
  -- des Spielers hängt seine Richtung an (QueuePikachuFollowCommand), und GetNextPikachuFollowCommand holt erst,
  -- wenn zwei Befehle liegen, den ältesten.  An der DE-ROM gemessen: neben/hinter dem Spieler läuft PIKACHU beim
  -- ersten Schritt auf dessen altes Feld, auf dem Spielerfeld bleibt es stehen (ohne sich umzudrehen), diagonal geht
  -- es nur die Zeile und bleibt danach eine Spalte versetzt, aus 2+ Feldern Abstand macht es einen Doppelschritt
  -- (2 Felder in einem Schritt) und bleibt versetzt.  Der Mod spielt den Puffer nach, bis er dem Folgen des Ports
  -- entspricht (genau ein Befehl, der auf das Spielerfeld führt); ein Text oder Menü füllt ihn wie
  -- RefreshPikachuFollow neu.  Zustand im Spielstand (dgmPikachu); bei importierten Spielständen aus dem
  -- SRAM-Abbild gelesen (sSpriteData Platz 15, sMainData + 320: Puffergröße, + 321: Befehle), beim Export
  -- zurückgeschrieben.
  local PIKA_PUFFER, PIKA_Y, PIKA_X, PIKA_KARTE = 320, 106, 107, 103
  local PIKA_BLICK = { [0] = "down", [4] = "up", [8] = "left", [12] = "right" }
  local PIKA_BLICK_BYTE = { down = 0, up = 4, left = 8, right = 12 }
  local PIKA_VEKTOR = { { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 } }   -- Befehle 1-4: unten, oben, links, rechts
  local function pika_vektor(c)
    local d, n = PIKA_VEKTOR[(c - 1) % 4 + 1], c > 4 and 2 or 1
    return d[1] * n, d[2] * n
  end
  -- ComputePikachuFollowCommand: Befehl von PIKACHU (kx, ky) zum Spieler (x, y), nil auf dem Spielerfeld
  local function pika_befehl(kx, ky, x, y)
    local dy, dx = y - ky, x - kx
    if dy ~= 0 then return (math.abs(dy) < 2 and 0 or 4) + (dy > 0 and 1 or 2) end
    if dx == 0 then return nil end
    return (math.abs(dx) < 2 and 0 or 4) + (dx < 0 and 3 or 4)
  end
  local function pikachu_laden_einhaengen()
    if not (GameVersion.isYellow and GameVersion.isYellow()) then return end
    local okp, PF = pcall(require, "src.world.PikachuFollower")
    local okg, GenSave = pcall(require, "src.save_convert.GenSave")
    local okm, Game = pcall(require, "src.core.Game")
    local oks, StateStack = pcall(require, "src.core.StateStack")
    if not (okp and okg and okm and oks and GenSave.OFFSETS and type(PF.update) == "function"
        and type(PF.current) == "function" and type(Game.restoreSave) == "function"
        and type(Game.writeSave) == "function" and type(StateStack.push) == "function") then return end
    local O = GenSave.OFFSETS
    local M, S1, S2 = O.mainData, O.spriteData + 0xF0, O.spriteData + 0x1F0
    local function kartennr(data, karte)
      local ok, cw = pcall(GenSave.crosswalks, data)
      return ok and type(cw) == "table" and cw.mapsIndex and cw.mapsIndex[karte]
    end

    -- Lage aus einem importierten SRAM-Abbild (nur solange der Spieler noch auf dessen Feld steht)
    local function aus_abbild(save, data)
      local roh, p = save.rawImport, save.player
      if not (type(roh) == "string" and #roh == GenSave.SAVE_SIZE and type(p) == "table") then return nil end
      local function b(i) return roh:byte(i + 1) end
      if b(S1) ~= 0x49 or b(S1 + 1) == 0 or not PIKA_BLICK[b(S1 + 9)] then return nil end
      local nr = kartennr(data, p.map)
      if not nr or b(M + PIKA_KARTE) ~= nr % 256 or b(M + PIKA_X) ~= p.x or b(M + PIKA_Y) ~= p.y then return nil end
      local puffer, n = {}, b(M + PIKA_PUFFER)
      if n ~= 0xFF then
        for i = 0, math.min(n, 15) do
          local c = b(M + PIKA_PUFFER + 1 + i)
          if c < 1 or c > 8 then break end
          puffer[#puffer + 1] = c
        end
      end
      return { karte = p.map, x = p.x, y = p.y, kx = b(S2 + 5) - 4, ky = b(S2 + 4) - 4,
               blick = PIKA_BLICK[b(S1 + 9)], puffer = puffer }
    end

    -- Übergabe an das Folgen des Ports, sobald der Puffer ihm entspricht
    local function uebergabe(ow, npc, zx, zy)
      local q = ow.dgmPikaPuffer
      local gx, gy = npc.goalX or npc.cellX, npc.goalY or npc.cellY
      if #q ~= 1 then return end
      local dx, dy = pika_vektor(q[1])
      if gx + dx == zx and gy + dy == zy then ow.dgmPikaPuffer, ow.dgmPikaLetzt = nil, nil end
    end

    local original_laden = Game.restoreSave
    Game.restoreSave = function(self, loaded, ...)
      local r = original_laden(self, loaded, ...)
      local ow, save = self.overworld, self.save
      local lage = type(save) == "table" and save.dgmPikachu
      if lage == nil and type(save) == "table" then lage = aus_abbild(save, self.data) end
      local npc = type(ow) == "table" and ow.player and PF.current(ow)
      if type(lage) == "table" and npc and lage.karte == ow.map.id and lage.x == ow.player.cellX
          and lage.y == ow.player.cellY then
        npc.cellX, npc.cellY = lage.kx, lage.ky
        npc.px, npc.py = lage.kx * 16, lage.ky * 16
        npc.facing = lage.blick or npc.facing
        npc.targetX, npc.targetY, npc.goalX, npc.goalY, npc.moving, npc.idle = nil, nil, nil, nil, false, nil
        local q = {}
        for i, c in ipairs(lage.puffer or {}) do q[i] = c end
        ow.dgmPikaPuffer, ow.dgmPikaLetzt = q, { x = ow.player.cellX, y = ow.player.cellY }
        ow.pikachuTrail = { x = ow.player.cellX, y = ow.player.cellY }
        uebergabe(ow, npc, ow.player.cellX, ow.player.cellY)
      end
      return r
    end

    -- Sichern: Lage und Puffer wie nach RefreshPikachuFollow im Startmenü
    local original_sichern = Game.writeSave
    Game.writeSave = function(self, ...)
      local ow, save = self.overworld, self.save
      local npc = type(ow) == "table" and ow.player and PF.current(ow)
      if type(save) == "table" then
        save.dgmPikachu = false
        if npc and not npc.moving then
          local p = ow.player
          local c = pika_befehl(npc.cellX, npc.cellY, p.cellX, p.cellY)
          save.dgmPikachu = { karte = ow.map.id, x = p.cellX, y = p.cellY, kx = npc.cellX, ky = npc.cellY,
                              blick = npc.facing, puffer = { c } }
        end
      end
      return original_sichern(self, ...)
    end

    -- Verdeckt: HidePikachuIfOffScreen vergleicht im Ruhezustand mit wYCoord/wXCoord, die erst am Ende des
    -- Spielerschritts weiterzählen → PIKACHU auf dem Spielerfeld bleibt während des ganzen ersten Schritts
    -- unsichtbar (DE-ROM gemessen); der Port vergleicht mit dem Ziel des Schritts und zeigt es schon beim Losgehen
    -- Unter dem Textfenster: CheckSpriteAvailability (engine/overworld/movement.asm) blendet ein Sprite ganz aus,
    -- wenn eine der vier Kacheln seines Felds keine Kartenkachel ist (≥ MAP_TILESET_SIZE, also Fenster); so
    -- verschwindet PIKACHU, das nach dem Laden zwei Felder unter dem Spieler steht (Station 82).  Sonst ragt es über
    -- das Fenster (pikachu_vorn_einhaengen).
    local function unter_fenster(ow, npc)
      local st = Game.stack and Game.stack.states
      local rd = Game.renderer
      if type(st) ~= "table" or not (ow.camera and rd and rd.worldViewSize) then return false end
      local vw, vh = rd:worldViewSize()
      local sx = math.floor((npc.px - ow.camera.x - ((vw or 160) - 160) / 2) / 8)
      local sy = math.floor((npc.py - ow.camera.y - ((vh or 144) - 144) / 2) / 8)
      local ueber = false
      for _, s in ipairs(st) do
        if s == ow then ueber = true
        elseif ueber and type(s) == "table" and s.boxTx and s.boxTy and s.boxTw and s.boxTh
            and sx + 1 >= s.boxTx and sx < s.boxTx + s.boxTw and sy + 1 >= s.boxTy and sy < s.boxTy + s.boxTh then
          return true
        end
      end
      return false
    end
    if type(PF.underPlayer) == "function" then
      PF.underPlayer = function(ow, npc)
        local p = type(ow) == "table" and ow.player
        if not (p and npc) then return false end
        if unter_fenster(ow, npc) then return true end
        if npc.moving then return false end
        return npc.cellX == p.cellX and npc.cellY == p.cellY
      end
    end

    -- Text oder Menü über der Karte: RefreshPikachuFollow
    local original_push = StateStack.push
    StateStack.push = function(self, ...)
      local ow = Game.overworld
      if type(ow) == "table" and ow.dgmPikaPuffer then ow.dgmPikaAuffrischen = true end
      return original_push(self, ...)
    end

    -- neue Karte: der Port setzt PIKACHU neu, ein Übergang über eine Verbindung verschiebt nur die Koordinaten
    local original_karte = PF.onMapEntered
    PF.onMapEntered = function(game, ow, opts, ...)
      if type(ow) == "table" and not (opts and opts.keepPikachu) then ow.dgmPikaPuffer, ow.dgmPikaLetzt = nil, nil end
      return original_karte(game, ow, opts, ...)
    end
    local original_rebase = PF.rebase
    PF.rebase = function(ow, dx, dy, ...)
      local l = type(ow) == "table" and ow.dgmPikaLetzt
      if l then l.x, l.y = l.x + dx, l.y + dy end
      return original_rebase(ow, dx, dy, ...)
    end

    local original_folgen = PF.update
    PF.update = function(game, ow, ...)
      local q = type(ow) == "table" and ow.dgmPikaPuffer
      local npc = q and not ow.pikaHop and PF.current(ow)
      if not npc or PF.isFollowingDisabled(ow) then return original_folgen(game, ow, ...) end
      local p = ow.player
      local zx, zy = p.targetX or p.cellX, p.targetY or p.cellY
      local l = ow.dgmPikaLetzt
      if ow.dgmPikaAuffrischen and not npc.moving then
        ow.dgmPikaAuffrischen = nil
        q = { pika_befehl(npc.cellX, npc.cellY, zx, zy) }
        ow.dgmPikaPuffer = q
      end
      -- QueuePikachuFollowCommand: der Schritt des Spielers wird beim Losgehen angehängt
      if zx ~= l.x or zy ~= l.y then
        q[#q + 1] = zy > l.y and 1 or zy < l.y and 2 or zx < l.x and 3 or 4
        l.x, l.y = zx, zy
      end
      -- PikachuMovementState_ProcessCommand: ab zwei Befehlen den ältesten ausführen (Normal- oder Doppelschritt)
      local steht = not npc.moving and (not npc.goalX or (npc.goalX == npc.cellX and npc.goalY == npc.cellY))
      if steht and #q >= 2 then
        local c = table.remove(q, 1)
        local dx, dy = pika_vektor(c)
        npc.idle = nil
        npc.px, npc.py = npc.cellX * 16, npc.cellY * 16
        npc.facing = PIKA_BLICK[((c - 1) % 4) * 4]
        npc.targetX, npc.targetY = npc.cellX + dx, npc.cellY + dy
        npc.goalX, npc.goalY = npc.targetX, npc.targetY
        npc.hopStep = c > 4 or nil
        npc.stepFrames = p.stepFramesCur or p.stepFrames or 16
        npc.moving, npc.progress = true, 0
        npc:update(ow.map, ow.entities)
      end
      uebergabe(ow, npc, zx, zy)
      ow.pikachuTrail = { x = zx, y = zy }
      return original_folgen(game, ow, ...)
    end

    -- Export: Platz 15 und Puffer ins SRAM-Abbild, danach die Prüfsumme neu
    local original_encode = GenSave.encode
    GenSave.encode = function(save, data, template, ...)
      local out = original_encode(save, data, template, ...)
      local lage = type(save) == "table" and save.dgmPikachu
      local p = type(save) == "table" and save.player
      if type(out) ~= "string" or #out ~= GenSave.SAVE_SIZE or type(lage) ~= "table" or type(p) ~= "table"
          or lage.karte ~= p.map or lage.x ~= p.x or lage.y ~= p.y then return out end
      local bytes = {}
      for i = 1, #out, 4096 do
        for j, v in ipairs({ out:byte(i, math.min(i + 4095, #out)) }) do bytes[i + j - 1] = v end
      end
      local function setze(i, v) bytes[i + 1] = v % 256 end
      if bytes[S1 + 1] ~= 0x49 or bytes[S1 + 2] == 0 then
        setze(S1, 0x49); setze(S2 + 6, 0xFE); setze(S2 + 14, 2)
      end
      local blick = PIKA_BLICK_BYTE[lage.blick] or 0
      local auf_spieler = lage.kx == lage.x and lage.ky == lage.y
      setze(S1 + 1, 1)
      setze(S1 + 2, auf_spieler and 0xFF or 0x10 + blick)
      setze(S1 + 3, 0); setze(S1 + 5, 0); setze(S1 + 7, 0); setze(S1 + 8, 0)
      setze(S1 + 4, 0x3C + 16 * (lage.ky - lage.y))
      setze(S1 + 6, 0x40 + 16 * (lage.kx - lage.x))
      setze(S1 + 9, blick)
      setze(S2 + 4, lage.ky + 4); setze(S2 + 5, lage.kx + 4)
      local puffer = lage.puffer or {}
      setze(M + PIKA_PUFFER, #puffer == 0 and 0xFF or #puffer - 1)
      for i = 1, 16 do setze(M + PIKA_PUFFER + i, puffer[i] or 0) end
      local summe = 0
      for i = O.checksumStart, O.checksumEnd - 1 do summe = summe + bytes[i + 1] end
      setze(O.mainChecksum, 255 - summe % 256)
      local teile = {}
      for i = 1, #bytes, 4096 do teile[#teile + 1] = string.char(unpack(bytes, i, math.min(i + 4095, #bytes))) end
      return table.concat(teile)
    end
  end

  -- Laden eines Spielstands: die zuletzt gewählte Zeile von Team-Menü und Beutel (wPartyAndBillsPCSavedMenuItem,
  -- wBagSavedMenuItem) liegt im Original im WRAM und ist nach dem Neustart leer; der Port behält sie im Spielobjekt
  -- über das Zurück zum Hauptmenü hinweg (Game.partyMenuSavedIndex, bagSavedMenuItem) → beim Laden zurücksetzen
  local function laden_einhaengen()
    local ok, Game = pcall(require, "src.core.Game")
    if not (ok and type(Game) == "table" and type(Game.restoreSave) == "function") then return end
    local original = Game.restoreSave
    Game.restoreSave = function(self, ...)
      self.partyMenuSavedIndex, self.bagSavedMenuItem = nil, nil
      if type(self.overworld) == "table" then self.overworld.dgmStehtext = nil end
      return original(self, ...)
    end
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

  -- Spielautomat, Textseiten der DE-ROM mit Fortsetzung (▼, dann eine Zeile hochrollen):
  -- * BetHowManySlotMachineText „Wie viele Münzen / möchtest Du ▼ / setzen?“: PrintText wartet am ▼, erst danach
  --   zeichnet MainSlotMachineLoop das Fenster ×3/×2/×1.  Der Port zeigt sofort das Menü (drawBottom, Stufe bet) →
  --   vorher die erste Seite mit ▼ bis A/B; danach bleiben „möchtest Du / setzen?“ unter dem Menü
  --   (automat_zeilen_einhaengen).
  -- * LinedUpText „Super! Du hast / 15 Münzen ▼ / gewonnen!“: der Port setzt alles in zwei Zeilen → erste Seite mit
  --   ▼, nach A/B die gerollte Seite „15 Münzen / gewonnen!“ (ohne Walzensymbol, es ist mit der Zeile weggerollt),
  --   dann wie im Port WaitForTextScrollButtonPress und Auszahlung.
  local function automat_seiten_einhaengen(de_text)
    local ok, SM = pcall(require, "src.ui.SlotMachine")
    if not (ok and type(SM) == "table" and type(SM.update) == "function" and type(SM.drawBottom) == "function"
        and type(SM.new) == "function" and type(SM.enterBet) == "function") then return end
    local Font = require("src.render.Font")
    local Sound = require("src.core.Sound")
    local einsatz = de_text and de_text._BetHowManySlotMachineText
    local seite1 = einsatz and ohne_ende(einsatz):match("^([^\v\f]-)\v")
    local alt_new, alt_bet = SM.new, SM.enterBet
    SM.new = function(...)
      local self = alt_new(...)
      if type(self) == "table" then self.dgmEinsatz = seite1 and 0 end
      return self
    end
    SM.enterBet = function(self, ...)
      local r = alt_bet(self, ...)
      self.dgmEinsatz = seite1 and 0
      return r
    end
    local function taste(self)
      local input = self.game.input
      if input:wasPressed("a") or input:wasPressed("b") then
        Sound.play(self.game.data, "Press_AB")
        return true
      end
    end
    local alt_update = SM.update
    SM.update = function(self, ...)
      -- NotEnoughCoinsSlotMachineText kehrt mit eigenem Text (betPrompt) ins Menü zurück, ohne Einsatzfrage
      if self.stage == "bet" and self.dgmEinsatz and not self.betPrompt then
        self.dgmEinsatz = self.dgmEinsatz + 1
        if taste(self) then self.dgmEinsatz = nil end
        return
      end
      if self.stage == "message" and self.dgmRest then
        if self.arrowTimer then self.arrowTimer = self.arrowTimer + 1 end
        if taste(self) then
          self.message, self.dgmRest, self.dgmGerollt = self.dgmRest, nil, true
        end
        return
      end
      local r = alt_update(self, ...)
      if self.stage == "message" and self.afterMessage == "payout" and not self.dgmGerollt
          and type(self.message) == "string" then
        local vorn, rest = self.message:match("^([^\v]-)\v(.*)$")
        local letzte = vorn and vorn:match("([^\n]*)$")
        if letzte then self.message, self.dgmRest = vorn, letzte .. "\n" .. rest end
      elseif self.stage ~= "message" and self.stage ~= "payout" then
        self.dgmGerollt = nil
      end
      return r
    end
    local alt_draw = SM.drawBottom
    SM.drawBottom = function(self, ...)
      if self.stage == "bet" and self.dgmEinsatz and not self.betPrompt then
        Font.drawBox(0, 12, 20, 6)
        love.graphics.setColor(0, 0, 0, 1)
        local z1, z2 = seite1:match("^([^\n]*)\n?(.*)$")
        Font.draw(z1, 8, 112)
        Font.draw(z2, 8, 128)
        if self.dgmEinsatz % 60 < 30 then Font.drawCode(0xEE, 144, 128) end
        love.graphics.setColor(1, 1, 1, 1)
        return
      end
      if not (self.dgmGerollt and (self.stage == "message" or self.stage == "payout")) then
        return alt_draw(self, ...)
      end
      local zeichne, fd = love.graphics.draw, Font.draw
      return ersetzt({
        { love.graphics, "draw", function(bild, ...)
          if bild == self.symbolImg then return end
          return zeichne(bild, ...)
        end },
        { Font, "draw", function(text, x, y, ...)
          if x == 40 and y == 112 then x = 8 end
          return fd(text, x, y, ...)
        end },
      }, alt_draw, self, ...)
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

  -- ================================================================ Haken: Textseiten und Abläufe

  -- Listen mit Frage im Textfenster (Spieler-PC: _WhatToWithdrawText, _WhatToTossText): im Original druckt PrintText
  -- die Frage, bevor die Liste erscheint, und die DE-ROM setzt dort eine Fortsetzung („Welches Item / möchtest Du ▼
  -- / mitnehmen?“), an der das Spiel auf A wartet.  Der Port zeigt Liste und die letzten zwei Zeilen sofort
  -- (ListMenu drawMessageBox) → bei Fragen mit Fortsetzung zuerst die Frage als Textfenster bis zu ihrem Ende, dann
  -- die Liste.  Nach einer Meldung („TRANK / mitgenommen.“, PlayerPC showCompletion) druckt das Original die Frage
  -- erneut, während die alte Liste samt Mengenfenster noch steht; neu gezeichnet wird die Liste erst danach → die
  -- Erneuerung der Zeilen (after) bis zum Ende der Frage zurückhalten
  local function listenfrage_einhaengen()
    local ok, LM = pcall(require, "src.ui.ListMenu")
    if not (ok and type(LM) == "table" and type(LM.new) == "function") then return end
    local TextBox = require("src.render.TextBox")
    local original = LM.new
    LM.new = function(game, title, items, opts, ...)
      local list = original(game, title, items, opts, ...)
      local frage = type(opts) == "table" and opts.messageBox and opts.footer
      if type(list) ~= "table" or type(frage) ~= "string" or not frage:find("\v", 1, true) then return list end
      local box = TextBox.new(game, frage, nil, { stay = {} })
      local erneut, zuletzt, gewickelt = false, frage, false
      local draw, update = list.draw, list.update
      list.update = function(self, ...)
        -- showCompletion legt PlayerPC erst nach ListMenu.new an
        if not gewickelt and type(self.showCompletion) == "function" then
          gewickelt = true
          local sc = self.showCompletion
          self.showCompletion = function(l, text, after, ...)
            local menge = l.pcQtyBox
            return sc(l, text, function() l.dgmNachher, l.dgmMenge = after, menge end, ...)
          end
        end
        if self.footer == frage and zuletzt ~= frage then
          box, erneut = TextBox.new(game, frage, nil, { stay = {} }), true
        end
        zuletzt = self.footer
        if not box then return update(self, ...) end
        box:update(...)
        if box.done then
          box, erneut = nil, false
          local nachher = self.dgmNachher
          self.dgmNachher, self.dgmMenge = nil, nil
          if nachher then nachher() end
        end
      end
      list.draw = function(self, ...)
        if self.footer ~= frage then zuletzt = self.footer end
        if not box then return draw(self, ...) end
        if erneut then
          draw(self, ...)
          if self.dgmMenge then self.dgmMenge:draw() end
        end
        return box:draw()
      end
      return list
    end
  end

  -- Texte ohne Buchstabenverzögerung (BIT_NO_TEXT_DELAY; Port: TextBox opts.instant), z. B. am Preisschalter „Wir
  -- tauschen / Münzen gegen ▼ / Preise ein.“ und „Du möchtest also / ABRA ▼ / haben?“: das Original druckt sie ohne
  -- Verzögerung, wartet aber an Fortsetzung und Absatz auf A (_ContText bzw. Paragraph → ManualTextScroll).  Der
  -- Port legt mit instant die letzte Seite fertig hin; die englischen Texte haben dort keine Fortsetzung → Texte mit
  -- Fortsetzung oder Absatz ohne Buchstabenverzögerung (noLetterDelay), aber mit ihren Wartestellen
  local function sofort_mit_halt_einhaengen()
    local TextBox = require("src.render.TextBox")
    local original = TextBox.new
    TextBox.new = function(game, text, onDone, opts, ...)
      if type(opts) == "table" and opts.instant and type(text) == "string" and text:find("[\v\f]") then
        local neu = {}
        for k, v in pairs(opts) do neu[k] = v end
        neu.instant, neu.noLetterDelay = nil, true
        opts = neu
      end
      return original(game, text, onDone, opts, ...)
    end
  end

  -- Fahrradladen: BikeShopClerkDoYouLikeItText „Das ist unser / bestes FAHRRAD! ▼ / Möchtest Du es ▼ / haben?“
  -- bleibt unter dem Kauffenster stehen, so wie das Textfenster nach dem Rollen aussieht (letzte zwei Zeilen).  Der
  -- Port legt eine Kopie der ganzen letzten Seite seiner Seitenteilung darunter (data/scripts/story2.lua
  -- BikeShopWindow.new), mit vier Zeilen die ersten beiden → die letzten zwei Zeilen setzen.  Der Cursor ▶ erscheint
  -- im Original erst mit HandleMenuInput nach dem Text; der Port zeichnet ihn immer → solange das Textfenster des
  -- Satzes oben liegt, ohne Cursor.
  local function fahrradladen_einhaengen()
    local TextBox = require("src.render.TextBox")
    local Font = require("src.render.Font")
    local Theme = require("src.ui.Theme")
    local gepatcht = setmetatable({}, { __mode = "k" })
    local function ohne_cursor(mt)
      if gepatcht[mt] or type(mt.draw) ~= "function" then return end
      gepatcht[mt] = true
      local draw = mt.draw
      mt.draw = function(self, ...)
        if not (self.dgmText and self.game.stack:top() == self.dgmText) then return draw(self, ...) end
        local dc = Font.drawCode
        return ersetzt({ { Font, "drawCode", function(code, ...)
          if code == Theme.cursor then return end
          return dc(code, ...)
        end } }, draw, self, ...)
      end
    end
    local original = TextBox.new
    TextBox.new = function(game, text, ...)
      local box = original(game, text, ...)
      local t = type(game) == "table" and game.data and game.data.text
      local fenster = t and text == t._BikeShopClerkDoYouLikeItText and game.stack and game.stack:top()
      if type(fenster) == "table" and type(fenster.footer) == "table" and fenster.onChoose then
        local seite = fenster.footer
        if #seite > 2 then fenster.footer = { seite[#seite - 1], seite[#seite] } end
        fenster.dgmText = box
        if getmetatable(fenster) then ohne_cursor(getmetatable(fenster)) end
      end
      return box
    end
  end

  -- Texte der Oberwelt (DisplayTextID: Personen, Schilder, Item-Bälle, Karten-Skripte): DisplayTextIDInit lädt erst
  -- die Schrift (LoadFontTilePatterns, CopyVideoDataDouble mit 8 Kacheln je Frame) und das Fenster
  -- (CopyScreenTileBufferToVRAM); erst dann beginnt der Text.  An der DE-ROM gemessen (p105_de_probe.py): leerer
  -- Kasten 19 Frames.  Folgetexte derselben Szene (text_asm, kein CloseTextDisplay dazwischen) laufen ohne diese Pause
  -- weiter.  Der Port tippt sofort; Texte, die von selbst schließen (Item-Ball nach der Melodie, „EICH: Warte! Geh
  -- nicht raus!“), sind dadurch früher weg → Texte, die die Oberwelt öffnet (während OverworldState.update), wenn
  -- seit mindestens 2 Frames kein Textfenster mehr lief, 19 Frames mit leerem Kasten beginnen
  local SCHRIFT_LADEN = 19
  local function oberwelttext_einhaengen()
    local ok, OW = pcall(require, "src.world.OverworldController")
    if not (ok and type(OW) == "table" and type(OW.update) == "function") then return end
    local TextBox = require("src.render.TextBox")
    local in_oberwelt, frame, zuletzt = 0, 0, -10
    local alt_update = OW.update
    OW.update = function(...)
      frame = frame + 1
      in_oberwelt = in_oberwelt + 1
      local okr, r = pcall(alt_update, ...)
      in_oberwelt = in_oberwelt - 1
      if not okr then error(r, 0) end
      return r
    end
    local alt_new = TextBox.new
    TextBox.new = function(...)
      local box = alt_new(...)
      if in_oberwelt > 0 and frame - zuletzt > 2 and type(box) == "table" then box.dgmVorlauf = SCHRIFT_LADEN end
      return box
    end
    local alt_tb, alt_draw = TextBox.update, TextBox.draw
    TextBox.update = function(self, ...)
      zuletzt = frame
      if (self.dgmVorlauf or 0) > 0 then
        self.dgmVorlauf = self.dgmVorlauf - 1
        return
      end
      return alt_tb(self, ...)
    end
    -- auch eine fertig hingelegte Seite (opts.instant) erscheint erst danach
    TextBox.draw = function(self, ...)
      if (self.dgmVorlauf or 0) <= 0 then return alt_draw(self, ...) end
      return ersetzt({ { self, "shown", {} } }, alt_draw, self, ...)
    end
  end

  -- Pokémon-Center: „OK. Wir benötigen / Deine POKéMON.“ endet ohne Tastendruck (done), das Fenster bleibt aber
  -- stehen, bis nach der Heilmaschine „Danke! …“ es ersetzt (pokecenter.asm: kein CloseTextDisplay dazwischen).  Der
  -- Port schließt es (TextBox auto) und zeigt die Maschine ohne Text → die fertige Textbox bis finishNurseHeal über
  -- der Oberwelt weiterzeichnen
  local function heiltext_einhaengen()
    local ok, OW = pcall(require, "src.world.OverworldController")
    if not (ok and type(OW) == "table" and type(OW.drawUI) == "function" and type(OW.finishNurseHeal) == "function")
    then return end
    local TextBox = require("src.render.TextBox")
    local alt_new = TextBox.new
    TextBox.new = function(game, text, onDone, opts, ...)
      local t = type(game) == "table" and game.data and game.data.text
      if not (t and text == t._NeedYourPokemonText and type(opts) == "table" and opts.auto and onDone) then
        return alt_new(game, text, onDone, opts, ...)
      end
      local box
      local weiter = onDone
      box = alt_new(game, text, function(...)
        if game.overworld then game.overworld.dgmStehtext = box end
        return weiter(...)
      end, opts, ...)
      return box
    end
    local alt_finish = OW.finishNurseHeal
    OW.finishNurseHeal = function(self, ...)
      self.dgmStehtext = nil
      return alt_finish(self, ...)
    end
    local alt_ui = OW.drawUI
    OW.drawUI = function(self, ...)
      local r = alt_ui(self, ...)
      if self.dgmStehtext and (self.healAnim or self.emote) then self.dgmStehtext:draw() end
      return r
    end
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
    if daten.stockwerke then aufzug_einhaengen(daten.stockwerke) end
    blitz_einhaengen(daten.text and daten.text._FlashLightsAreaText)
    automat_verloren_einhaengen(daten.text and daten.text._NotThisTimeText)
    automat_seiten_einhaengen(daten.text)
    listenfrage_einhaengen()
    fahrradladen_einhaengen()
    sofort_mit_halt_einhaengen()
    if daten.feldattacken then teammenue_einhaengen(daten.feldattacken) end
    flugkarte_einhaengen()
    kampftext_rollen_einhaengen()
    laden_einhaengen()
    oberwelttext_einhaengen()
    heiltext_einhaengen()
    statusfenster_einhaengen()
    randfuellung_einhaengen()
    ruhmeshalle_pc_einhaengen()
    pokedex_schrei_einhaengen()
    statusattacke_einhaengen()
    fangvorfuehrung_einhaengen()
    pikachu_halten_einhaengen()
    pikachu_vorn_einhaengen()
    pikachu_bild_einhaengen(daten.pikaschreie)
    fanclub_einhaengen()
    pikachu_laden_einhaengen()
    og_farben_einhaengen()
    -- Bilder mit deutscher Schrift (Mod-Cache, Assets.resolve; Feldpfade direkt an newImage umgebogen)
    bericht.bilder = G.bilder_einhaengen(bilder, schluessel, { Data.field })
    titel_einhaengen(bilder)
    surf_einhaengen(bilder, daten.surfergebnis)
  end

  -- ================================================================ Start

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
