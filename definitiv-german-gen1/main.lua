-- 📀🇩🇪 Definitiv German 💬✅ Gen 1  (Rot, Blau, Gelb)
--
-- Dieser Mod enthaelt KEINE Texte oder Grafiken der Spiele.  Er bringt nur Rezepte mit
-- (Adressen in der deutschen ROM) und liest beim Start die deutsche ROM der laufenden Edition,
-- die du im Launcher importiert hast -- immer genau das Gegenstueck:
--   Rot -> Rote Edition, Blau -> Blaue Edition, Gelb -> Gelbe Edition.
--
-- Aufbau (jeder Baustein hat sein eigenes Rezept rezept_<edition>_<baustein>.lua):
--   werkzeug.lua    Edition, deutsche ROM, Rezepte, gemeinsame Helfer
--   zeichen.lua     Zeichentabelle und Sonderzeichen-Woerter (TEAM ROCKET, PC, TM ...) aus der DE-ROM
--   dialoge.lua     alle Dialogtexte                    (mod.content.text)
--   daten.lua       Pokemon, Attacken, Items, Trainer, Typen, Orte, Abspann, Tausch, Namensvorschlaege
--   port_texte.lua  feste Texte des Ports (mod.content.strings) und Menues
--   grafik.lua      Bilder, Schrift, Titelbild         (Assets.compose)
--   layout.lua      Kaesten und Positionen wie in der DE-ROM
return function(mod)
  local quelle = mod:read("werkzeug.lua")
  local chunk, err = (loadstring or load)(quelle or "", "@werkzeug.lua")
  if not chunk then
    mod.log:warn("Deutsch Gen 1: werkzeug.lua fehlerhaft: %s", tostring(err))
    return
  end
  local W = chunk()(mod)
  if not W then return end
  for _, baustein in ipairs({ "zeichen", "dialoge", "daten", "port_texte", "grafik", "layout" }) do
    W.baustein(baustein)
  end
  W.bericht()
end
