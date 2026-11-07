-- Editions-Intro beim Spielstart (in Gen 1, 2 und 3 byte-gleich)
--
-- Spielt beim Start das Intro der laufenden Edition (video/<edition>.ogv, Theora mit Vorbis-Ton) über das ganze
-- Fenster.  Solange es läuft, steht das Spiel still und seine Musik schweigt.  Jede Taste, jeder Knopf am Controller,
-- ein Mausklick oder ein Tippen überspringt es; der Druck (samt Loslassen) erreicht das Spiel nicht.  Das Intro endet
-- in Weiß, wie das erste Bild des Spiels.
--
--   Optionen unter MODS:  INTRO ZEIGEN (an/aus), INTRO-TON (an/aus)
--
-- Ohne Video der Edition (z. B. noch kein Intro für Feuerrot/Blattgrün), mit INTRO ZEIGEN aus oder wenn das Video
-- nicht abspielbar ist, hängt sich der Mod nirgends ein.  Haken auf Bild und Eingabe kommen erst mit dem Intro dazu,
-- und nach dem Intro werden alle Haken wieder gelöst: danach läuft das Spiel genau wie ohne Intro.  Treiber-Läufe
-- (POKEPORT_DRIVER/POKEPORT_AUTOPILOT) rufen core.update nicht auf; dort startet das Intro nie.

local EINBLENDEN_HINWEIS = 1.0   -- s, ab dann erscheint der Hinweis zum Überspringen
local HINWEIS = "Überspringen: beliebige Taste"
local HOECHSTENS = 14            -- s, danach geht es in jedem Fall ins Spiel (alle Intros sind kürzer als 11 s)

