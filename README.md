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
| Sing (AI vocal removal) | **working** with Spleeter 2-stems; UVR MDX-Net 9482 as a second model (Neural Engine, 49 ms per 5.9 s on an iPhone 13; new, not yet heard on a device) |
| Debug panel + in-app log | done (three-finger double tap) |
| Runtime probes | logs which player / settings screens appear, to settle the analysis' open questions |
| DSP C core (`DZDSP.c`) | not used by the AVAudioEngine backend (Apple's units do the work); kept for other backends |
| CI build | `.github/workflows/build.yml`: `Deezit.dylib` + rootless `.deb` |

The audio hook has a kill switch: if playback breaks, open the debug panel,
tap **⋯ → Turn audio hook off**, and relaunch Deezer. Deezit then leaves
Deezer's audio completely alone.

## Opening the controls

**Full-screen player → ••• → Playback Controls** opens the sound controls
(Slowed + Reverb, Sing vocals, presets, speed, reverb) as a half-height sheet
over the player.

Gestures, anywhere in Deezer:

| Gesture | Opens |
|---|---|
| **Three-finger hold** | Deezit Settings: Sing model download, model lab (MDX-Net), lock-screen covers |
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

## Sing (AI vocal removal)

1. **Settings** (three-finger hold) → **Sing → Download** fetches the vocal
   model once (about 40 MB, from this repo's `vocal-model-v1` release) and
   prepares it for the phone's Neural Engine.
2. **Playback Controls → Sing → Vocals** sets how much singing is left
   (100% = untouched); **Backing vocals** keeps the harmonies that are
   spread left / right and removes only the centred lead; **Strength**
   (Gentle / Normal / Strong) sets how sure the model must be before a sound
   counts as voice, so Gentle and Normal leave instruments it only
   half-mistakes for singing (violins, claps, synth leads) alone. Changes
   are heard after about 3 seconds.
3. Optional: **Settings → Model lab → MDX-Net → Download** (about 14 MB), then
   **Playback Controls → Sing → Model → MDX-Net**. UVR's MDX-Net 9482 sees the
   whole spectrum (to ~22 kHz) and estimates the vocals themselves, so more of
   the instruments and the highs survive. Switching models restarts Sing for a
   moment, like the start of a track.

The model is **Spleeter 2-stems** (Deezer Research, MIT licence), converted
by `tools/vocal_model/convert.py` in `.github/workflows/vocal-model.yml`: the
TensorFlow weights are loaded into a PyTorch copy of Spleeter's U-Nets,
checked layer by layer against a Keras build, and turned into one fp16
Core ML file. Audio never leaves the phone.

How it plays (`DZSeparator.m`, `DZSing.x`): Deezer schedules 83 ms buffers and
keeps 3 s queued (`DZBufferProbe.x`). With Sing on, Deezit holds ~0.8 s of
them, runs a streaming STFT (4096 / 1024) and asks the model for the vocal
mask every 32 frames, seeing 80 frames of the past and 16 of the future
(~0.37 s look-ahead, still inside Deezer's queue). Above the model's ~11 kHz
range the mask is its mean over ~8.3-11 kHz, so sibilants go with the voice.
The vocal part (mask * mix) is split into centre (lead) and sides (backing):
the lead is removed by the Vocals amount, the sides by that times
(1 - Backing vocals). The result is inverse-STFT'd with overlap-add, written
back into Deezer's buffers and scheduled in order. Core ML runs it on the
Neural Engine + CPU only (no GPU, which iOS blocks in the background). Nothing is delayed, so the position and lyrics stay in sync.
Buffers pass through untouched until the player is well fed; if its queue
ever runs low, Deezit lets everything through unprocessed for the rest of
that track. The debug panel's `sing:` line shows what it is doing.

### MDX-Net (model lab)

Settings → **Model lab** downloads **UVR MDX-Net 9482** (Ultimate Vocal
Remover, by Anjok07, MIT licence). `tools/vocal_model/fetch_mdx.py` in
`.github/workflows/vocal-model-mdx.yml` converts UVR's `.onnx` itself
(onnx2torch -> Core ML, fp16) and checks it against ONNX Runtime on a
realistic spectrogram. Core ML mis-converted its 2x2 stride-2 convolutions
(also in the public Core ML port), so CI rewrites them in an equivalent form
first (pixel-unshuffle + 1x1 conv, 1x1 conv + pixel-shuffle); the fp32
conversion then matches ONNX at 107.6 dB, fp16 at 28.3 dB, far under the
model's own separation error. UVR's Voc FT model loses too much in fp16
(15 dB) and is skipped.

It takes the same 4096 / 1024 STFT as complex numbers, all 2048 bins, in a
256-frame window (208 past, the same 32 new and 16 ahead as Spleeter), and
returns the vocals' spectrum; their share of each bin, |vocals| / |mix|, is
the mask the Vocals / Backing vocals / Strength controls work on. Run
benchmark (iPhone 13): 49 ms per run, 24 MB, 100% Neural Engine.

**HT-Demucs** (Demucs `htdemucs_ft` vocals, `convert_htdemucs.py`) was tried
first: on an iPhone 13 it ran entirely on the CPU, 1.1 s per 2.6 s window and
1.3 GB, too slow for live Sing.

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
DZAudioHook.x               AVAudioEngine backend: splices varispeed + reverb before the output node
DZSing.x / DZSeparator.*    "Sing": AI vocal removal on Deezer's buffers as they are scheduled
DZVocalModel.*              vocal model download / compile / load
DZDemucsModel.*             model lab: MDX-Net download, benchmark, playback loading
tools/vocal_model/          Spleeter / MDX-Net / HT-Demucs -> Core ML (vocal-model*.yml)
DZBufferProbe.x             logs how Deezer schedules audio (what sized the Sing pipeline)
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

Sing uses [Spleeter](https://github.com/deezer/spleeter)'s pretrained
2-stems model by Deezer Research (MIT licence), converted to Core ML; the
PyTorch port in `tools/vocal_model/convert.py` was written for Deezit.
Its MDX-Net option is UVR's [MDX-Net 9482](https://github.com/TRvlvr/model_repo)
vocal model by Anjok07 (Ultimate Vocal Remover, MIT licence), on KUIELab's
MDX-Net architecture, converted to Core ML in Deezit's CI.

The Apple Music lookup (iTunes Search matching, web-player token, catalog
`editorialVideo`) is adapted from
[twenty-one-reborn](https://github.com/pisknk/twenty-one-reborn). The idea of
using iOS 26's animated now-playing artwork from inside the app came from
spoti.pw; none of its code was used.

The general approach (inject into a decrypted IPA, hook the player's audio
output) is inspired by [spoti.pw](https://github.com/skopevoj/spoti.pw). No code
was taken from it: that project is PolyForm Strict licensed.
