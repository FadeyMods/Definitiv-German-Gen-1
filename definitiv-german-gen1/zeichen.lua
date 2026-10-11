-- Zeichentabelle der DE-ROM und die Woerter hinter den Sonderzeichen.
-- Die Sonderzeichen ($54 POKe, $5B PC, $5C TM, $5D TRAINER, $5E ROCKET) schreibt das Spiel als Wort aus;
-- welches Wort, steht in der ROM (home/text.asm: PCCharText, TMCharText ...).  Die deutsche Gelbe Edition
-- schreibt z. B. "TEAM ROCKET" statt "ROCKET" -- deshalb kommen die Woerter aus der DE-ROM, nicht fest.
return function(W)
  local R = W.R
  for code, zeichen in pairs(R.cm or {}) do W.CM[code] = zeichen end
  W.apply("sonderzeichen", R.steuerzeichen, function(code, teile)
    W.CM[code] = W.T(teile)
  end)
end
