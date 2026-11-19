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
| IPA analysis tooling (`tools/analyze_ipa.py`) | done, tested on synthetic binaries |
| Analysis of Deezer 11.27.0 | **pending**: see [`docs/ANALYSIS.md`](docs/ANALYSIS.md) |
| Settings page (switch, presets, sliders, reset) | done, saves prefs |
| Prefs → realtime-safe audio params | done |
| Audio hook | scaffold only. The backend is picked from the analysis |
| DSP (varispeed + reverb) | interface only, pass-through for now |
| CI build | `.github/workflows/build.yml` |

Until the audio hook lands, injecting the dylib only adds the settings page.
Deezer's playback is untouched.

## Opening the settings

Temporary: **three-finger long press** anywhere in Deezer. A row in Deezer's
own Settings and a button on Now Playing come once the analysis names those
screens.

## Building

CI builds on every push. Download `Deezit-<version>` from the run's artifacts.

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

Then sideload `Deezer-Deezit.ipa` as usual. Logs: Console.app, filter
`subsystem:com.pisknk.deezit`.

## Layout

```
Tweak.x                     entry point (%ctor)
DZPrefs.*                   NSUserDefaults suite + atomic mirror for the audio thread
DZAudioParams.h             plain-C params struct shared with the DSP
DZPresets.*                 Off / Slowed / Slowed + Reverb / Dreamy / Sped Up / Nightcore
DZDSP.*                     engine-agnostic DSP core (C)
DZAudioHook.*               audio backend selection (RemoteIO / AudioQueue-style / AVPlayer / AVAudioEngine / SampleBuffer)
DZSettingsViewController.*  settings page
DZSettingsEntry.*           how the page is opened
tools/analyze_ipa.py        IPA analyser (stdlib-only Python)
docs/ANALYSIS.md            findings + hook decision table
```

## Credits

The general approach (inject into a decrypted IPA, hook the player's audio
output) is inspired by [spoti.pw](https://github.com/skopevoj/spoti.pw). No code
was taken from it: that project is PolyForm Strict licensed.
