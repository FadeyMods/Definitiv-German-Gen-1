<p align="center"><img src="banner.png" alt="Definitiv German Gen 1" width="100%"></p>

# Definitiv German Gen 1

Komplett deutsche Rote, Blaue und Gelbe Edition für [gen1recomp](https://github.com/bryanthaboi/gen1recomp), so als
wäre die englische ROM die deutsche.

*A full German translation mod for gen1recomp (Red, Blue, Yellow). It reads everything from your own German ROMs.*

## Was der Mod macht

- **Alle Texte**: Dialoge, Kämpfe, Menüs, Pokédex-Einträge und Abspann im Wortlaut der deutschen Originale
- **Alle Namen**: Pokémon, Attacken, Items (TM/VM), Trainer, Typen und Orte
- **Deutsche Schrift**: Umlaute, ß und die Sonderzeichen der deutschen Spiele, deutsche Namenseingabe
- **Deutsche Grafiken**: Titelbild (ROTE / BLAUE / GELBE EDITION), Copyright-Tafeln, Spielautomat,
  Pokédex-Einheiten, Urkunde; Gelb zusätzlich Surf-Minispiel und Drucker
- **Deutsche Anordnung**: Menüs und Kästen sitzen wie im deutschen Original
- **Start- und Hauptmenü wie im Original**: Das START-Menü endet mit ZURÜCK, das Hauptmenü hat kein
  SPIEL BEENDEN (siehe Mod-Option unten)
- **Zusätze von gen1recomp** wie Optionen, Mod-Verwaltung, Link- und KONNEX-Meldungen auf Deutsch, im Stil der
  deutschen Spiele

## Voraussetzungen

- **gen1recomp ab 0.3.97** (getestet mit 0.3.97)
- Die **englische ROM** der Edition, wie gen1recomp sie verlangt. gen1recomp nimmt je Edition genau eine Fassung an:

| Edition | englische ROM | MD5 |
|---|---|---|
| Rot | Pokemon - Red Version (USA, Europe) (SGB Enhanced) | `3d45c1ee9abd5738df46d2bdda8b57dc` |
| Blau | Pokemon - Blue Version (USA, Europe) (SGB Enhanced) | `50927e843568814f7ed45ec4f944bd8b` |
| Gelb | Pokemon - Yellow Version - Special Pikachu Edition (USA, Europe) (CGB+SGB Enhanced) | `d9290db87b1f0a23b89f99ee4469e34b` |

- Deine **deutsche ROM** der Edition, die du spielen willst (jede Edition braucht nur ihre eigene):

| Edition | deutsche ROM | MD5 |
|---|---|---|
| Rote Edition | Pokemon - Rote Edition (Germany) (SGB Enhanced) | `8ed0e8d45a81ca34de625d930148a512` |
| Blaue Edition | Pokemon - Blaue Edition (Germany) (SGB Enhanced) | `a1ec7f07c7b4251d5fafc50622d546f8` |
| Gelbe Edition | Pokemon - Gelbe Edition - Special Pikachu Edition (Germany) (CGB+SGB Enhanced) | `e93f10168e3c9b9d18e3ad4a1415e1d0` |

## Installation

1. Im Launcher unter **MODS** den Mod suchen und installieren, oder die `.zip` aus dem
   [neuesten Release](https://github.com/FadeyMods/Definitiv-German-Gen-1/releases/latest) über
   **Import mod .zip** einspielen.
2. **Deutsche ROM importieren:** In den **Details** des Mods die deutsche(n) ROM(s) auswählen. Der Launcher prüft
   die MD5 und legt eine Kopie beim Mod ab. Ohne deutsche ROM bleibt die Edition englisch.
3. Mod aktivieren und spielen. Beim ersten Start liest der Mod die deutsche ROM aus und legt das Ergebnis im
   Mod-Cache ab; danach startet er aus dem Cache.

Falls noch der ältere Mod `deutsch-gen1` installiert ist: bitte entfernen, der Launcher meldet sonst einen Konflikt.

## Mod-Verwaltung und Mod-Option

- Die Mod-Verwaltung öffnest du im Spiel über **OPTION → MODS** (nach EXTRAS), mit **F10** auf der Tastatur oder
  im Launcher unter **MODS**.
- **ORIGINAL-MENÜS** (Standard: an): START- und Hauptmenü wie im Original. Zum Titelbild geht es mit
  A+B+SELECT+START, beendet wird über das Fenster. Wer die Zeilen MODS / BEENDEN / SPIEL BEENDEN von gen1recomp
  zurück möchte, schaltet die Option in der Mod-Verwaltung unter diesem Mod (**OPTIONEN..**) oder im Launcher aus.

## Online-Spiel

Die Online-Funktionen von gen1recomp (KONNEX-Klub online, Arenen und Turniere) sind mit aktivem Mod **nicht
nutzbar**. gen1recomp lässt online nur reine Übersetzungs-Mods zu, die nichts am Programm ändern; dieser Mod muss
ins Programm eingreifen, um alles aus deiner deutschen ROM zu lesen. Außerdem darf online kein Mod die Namen von
Pokémon, Attacken und Items ändern. Zum Online-Spielen den Mod im Launcher abschalten; online ist das Spiel dann
englisch.

## Bekannte Abweichungen durch gen1recomp

- Der Launcher bleibt englisch, ebenso Namen, Beschreibungen und Fehlermeldungen anderer Mods.
- Bildschirme, die es nur in gen1recomp gibt (Optionen, Mod-Verwaltung, KONNEX-Klub, Ladebericht), behalten
  ihren eigenen Aufbau; ihre Texte sind eigene Übersetzungen.
- Was gen1recomp nicht hat, kann der Mod nicht zeigen, z. B. in Gelb die Druckerfehler-Meldungen und die
  Kolosseum-2-Regeln des Originals.

## Keine ROM-Inhalte enthalten

Der Mod enthält **keine Texte oder Grafiken der Spiele**. Er bringt nur Code und „Rezepte“ mit (Positionen in der
ROM, Prüfsummen). Beim Start liest er deine eigene deutsche ROM und baut daraus alles zusammen.

Was sich in einer Version geändert hat, steht im jeweiligen
[Release](https://github.com/FadeyMods/Definitiv-German-Gen-1/releases).

Weitere Generationen: [Definitiv German Gen 2](https://github.com/FadeyMods/Definitiv-German-Gen-2) · [Definitiv German Gen 3](https://github.com/FadeyMods/Definitiv-German-Gen-3)
