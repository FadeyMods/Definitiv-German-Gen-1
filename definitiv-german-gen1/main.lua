-- Definitiv German Gen 1 (Rot, Blau, Gelb)
--
-- Der Mod enthält keine Texte oder Grafiken der Spiele und keine englischen Texte als Suchschlüssel.  Er bringt nur
-- Rezepte mit (Adressen in der deutschen ROM, Port-Texte nur als Prüfsumme) und liest beim Start die deutsche ROM
-- der laufenden Edition, die im Launcher beim Mod importiert wurde.
--
--   kern.lua          deutsche ROM → Port-Extraktor → Texte, Namen, Pokédex, Schrift, Bilder; Haken in den Port
--   gemeinsam.lua     Bausteine aller drei Definitiv-German-Mods (in Gen 1, 2 und 3 byte-gleich)
--   zeichen.lua       Zeichensatz der deutschen Editionen (welcher Code welches Zeichen ist)
--   rezept_<ed>.lua   DE-Adressen der Port-Symbole und weitere Lagen je Edition
--   zusatz.lua        deutsche Texte für Port-Zusätze ohne Gegenstück in der ROM
local VERSION = "1.0.4"

return function(mod)
  local quelle = mod:read("kern.lua")
  local chunk, err = (loadstring or load)(quelle or "", "@kern.lua")
  if not chunk then
    mod.log:warn("Definitiv German: kern.lua fehlerhaft: %s", tostring(err))
    return
  end
  local K = chunk()(mod, VERSION)
  -- Schnittstelle für andere Mods (z. B. Definitiv XP): läuft die deutsche Fassung wirklich?
  local function deutsch() return K.aktiv == true end
  pcall(function()
    mod.exports = mod.exports or {}
    mod.exports.deutsch = deutsch
  end)
  local ok, fehler = pcall(K.start)
  if not ok then mod.log:warn("Definitiv German: %s", tostring(fehler)) end
  -- gemeinsam.lua setzt beim Einhängen exports.deutsch = true; die Schnittstelle bleibt die Funktion
  pcall(function() mod.exports.deutsch = deutsch end)
end
