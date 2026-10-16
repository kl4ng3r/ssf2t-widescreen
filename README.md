# SSF2T Widescreen for iPhone / iPad (iOS 17+)

The same 16:9 widescreen Super Street Fighter II Turbo as the Windows version, as an iOS app
with game controller support. GitHub's free Mac build machines compile it, so you don't need a
Mac. No game files are included: you add your own `ssf2t.zip` on the phone.

## 1. Build the app on GitHub (one time, ~15–25 minutes)

1. Sign in at https://github.com (a free account is fine) and click **New repository**.
   Name it e.g. `ssf2t-ios`, choose **Public** (Mac build minutes are free and unlimited for public
   repositories; private ones have a small monthly allowance), then **Create repository**.
2. On the new repository page click **uploading an existing file**, and drag in the *contents* of
   this folder: `.github`, `core`, `ios` and this `README.md`. Click **Commit changes**.
   (If your file manager hides the `.github` folder, turn on hidden files first. The workflow file
   must end up at `.github/workflows/build-ios.yml` in the repository.)
   **Never upload your ROM (ssf2t.zip) to GitHub.**
3. Open the **Actions** tab. The build starts by itself after the upload. If it doesn't,
   pick **Build iOS app (unsigned .ipa)** and click **Run workflow**.
4. When it shows a green tick, open the run and download **SSF2T-Widescreen-ipa** under
   *Artifacts*. Unzip it to get `SSF2T-Widescreen-unsigned.ipa`.

## 2. Install it on your iPhone (from Windows)

Use **Sideloadly** (https://sideloadly.io) or **AltStore** (https://altstore.io) with your Apple ID.
They sign the app for your own device.

1. Install iTunes (from Apple's website, not the Microsoft Store version) and Sideloadly on the PC,
   connect the iPhone by cable and tap *Trust* on the phone.
2. In Sideloadly drop in the `.ipa`, enter your Apple ID and click **Start**.
3. On the iPhone: **Settings › Privacy & Security › Developer Mode › On** (the phone restarts),
   then **Settings › General › VPN & Device Management** › your Apple ID › **Trust**.

With a free Apple ID the app must be re-signed every 7 days (Sideloadly/AltStore can refresh it).
A paid developer account lasts a year.

## 3. Add the game

Open the app and tap **Import ssf2t.zip**, then pick your MAME/FBNeo `ssf2t.zip` (the World
940223 parent set). Or copy it with the Files app into *On My iPhone › SSF2T Widescreen*.
The app creates its small `ssf2tws.zip` launch file itself.

## Controls

| Game          | Controller (Xbox / PlayStation / MFi)   | Touch (no controller connected)      |
|---------------|-----------------------------------------|--------------------------------------|
| LP / MP / HP  | X / Y / RB  (□ / △ / R1)                | X / Y / RB on the on-screen pad      |
| LK / MK / HK  | A / B / RT or LT  (✕ / ○ / R2 or L2)    | A / B / RT                           |
| Move          | D-pad or left stick                     | on-screen d-pad                      |
| Coin / Start  | View/Select (Share/Create) / Menu (Options) | COIN / START buttons at the top  |

Menu (save/load state, **Test Menu** for difficulty, reset, import): tap **MENU** at the top or
press **L3 + R3** together. Shortcuts: **LB + Start** saves a state, **LB + Coin** loads it.
The first controller is player 1 and the second is player 2. When a controller connects, the
touch controls hide themselves.

The game starts on **GAME DIFFICULTY 1/EASIEST** and **GAME SPEED TURBO 0** (the arcade factory
defaults are 2 and TURBO 1). To change them use the Test Menu, the arcade's own service menu:
**3 SYSTEM CONFIGURATION**, then EXIT and press START to save. What you save there is kept. Settings
and high scores are saved whenever the app goes to the background.

Sound plays even with the silent switch on (like a video app). Use the volume buttons to turn it down.

## What's inside

* `core/` – the widescreen changes to FinalBurn Neo (libretro), as a patch against the commit in
  `BASE_COMMIT.txt`, plus the game patch table. Identical to the Windows build.
* `ios/Sources/main.m` – the iOS frontend (video, audio, controllers, touch controls, menu).
* `ios/project.yml` – Xcode project description (XcodeGen).
* `.github/workflows/build-ios.yml` – builds the core for iOS arm64, then the app, and packages
  an unsigned `.ipa`.

FinalBurn Neo is distributed under its own non-commercial license.
