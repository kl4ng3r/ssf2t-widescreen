# NBA Jam TE Rewind – Widescreen (Windows + iPhone/iPad)

NBA Jam Tournament Edition (rev 2.1) with the NBA Jam Rewind 1.1 patches, running in a true widescreen
picture: the court, crowd, players and ball are drawn across a 512-pixel-wide picture instead of
the arcade's 400 pixels (about 15.4:9, with the same pixel shape as the original 4:3 picture).
It is built on FinalBurn Neo (libretro), like the SSF2T widescreen project.

No game files are included. You need your own **nbajamte2.zip** (NBA Jam TE rev 2.1 2/06/94,
MAME/FBNeo romset) **with the NBA Jam Rewind 1.1 patches applied** (the 16 standard .bps patches, with or without the optional "Get that BLEEP outta here"
files). The launchers recognise which version a zip is and load the matching driver
(`nbajamrw` or `nbajamrwb`); an unpatched set is refused with a message.

## What changed for widescreen

* **Core** (`core/`): a new FBNeo driver `nbajamrw` (Rewind ROM checksums) that shows the whole
  512-pixel video RAM row. The game already draws its 400-pixel picture at columns 56–455, so the
  extra 56 pixels on each side are real video memory the game can draw into.
* **Game patches** (`core/nbajamrw_patches.h`, applied in memory after loading; every word is
  checked first and nothing is patched if the ROM differs):
  * the sprite clipping window is widened by 56 pixels on each side, so players, the ball, the
    crowd, the stands and backboards are drawn into the extra width;
  * the perspective court floor is drawn 512 pixels wide (it is one blit per scan line);
  * the camera stops 56 pixels earlier at both ends of the court, so the view never shows past the
    arena art (at the ends you see exactly what the original showed, plus more of the court);
  * the off-screen player arrows move out to the new screen edges and only appear when a player is
    outside the wide picture.
* Screens other than the court (title, team select, tonight's match-up, attract text screens) are
  400 pixels wide by design; their sides are shown black.

## Windows

1. Put `NBAJamWS.exe` in a folder of its own.
2. Start it and drag your patched `nbajamte2.zip` onto the window (it is copied next to the program
   as `nbajamrw.zip`), or copy the zip there yourself under that name.
3. The first start shows "CMOS INVALID – FACTORY SETTINGS RESTORED": press any button.

Settings, high scores and the save state live in the `saves` folder next to the program.
Needs a graphics card with OpenGL 3.3 (anything from the last ~12 years).

| Action        | Keyboard (player 1)  | Keyboard (player 2) | Controller (Xbox / PlayStation)        |
|---------------|----------------------|---------------------|----------------------------------------|
| Move          | Arrow keys           | W A S D             | D-pad or left stick                    |
| Shoot         | Z or Space           | J                   | A (✕)                                  |
| Pass          | X                    | K                   | X or Y (□ / △)                         |
| Turbo         | C or Left Shift      | L                   | B (○), RB, LT or RT                    |
| Coin / Start  | 5 / 1 (or Enter)     | 6 / 2               | View/Back / Menu/Start                 |

Up to 4 controllers: controller 1 is player 1, and so on (the keyboard also controls players 1 and 2).

* **Esc** (or the controller's Guide button, or L3 + R3): menu – resume, save / load state, CRT
  filter, fullscreen, the arcade's test menu (difficulty, free play, etc.), reset, quit.
* **F2** save state, **F4** load state (controller: LB + Start / LB + Back), **F3** CRT filter,
  **F11** or **Alt+Enter** fullscreen.
* Moving the mouse to the top of the window shows the **COIN / START / MENU / CRT** buttons; they
  hide again after 5 seconds.

To build the exe yourself on Linux: `sudo apt install mingw-w64`, then `sh windows/build.sh`
(or let GitHub build it: the **Build Windows launcher** workflow uploads `NBAJamWS.exe` as an artifact).

## iPhone / iPad (iOS 17+)

Same procedure as the SSF2T app; GitHub's free Mac build machines compile it.

1. Create a new **public** repository on GitHub (e.g. `nbajam-widescreen`) and upload the
   *contents* of this folder: `.github`, `core`, `ios`, `windows`, `.gitattributes` and this README.
   **Never upload the ROM.**
2. Open **Actions**: **Build iOS app (unsigned .ipa)** starts by itself (or click *Run workflow*).
   When it is green, download **NBAJam-Widescreen-ipa** and unzip it.
3. Install `NBAJam-Widescreen-unsigned.ipa` with Sideloadly or AltStore (free Apple ID: re-sign every
   7 days), turn on Developer Mode and trust your Apple ID on the phone.
4. Open the app, tap **Import patched nbajamte2.zip** and pick your patched zip (any file name).

Controls on iOS: up to 4 controllers (same layout as above: A shoot, X/Y pass, B/RB/triggers turbo,
Options/Share = coin, Menu = start). Without a controller, an on-screen pad appears (A shoot,
X pass, B turbo). **COIN / START / MENU / CRT** buttons sit at the top (tap the top of the screen to
show them). L3 + R3 opens the menu, LB + Start saves a state, LB + Coin loads it.

## Notes

* The arcade runs at 54.71 Hz; both launchers pace the emulation to that rate (not to the display's
  60 Hz) so the game runs at its real speed.
* 2 credits start a game by default. Coinage (including free play) and difficulty are set in the
  arcade's own test menu (Menu › Test Menu, then Game Adjustment). What you set there is saved.
* The camera range at the ends of the court is 56 pixels shorter than in the original.

## Files

* `core/fbneo-nbajamrw.diff` – changes to FinalBurn Neo (libretro) against the commit in
  `core/BASE_COMMIT.txt`, including `Makefile.tunit` (a build with only the Midway T-Unit games).
* `core/nbajamrw_patches.h` – the game-code patch table.
* `ios/` – iOS frontend (Objective-C + Metal CRT shader), XcodeGen project.
* `windows/` – Windows frontend (`nbajamws.cpp`, SDL2 + OpenGL), icon, build script.

Licenses: FinalBurn Neo is under its own non-commercial license. The newpixie CRT shader is by
Mattias Gustavsson (MIT / public domain; slang version by hunterk). The on-screen font is generated
from DejaVu Sans Bold (Bitstream Vera / DejaVu fonts license). SDL2 is zlib-licensed.
