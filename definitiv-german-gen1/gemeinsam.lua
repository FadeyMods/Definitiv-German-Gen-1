-- Definitiv German – gemeinsame Bausteine aller drei Mods (Gen 1, Gen 2, Gen 3).
-- Quelle: Test/mods/gemeinsam/gemeinsam.lua; jeder Mod bringt eine identische Kopie mit (Test/werkzeug/
-- mod_bauen.py), damit er allein lauffähig bleibt.
--
--   G.pruefsumme(s)                      "~" + FNV-1a 32 Bit + Länge (wie Test/werkzeug/pruefsumme.py)
--   G.katalog_einhaengen(data, tab, kx)  Data.strings um Prüfsummen-Nachschlag ergänzen (+ Bildschirm-Kontexte)
--   G.kontexte_einhaengen(dateien)       Funktionen der Quelldateien setzen G.kontext während ihres Laufs
--   G.literale_einhaengen(l)             Port-Literale ohne Strings() beim Zeichnen tauschen (je Quelldatei)
--   G.cache_lesen / G.cache_schreiben    Ergebnis der ROM-Extraktion im Mod-Cache
--   G.bilder_einhaengen(bilder, schl)    Bilder mit deutscher Schrift über Assets.resolve + Feldpfade ausliefern
return function(mod)
  local G = {}
  local bit = require("bit")
  local LuaWriter = require("src.import.LuaWriter")
  local Assets = require("src.render.Assets")
  local loadstring = loadstring or load

  function G.pruefsumme(s)
    local h = 2166136261
    for i = 1, #s do
      h = bit.bxor(h, s:byte(i)) % 4294967296
      -- h * 16777619 mod 2^32 ohne Genauigkeitsverlust: 16777619 = 2^24 + 403
      h = ((h % 256) * 16777216 + h * 403) % 4294967296
    end
    return ("~%08x%04x"):format(h, #s)
  end
  local pruefsumme = G.pruefsumme

  -- Katalog des Ports (Data.strings): nachgeschlagen wird über die Prüfsumme des englischen Schlüssels; Kontext
  -- (Quelldatei → Prüfsumme → Text) gilt, solange eine Funktion dieser Datei läuft.  Ein vorhandenes __index
  -- (Katalog eines anderen Mods) wird weitergereicht.
  function G.katalog_einhaengen(data, tab, kontexte)
    local cat = data.strings
    if type(cat) ~= "table" then
      cat = {}
      data.strings = cat
    end
    rawset(cat, "\0definitiv-german", "")  -- Strings.load nimmt den Katalog nur mit mindestens einem Eintrag
    local mt = getmetatable(cat) or {}
    local alt = mt.__index
    local summen = {}
    kontexte = kontexte or {}
    mt.__index = function(t, k)
      if type(k) == "string" then
        local chk = summen[k]
        if not chk then
          chk = pruefsumme(k)
          summen[k] = chk
        end
        local kt = G.kontext and kontexte[G.kontext]
        local w = (kt and kt[chk]) or tab[chk]
        if w then return w end
      end
      if type(alt) == "function" then return alt(t, k) end
      if type(alt) == "table" then return alt[k] end
      return nil
    end
    setmetatable(cat, mt)
  end

  -- Port-Modul laden, ohne dass der Loader das require dem Mod zuschreibt (wie G.rom_manifest): der Mod hängt sich
  -- nur an Funktionen, die Text zeichnen oder zusammensetzen (z. B. src.link.LinkState/Handshake), und braucht dafür
  -- kein Netz – die Prüfung „undeclared network require“ gilt Mods, die selbst an die Leitung gehen
  function G.port_modul(modul)
    local ok_rt, Runtime = pcall(require, "src.mods.Runtime")
    local vorher, vorher_r = ok_rt and Runtime.currentMod, ok_rt and Runtime.modRequire
    if ok_rt then Runtime.currentMod, Runtime.modRequire = nil, nil end
    local ok, M = pcall(require, modul)
    if ok_rt then Runtime.currentMod, Runtime.modRequire = vorher, vorher_r end
    return ok, M
  end

  function G.kontexte_einhaengen(dateien)
    for d in pairs(dateien) do
      local modul = d:gsub("%.lua$", ""):gsub("/", ".")
      local ok, M = G.port_modul(modul)
      if ok and type(M) == "table" then
        for name, f in pairs(M) do
          if type(f) == "function" then
            local function zurueck(alt, ...)
              G.kontext = alt
              return ...
            end
            M[name] = function(...)
              local alt = G.kontext
              G.kontext = d
              return zurueck(alt, f(...))
            end
          end
        end
      end
    end
  end

  -- l: Quelldatei → { ganz = {Prüfsumme → DE}, anfang = {{Länge, Prüfsumme, DE, frei}}, ende = {{Länge, Prüfsumme,
  -- DE}} }; Font.draw tauscht, solange eine Funktion dieser Datei läuft
  function G.literale_einhaengen(l)
    if type(l) ~= "table" or not next(l) then return end
    local function tauschen(t, e)
      if type(t) ~= "string" or type(e) ~= "table" then return t end
      local g = e.ganz[pruefsumme(t)]
      if g then return g end
      for _, a in ipairs(e.anfang or {}) do
        local n = a[1]
        if #t > n and pruefsumme(t:sub(1, n)) == a[2] and (a[4] or t:sub(n + 1, n + 1) == " ") then
          t = a[3] .. t:sub(n + 1)
          break
        end
      end
      for _, a in ipairs(e.ende or {}) do
        local n = a[1]
        if #t > n and pruefsumme(t:sub(-n)) == a[2] then
          t = t:sub(1, #t - n) .. a[3]
          break
        end
      end
      return t
    end
    G.tauschen = tauschen
    G.literale = l
    G.literal_encode_einhaengen()
  end

  -- Globale Literale (ohne Bildschirm-Kontext): Prüfsumme des englischen Literals → deutscher Text; für eindeutige
  -- Menüwörter, die der Port in Port-Skripten fest einträgt und die im Original aus der ROM kommen (Schultafel,
  -- Link-Anleitung).  G.literale_global wird von G.romliterale_lesen gefüllt.
  G.literale_global = {}
  -- Wörter, die der Port auch roh (ohne Strings()) zeichnet und die der Katalog übersetzt: Prüfsumme → true
  -- (OptionsMenu/gen2 OptionsMenu/game3 option_rows volLabel: „OFF“ bei Lautstärke 0)
  G.ROH = { ["~2e1505ea0003"] = true }
  local global_memo = setmetatable({}, { __mode = "k" })
  function G.literal_encode_einhaengen()
    if G._encode_haken then return end
    G._encode_haken = true
    local Font = require("src.render.Font")
    -- Am Kodierpunkt tauschen, nicht nur in Font.draw: Gen 2 zeichnet über Chrome.print/printThrough →
    -- Font.encode → Font.drawCode an Font.draw vorbei; Font.draw und Font.width nehmen eine ersetzte encode mit.
    local fe = Font.encode
    local S = require("src.core.Strings")
    Font.encode = function(text, ...)
      if type(text) == "string" then
        -- rohe Port-Wörter, die der Port an einer Stelle ohne Strings() zeichnet (Lautstärke 0 = volLabel „OFF“)
        if #text <= 8 and G.ROH[pruefsumme(text)] then text = S(text) end
        local e = G.kontext and G.literale and G.literale[G.kontext]
        if e then text = G.tauschen(text, e) end
        if next(G.literale_global) then
          local w = global_memo[text]
          if w == nil then
            w = G.literale_global[pruefsumme(text)] or false
            global_memo[text] = w
          end
          if w then text = w end
        end
      end
      return fe(text, ...)
    end
  end

  -- ROM-Literale (Rezept pl = { [Prüfsumme] = { Bank, Adresse, Zeile } }): die Zeile einer @-Zeichenkette der DE-ROM,
  -- Leerzeichen am Rand bleiben (Layout der Original-Spalte, z. B. „ SLF“)
  function G.romliterale_lesen(ex, rezept, charmap)
    local erg = {}
    for chk, ort in pairs(rezept.pl or {}) do
      erg[chk] = G.romtext(ex, charmap, ort[1], ort[2], 2, ort[3], 0, true)
    end
    return erg
  end

  function G.romliterale_einhaengen(t)
    local n = 0
    for chk, text in pairs(t or {}) do
      if type(text) == "string" and text ~= "" then
        G.literale_global[chk] = text
        n = n + 1
      end
    end
    if n > 0 then G.literal_encode_einhaengen() end
    return n
  end

  -- Link-Hinweis „Spiele passen nicht zusammen“ (src/link/Handshake.lua describe): der Port bricht seine englischen
  -- Sätze fest in Zeilen um (wrap, 19 Zeichen).  hs = { b = { { {Prüfsumme oder false}, {DE-Zeilen} }, … },
  -- z = {Prüfsumme → DE-Zeile}, a = { {Länge, Prüfsumme, DE} } (Anfang), e = { {Länge, Prüfsumme, DE} } (Ende) }.
  -- Blöcke: Folgen ganzer Zeilen; false = beliebige Zeile (Spielname), in der DE-Zeile als %1, vorher über z übersetzt.
  -- Tastenbelegung (src/ui/BindingsMenu.lua, Gen 3: src/ui/game3/controls_menu.lua): rechte Spalte „TASTE/PAD“ aus
  -- festen Kurznamen (KEY_SHORT/PAD_SHORT, SDL-Namen in Großbuchstaben).  tk = { t = {Prüfsumme → DE-Kürzel},
  -- v = {Prüfsumme eines Anfangs → DE-Anfang} }; übersetzt wird beim Zeichnen, weil der Port die Spalte nach jeder
  -- Änderung (auch aus Rückfragen heraus) neu setzt.
  function G.tasten_einhaengen(tk)
    if type(tk) ~= "table" or type(tk.t) ~= "table" then return end
    local ok, BM = G.port_modul("src.ui.BindingsMenu")
    if not ok or type(BM) ~= "table" or type(BM.new) ~= "function" then return end
    local fertig = {}
    local function teil(s)
      local w = tk.t[pruefsumme(s)]
      if w then return w end
      for chk, de in pairs(tk.v or {}) do
        local n = chk:match("^~%x%x%x%x%x%x%x%x(%x%x%x%x)$")
        n = n and tonumber(n, 16)
        if n and #s > n and pruefsumme(s:sub(1, n)) == chk then return (de .. s:sub(n + 1)):sub(1, 5) end
      end
      return s
    end
    local function wandeln(s)
      if type(s) ~= "string" then return s end
      local w = fertig[s]
      if w then return w end
      local teile = {}
      for p in (s .. "/"):gmatch("(.-)/") do teile[#teile + 1] = teil(p) end
      w = table.concat(teile, "/")
      fertig[s], fertig[w] = w, w
      return w
    end
    local function alle(menue)
      if type(menue) ~= "table" or type(menue.items) ~= "table" then return end
      for _, it in ipairs(menue.items) do
        if type(it) == "table" and it.right then it.right = wandeln(it.right) end
      end
    end
    local alt_draw = BM.draw
    if type(alt_draw) == "function" then
      BM.draw = function(self, ...) alle(self) return alt_draw(self, ...) end
    end
    local alt_new = BM.new
    BM.new = function(game, opts, ...)
      local self = alt_new(game, opts, ...)
      alle(self)
      if opts and opts.buttons == BM.GEN3_BUTTONS then
        local okc, C = G.port_modul("src.ui.game3.controls_menu")
        if okc and type(C) == "table" and type(C.draw) == "function" and not C.__dg_tasten then
          local alt_c = C.draw
          C.__dg_tasten = true
          C.draw = function(...) alle(C._bm) return alt_c(...) end
        end
      end
      return self
    end
  end

  -- Eingehängt wird ohne require eines Link-Moduls: das Sandbox-require schreibt jedes src.link.*-require dem Mod zu
  -- („undeclared network require“, die Rechte-Prüfung gilt Mods, die selbst ans Netz gehen).  Die Zeilen entstehen in
  -- LinkState:decideCompat (self.noticeLines = Handshake.describe(…)); LinkState wird über src.core.StateStack auf den
  -- Spielstapel gelegt (OverworldController, CodeEntry) → beim ersten solchen push die Klasse über getmetatable greifen
  -- und decideCompat umhüllen.
  function G.handshake_einhaengen(hs)
    if type(hs) ~= "table" or type(hs.b) ~= "table" then return end
    local ok, Stapel = G.port_modul("src.core.StateStack")
    if not ok or type(Stapel) ~= "table" or type(Stapel.push) ~= "function" or Stapel.__dg_hs then return end
    local function zeile(t)
      local w = hs.z and hs.z[pruefsumme(t)]
      if w then return w end
      for _, a in ipairs(hs.a or {}) do
        if #t >= a[1] and pruefsumme(t:sub(1, a[1])) == a[2] then t = a[3] .. t:sub(a[1] + 1) break end
      end
      for _, e in ipairs(hs.e or {}) do
        if #t >= e[1] and pruefsumme(t:sub(-e[1])) == e[2] then t = t:sub(1, #t - e[1]) .. e[3] break end
      end
      return t
    end
    local function uebersetzen(lines)
      if type(lines) ~= "table" then return lines end
      local chk = {}
      for i, t in ipairs(lines) do chk[i] = type(t) == "string" and pruefsumme(t) or "" end
      local out, i = {}, 1
      while i <= #lines do
        local treffer
        for _, b in ipairs(hs.b) do
          local en = b[1]
          local passt = i + #en - 1 <= #lines
          for j = 1, #en do
            if not passt then break end
            if en[j] ~= false and en[j] ~= chk[i + j - 1] then passt = false end
          end
          if passt then treffer = b; i = i + #en; break end
        end
        if treffer then
          local frei_de
          for j, en in ipairs(treffer[1]) do
            if en == false then frei_de = zeile(lines[i - #treffer[1] + j - 1]) end
          end
          for _, d in ipairs(treffer[2]) do
            out[#out + 1] = frei_de and (d:gsub("%%1", function() return frei_de end)) or d
          end
        else
          out[#out + 1] = type(lines[i]) == "string" and zeile(lines[i]) or lines[i]
          i = i + 1
        end
      end
      return out
    end
    local alt_push = Stapel.push
    Stapel.__dg_hs = true
    Stapel.push = function(self, state, ...)
      local K = type(state) == "table" and getmetatable(state)
      if type(K) == "table" and type(rawget(K, "decideCompat")) == "function" and not rawget(K, "__dg_hs") then
        local alt_dc = K.decideCompat
        K.__dg_hs = true
        K.decideCompat = function(link, ...)
          local erg = { alt_dc(link, ...) }
          if type(link) == "table" and type(link.noticeLines) == "table" then
            local ok_u, z = pcall(uebersetzen, link.noticeLines)
            if ok_u then link.noticeLines = z end
          end
          return (table.unpack or unpack)(erg)
        end
      end
      return alt_push(self, state, ...)
    end
  end

  -- Texttabellen der Online-Vorbereitungen (KONNEX-Kampf/-Tausch, Prüfmeldungen der Umwandlung): der Port füllt sie
  -- selbst mit {name}-Platzhaltern, ohne Strings().  tb = { { Modul, Pfad, { [Schlüssel] = { Prüfsumme, DE } } }, … };
  -- Pfad „TEXT“ = Feld des Moduls, „text>TEXT“ bzw. „Controller.reasonText>CODE_TEXT“ = Upvalue TEXT der Funktion
  -- text (lokale Tabelle).  Ersetzt wird nur, solange der englische Eintrag noch der Prüfsumme entspricht.
  function G.tabellen_einhaengen(tb)
    if type(tb) ~= "table" then return 0 end
    local n = 0
    for _, e in ipairs(tb) do
      local ok, M = G.port_modul(e[1])
      local tab
      if ok and type(M) == "table" then
        local feld, up = e[2]:match("^(.-)>(.+)$")
        if not feld then
          tab = M[e[2]]
        else
          -- lokale Tabelle: Mods haben keine debug-Bibliothek → nur vormerken; G.union_einhaengen hängt sich an die
          -- Funktionen, die sie lesen (Messages.text/about/change, Controller.reasonText/blockLines/page)
          G.tb_lokal = G.tb_lokal or {}
          G.tb_lokal[e[1] .. "|" .. up] = e[3]
        end
      end
      if type(tab) == "table" then
        for k, w in pairs(e[3]) do
          if type(tab[k]) == "string" and pruefsumme(tab[k]) == w[1] then
            tab[k] = w[2]
            n = n + 1
          end
        end
      end
    end
    return n
  end

  -- Online-Vorbereitungen: GB-Bildschirme setzen Fließtext und Beschriftungen mit string.upper() in Großbuchstaben, das
  -- ä/ö/ü nicht umsetzt → vorher selbst umsetzen; Editionsname „Pokémon <label>“ (englisch) → deutscher Name.
  -- ed = { [Prüfsumme des englischen Labels] = deutscher Name }, fb = { [Prüfsumme] = DE } für Rückfall-Wörter
  function G.union_einhaengen(ed, fb)
    local function gross(t)
      return (t:gsub("ä", "Ä"):gsub("ö", "Ö"):gsub("ü", "Ü"))
    end
    local function editionen(t)
      return (t:gsub("Pokémon (%a+)", function(w)
        local de = ed and ed[pruefsumme(w)]
        if de then return "Pokémon " .. de end
        return nil
      end))
    end
    local okm, Messages = G.port_modul("src.online.xgen.Messages")
    if okm and type(Messages) == "table" and type(Messages.format) == "function" then
      local alt = Messages.format
      Messages.format = function(text, gen, ...)
        if type(text) == "string" then
          text = editionen(text)
          if Messages.style and Messages.style(gen) == "gb" then text = gross(text) end
        end
        return alt(text, gen, ...)
      end
    end
    for _, quelle in ipairs({ { "src.ui.union.prep.OpenTrade", "Controller" }, { "src.online.union.BattlePrepModel" } }) do
      local ok, M = G.port_modul(quelle[1])
      local K = ok and type(M) == "table" and (quelle[2] and M[quelle[2]] or M)
      if type(K) == "table" and type(K.label) == "function" then
        local alt = K.label
        K.label = function(self, text, ...)
          if type(text) == "string" then
            local w = fb and fb[pruefsumme(text)]
            if w then text = w end
            text = editionen(text)
            if type(self) == "table" and type(self.style) == "function" and self:style() == "gb" then text = gross(text) end
          end
          return alt(self, text, ...)
        end
      end
    end
    -- KONNEX-Klub Gen 1/2 (src/ui/union/gen1/Text.lua, src/ui/gen2/union/Text.lua): gameName = englische
    -- Editionsbezeichnung in Großbuchstaben („Importiere WALLY aus POKéMON EMERALD“)
    -- nur das Modul der eigenen Generation laden (ein fremdes Modul gälte sonst als vom Spiel geladen)
    local eigen = ({ ["1"] = "src.ui.union.gen1.Text", ["2"] = "src.ui.gen2.union.Text" })[
      tostring(mod.id):match("gen(%d)") or ""]
    for _, modul in ipairs({ eigen }) do
      local ok, T = G.port_modul(modul)
      if ok and type(T) == "table" and type(T.gameName) == "function" then
        local okv, GV = G.port_modul("src.core.GameVersion")
        local alt = T.gameName
        T.gameName = function(version, ...)
          local info = okv and type(GV) == "table" and type(GV.VERSIONS) == "table" and GV.VERSIONS[version or ""]
          local de = info and type(info.label) == "string" and ed and ed[pruefsumme(info.label)]
          if de then return gross(de:upper()) end
          return alt(version, ...)
        end
      end
    end
    G.union_lokal_einhaengen(Messages)
  end

  -- KONNEX-Vorbereitungen zwischen den Spielen (src/online/xgen/Datasets.get): Namen von Pokémon, Attacken und Items
  -- liest der Port direkt aus den Import-Dateien (englisch, am Mod vorbei) → nur die angezeigten Namen (name) ersetzen;
  -- die Abgleich-Schlüssel (key, englisch normalisiert) bleiben, sonst fände der Tausch die Items der Gegenseite nicht.
  -- Eigene Edition: namen.art/attacke/item(eintrag) → deutscher Name; fremde Editionen: über Pokédex-Nr., Attacken-Nr.
  -- bzw. Item-Schlüssel auf die Namen der eigenen Edition (was die eigene DE-ROM nicht kennt, bleibt wie geliefert)
  function G.xgen_einhaengen(namen)
    local ok, D = G.port_modul("src.online.xgen.Datasets")
    if not ok or type(D) ~= "table" or type(D.get) ~= "function" or rawget(D, "__dg_namen") then return false end
    local okv, GV = G.port_modul("src.core.GameVersion")
    local alt = D.get
    local fertig = setmetatable({}, { __mode = "k" })
    local art, attacke, item = {}, {}, {}
    local function nimm(f, x)
      if type(f) ~= "function" then return nil end
      local okf, w = pcall(f, x)
      return okf and type(w) == "string" and w ~= "" and w or nil
    end
    local function eigene_version()
      local okg, v = pcall(function() return GV.get() end)
      return okv and okg and type(v) == "string" and v or nil
    end
    local function bearbeiten(d, eigen)
      for n, sp in pairs(type(d.species) == "table" and d.species or {}) do
        if type(sp) == "table" then
          local w
          if eigen then w = nimm(namen.art, sp); art[n] = w else w = art[n] end
          if w then sp.name = w end
        end
      end
      for id, mv in pairs(type(d.moves) == "table" and d.moves or {}) do
        if type(mv) == "table" then
          local w
          if eigen then w = nimm(namen.attacke, mv); attacke[id] = w else w = attacke[id] end
          if w then mv.name = w end
        end
      end
      local lokal = type(d.items) == "table" and type(d.items.byLocal) == "table" and d.items.byLocal or {}
      for _, it in pairs(lokal) do
        if type(it) == "table" then
          local w
          if eigen then
            w = nimm(namen.item, it)
            if w and type(it.key) == "string" then item[it.key] = w end
          else
            w = type(it.key) == "string" and item[it.key] or nil
          end
          if w then it.name = w end
        end
      end
    end
    D.__dg_namen = true
    D.get = function(version, ...)
      local d = alt(version, ...)
      if type(d) == "table" and not fertig[d] then
        fertig[d] = true
        local eigene = eigene_version()
        local okb, err = pcall(function()
          if eigene and d.version ~= eigene then D.get(eigene) end   -- eigene Edition zuerst (Namen nach Nummer)
          bearbeiten(d, eigene ~= nil and d.version == eigene)
        end)
        if not okb and mod.log then mod.log:warn("Definitiv German: KONNEX-Namen: %s", tostring(err)) end
      end
      return d
    end
    return true
  end

  -- Lokale Texttabellen der Online-Vorbereitungen (G.tb_lokal): an den lesenden Funktionen tauschen.
  -- Messages.text/about füllen ihre Vorlage selbst ({species}, {move} …): das Original einmal mit Markern aufrufen ergibt
  -- die englische Vorlage samt Platzhalter-Reihenfolge; daraus werden die Werte des echten Ergebnisses gelesen und in
  -- die deutsche Vorlage gesetzt (passt das Muster nicht, bleibt das Original).
  function G.union_lokal_einhaengen(Messages)
    local L = G.tb_lokal or {}
    local function de_tab(schluessel)
      local t = {}
      for k, w in pairs(L[schluessel] or {}) do t[k] = w[2] end
      return t
    end
    local TXT, CHG, FLD = de_tab("src.online.xgen.Messages|TEXT"), de_tab("src.online.xgen.Messages|CHANGE"),
      de_tab("src.online.xgen.Messages|FIELD")
    local CODE = de_tab("src.ui.union.prep.OpenTrade|CODE_TEXT")
    local CODE_CHK = {}
    for _, w in pairs(L["src.ui.union.prep.OpenTrade|CODE_TEXT"] or {}) do CODE_CHK[w[1]] = w[2] end
    local function marken_werte(alt, code, detail, names)
      local md = setmetatable({}, { __index = function(_, k) return "\1" .. k .. "\1" end })
      local mn = { species = function() return "\1species\1" end, move = function() return "\1move\1" end,
                   item = function() return "\1item\1" end }
      local okv, vorlage = pcall(alt, code, md, mn)
      local echt = alt(code, detail, names)
      if not okv or type(vorlage) ~= "string" then return nil, echt end
      local reihe, muster, pos = {}, "^", 1
      while true do
        local a, e, k = vorlage:find("\1(%w+)\1", pos)
        if not a then break end
        muster = muster .. vorlage:sub(pos, a - 1):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "(.-)"
        reihe[#reihe + 1] = k
        pos = e + 1
      end
      muster = muster .. vorlage:sub(pos):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "$"
      local caps = { echt:match(muster) }
      if #reihe > 0 and #caps ~= #reihe then return nil, echt end
      local werte = {}
      for i, k in ipairs(reihe) do werte[k] = caps[i] end
      return werte, echt
    end
    local function fuellen(de, werte)
      return (de:gsub("{(%w+)}", function(k) return werte[k] or "" end))
    end
    if type(Messages) == "table" and type(Messages.text) == "function" and next(TXT) then
      local alt_text = Messages.text
      Messages.text = function(code, detail, names, ...)
        local de = TXT[code]
        if not de then return alt_text(code, detail, names, ...) end
        local werte, echt = marken_werte(alt_text, code, detail, names)
        if not werte then return echt end
        return fuellen(de, werte)
      end
      if type(Messages.about) == "function" then
        local alt_about = Messages.about
        Messages.about = function(name, code, detail, names, ...)
          local de = TXT[code]
          if not de then return alt_about(name, code, detail, names, ...) end
          local werte = marken_werte(alt_text, code, detail, names)
          if not werte then return alt_about(name, code, detail, names, ...) end
          if not de:find("{species}", 1, true) then return tostring(name) .. ": " .. fuellen(de, werte) end
          werte.species = tostring(name)
          return fuellen(de, werte)
        end
      end
    end
    if type(Messages) == "table" and type(Messages.change) == "function" and next(CHG) then
      local alt_change = Messages.change
      Messages.change = function(row, gen, ...)
        if type(row) ~= "table" then return alt_change(row, gen, ...) end
        local vorlage = CHG[row.kind] or CHG.change
        local feld = FLD[row.field] or FLD[(tostring(row.field):match("^(%a+)"))]
        if not (vorlage and feld) then return alt_change(row, gen, ...) end
        return Messages.format(fuellen(vorlage, { field = feld }), gen)
      end
    end
    local okt, Open = G.port_modul("src.ui.union.prep.OpenTrade")
    local Ctl = okt and type(Open) == "table" and Open.Controller
    if type(Ctl) == "table" and next(CODE) then
      if type(Ctl.reasonText) == "function" then
        local alt = Ctl.reasonText
        Ctl.reasonText = function(self, code, ...)
          if code ~= nil and CODE[code] then return CODE[code] end
          return alt(self, code, ...)
        end
      end
      if type(Ctl.blockLines) == "function" then
        local alt = Ctl.blockLines
        Ctl.blockLines = function(self, report, ...)
          local lines = alt(self, report, ...)
          if type(lines) == "table" and type(report) == "table" then
            for i, b in ipairs(report.blocks or {}) do
              if type(b) == "table" and CODE[b.code] and lines[i] then lines[i] = "- " .. CODE[b.code] end
            end
          end
          return lines
        end
      end
      if type(Ctl.page) == "function" then
        local alt = Ctl.page
        Ctl.page = function(self, ...)
          local pg = alt(self, ...)
          if type(pg) == "table" then
            for _, it in ipairs(pg.items or {}) do
              if type(it) == "table" and type(it.detail) == "table" then
                for j, d in pairs(it.detail) do
                  if type(d) == "string" and CODE_CHK[pruefsumme(d)] then it.detail[j] = CODE_CHK[pruefsumme(d)] end
                end
              end
            end
          end
          return pg
        end
      end
    end
  end

  -- Ganze Textbox-Texte, die der Port als Literal übergibt (Klartext der Port-Skripte, show_text-Literale): steht
  -- der englische Text im Katalog (Port-Zusatz bzw. ROM-Stelle) und enthält er keine %-Angaben, zeigt die Textbox
  -- den deutschen Text.  ROM-Texte sind schon deutsch und treffen keine englische Prüfsumme.
  function G.textbox_einhaengen(katalog)
    local ok, TextBox = pcall(require, "src.render.TextBox")
    if not ok or type(TextBox) ~= "table" or type(TextBox.new) ~= "function" or G._textbox_haken then return end
    G._textbox_haken = true
    local alt = TextBox.new
    TextBox.new = function(game, text, ...)
      if type(text) == "string" and #text > 3 then
        local w = katalog[pruefsumme(text)]
        if type(w) == "string" and not w:find("%%") then text = w end
      end
      return alt(game, text, ...)
    end
  end

  -- ROM-Manifest des Ports für eine Edition (Symboltabelle, Konstanten, Zeichentabelle), als eigene Kopie.
  -- RomManifest.decode lädt intern src.link.Json nach; die Stolperfalle des Loaders schreibt jedes require während
  -- des Mod-Ladens dem Mod zu und meldet es auf Gen 2 als „undeclared network require“.  Es ist aber ein require
  -- des Port-Moduls selbst (so wie der Loader es bei verschachtelten requires auch wertet) – der Mod braucht kein
  -- Netz.  Deshalb läuft dieser eine Aufruf ohne Mod-Zuschreibung.
  function G.rom_manifest(edition)
    local RomManifest = require("src.import.RomManifest")
    local ok_rt, Runtime = pcall(require, "src.mods.Runtime")
    local vorher = ok_rt and Runtime.currentMod
    if ok_rt then Runtime.currentMod = nil end
    local ok, m = pcall(RomManifest.decode, edition)
    if ok_rt then Runtime.currentMod = vorher end
    if not ok then error(m, 0) end
    return G.kopie(m)
  end

  function G.datei(name)
    local quelle = mod:read(name)
    if not quelle then return nil, name .. " fehlt" end
    local chunk, err = loadstring(quelle, "@" .. name)
    if not chunk then return nil, err end
    local ok, wert = pcall(chunk)
    if not ok then return nil, wert end
    return wert
  end

  function G.kopie(t, gesehen)
    if type(t) ~= "table" then return t end
    gesehen = gesehen or {}
    if gesehen[t] then return gesehen[t] end
    local neu = {}
    gesehen[t] = neu
    for k, v in pairs(t) do neu[G.kopie(k, gesehen)] = G.kopie(v, gesehen) end
    return neu
  end

  function G.cache_lesen(schluessel)
    if not mod.cache:read(schluessel .. "/fertig") then return nil end
    local quelle = mod.cache:read(schluessel .. "/daten.lua")
    local chunk = quelle and loadstring(quelle, "@cache")
    if not chunk then return nil end
    local ok, inhalt = pcall(chunk)
    if not ok or type(inhalt) ~= "table" then return nil end
    local bilder = {}
    for rel in pairs(inhalt.bilder or {}) do
      local bytes = mod.cache:read(schluessel .. "/bilder/" .. rel)
      if not bytes then return nil end
      bilder[rel] = love.image.newImageData(love.filesystem.newFileData(bytes, rel))
    end
    return inhalt.daten, bilder
  end

  function G.cache_schreiben(schluessel, daten, bilder)
    local liste = {}
    for rel, bild in pairs(bilder) do
      liste[rel] = true
      mod.cache:write(schluessel .. "/bilder/" .. rel, bild:encode("png"):getString())
    end
    mod.cache:write(schluessel .. "/daten.lua", LuaWriter.encode({ daten = daten, bilder = liste }))
    mod.cache:write(schluessel .. "/fertig", "1")
    pcall(G.cache_alte_entfernen, schluessel)
  end

  -- Älteren Stand derselben ROM (anderer Mod-Stand) aus dem eigenen Cache entfernen, damit sich nach Updates nichts
  -- im Spielprofil ansammelt.  Die Sandbox listet keine Ordner auf: der zuletzt geschriebene Schlüssel steht in
  -- „<Edition>/<ROM>/letzter“, seine Dateien (daten.lua, fertig, Bilder laut daten.lua) werden über mod.cache gelöscht.
  function G.cache_alte_entfernen(schluessel)
    local eltern = schluessel:match("^(v%d+/[^/]+/[^/]+)/")
    if not eltern or type(mod.cache.delete) ~= "function" then return end
    local merk = eltern .. "/letzter"
    local alt = mod.cache:read(merk)
    if type(alt) == "string" and alt ~= "" and alt ~= schluessel and alt:sub(1, #eltern + 1) == eltern .. "/" then
      local quelle = mod.cache:read(alt .. "/daten.lua")
      local chunk = quelle and loadstring(quelle, "@cache")
      local ok, inhalt = false, nil
      if chunk then ok, inhalt = pcall(chunk) end
      if ok and type(inhalt) == "table" then
        for rel in pairs(inhalt.bilder or {}) do mod.cache:delete(alt .. "/bilder/" .. rel) end
      end
      mod.cache:delete(alt .. "/fertig")
      mod.cache:delete(alt .. "/daten.lua")
    end
    mod.cache:write(merk, schluessel)
  end

  -- Nur Bilder behalten, die sich vom englischen Import unterscheiden (Schrift, Schilder, Titel …)
  function G.anders_als_en(rel, bild)
    local ok, en = pcall(love.image.newImageData, "assets/generated/" .. rel)
    if not ok or not en then return true end
    if en:getWidth() ~= bild:getWidth() or en:getHeight() ~= bild:getHeight() then return true end
    return en:getString() ~= bild:getString()
  end

  -- Bilder mit deutscher Schrift: PNG im Mod-Cache; Assets.resolve liefert für diese Bilder den Cache-Pfad (erreicht
  -- jeden Ladeweg), Overrides anderer Mods behalten Vorrang.  Feldpfade, die der Port direkt an newImage gibt,
  -- werden in den Datentabellen umgebogen.  Rückgabe: Anzahl.
  function G.bilder_einhaengen(bilder, schluessel, tabellen)
    local n, pfade = 0, {}
    for rel in pairs(bilder) do
      local p = "mod_cache/" .. mod.id .. "/" .. schluessel .. "/bilder/" .. rel
      if Assets.exists(p) then
        pfade["assets/generated/" .. rel] = p
        n = n + 1
      else
        local b = bilder[rel]
        Assets.compose("assets/generated/" .. rel, function() return b end)
      end
    end
    local vorher = Assets.resolve
    Assets.resolve = function(pfad)
      local r = vorher(pfad)
      if r == pfad and pfade[pfad] then return pfade[pfad] end
      return r
    end
    Assets.invalidate()
    local gesehen = {}
    local function umbiegen(t, tiefe)
      if type(t) ~= "table" or gesehen[t] or tiefe > 6 then return end
      gesehen[t] = true
      for k, v in pairs(t) do
        if type(v) == "string" and pfade[v] then
          t[k] = pfade[v]
        elseif type(v) == "table" then
          umbiegen(v, tiefe + 1)
        end
      end
    end
    for _, t in ipairs(tabellen or {}) do umbiegen(t, 0) end
    return n, pfade
  end

  -- ---------------------------------------------------------------- Port-Texte aus der ROM
  -- @-Zeichenkette der DE-ROM lesen (Zeilen getrennt an $4E/$4F); art 1 ganz, 2 eine Zeile, 3 ein Wort einer Zeile,
  -- 5 Zeile ohne „ :“, 6 Wert in Klammer-Kacheln
  function G.romtext(ex, charmap, bank, adresse, art, zeile_nr, wort_nr, mit_token)
    if art == 8 then
      -- Kacheltext-Liste mit $FF als Trenner (Gen 2 Pokédex „GES“/„BES“): Eintrag zeile_nr
      local adr, nr, out = adresse, 0, {}
      for _ = 1, 200 do
        local x = ex.rom:byte(bank, adr)
        adr = adr + 1
        if x == 0xFF or x == 0x50 then
          if nr == zeile_nr then break end
          nr, out = nr + 1, {}
        else
          out[#out + 1] = charmap[tostring(x)] or ""
        end
      end
      local text = table.concat(out)
      if nr == zeile_nr and text ~= "" then return text end
      return nil
    end
    if art == 9 then
      -- Kacheltext bis zur Kopf-Kachel $3C (Pokédex-Fensterköpfe), Leerzeichen gehören dazu
      local out = {}
      for i = 0, 40 do
        local x = ex.rom:byte(bank, adresse + i)
        if x == 0x3C or x == 0x50 or x == 0xFF then break end
        out[#out + 1] = charmap[tostring(x)] or ""
      end
      local text = table.concat(out)
      if text ~= "" then return text end
      return nil
    end
    if art == 7 then
      -- Textbefehlsstrom: $00, Zeichen, Zeilen-/Absatzbefehle, Ende an $57/$58/$50
      if ex.rom:byte(bank, adresse) ~= 0x00 then return nil end
      local out = {}
      local STEUER = { [0x4E] = "\n", [0x4F] = "\n", [0x51] = "\f", [0x55] = "\v", [0x52] = "{PLAYER}",
        [0x53] = "{RIVAL}", [0x54] = "POKé", [0x4A] = "<PK><MN>" }
      for i = 1, 400 do
        local x = ex.rom:byte(bank, adresse + i)
        if x == 0x57 or x == 0x58 or x == 0x50 then break end
        out[#out + 1] = STEUER[x] or charmap[tostring(x)] or ""
      end
      local text = table.concat(out)
      if text ~= "" then return text end
      return nil
    end
    local zeilen, zeile = {}, {}
    local adr = adresse
    for _ = 1, 400 do
      local x = ex.rom:byte(bank, adr)
      adr = adr + 1
      if x == 0x50 then break end
      if x == 0x4E or x == 0x4F or (x == 0x22 and charmap["34"] == "<LF>") then
        zeilen[#zeilen + 1] = table.concat(zeile)
        zeile = {}
      elseif x == 0x54 then
        zeile[#zeile + 1] = "POKé"
      elseif x == 0x4A then
        zeile[#zeile + 1] = "<PK><MN>"
      elseif mit_token and x == 0x52 then
        zeile[#zeile + 1] = "{PLAYER}"
      elseif mit_token and x == 0x53 then
        zeile[#zeile + 1] = "{RIVAL}"
      else
        zeile[#zeile + 1] = charmap[tostring(x)] or ""
      end
    end
    zeilen[#zeilen + 1] = table.concat(zeile)
    for i = #zeilen, 2, -1 do
      if zeilen[i]:match("^%s*$") then table.remove(zeilen, i) else break end
    end
    -- Leerzeichen am Rand sind Layout der ROM-Box (der Port setzt selbst); in Zusammensetzungen gehören sie zum
    -- Text („YOUR @“ + „NAME?@“) und bleiben
    if not mit_token then
      for i = 1, #zeilen do zeilen[i] = zeilen[i]:gsub("%s+$", ""):gsub("^%s+", "") end
    end
    local text
    if art == 1 then
      text = table.concat(zeilen, "\n")
    elseif art == 2 then
      text = zeilen[zeile_nr + 1]
    elseif art == 6 then
      text = table.concat(zeilen, "\n"):gsub("^%[%s*", ""):gsub("%s*%]$", "")
    elseif art == 5 then
      text = zeilen[zeile_nr + 1] and zeilen[zeile_nr + 1]:gsub("%s*:$", "")
    else
      local woerter = {}
      for w in (zeilen[zeile_nr + 1] or ""):gmatch("%S+") do woerter[#woerter + 1] = w end
      text = woerter[wort_nr + 1]
    end
    if text and text ~= "" then return text end
    -- Zeilen-Quelle mit vorhandener, aber leerer Zeile: die DE-ROM zeigt dort nichts (Trainerpass Gold/Silber
    -- 09:5253 „<leer>/<leer>/GELD“ statt „NAME/“) – leer übernehmen statt auf Englisch zurückzufallen
    if text == "" and (art == 2 or art == 5) and #zeilen > 1 then
      return text
    end
    return nil
  end

  function G.ohne_ende(t)
    local alt
    repeat
      alt = t
      t = t:gsub("{PROMPT}$", ""):gsub("{DONE}$", "")
    until t == alt
    return t
  end
  local ohne_ende = G.ohne_ende

  -- Seite nr eines Textes; nr = { a, b } liefert die Seiten a bis b (mit \f verbunden)
  local function seite(t, nr)
    if type(nr) == "table" and nr[1] == "v" then
      -- Abschnitte nr[2]..nr[3], getrennt an \v oder \f, mit Zeilenwechsel verbunden
      local teile = {}
      for s in (t:gsub("\f", "\v") .. "\v"):gmatch("(.-)\v") do teile[#teile + 1] = s end
      local bis = nr[3] < 0 and #teile - 1 or nr[3]  -- -1: bis zum Ende
      if bis + 1 > #teile or nr[2] > bis then return nil end
      return table.concat(teile, "\n", nr[2] + 1, bis + 1)
    end
    local seiten = {}
    for s in (t .. "\f"):gmatch("(.-)\f") do seiten[#seiten + 1] = s end
    if type(nr) == "table" then
      if nr[2] + 1 > #seiten then return nil end
      return table.concat(seiten, "\f", nr[1] + 1, nr[2] + 1)
    end
    return seiten[nr + 1]
  end

  local function woertlich(t, alt, neu)
    local i, j = t:find(alt, 1, true)
    while i do
      t = t:sub(1, i - 1) .. neu .. t:sub(j + 1)
      i, j = t:find(alt, i + #neu, true)
    end
    return t
  end

  -- Zusammengesetzter Port-Text ("k"): deutsche Stücke aus der ROM (Dialog-Label, Label-Seite, ROM-Zeichenkette),
  -- Argumente des Port-Literals (%s/%d) an den Stellen der deutschen Platzhalter-Token, nummeriert wie im Englischen
  -- (Rezept: je Teil Token → Argumentnummern).  Ergebnis: Formatzeichenkette mit %n$-Angaben für Strings.render.
  -- daten.text = Dialogtexte nach Label (Gen 1 text, Gen 2 rom_text).
  function G.zusammensetzen(spec, daten, ex, charmap)
    local teile, specs = spec[2], spec[3]
    local aus, benutzt = {}, false
    local function angabe(n)
      benutzt = true
      return "%" .. n .. "$" .. specs[n]:sub(2)
    end
    local function platzhalter(text, zuord)
      text = text:gsub("%%", "%%%%")
      local zaehler = {}
      return (text:gsub("{[^}]*}", function(tok)
        local nr = zuord and zuord[tok]
        if not nr then return nil end
        local i = (zaehler[tok] or 0) + 1
        zaehler[tok] = i
        return angabe(nr[math.min(i, #nr)])
      end))
    end
    for _, t in ipairs(teile) do
      if t[1] == "t" then
        local text = daten.text and daten.text[t[2]]
        if not text then return nil end
        text = ohne_ende(text)
        if type(t[3]) == "table" or t[3] >= 0 then
          text = seite(text, t[3])
          if not text then return nil end
          text = ohne_ende(text)
        end
        for tok, q in pairs(t[4] or {}) do
          if q[1] == "" then
            -- Platzhalter weglassen (der Port setzt den Wert selbst davor) bzw. wörtlich ersetzen („{PLAYER}“, das
            -- der Port beim Anzeigen füllt; fester Statusname)
            text = woertlich(text, tok, q[2] or "")
          else
            local tab = daten[q[1]]
            local e = tab and tab[q[2]]
            if not (e and e.name) then return nil end
            text = woertlich(text, tok, e.name)
          end
        end
        aus[#aus + 1] = platzhalter(text, t[5])
      elseif t[1] == "a" then
        aus[#aus + 1] = angabe(t[2])
      elseif t[1] == "l" then
        aus[#aus + 1] = (t[2]:gsub("%%", "%%%%"))
      elseif t[1] == "p" then
        -- feste Spalte der ROM: bis Zeichen t[2] auffüllen (Zeichen zählen, „%%“ ist eins)
        local bisher = table.concat(aus):gsub("%%%%", "%%"):gsub("[\128-\191]", "")
        if #bisher < t[2] then aus[#aus + 1] = (" "):rep(t[2] - #bisher) end
      elseif t[1] == "r" then
        local x = G.romtext(ex, charmap, t[2], t[3], t[4], t[5], t[6], true)
        if not x then return nil end
        aus[#aus + 1] = platzhalter(x, t[7])
      elseif t[1] == "n" then
        local tab = daten[t[2]]
        local e = tab and tab[t[3]]
        if not (e and e.name) then return nil end
        aus[#aus + 1] = (e.name:gsub("%%", "%%%%"))
      end
    end
    local s = table.concat(aus)
    -- ein Text ohne jede Angabe würde als „falsche Anzahl“ verworfen: Argument 1 unsichtbar einbinden
    if #specs > 0 and not benutzt then s = "%1$.0s" .. s end
    return s
  end

  -- Port-Texte, die im Original aus der ROM kommen: Rezept p (Prüfsumme des englischen Katalog-Schlüssels → Quelle)
  -- und pk (Quelldatei → Prüfsumme → Quelle).  "t" verweist auf ein Dialog-Label (aufgelöst beim Einhängen).
  function G.porttexte_lesen(ex, rezept, charmap, daten)
    local p = {}
    for chk, spec in pairs(rezept.p or {}) do
      if spec[1] == "t" then
        p[chk] = { t = spec[2], rand = spec[3] }
      elseif spec[1] == "k" then
        p[chk] = G.zusammensetzen(spec, daten, ex, charmap)
      else
        p[chk] = G.romtext(ex, charmap, spec[2], spec[3], spec[4], spec[5], spec[6])
      end
    end
    local pk = {}
    for datei, eintraege in pairs(rezept.pk or {}) do
      local t = {}
      for chk, spec in pairs(eintraege) do
        if spec[1] == "t" then
          local x = daten.text and daten.text[spec[2]]
          t[chk] = x and G.ohne_ende(x) or nil
        else
          t[chk] = G.romtext(ex, charmap, spec[2], spec[3], spec[4], spec[5], spec[6])
        end
      end
      pk[datei] = t
    end
    return p, pk
  end

  -- Deutsche Texte mit einem Wert, den der Port nicht mitgibt (z. B. die Menge in „{NUM} x {STRBUF}
  -- weggeworfen“): Rezept mg = { [Prüfsumme Zieltext] = { Prüfsumme Quelltext, Argument im Quelltext } }.  Der Wert
  -- wird beim Quelltext (der Wegwerf-Rückfrage mit Mengenangabe) gemerkt und dem Zieltext als zusätzliches Argument
  -- (Nummer = Zahl seiner Angaben + 1) mitgegeben; formatiert wird hier, weil Strings.render nur die Argumente
  -- des englischen Textes zulässt.
  function G.mengen_einhaengen(mg)
    if type(mg) ~= "table" or not next(mg) then return end
    local Strings = require("src.core.Strings")
    local quellen = {}
    for _, q in pairs(mg) do quellen[q[1]] = q[2] end
    local gemerkt = {}
    local summen = {}
    local function chk(s)
      local c = summen[s]
      if not c then
        c = pruefsumme(s)
        summen[s] = c
      end
      return c
    end
    local get = Strings.get
    Strings.get = function(source, ...)
      if type(source) == "string" then
        local c = chk(source)
        local nr = quellen[c]
        if nr and select("#", ...) >= nr then gemerkt[c] = (select(nr, ...)) end
        local ziel = mg[c]
        if ziel and gemerkt[ziel[1]] ~= nil and G.katalog and type(G.katalog[c]) == "string" then
          local args = { ... }
          local n = select("#", ...)
          args[n + 1] = gemerkt[ziel[1]]
          local ok, out = pcall(function()
            local t = G.katalog[c]:gsub("%%(%d+)%$([-+ #0]*%d*%.?%d*%a)", function(i, spec)
              return (("%" .. spec):format(args[tonumber(i)]):gsub("%%", "%%%%"))
            end)
            return (t:gsub("%%%%", "%%"))
          end)
          if ok then return out end
        end
      end
      return get(source, ...)
    end
  end

  -- Katalog bauen (ROM-Texte vor Port-Zusätzen aus zusatz.lua) und beim Laden der Mods einhängen.
  -- texte = Dialogtexte nach Label (für "t"-Einträge).  Rückgabe: Anzahl der Katalogeinträge.
  function G.porttexte_einhaengen(porttexte, portkontexte, texte)
    local katalog, quelle_k, quelle_x = {}, {}, {}
    for chk, v in pairs(porttexte or {}) do
      if type(v) == "table" then
        local t = texte and texte[v.t]
        if t then
          t = ohne_ende(t)
          if v.rand then t = t:gsub("^\n+", ""):gsub("\n+$", "") end
          katalog[chk] = t
          quelle_k[chk] = "rom"
        end
      else
        katalog[chk] = v
        quelle_k[chk] = "rom"
      end
    end
    local zusatz = G.datei("zusatz.lua")
    local zk, zl = {}, {}
    if type(zusatz) == "table" then
      for chk, text in pairs(zusatz.t or {}) do
        if katalog[chk] == nil then katalog[chk] = text; quelle_k[chk] = "zusatz" end
      end
      zk, zl = zusatz.k or {}, zusatz.l or {}
    end
    local kontexte = {}
    for datei, t in pairs(portkontexte or {}) do
      kontexte[datei] = t
      quelle_x[datei] = {}
      for chk in pairs(t) do quelle_x[datei][chk] = "rom" end
    end
    for datei, t in pairs(zk) do
      kontexte[datei] = kontexte[datei] or {}
      quelle_x[datei] = quelle_x[datei] or {}
      for chk, text in pairs(t) do
        if kontexte[datei][chk] == nil then kontexte[datei][chk] = text; quelle_x[datei][chk] = "zusatz" end
      end
    end
    -- Dateien mit Port-Literalen brauchen ebenfalls den Bildschirm-Kontext
    for datei in pairs(zl) do kontexte[datei] = kontexte[datei] or {} end
    mod.events:on("mods.loaded", function(ev)
      G.katalog_einhaengen((ev and ev.data) or require("src.core.Data"), katalog, kontexte)
      G.kontexte_einhaengen(kontexte)
      if type(zusatz) == "table" then
        G.handshake_einhaengen(zusatz.hs)
        G.tabellen_einhaengen(zusatz.tb)
        G.union_einhaengen(zusatz.ued, zusatz.ufb)
        G.tasten_einhaengen(zusatz.tk)
      end
      -- KONNEX-Namen (Datasets): die deutschen Tabellen des Spiels (Pokémon/Attacken/Items nach Port-Schlüssel)
      local data = (ev and ev.data) or require("src.core.Data")
      local function aus(tab, schl)
        local t = type(data) == "table" and data[tab]
        local e = type(t) == "table" and t[schl]
        return type(e) == "table" and e.name or nil
      end
      G.xgen_einhaengen({ art = function(sp) return aus("pokemon", sp.localKey) end,
        attacke = function(mv) return aus("moves", mv.localKey) end,
        item = function(it) return aus("items", it.localKey) end })
    end)
    G.literale_einhaengen(zl)
    G.katalog = katalog
    G.katalog_quelle = quelle_k
    G.kontexte = kontexte
    G.textbox_einhaengen(katalog)
    -- Schnittstelle für andere Mods und die Prüfwerkzeuge (optional, niemand hängt davon ab):
    --   find("definitiv-german-genN").exports.deutsch == true
    --   exports.text(englisch, quelldatei) → deutscher Text, wie er in dieser Quelldatei erscheint, und seine
    --   Herkunft ("rom" | "zusatz"), oder nil
    if type(mod.exports) == "table" then
      mod.exports.api = 1
      mod.exports.deutsch = true
      mod.exports.text = function(en, datei)
        if type(en) ~= "string" then return nil end
        local chk = pruefsumme(en)
        local kt = datei and kontexte[datei]
        if kt and kt[chk] ~= nil then return kt[chk], quelle_x[datei] and quelle_x[datei][chk] or "rom" end
        if katalog[chk] ~= nil then return katalog[chk], quelle_k[chk] or "rom" end
        local e = datei and zl[datei]
        if e then
          local t = G.tauschen and G.tauschen(en, e)
          if t and t ~= en then return t, "zusatz" end
        end
        return nil
      end
    end
    local n = 0
    for _ in pairs(katalog) do n = n + 1 end
    return n
  end

  return G
end
