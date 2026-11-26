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
| ••• menu row | **working**: "Playback Controls" and "Karaoke Mode" as the first options of the full-screen player's ••• menu |
| Sing (AI vocal removal) | **working**, in ••• → Karaoke Mode: Spleeter 2-stems or UVR MDX-Net 9482 (Neural Engine, 49 ms per 5.9 s on an iPhone 13) |
| AutoMix | **new, untested on a phone**: per-pair crossfades from Apple Music's analysis and Deezit's own, in ••• → Playback Controls |
| Player extras | **new, untested on a phone**: swipe left or right to delete in Up next; artist · album opens a Go to artist / album menu |
| Lyrics | **new, untested on a phone**: Karaoke Mode button (tap: lead vocals off; hold: options); word-by-word highlight (estimated within Deezer's line timing) |
| Animated cover in the player | **new, untested on a phone**: Apple Music motion cover inside the player's cover square |
| Debug panel + in-app log | done (three-finger double tap) |
| Runtime probes | logs which player / settings screens appear, to settle the analysis' open questions |
| DSP C core (`DZDSP.c`) | not used by the AVAudioEngine backend (Apple's units do the work); kept for other backends |
| CI build | `.github/workflows/build.yml`: `Deezit.dylib` + rootless `.deb` |

The audio hook has a kill switch: if playback breaks, open the debug panel,
tap **⋯ → Turn audio hook off**, and relaunch Deezer. Deezit then leaves
Deezer's audio completely alone.

## Opening the controls

**Full-screen player → ••• → Playback Controls** opens the sound controls
(Slowed + Reverb, AutoMix, presets, speed, reverb) as a half-height sheet; **••• → Karaoke
Mode**, the row under it, opens Sing (vocals, backing vocals, strength, model)
the same way. Both sheets open
over the player.

Gestures, anywhere in Deezer:

| Gesture | Opens |
|---|---|
| **Deezer → Settings → Deezit** (card under Log out) or **three-finger hold** | Deezit Settings: Sing model download, model lab (MDX-Net), native ••• menu, animated covers, lyrics |
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
2. **••• → Karaoke Mode → Vocals** sets how much singing is left
   (100% = untouched); **Backing vocals** keeps the harmonies that are
   spread left / right and removes only the centred lead; **Strength**
   (Gentle / Normal / Strong) sets how sure the model must be before a sound
   counts as voice, so Gentle and Normal leave instruments it only
   half-mistakes for singing (violins, claps, synth leads) alone. Changes
   are heard after about 3 seconds.
3. Optional: **Settings → Model lab → MDX-Net → Download** (about 14 MB), then
   **••• → Karaoke Mode → Model → MDX-Net**. UVR's MDX-Net 9482 sees the
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

## AutoMix

**••• → Playback Controls → AutoMix** plans each crossfade from the two songs.
What it builds on, from the AutoMix probe on Deezer 11.27.0:

- Deezer plays the next song on a second player node. With a crossfade of D
  seconds it starts that song from 0:00 and fades the current one out, D
  seconds before its end. Skips are hard cuts.
- Deezer asks `-[DZRAudioPlayer crossFadeDurationForPlayable:followedByPlayable:]`
  for each pair (current, next) when a song starts, when the queue changes
  and when the setting changes.

AutoMix answers that question. B's first downbeat lands on A's bar line where
A's music winds down, kept between 1 and 12 s. It knows songs from:

1. **Apple Music's audio analysis**, looked up by ISRC (bars, beats, fade-out;
   web-player token, like the lock-screen covers). In the probe it had 4 of 5
   songs.
2. **Deezit's own analysis** (`DZSongAnalysis.m`): a song that plays from its
   start to its end without a seek is analysed as Deezer decodes it (in
   `-[DZRAudioTrackController readAudioIntoBuffer:frames:endReached:]`, about
   3 s ahead of playback) and remembered in `Library/Application
   Support/Deezit/AutoMix/`. It finds where the music starts and winds down
   (level against the song's typical loudness), the tempo (onset
   autocorrelation) and the beats (dynamic programming, after D. Ellis 2007),
   and groups beats into bars by the low end.

**Transitions** (`DZTransitionFX.c`): Deezit processes the buffers Deezer
schedules on the two songs' player nodes (about 3 s ahead, by song position),
so a change is more than a volume crossfade. Per pair it picks:

- **bass swap** when the tempos are within 10 % (half / double time counts;
  6 % with tempo matching off): B comes in 2-8 bars early (at most about
  17 s) without bass, then
  on A's bar line A's bass is pulled out and B's drops in, and A fades out
  over 2 bars;
- **echo out** when A has bars: A's last beats repeat on a ¾-beat echo with
  darkening repeats and A drops out on the bar B's first downbeat lands on;
- **filter fade** otherwise: A closes into a low-pass, B opens from a
  high-pass.

A mixes out on the start of a phrase (every 8th bar from its first) in the
32 s before its music winds down, so its last part may be skipped; it then
plays on silently to its end. Overlaps go up to 50 s.

**Tempo matching** (`DZTimeStretch.c`, Settings → AutoMix → Tempo matching,
on by default): while the two overlap, B plays at A's tempo, with its key
kept (WSOLA: 46 ms frames, each moved by up to ±12 ms to line up with the
last). Once A is gone, B eases back to its own tempo over 4-8 bars. B's
stretched buffers are scheduled in place of Deezer's. Deezer's clock for a
song adds up the frames of the buffers it scheduled
(`-[DZRAudioTrackController outputChannelDidPlay:]`), so B's lyrics and
progress stay with B. `tests/dsp_test.c` checks the stretcher and the effects
in CI.

**Timing:** Deezer starts B when A's remaining time drops below the
crossfade, checked as each 83 ms buffer of A finishes. Deezit tells Deezer
0.12 s more than its plan and starts B with the few ms of silence that put
its downbeat on A's bar line. A started somewhere else (a seek into the
change) gets Deezer's own crossfade.

