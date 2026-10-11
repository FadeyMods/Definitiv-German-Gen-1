-- Alle Dialogtexte (Text-Baenke) aus der DE-ROM: mod.content.text, Schluessel = Label wie im Port.
-- Dazu die Werfer-Namen im Fang-Tutorial (DisplayBattleMenu.oldManName / Gelb .profOakName).
return function(W)
  local mod, T = W.mod, W.T
  W.apply("text", W.R.text, function(label, teile) mod.content.text:override(label, T(teile)) end)
end
