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
| Audio hook | **AVAudioEngine backend written, not yet tested on a device**: varispeed + Apple Reverb2 spliced in front of Deezer's output node |
| Debug panel + in-app log | done (three-finger double tap) |
| Runtime probes | logs which player / settings screens appear, to settle the analysis' open questions |
| DSP C core (`DZDSP.c`) | not used by the AVAudioEngine backend (Apple's units do the work); kept for other backends |
| CI build | `.github/workflows/build.yml`: `Deezit.dylib` + rootless `.deb` |

The audio hook has a kill switch: if playback breaks, open the debug panel,
tap **⋯ → Turn audio hook off**, and relaunch Deezer. Deezit then leaves
Deezer's audio completely alone.

## Gestures

Anywhere in Deezer:

| Gesture | Opens |
|---|---|
| **Three-finger hold** | Deezit settings (temporary: a button on Deezer's own Settings / player comes later) |
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
DZAudioHook.x               AVAudioEngine backend: splices varispeed + reverb before the output node
DZProbes.x                  runtime probes (which player / settings screens appear)
DZSettingsViewController.*  settings page
DZDebugViewController.*     debug panel + toast banner
DZSettingsEntry.*           gestures that open the pages
tools/analyze_ipa.py        IPA analyser (stdlib-only Python)
docs/ANALYSIS.md            findings + hook decision table
```

## Credits

The general approach (inject into a decrypted IPA, hook the player's audio
output) is inspired by [spoti.pw](https://github.com/skopevoj/spoti.pw). No code
was taken from it: that project is PolyForm Strict licensed.