**A's level:** Deezer fades a song out through its player node's volume
(`-audioMixingVolumeDidUpdate:` → `-setVolume:`). During a transition Deezit
keeps A's node at the volume it had and the transition shapes A's level.

B's part only runs on a B that came in with the crossfade (never after a
skip). Deezer asks about the next pair as soon as B starts, so the running
transition is kept apart from the next one planned.

Where the music ends comes from Deezit's own analysis when there is one (it
measured Deezer's file; in the probe Apple's fade-out time was about 2 s early
for one song), bars from Apple when its release has the same length. A pair
with nothing known about the first song keeps Deezer's crossfade setting.
Album tracks in order are mixed like any pair, unless one runs straight into
the next (its music goes on to its last second and the next starts at once,
as on a live album): those stay gapless. The log shows each plan
("automix:"), each change as it starts (where A was against the plan), B's
tempo ("comes in … ms ahead, padded, at …% speed", "back at its own tempo")
and the volume hold ("holding … at volume …"), and, for songs both know,
Deezit's analysis next to Apple's.

## Player and lyrics extras

- **Up next:** Deezer offers Delete on a swipe to the left only in its own
  delete mode. Deezit lets every row Deezer can delete (the queue is
  editable and it isn't the song playing) be swiped at any time, to the left
  or to the right (`DZPlayerExtras.x`). iOS turns the table's editing on
  while a row is swiped, so the delete style doesn't depend on it. Each time
  Up next appears the log says whether the queue is editable, whether the
  next row offers Delete and which pan gestures sit above the table; a
  swipe logs "swipe opened" / "swipe closed".
- **Artist · album line:** opens a native menu, "Go to <artist>" (each
  artist when there are several) and "Go to <album>", through Deezer's own
  `dzrGoToArtist:` / `dzrGoToAlbum:`.
- **Player buttons** (`DZPlayerButtons.x`): Slowed + Reverb, Karaoke Mode
  and AutoMix next to Share, in Deezer's own `DZRPlayerButton`, with icons
  from Deezer's own icon set, Tempo (`Tempo_Tempo.bundle` in the app, loaded
  at runtime): `gauge`, `microphoneMusic`, `noteDouble`, filled when on
  (`microphoneMusicFill`, `noteDoubleFill`; Tempo has no filled gauge, so it's
  cut out of a solid disc). SF Symbols if Tempo isn't found. The row is spaced
  evenly. Tap: on / off; touch and hold: the feature's sheet.
- **Karaoke Mode button** in the lyrics, bottom left (`DZLyrics.x`): a
  "Karaoke Mode" pill that shrinks to a round icon. Tap: lead vocals to 0 %
  with the backing vocals kept; tap again to undo. Touch and hold: the
  Karaoke Mode sheet.
- **Word by word:** Deezer's lyrics are timed per line only
  (`LyricsSynchronizedLineFields { lrcTimestamp line lineTranslated
  milliseconds duration }`, read from its GraphQL reply). Deezit spreads each
  line's time over its words by syllables and lights them up with a soft
  wipe. It's close, not exact. Settings → Lyrics → Word by word.
- **Animated cover in the player** (`DZPlayerArtwork.x`): the album's Apple
  Music motion cover plays muted inside the cover square, found and cached
  like the lock-screen one. Settings → Animated covers → Player.
- **Native ••• menu** (`DZPlayerMenu.x`, Settings → Player): the ••• opens an
  iOS menu. When it opens, Deezit asks Deezer for its sheet, takes it instead
  of showing it and reads its rows (`actionText`, `actionImage`,
  `displaysChevron`). Rows with a chevron (Add to Playlist, Share…) present
  Deezer's sheet and select the row in it. Other rows run in the unseen sheet:
  anything they present is shown from the player. The song's artists replace
  the sheet's header.

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
DZAutoMix.x                 AutoMix: plans Deezer's crossfade per pair, learns songs as they're decoded
DZTransitionFX.c            AutoMix transitions: bass swap, echo out, filter fade
DZTimeStretch.c             AutoMix tempo matching: WSOLA time-stretch of the song coming in
tests/dsp_test.c            CI checks of the two above
DZSongAnalysis.*            song analysis (beats, bars, music start / end), Apple's analysis, the planner
DZBufferProbe.x             logs how Deezer schedules audio (what sized the Sing pipeline)
DZProbes.x                  runtime probes (which player / settings screens appear)
DZPlayerMenu.x              "Playback Controls" row in the player's ••• menu
DZPlayerExtras.x            Up next swipe delete, artist · album menu
DZPlayerArtwork.x           animated cover inside the player's cover square
DZLyrics.x                  lyrics: Karaoke Mode button, word-by-word highlight
DZDeezerSettings.x          "Deezit" card in Deezer's own Settings page
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
