-- Kaesten und Positionen wie in der DE-ROM (Diplom, Trainerpass, JA/NEIN-Kaesten, Kampfmenue,
-- Weiter-/Speichern-Infokasten, PC-Menues, Spielautomat, Preis-Theke).
return function(W)
  local mod, R, remapped = W.mod, W.R, W.remapped
  local Font = require("src.render.Font")
  -- Diplom: DE-Anordnung (Zeile ab Spalte 2, Name bei Spalte 9 / Zeile 6, Kreis bei Spalte 12)
  if R.diploma then
    pcall(function()
      local D = require("src.ui.Diploma")
      local Font = require("src.render.Font")
      D._deutschRender = D._deutschRender or D.render
      D.render = function(game)
        local fdraw, gdraw = Font.draw, love.graphics.draw
        Font.draw = function(t, x, y, ...)
          if y == 32 and x == 24 then x = 16
          elseif y == 32 and x == 80 then x, y = 72, 48 end
          return fdraw(t, x, y, ...)
        end
        love.graphics.draw = function(img, a, b, c, ...)
          if type(a) == "number" and a == 104 and b == 16 then a = 96 end
          return gdraw(img, a, b, c, ...)
        end
        local ok, e = pcall(D._deutschRender, game)
        Font.draw, love.graphics.draw = fdraw, gdraw
        if not ok then error(e) end
      end
    end)
  end

  -- Trainerpass: DE-ROM druckt "●ORDEN●" ab Spalte 6 -- der rechte Punkt steht direkt hinter
  -- dem (kuerzeren) Wort, nicht fest bei x 104 wie bei "●BADGES●"
  pcall(function()
    local TC = require("src.ui.TrainerCard")
    local Font = require("src.render.Font")
    local Strings = require("src.core.Strings")
    TC._deutschDraw = TC._deutschDraw or TC.draw
    TC.draw = function(self, ...)
      local gdraw = love.graphics.draw
      local rx = 56 + Font.width(Strings("BADGES"))
      love.graphics.draw = function(img, a, b, ...)
        if img == self.circle and a == 104 and b == 72 then a = rx end
        return gdraw(img, a, b, ...)
      end
      local ok, e = pcall(TC._deutschDraw, self, ...)
      love.graphics.draw = gdraw
      if not ok then error(e) end
    end
  end)


  -- ------------------------------------------------------------ Anordnung wie in der DE-ROM
  -- Zwei-Optionen-Menues (JA/NEIN) sind in DE 5 statt 4 breit; das Standardfeld steht bei
  -- Spalte 13 (InitYesNoTextBoxParameters, TwoOptionMenuStrings)
  pcall(function()
    local Theme = require("src.ui.Theme")
    Theme.choiceBox = { tx = 13, ty = 7, tw = 7, th = 5 }
    Theme.saveBox = { tx = 0, ty = 7, tw = 7, th = 5 }
    Theme.trainerSwitchBox = { tx = 0, ty = 7, tw = 7, th = 5 }
    Theme.useNextMonBox = { tx = 13, ty = 9, tw = 7, th = 5 }
  end)


  -- Kampfmenue: DE-Kasten (6,12)-(19,17), Text ab Spalte 8, Cursor 7 / 12; Safari rechts 12 / 13
  pcall(function()
    local BS = require("src.battle.BattleState")
    BS._deutschTextArea = BS._deutschTextArea or BS.drawTextArea
    -- Rahmenteile zeichnet Font.drawBox selbst ueber drawCode: die bleiben, wo sie sind
    local function isBorder(c)
      for _, v in pairs(Font.BORDER or {}) do if v == c then return true end end
      return false
    end
    local normal = {
      box = function(x, y, w, h)
        if x == 8 and y == 12 and w == 12 and h == 6 then return 6, 12, 14, 6 end
        return x, y, w, h
      end,
      -- US: Cursor 72 / 120, Woerter ab 80 / 128 -> DE: Cursor 56 / 96, Woerter ab 64 / 104
      code = function(c, x, y)
        if (y == 112 or y == 128) and not isBorder(c) then
          if x < 120 then x = x - 16 else x = x - 24 end
        end
        return x, y
      end,
    }
    local safari = {
      -- US: rechter Cursor 104, rechte Woerter ab 112 -> DE: 96 / 104
      code = function(c, x, y)
        if (y == 112 or y == 128) and x >= 104 and not isBorder(c) then x = x - 8 end
        return x, y
      end,
    }
    BS.drawTextArea = function(self, ...)
      if self.phase == "menu" then
        return remapped(self.safari and safari or normal, BS._deutschTextArea, self, ...)
      end
      return BS._deutschTextArea(self, ...)
    end
  end)

  -- Weiter-Infokasten (Hauptmenue) und Speichern-Infokasten: DE eine Spalte weiter links, breiter
  pcall(function()
    mod.events:on("screen.pushed", function(ev)
      local st = ev and ev.state
      if type(st) ~= "table" or type(st.draw) ~= "function" or st._deutsch then return end
      local tb = st.titleUiBox
      if tb and tb[1] == 4 and tb[2] == 7 then              -- ContinueInfo
        st._deutsch = true
        st.titleUiBox = { 3, 7, tb[3], tb[4] }
        local draw = st.draw
        st.draw = function(s, ...)
          return remapped({
            box = function(x, y, w, h)
              if x == 4 and y == 7 then return 3, 7, w + 1, h end
              return x, y, w, h
            end,
            text = function(t, x, y)
              if x == 40 then x = 32 elseif y == 72 and x > 40 and x < 120 then x = 96 end
              return x, y
            end,
          }, draw, s, ...)
        end
      elseif st.openPrompt and st.holdsUIAnchors then        -- Speichern-Panel
        st._deutsch = true
        local draw = st.draw
        st.draw = function(...)
          return remapped({
            box = function(x, y, w, h)
              if x == 4 and y == 0 then return 3, 0, w + 1, h end
              return x, y, w, h
            end,
            text = function(t, x, y)
              if x == 40 then x = 32 end
              return x, y
            end,
          }, draw, ...)
        end
      end
    end)
  end)

  -- PC-Menues (DE breiter) und Untermenue ABLEGEN/MITNEHMEN (DE eine Spalte weiter links)
  -- (Haken am gemeinsamen Menu.new-Wrapper im Kern)
  W.menuHaken[#W.menuHaken + 1] = function(items, opts)
    if type(opts) == "table" and opts.noSound and opts.tx == 0 and opts.ty == 0 then
      if opts.tw == 16 then opts.tw = 17 elseif opts.tw == 14 then opts.tw = 16 end
    elseif type(opts) == "table" and opts.tx == 9 and opts.ty == 10 and opts.tw == 11 and opts.th == 8 then
      opts.tx, opts.tw = 8, 12
    end
  end

  -- Spielautomat "Noch mal?": JA/NEIN-Feld bei Spalte 13 (DE)
  pcall(function()
    local SM = require("src.ui.SlotMachine")
    SM._deutschDraw = SM._deutschDraw or SM.draw
    SM.draw = function(self, ...)
      if self.stage ~= "onemore" then return SM._deutschDraw(self, ...) end
      return remapped({
        box = function(x, y, w, h)
          if x == 14 and y == 12 and w == 6 and h == 5 then return 13, 12, 7, 5 end
          return x, y, w, h
        end,
        text = function(t, x, y)
          if x == 128 and (y == 104 or y == 112) then x = 120 end
          return x, y
        end,
        code = function(c, x, y)
          if c == 0xED and x == 120 and (y == 104 or y == 112) then x = 112 end
          return x, y
        end,
      }, SM._deutschDraw, self, ...)
    end
  end)


  -- Preis-Theke: "MÜNZ" bei Spalte 13 (PrintPrizePrice)
  pcall(function()
    local PC = require("src.ui.PrizeCounter")
    PC._deutschDraw = PC._deutschDraw or PC.draw
    PC.draw = function(self, ...)
      return remapped({
        text = function(t, x, y)
          if x == 96 and y == 0 then x = 104 end
          return x, y
        end,
      }, PC._deutschDraw, self, ...)
    end
  end)

end
