-- Bilder mit Schrift aus der DE-ROM: Grafiken, die in der DE-Fassung anders aussehen (Assets.compose),
-- deutsche Schriftseite, Pokedex-Einheiten, Titelbild (Schriftzug, Logozeile, Copyright), Surf-Titel (Gelb).
return function(W)
  local mod, R, rom, apply, log, ver = W.mod, W.R, W.rom, W.apply, W.log, W.ver
  local Assets = require("src.render.Assets")
  local byte, floor = string.byte, math.floor
  -- ------------------------------------------------------------ Grafik
  local SH = { 1, 170 / 255, 85 / 255, 0 }
  local function bit(v, b) return floor(v / 2 ^ b) % 2 end

  -- Kachelbild wie ImageWriter.decode1bpp/decode2bpp der Engine (fehlende Bytes = 0)
  local function decodeTiles(off, len, w, h, bpp, transparent)
    local img = love.image.newImageData(w, h)
    local per, tsize = w / 8, (bpp == 1) and 8 or 16
    local function rb(i) if i < len then return byte(rom, off + i + 1) end return 0 end
    for t = 0, (w / 8) * (h / 8) - 1 do
      local tx, ty = (t % per) * 8, floor(t / per) * 8
      for y = 0, 7 do
        if bpp == 1 then
          local row = rb(t * 8 + y)
          for x = 0, 7 do
            local f = bit(row, 7 - x)
            local v = (f == 1) and 0 or 1
            img:setPixel(tx + x, ty + y, v, v, v, (transparent and f == 0) and 0 or 1)
          end
        else
          local lo, hi = rb(t * 16 + y * 2), rb(t * 16 + y * 2 + 1)
          for x = 0, 7 do
            local s = bit(hi, 7 - x) * 2 + bit(lo, 7 - x)
            local v = SH[s + 1]
            img:setPixel(tx + x, ty + y, v, v, v, (transparent and s == 0) and 0 or 1)
          end
        end
      end
    end
    return img
  end

  -- einzelne Bildschirmkachel (Titelbild) deckend an (x, y) setzen; 1bpp = verdoppelt geladen
  local function putCell(img, x0, y0, off, bpp)
    for y = 0, 7 do
      local lo, hi
      if bpp == 1 then
        lo = byte(rom, off + y + 1); hi = lo
      else
        lo, hi = byte(rom, off + y * 2 + 1), byte(rom, off + y * 2 + 2)
      end
      for x = 0, 7 do
        local s = bit(hi, 7 - x) * 2 + bit(lo, 7 - x)
        local v = SH[s + 1]
        img:setPixel(x0 + x, y0 + y, v, v, v, 1)
      end
    end
  end

  local function cellImage(cells, w, h, base)
    local img = base
    if not img then
      img = love.image.newImageData(w, h)
      img:mapPixel(function() return 1, 1, 1, 1 end)
    end
    for _, c in ipairs(cells) do putCell(img, c[1], c[2], c[3], c[4]) end
    return img
  end

  -- zur Laufzeit gebaute Bilder; beim Editionswechsel werden alte Eintraege entfernt
  Assets._deutschGen1 = Assets._deutschGen1 or {}
  for path in pairs(Assets._deutschGen1) do Assets.compose(path, nil) end
  Assets._deutschGen1 = {}
  local function compose(path, build)
    local cached
    Assets.compose(path, function()
      cached = cached or build()
      return cached
    end)
    Assets._deutschGen1[path] = true
  end


  -- Grafiken, die in der DE-Fassung anders aussehen
  apply("grafik", R.gfx, function(_, g)
    compose(g.path, function() return decodeTiles(g.off, g.len, g.w, g.h, g.bpp, g.transparent) end)
  end)
  -- Gelb: Surf-Titelbild ("Pikachus Strand" / "Surfe mit dem Steuerkreuz!")
  if R.surfTitle then
    compose("assets/generated/minigame/title_bg.png", function() return cellImage(R.surfTitle, 160, 144) end)
  end

  -- Einige Bildschirme laden ihre Bilder direkt mit love.graphics.newImage(pfad) statt ueber Assets
  -- (Spielautomat, Surf-Minigame, Titel).  Fuer genau die Pfade, die dieser Mod aus der ROM baut,
  -- liefert der Haken das deutsche Bild; alles andere geht unveraendert durch.
  pcall(function()
    local LG = love.graphics
    LG._deutschNewImage = LG._deutschNewImage or LG.newImage
    LG.newImage = function(src, ...)
      if type(src) == "string" then
        local rel = src:match("(assets/generated/.+)$")
        local mine = Assets._deutschGen1
        if rel and mine and mine[rel] then
          local ok, d = pcall(Assets.imageData, rel)
          if ok and d then return LG._deutschNewImage(d, ...) end
        end
      end
      return LG._deutschNewImage(src, ...)
    end
  end)

  -- Schrift: deutsche Zeichen (Umlaute, ß, Ligaturen) als eigene Seite
  if R.font then
    local path = "definitiv-german-gen1/schrift_" .. ver .. ".png"
    compose(path, function() return decodeTiles(R.font.off, 128 * 8, 128, 64, 1, true) end)
    local page = { image = path, base = 0x100, glyphsPerRow = 16, charmap = {} }
    for seq, code in pairs(R.font.chars) do page.charmap[#page.charmap + 1] = { seq = seq, code = code } end
    local ok, e = pcall(function() mod.content.font:register("deutsch", page) end)
    if not ok then log:warn("Deutsch Gen 1: Schrift: %s", tostring(e)) end
  end

  -- Pokedex-Einheiten m / k / g (DE-Kacheln $60-$62)
  if R.dexUnits then
    local path = "definitiv-german-gen1/dex_einheiten_" .. ver .. ".png"
    compose(path, function()
      local src = decodeTiles(R.dexUnits.off, 48, 24, 8, 2, false)
      src:mapPixel(function(_, _, r)
        if r < 0.5 then return 0, 0, 0, 1 end
        return 1, 1, 1, 0
      end)
      return src
    end)
    local page = { image = path, base = 0x200, glyphsPerRow = 3, charmap = {} }
    for seq, code in pairs(R.dexUnits.chars) do page.charmap[#page.charmap + 1] = { seq = seq, code = code } end
    pcall(function() mod.content.font:register("deutsch_dex", page) end)
  end

  -- Titelbild: DE-Schriftzug (Rot/Blau), DE-Logozeile (Gelb), DE-Copyright-Zeile
  if R.title then
    local TS = require("src.ui.TitleState")
    TS._deutschNew = TS._deutschNew or TS.new
    TS._deutschCopy = TS._deutschCopy or TS.drawCopyright
    local copyImg
    TS.new = function(game, opts, ...)
      local self = TS._deutschNew(game, opts, ...)
      if self then
        pcall(function()
          if R.title.ribbon then
            self.version = love.graphics.newImage(cellImage(R.title.ribbon, 80, 8))
            self.versionFull = true
          end
          if R.title.logo and self.logo then
            local lp = self.title and self.title.logo
            lp = type(lp) == "table" and lp.path or lp or "assets/logo/pokemon_logo.png"
            local base = love.image.newImageData(Assets.resolve(lp))
            self.logo = love.graphics.newImage(cellImage(R.title.logo, 0, 0, base))
          end
          -- Gelb: die Sprechblase (bei 48,32) ueberdeckt einen Teil der Logo-Zeile -> dieselben DE-Kacheln
          if R.title.logo and self.yellowBubble then
            local bp = self.title and self.title.pikaBubble
            bp = type(bp) == "table" and bp.path or bp or "assets/generated/title/pika_bubble.png"
            local base = love.image.newImageData(Assets.resolve(bp))
            local bw, bh = base:getDimensions()
            local cells = {}
            for _, c in ipairs(R.title.logo) do
              local x, y = c[1] + 16 - 48, c[2] + 8 - 32       -- Logo (16,8) -> Blase (48,32)
              if x >= 0 and y >= 0 and x + 8 <= bw and y + 8 <= bh then
                cells[#cells + 1] = { x, y, c[3], c[4] }
              end
            end
            if #cells > 0 then
              self.yellowBubble = love.graphics.newImage(cellImage(cells, 0, 0, base))
            end
          end
        end)
      end
      return self
    end
    TS.drawCopyright = function(self, y)
      if R.title.copyrightLine then
        if not copyImg then
          local ok, img = pcall(function()
            return love.graphics.newImage(cellImage(R.title.copyrightLine, 160, 8))
          end)
          copyImg = ok and img or false
        end
        if copyImg then
          love.graphics.draw(copyImg, 0, y)
          return
        end
      end
      return TS._deutschCopy(self, y)
    end

    -- Copyright-Karte beim Einschalten: die Engine setzt "(c)'95.'96.'98" aus Kachelnummern der
    -- EN-Reihenfolge zusammen; die DE-ROM schreibt "(c)1995-1999" -> dieselben 7 Kacheln wie in
    -- der DE-Titelzeile (dort ab x=16) zeichnen
    -- (gleiche Folge auf der Copyright-Seite am Ende des Abspanns: Credits.drawCopyPrefix)
    if R.title.copyrightLine then
      local prefImg, prefQuad
      local function prefix(x, y)
        if prefImg == nil then
          local ok, img = pcall(function()
            return love.graphics.newImage(cellImage(R.title.copyrightLine, 160, 8))
          end)
          prefImg = ok and img or false
          if prefImg then prefQuad = love.graphics.newQuad(16, 0, 56, 8, prefImg:getDimensions()) end
        end
        if prefImg then love.graphics.draw(prefImg, prefQuad, x, y) return true end
      end
      for _, modul in ipairs({ "src.ui.IntroMovie", "src.ui.Credits" }) do
        pcall(function()
          local M = require(modul)
          M._deutschPrefix = M._deutschPrefix or M.drawCopyPrefix
          M.drawCopyPrefix = function(self, x, y)
            if prefix(x, y) then return end
            return M._deutschPrefix(self, x, y)
          end
        end)
      end
    end
  end


  -- Pokedex: Dezimalpunkt wie in der DE-ROM
  if R.dexDot then
    pcall(function()
      local DM = require("src.ui.DexEntryMenu")
      local Font = require("src.render.Font")
      -- an render (nicht draw): auch die Vorschau beim Fang/in Eichs Labor laeuft darueber
      DM._deutschDraw = DM._deutschDraw or DM.render
      DM.render = function(...)
        local fdraw = Font.draw
        Font.draw = function(t, x, y, ...)
          if type(t) == "string" and (t:sub(1, 3) == "GR." or t:sub(1, 3) == "GEW") then
            t = t:gsub("(%d),(%d)", "%1.%2")
          end
          return fdraw(t, x, y, ...)
        end
        local ok, e = pcall(DM._deutschDraw, ...)
        Font.draw = fdraw
        if not ok then error(e, 0) end
      end
    end)
  end

  -- Zusatzschrift (font_extra): TextBoxGraphics mit Schwelle, 2 Pokedex-Kacheln vorne (RomExtractor)
  if R.fontExtra then
    compose("assets/generated/fonts/font_extra.png", function()
      local tb = decodeTiles(R.fontExtra.tb, 32 * 16, 128, 16, 2, false)
      local out = love.image.newImageData(128, 16)
      out:mapPixel(function(x, y)
        local r = tb:getPixel(x, y)
        if r < 0.5 then return 0, 0, 0, 1 end
        return 0, 0, 0, 0
      end)
      local dex = decodeTiles(R.fontExtra.dex, 32, 16, 8, 2, false)
      for y = 0, 7 do
        for x = 0, 15 do
          local r = dex:getPixel(x, y)
          out:setPixel(x, y, 0, 0, 0, r < 0.5 and 1 or 0)
        end
      end
      return out
    end)
  end

end
