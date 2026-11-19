# Deezer 11.27.0 IPA analysis

> **Status: not run yet.** The IPA (`D:\Downloads\Deezer_v11.27.0-AppAssassin`)
> lives on the Windows machine and was not reachable from the cloud session
> that set up this repo, so **nothing below is a finding yet**. Every
> "Findings" field is a blank to fill from the analyser's report. Nothing about
> Deezer's internals has been guessed or filled in from memory.

## How to run the analysis

`tools/analyze_ipa.py` uses only the Python standard library (3.8+). It takes
the `.ipa` (a zip, with or without the extension), an extracted folder, a
`Payload` folder or the `.app` itself:

```bat
py tools\analyze_ipa.py "D:\Downloads\Deezer_v11.27.0-AppAssassin" -o docs\analysis\report.md --classes docs\analysis\classes.txt
```

Commit `docs/analysis/report.md`. `classes.txt` (every class name) is
gitignored because it is large. Share it in the session instead if a class
can't be found from the report.

What the script does:

| Question | How it is answered |
|---|---|
| Decrypted? | `cryptid` in `LC_ENCRYPTION_INFO(_64)` of the main binary, every `Frameworks/*` binary and every app extension. Any non-zero value means a bad dump. |
| UIKit / SwiftUI / React Native / Flutter | RN: `*.jsbundle` / Hermes bytecode magic, `React`/`hermes` frameworks, `RCT*` classes. Flutter: `Flutter.framework` / `App.framework`. UIKit: classes whose superclass chain (walked through `__objc_classlist` and resolved across chained-fixup binds) reaches `UIViewController` / `UIView` / cells. SwiftUI: imported `$s7SwiftUI…` symbols, `UIHostingController` references, Swift structs named `*View`/`*Screen`. |
| Now Playing / artwork classes | ObjC-visible classes (with superclass chain) and Swift nominal types (`__swift5_types`) matching player/now-playing/artwork/cover/queue/lyrics/settings keywords, per binary. |
| Audio path | Imported symbols per binary: AudioUnit/AUGraph, AudioQueue, AVAudioEngine nodes, AVPlayer + `MTAudioProcessingTap`, `AVSampleBufferAudioRenderer`, AudioConverter/AudioFileStream, plus string hints for bundled decoders (FLAC, mpg123, ffmpeg …). |

The parser was checked against arm64 and arm64e iOS test binaries built with
clang/lld: chained fixups and classic bind opcodes, a `cryptid` 1 copy, an external
`UIViewController` superclass, and zip and folder input. It has not run on a
real Swift binary yet, so treat the Swift-type section as best effort.

## Findings

### 1. Decryption

- Main binary `cryptid`: _pending_
- Frameworks / extensions `cryptid`: _pending_
- Bundle id / executable name: _pending_ (the skeleton assumes
  `com.deezer.Deezer` / `Deezer` in `Deezit.plist` and the Makefile; fix them if
  the report disagrees. Neither matters for cyan injection, since the dylib
  loads into whatever app it is injected into)

### 2. UI technology

- Verdict: _pending_
- Evidence: _pending_

### 3. Now Playing / artwork classes

- Full-screen player VC: _pending_
- Mini player: _pending_
- Artwork view: _pending_
- Settings screen (for the Deezit entry row): _pending_

### 4. Audio playback path

- Binary that owns playback (main vs which framework): _pending_
- Output API: _pending_
- Decoder: _pending_

## What each audio finding means for the hook

v1 wants speed with pitch following (varispeed) plus reverb, at the audio
output. The backend is chosen from section 4:

| If the player uses | Speed (pitch follows) | Reverb | Hook mechanism | Notes |
|---|---|---|---|---|
| **AudioUnit RemoteIO / AUGraph** | Wrap the output render callback. Pull `speed × N` source frames from Deezer's callback and resample them to N | Process the resampled buffer | fishhook `AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)` / `AUGraphSetNodeInputCallback` in Deezer's own images | The true output level, and it works whatever the decoder is. The player's clock drifts from the displayed position (expected for varispeed). |
| **AudioQueue** | `kAudioQueueProperty_EnableTimePitch` + `kAudioQueueTimePitchAlgorithm_Varispeed` + `kAudioQueueParam_PlayRate` | Wrap the output callback and process buffers before `AudioQueueEnqueueBuffer` | fishhook `AudioQueueNewOutput*` / `AudioQueueEnqueueBuffer` | Rate is native. Only reverb needs DSP. |
| **AVPlayer / AVQueuePlayer** | `item.audioTimePitchAlgorithm = Varispeed` + `player.rate` | `MTAudioProcessingTap` on `item.audioMix` | Logos `%hook AVPlayer` / `AVPlayerItem` (ObjC, no fishhook) | Deezer must not reset `rate` to 1 on every tick. Re-apply it on `-setRate:` if it does. |
| **AVAudioEngine** | `AVAudioUnitVarispeed` | `AVAudioUnitReverb` or a DSP node | Hook `-[AVAudioEngine connect:to:format:]` / `-prepare` and splice the nodes in before `mainMixerNode` | Built-in units, so very little custom DSP. |
| **AVSampleBufferAudioRenderer** | `renderer.audioTimePitchAlgorithm = Varispeed` + `synchronizer.rate` | Process `CMSampleBuffer`s before `-enqueueSampleBuffer:` | Logos hooks on the renderer / synchronizer | |

fishhook caveat: it rebinds imports only in images it can patch, which means
Deezer's binary and its embedded frameworks, not calls Apple frameworks make
internally. That is enough when Deezer itself calls `AudioUnitSetProperty` /
`AudioQueueNewOutput`, which the "binary that owns playback" row confirms.

## Code that is waiting on this

- `DZAudioHook.m`: `kDZChosenBackend` (currently `None`, so the skeleton never
  touches audio)
- `DZDSP.c`: the varispeed resampler and reverb (currently pass-through)
- `DZSettingsEntry.m`: the Settings-row and Now Playing entry points (currently
  a temporary three-finger long press)
