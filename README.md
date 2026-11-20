# Deezit
Quality of Life improvements to Deezer (No Jailbreak Required)

A Theos tweak for Deezer iOS (targeting 11.27.0) that you inject into your own
decrypted IPA (e.g. with [cyan](https://github.com/asdfzxcvbn/pyzule-rw)) and
sideload. It needs no Substrate/ElleKit: hooks use Logos' `internal`
generator (plain ObjC runtime).

## v1 goals

- **Slowed + reverb**: speed slider (pitch follows speed, like a turntable),
  reverb mix / room / damping, and presets, applied at the audio-output level
- **In-app settings page**
- **GitHub Action** that builds `Deezit.dylib`

## Status

| Part | State |
|---|---|
| IPA analysis tooling (`tools/analyze_ipa.py`) | done, run on the real 11.27.0 binary |
| Analysis of Deezer 11.27.0 | done: see [`docs/ANALYSIS.md`](docs/ANALYSIS.md) |
| Settings page (switch, presets, sliders, reset) | done, saves prefs |
| Prefs → realtime-safe audio params | done |
| Audio hook | **working** (tested on iOS 27.0.1): varispeed + Apple Reverb2 spliced in front of Deezer's output node |
| Animated lock-screen covers | **working**: Apple Music motion covers on the lock screen via iOS 26's `MPMediaItemAnimatedArtwork` |
| ••• menu row | **working**: "Playback Controls" as the first option of the full-screen player's ••• menu |
| Sing (vocal reduction) | DSP version: "Vocals" slider, mid/side removal of the centre voice band (new, not yet tested on a device); an ML separator is planned |
| Debug panel + in-app log | done (three-finger double tap) |
| Runtime probes | logs which player / settings screens appear, to settle the analysis' open questions |
| DSP C core (`DZDSP.c`) | not used by the AVAudioEngine backend (Apple's units do the work); kept for other backends |
| CI build | `.github/workflows/build.yml`: `Deezit.dylib` + rootless `.deb` |

The audio hook has a kill switch: if playback breaks, open the debug panel,
tap **⋯ → Turn audio hook off**, and relaunch Deezer. Deezit then leaves
Deezer's audio completely alone.

## Opening the controls

**Full-screen player → ••• → Playback Controls** opens the slowed + reverb
controls as a half-height sheet over the player.

Gestures, anywhere in Deezer:

| Gesture | Opens |
|---|---|
| **Three-finger hold** | Deezit settings (same page, full height) |
| **Three-finger double tap** | Debug panel: status, live log, share / copy / clear, audio-hook kill switch |

The first launch of each Deezit version shows a short banner to confirm the
injection worked.

## Building

CI builds on every push (except docs-only pushes). Download `Deezit-<version>`
from the run's artifacts: it holds `Deezit.dylib` and a rootless `.deb`.

Locally (macOS with Xcode, or Linux with a Theos toolchain + SDK):

```bash
make FINALPACKAGE=1
```

The dylib lands in `.theos/obj/Deezit.dylib`. On Linux, pass an SDK you have,
e.g. `make TARGET=iphone:clang:16.5:15.0 FINALPACKAGE=1`.

## Injecting

```bash
cyan -i Deezer.ipa -o Deezer-Deezit.ipa -f .theos/obj/Deezit.dylib
```

Then sideload `Deezer-Deezit.ipa` as usual.

## Sing (vocal reduction)

Playback Controls → **Sing → Vocals** turns the lead voice down (100% =
untouched). It's Deezit's own audio unit (`DZVocalUnit.m` + `DZVocals.c`),
first in the chain after Deezer's mixer, so the slider acts instantly and
works with or without Slowed + Reverb:

- the mix is split into mid (L+R) and side (L-R)
- the voice band of the mid, about 120 Hz - 8 kHz, is removed by the slider
  amount; bass, kick, cymbals and everything panned off-centre stay

It's a plain DSP trick, so it works best on studio tracks with a centred,
dry lead vocal; centred instruments in the same range (snare, some synths)
drop too. A machine-learning separator is the planned upgrade: Deezer queues
3 s of decoded audio ahead of playback (see `DZBufferProbe.x`), enough to
separate each chunk before it plays without delaying anything.

If the engine won't start with the unit, Deezit removes just that unit and
retries, so slowed + reverb keep working.

## Animated lock-screen covers

On iOS 26 and later, Deezit shows the Apple Music motion cover of the album
playing on the lock screen, when Apple Music has one (Settings → Lock Screen →
Animated album covers, on by default, paused in Low Power Mode). It runs in
Deezer's own process, so no jailbreak is needed:

1. hooks `-[MPNowPlayingInfoCenter setNowPlayingInfo:]` and reads the title,
   artist and album Deezer sets
2. finds the album's motion cover through Apple Music's catalog search
   (`editorialVideo`, web-player token), picking among same-name albums the
   one that has a cover; if the album has none, the song's other releases
   (singles first) are tried
3. downloads the HLS variant nearest 1100 px wide as one MP4 into
   `Library/Caches/Deezit/motion` (kept under 150 MB)
4. adds an `MPMediaItemAnimatedArtwork` under the 3:4 (or 1:1) key iOS offers

Albums are matched by name, so some won't be found. The token is scraped from
music.apple.com and can break if Apple changes that page. The debug panel's
"lock art" line and log show what happened for each album.

## Logs

The debug panel (three-finger double tap) shows this session's log live, and
its share button sends it plus the previous session's file (handy after a
crash). The files live in the app container under
`Library/Application Support/Deezit/`. With a Mac, Console.app also shows
everything: filter `subsystem:com.pisknk.deezit`.

## Layout

```
Tweak.x                     entry point (%ctor)
DZLog.h / DZDebugLog.*      logging: os_log + in-app ring + log files
DZPrefs.*                   NSUserDefaults suite + atomic mirror for the audio thread
DZAudioParams.h             plain-C params struct shared with the DSP
DZPresets.*                 Off / Slowed / Slowed + Reverb / Dreamy / Sped Up / Nightcore
DZDSP.*                     engine-agnostic DSP core (C)
DZVocals.* / DZVocalUnit.*  "Sing": mid/side vocal reduction (C) as an in-process AUAudioUnit
DZAudioHook.x               AVAudioEngine backend: splices vocals + varispeed + reverb before the output node
DZBufferProbe.x             logs how Deezer schedules audio (sizing the future ML separator)
DZProbes.x                  runtime probes (which player / settings screens appear)
DZPlayerMenu.x              "Playback Controls" row in the player's ••• menu
DZLockArtwork.x             animated lock-screen cover (now-playing hook)
DZAppleMusic.*              Apple Music album match + motion-cover lookup
DZMotionFile.*              motion cover HLS -> cached local MP4 + still frame
DZSettingsViewController.*  settings page
DZDebugViewController.*     debug panel + toast banner
DZSettingsEntry.*           gestures that open the pages
tools/analyze_ipa.py        IPA analyser (stdlib-only Python)
docs/ANALYSIS.md            findings + hook decision table
```

## Credits

The Apple Music lookup (iTunes Search matching, web-player token, catalog
`editorialVideo`) is adapted from
[twenty-one-reborn](https://github.com/pisknk/twenty-one-reborn). The idea of
using iOS 26's animated now-playing artwork from inside the app came from
spoti.pw; none of its code was used.

The general approach (inject into a decrypted IPA, hook the player's audio
output) is inspired by [spoti.pw](https://github.com/skopevoj/spoti.pw). No code
was taken from it: that project is PolyForm Strict licensed.
