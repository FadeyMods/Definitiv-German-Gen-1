-- Zeichensatz der deutschen Gen-1-Editionen (Rot, Blau, Gelb).
--
-- Der deutsche Font belegt einige Codes anders als der englische (geprüft am Font der DE-ROM, Raster in
-- Test/aus/extrakt/red/font_raster_de.png): statt der Ligaturen 'd 'l 's 't 'v 'r 'm stehen dort Akzent- und
-- Umlautbuchstaben und eigene Apostroph-Glyphen.  Diese Tabelle sagt nur, welcher Code welches Zeichen ist –
-- die Glyphen selbst kommen aus der ROM des Spielers.
local Z = {}

-- Code → Zeichen (Dekodieren der Texte)
Z.CODES = {
  [0xBA] = "à", [0xBB] = "è", [0xBC] = "é", [0xBD] = "ù", [0xBE] = "ß", [0xBF] = "ç",
  [0xC0] = "Ä", [0xC1] = "Ö", [0xC2] = "Ü", [0xC3] = "ä", [0xC4] = "ö", [0xC5] = "ü",
  [0xC6] = "ë", [0xC7] = "ï", [0xC8] = "â", [0xC9] = "ô", [0xCA] = "û", [0xCB] = "ê", [0xCC] = "î",
  [0xD4] = "c'", [0xD5] = "d'", [0xD6] = "j'", [0xD7] = "l'", [0xD8] = "m'", [0xD9] = "n'", [0xDA] = "p'",
  [0xDB] = "s'", [0xDC] = "'s", [0xDD] = "t'", [0xDE] = "u'", [0xDF] = "y'",
  [0xE4] = "+",
  -- $30 steht nur einmal in einem Text der deutschen Rot/Blau-ROM („TIPS FÜR TRAINER“, Marmoria City, nach
  -- „Erfahrungspunkte,“) – ein Fehler der DE-ROM (im Textmodus eine Kartenkachel, kein Zeichen).  Der Port würde
  -- dort ein Kana zeichnen; dargestellt wird ein Leerzeichen.
  [0x30] = " ",
}

-- Codes, die der englische Font mit Ligaturen belegt und der deutsche nicht (dort andere oder leere Glyphe)
Z.FREI = { [0xBB] = true, [0xBC] = true, [0xBD] = true, [0xBE] = true, [0xBF] = true, [0xE4] = true,
  [0xE5] = true }

-- Manifest-Kopie auf den deutschen Zeichensatz umstellen (charmap: Code → Zeichen; fontCharmap: Folge → Code)
function Z.anwenden(manifest)
  local cm = {}
  for k, v in pairs(manifest.charmap) do cm[k] = v end
  for code, z in pairs(Z.CODES) do cm[tostring(code)] = z end
  cm[tostring(0xE5)] = nil
  manifest.charmap = cm
  manifest.fontCharmap = Z.fontCharmap(manifest.fontCharmap)
end

-- fontCharmap ohne die englischen Ligaturen auf umbelegten Codes, plus die deutschen Folgen
function Z.fontCharmap(alt)
  local neu, belegt = {}, {}
  for code, z in pairs(Z.CODES) do if code >= 0x80 then belegt[z] = true end end
  for _, e in ipairs(alt) do
    local weg = Z.FREI[e.code] and e.seq:sub(1, 1) == "'" or belegt[e.seq]
      or (e.code == 0xBA and e.seq == "é")
    if not weg then neu[#neu + 1] = e end
  end
  for code, z in pairs(Z.CODES) do
    if code >= 0x80 then neu[#neu + 1] = { code = code, seq = z } end  -- $30 nur zum Lesen (siehe oben)
  end
  table.sort(neu, function(a, b) if a.code ~= b.code then return a.code < b.code end return a.seq < b.seq end)
  return neu
end

return Z