return function(mod)
  mod.options:define({
    { key = "intro", label = "INTRO ZEIGEN", type = "toggle", default = true },
    { key = "intro_ton", label = "INTRO-TON", type = "toggle", default = true },
  })
  if mod.options:get("intro") == false then return end
  if not (love and love.graphics and love.graphics.newVideo) then return end

  local okV, GameVersion = pcall(require, "src.core.GameVersion")
  local edition = okV and type(GameVersion) == "table" and GameVersion.get and GameVersion.get() or nil
  if type(edition) ~= "string" then return end
  local datei = "video/" .. edition .. ".ogv"
  local info = mod.assets:info(datei)
  if not (info and info.type == "file") then return end   -- Edition ohne Intro: nichts tun

  local video, quelle, pausiert, hinweisFont
  local zustand = "wartet"   -- wartet -> laeuft -> fertig
  local beginn, alter = nil, 0
  local gedrueckt = {}       -- Taste, die übersprungen hat: bis zu ihrem Loslassen gehört sie dem Intro
  local fertigSeit = nil
  -- Lösefunktionen der Haken (hooks:wrap gibt sie zurück): das Bild (render.compose) gleich am Ende des Intros,
  -- Takt und Eingabe, sobald auch das Loslassen der Skip-Taste dem Intro gehört hat
  local loesen = { bild = {}, rest = {} }

  local function haken(gruppe, name, fn)
    local los = mod.hooks:wrap(name, fn)
    if type(los) == "function" then table.insert(loesen[gruppe], los) end
  end

  local function loesenGruppe(gruppe)
    local liste = loesen[gruppe]
    loesen[gruppe] = {}
    for i = #liste, 1, -1 do pcall(liste[i]) end
  end

  -- Takt- und Eingabe-Haken weg, sobald keine Skip-Taste mehr unterwegs ist (spätestens 5 s nach dem Intro)
  local function aufraeumen()
    if zustand ~= "fertig" or #loesen.rest == 0 then return end
    local jetzt = love.timer and love.timer.getTime and love.timer.getTime() or nil
    if next(gedrueckt) ~= nil and not (jetzt and fertigSeit and jetzt - fertigSeit > 5) then return end
    gedrueckt = {}
    loesenGruppe("rest")
  end

  local function lautstaerke()
    if mod.options:get("intro_ton") == false then return 0 end
    local ok, opt = pcall(function() return require("src.core.SaveData").loadOptions() end)
    local v = ok and type(opt) == "table" and tonumber(opt.sfxVol) or 7
    return math.max(0, math.min(7, v)) / 7
  end

  local function beenden()
    local lief = zustand == "laeuft"
    zustand = "fertig"
    fertigSeit = love.timer and love.timer.getTime and love.timer.getTime() or nil
    loesenGruppe("bild")   -- nie aus render.compose heraus aufgerufen, darum hier gefahrlos
    if not lief then return end
    if video then
      pcall(function() video:pause() end)
      if quelle then pcall(function() quelle:stop() end) end
      pcall(function() video:release() end)
    end
    if hinweisFont then pcall(function() hinweisFont:release() end) end
    video, quelle, hinweisFont = nil, nil, nil
    if pausiert and #pausiert > 0 then pcall(love.audio.play, pausiert) end
    pausiert = nil
  end

  local function zeichnen(next, renderer, ctx)
    if zustand ~= "laeuft" or not video then return next(renderer, ctx) end
    local G = love.graphics
    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha", "alphamultiply")
    G.clear(0, 0, 0, 1)
    -- in das Ziel, in das das Spiel gerade sein Bild legt (Fenster oder Ansicht eines Layout-Mods)
    local ziel = G.getCanvas()
    local ww, wh
    if ziel then ww, wh = ziel:getDimensions() else ww, wh = G.getDimensions() end
    local vw, vh = video:getDimensions()
    local s = math.min(ww / vw, wh / vh)   -- ganzes Bild sichtbar, Ränder schwarz
    G.setColor(1, 1, 1, 1)
    G.draw(video, (ww - vw * s) / 2, (wh - vh * s) / 2, 0, s, s)
    if alter > EINBLENDEN_HINWEIS then
      if hinweisFont == nil then
        local okF, f = pcall(G.newFont, math.max(10, math.floor(wh / 36 + 0.5)))
        hinweisFont = okF and f or false
      end
      local tw = hinweisFont and hinweisFont:getWidth(HINWEIS) or ww
      if tw <= ww * 0.9 then   -- in sehr kleinen Fenstern lieber kein Hinweis als ein abgeschnittener
        local rand = math.floor(hinweisFont:getHeight() * 1.5)
        local x, y = ww - tw - rand, wh - rand - hinweisFont:getHeight()
        local a = math.min(1, (alter - EINBLENDEN_HINWEIS) / 0.5) * 0.55
        G.setFont(hinweisFont)
        G.setColor(0, 0, 0, a * 0.6)
        G.print(HINWEIS, x + 1, y + 1)
        G.setColor(1, 1, 1, a)
        G.print(HINWEIS, x, y)
      end
    end
    G.pop()
    return true
  end

  -- Eingaben: während des Intros überspringt jeder Druck; nichts davon erreicht das Spiel
  local function eingabe(art)
    return function(next, game, ev)
      local id = art .. ":" .. tostring(ev.key or ev.button or ev.id or "?")
      if zustand == "laeuft" then
        if ev.phase == "pressed" then gedrueckt[id] = true; beenden() end
        return true
      end
      if gedrueckt[id] then
        -- auch eine Tastenwiederholung der Skip-Taste gehört noch dem Intro
        if ev.phase == "released" or ev.phase == "cancelled" then
          gedrueckt[id] = nil
          aufraeumen()
        end
        return true
      end
      aufraeumen()
      return next(game, ev)
    end
  end

  local function starten()
    local ok, v = pcall(love.graphics.newVideo, mod.assets:path(datei), { audio = love.audio ~= nil })
    if (not ok or not v) and love.audio then
      ok, v = pcall(love.graphics.newVideo, mod.assets:path(datei), { audio = false })   -- notfalls ohne Ton
    end
    if not ok or not v then
      mod.log:warn("Intro nicht abspielbar: %s", tostring(v))
      zustand = "fertig"
      return
    end
    video = v
    pcall(function() video:setFilter("linear", "linear") end)
    pausiert = love.audio and love.audio.pause() or {}   -- Musik des Spiels anhalten, nach dem Intro weiter
    local okQ, q = pcall(function() return video:getSource() end)
    quelle = okQ and q or nil
    if quelle then pcall(function() quelle:setVolume(lautstaerke()) end) end
    local okP, perr = pcall(function() video:play() end)
    if not okP then
      mod.log:warn("Intro nicht abspielbar: %s", tostring(perr))
      zustand = "laeuft"
      beenden()
      return
    end
    zustand = "laeuft"
    beginn = love.timer and love.timer.getTime and love.timer.getTime() or nil
    haken("bild", "render.compose", zeichnen)
    haken("rest", "input.key", eingabe("key"))
    haken("rest", "input.gamepad", eingabe("pad"))
    haken("rest", "input.pointer", eingabe("zeiger"))
  end

  -- Erst im ersten Spielbild starten: dann zeichnet die Engine schon, und vom Video geht nichts verloren
  haken("rest", "core.update", function(next, game, dt)
    if zustand == "wartet" then starten() end
    if zustand == "laeuft" then
      -- Wanduhr ab dem Start des Videos (ein langes erstes Bild nach dem Laden zählt nicht mit)
      if beginn then alter = love.timer.getTime() - beginn else alter = alter + math.min(dt or 0, 0.1) end
      -- Ende des Videos; ein hängender Decoder darf das Spiel nie blockieren
      local okP, spielt = pcall(function() return video:isPlaying() end)
      if not (okP and spielt) or alter > HOECHSTENS then beenden() else return end
    end
    -- ab hier wie ohne Intro: erst das Spiel, dann (nach dem Aufruf, damit die Kette dieses Bildes vollständig
    -- läuft) die übrigen Haken lösen
    local r = { n = 0 }
    local function sammeln(...) r = { n = select("#", ...), ... } end
    sammeln(next(game, dt))
    aufraeumen()
    return (unpack or table.unpack)(r, 1, r.n)
  end)
end
