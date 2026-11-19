# Deezer 11.27.0 IPA analysis

> **Status: analysis run (2026-11-19)** on the decrypted IPA
> (`D:\Downloads\Deezer_v11.27.0-AppAssassin`, extracted folder, Deezer
> 11.27.0 build 11.27.0.4). Every finding below comes from
> [`analysis/report.md`](analysis/report.md) or the gitignored `classes.txt`
> dump the same run produces. Nothing was filled in from memory. Where static
> analysis can't settle something, the text says so and leaves it as a
> runtime check. **No hook has been implemented yet.**

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

The parser was first checked against arm64 and arm64e iOS test binaries built
with clang/lld: chained fixups and classic bind opcodes, a `cryptid` 1 copy, an
external `UIViewController` superclass, and zip and folder input.

### Fixes after the first run on the real Deezer binary

The first run didn't crash, but it misread these things, and all of them are
now fixed:

1. **Swift type paths.** About 1,575 of the main binary's 11,349 Swift
   types came out without their module or parent (`struct Account` instead of
   `Deezer.….Account`). The walk stopped at anonymous (`private`/`fileprivate`)
   contexts (988), at parents reached through an indirect (GOT) pointer
   (552) and at extension contexts (35). Anonymous contexts are now
   transparent, indirect pointers are followed (to a local descriptor or to the
   imported descriptor symbol, e.g. `SwiftUI.EnvironmentValues.__Key_…`), and an
   extension resolves to the type it extends through its symbolic-reference
   mangled name. Every Swift type in the main binary now has a full path.
2. **`__swift5_types2` was ignored.** The section exists (21 descriptors)
   and is now read too.
3. **Swift superclasses.** A Swift class with a generic superclass has no
   static ObjC class object, so the ObjC walk gave it no chain
   (`Deezer.SettingsHostingController` had none). The superclass is now read
   from the Swift class descriptor (generic arguments dropped), so it shows
   as `Deezer.SettingsHostingController : SwiftUI.UIHostingController`. The ObjC
   chain still wins where both exist.
4. **Garbage "class names".** `__objc_classname` also stores ivar-layout byte
   strings (`\x01\x11…`), and 339 of them were listed as classes. Only
   identifier-shaped names are kept now.
5. **Report coverage.** The capped candidate lists (400 ObjC / 300 Swift)
   cut off key types such as `BusinessViews.SettingsRootPage` and
   `CorePlayback.DZRAudioRendererAVAudioEngineErrorType`. Generated
   `ApolloGenerated.*` / `TrackingPlan.*` / `XPlayerApollo*` types and
   `CodingKeys` (hundreds of keyword hits, none UI or audio) are now left out
   of the report, though not of `classes.txt`, and the cap is 1,500. Nothing is
   truncated now.
6. **Audio signatures.** Added `AudioQueueNewInput*` (so a recording-only
   queue isn't mistaken for playback), `AVAudioPCMBuffer`,
   `AVAudioEngineConfigurationChangeNotification`, `AVPlayerLayer`, more
   AudioToolbox decode calls, and the AVAudioEngine graph/scheduling selectors.

## Findings

### 1. Decryption

- Main binary `cryptid`: **0** (`Deezer`, thin arm64, 83.5 MB)
- Frameworks / extensions `cryptid`: **0 for all of them**: 24 entries under
  `Frameworks/` (23 frameworks + `libswiftCompatibilitySpan.dylib`; the dylib,
  the FBSDK*, FBAEMKit and GoogleInteractiveMediaAds binaries are fat, read as
  arm64) and
  5 app extensions (Notification Service, Intents, Widget, iMessage,
  Notification Content). Report verdict: "all binaries decrypted (cryptid 0)".
- Bundle id / executable name: **`com.deezer.Deezer` / `Deezer`**, which matches
  `Deezit.plist` and `INSTALL_TARGET_PROCESSES`, so nothing changed.
- Also from `Info.plist`: `MinimumOSVersion` 18.5, `UIBackgroundModes`
  `audio, fetch, remote-notification`, scene manifest present,
  `UIMainStoryboardFile` `Main`.
- Note: 9 framework binaries are ~35 KB stubs (0.0 MB in the report) with no
  classes and no imports: `XPlayer`, `YapDatabase`, `BrazeKit`,
  `CocoaLumberjack`, `FirebaseAnalytics`, `GoogleAppMeasurement`,
  `GoogleAppMeasurementIdentitySupport`, `GoogleTagManager`,
  `GoogleAdsOnDeviceConversion`. Their code is in the main binary instead: the
  `XPlayer*` ObjC classes and the `BrazeKit.*` Swift types are listed under
  `Deezer`.

### 2. UI technology

- Verdict: **native UIKit app with SwiftUI screens mixed in. Not React Native,
  not Flutter.** The player, the mini player and most legacy pages are UIKit.
  Newer screens, including Settings, are SwiftUI hosted in
  `UIHostingController`s.
- Evidence (report, "UI framework"):
  - React Native: no `.jsbundle`/Hermes bytecode, no RN frameworks, no `RCT*`
    classes. Flutter: no `Flutter.framework`/`App.framework`, no Flutter classes.
  - Main binary: 5,715 ObjC-visible classes, **429 resolved UIKit subclasses**,
    159 `*ViewController` classes, 199 nibs/storyboards, `Main` storyboard.
  - Main binary: **1,928 imported SwiftUI symbols**, **15 `UIHostingController`
    references**, 369 Swift structs named `*View/*Screen/*Page`.
  - The analyser's heuristic says "SwiftUI-heavy (381 structs vs 204 VCs)", but
    it counts every struct whose name ends in `View`, so it overstates. The class
    chains in section 3 show the player surfaces are UIKit (`UIViewController` /
    `UIView` subclasses), so a UIKit-first reading fits better.

### 3. Now Playing / artwork classes

All of these are in the **main `Deezer` binary**. Chains are as the report
prints them.

- Full-screen player VC (two candidates; which one is the on-screen root has
  to be confirmed at runtime):
  - `DZRPlayerViewController : CommonController > UIViewController`
  - `DZRPlayerMainViewController : CommonController > UIViewController`
    (with `Deezer.PlayerMainViewControllerVolumeHandler : NSObject` and the
    `Deezer.PlayerMainViewControllerVolumeHandling` protocol)
  - also `DZRPlayerOverlayViewController : UIViewController`,
    `DZRPlayerTrackActionsController : NSObject`, `Deezer.PlayerColorView : UIView`
  - existing speed UI: `Deezer.PlaybackSpeedSelectionViewController : UIViewController`
    (ObjC protocol `Deezer.PlaybackSpeedSelectionViewControllerDelegate`), and
    `DZRPlaybackSpeedButton : UIButton` (Swift `Deezer.PlaybackSpeedButton`)
  - queue: `BusinessViews.QueueCollectionViewController : UIViewController`,
    `DZRQueueListViewController : DZRCommonTableViewController > CommonController > UIViewController`
- Mini player:
  - `Deezer.MiniPlayerViewController : UIViewController`
  - `Deezer.MiniPlayerView : UIView`, `Deezer.MiniPlayerTrackInfoView : UIView`,
    `Deezer.MiniPlayerTrackStripView : UIView`,
    `Deezer.MiniPlayerSwipeController : NSObject`
- Artwork view:
  - full player: `DZRPlayerCoverCollectionViewController : UIViewController`
    with `DZRPlayerCoverCollectionViewCell : UICollectionViewCell`,
    `DZRPlayerCoverCollectionViewFitFlowLayout : UICollectionViewFlowLayout`
    and `DZRPlayerCoverView : UIView`
  - mini player: `Deezer.MiniPlayerCoverView : UIView`
  - shared design-system view: `Tempo.CoverView : UIView`
- Settings screen (for the Deezit entry row):
  - host: **`Deezer.SettingsHostingController : SwiftUI.UIHostingController`**
  - content (SwiftUI structs, `BusinessViews` module):
    `BusinessViews.SettingsRootPage`, `BusinessViews.SettingsPage`, and
    sub-pages such as `SettingsMusicPage`, `SettingsDisplayPage`,
    `SettingsAccountPage`. Navigation goes through the `BusinessViews.SettingsPath`
    enum (cases include `Music`, `AudioQuality`, `DeveloperMenu`, …). Existing
    audio controls there include `BusinessViews.SettingsCrossFadeDurationSlider`
    and `SettingsAudioQualityVisualizer`.
  - The settings list is SwiftUI, so there's no `UITableView` data source to
    hook for an extra row. The practical entry point is the UIKit host
    (`Deezer.SettingsHostingController`, e.g. a navigation-bar item added in
    `viewDidLoad`/`viewWillAppear:`). Which method to hook will be decided when
    the entry is implemented. Legacy UIKit settings VCs
    (`DZRDeveloperSettingsViewController`, `Deezer.DeveloperAdsSettingsViewController`, …)
    are developer menus, not the user-facing screen.

### 4. Audio playback path

- Binary that owns playback: **the main `Deezer` binary.** All the
  playback-engine imports are there (below). It also holds the `CorePlayback.*`
  Swift module, `CommonAudio.*`, the `DZRAudio*` ObjC classes and the `XPlayer*`
  player-state classes. `Frameworks/XPlayer.framework/XPlayer` is a stub with
  no imports. No other framework imports AVAudioEngine. AVPlayer appears only
  in ad/social SDKs (IMA, InAppStory, Waze, FBSDKShareKit). RiveRuntime is the
  only framework with AudioUnit/RemoteIO imports, and that is the Rive
  animation runtime.
- Output API: **AVAudioEngine.**
  - imports: `AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioMixerNode`,
    `AVAudioUnitTimePitch`, `AVAudioUnitEQ`, `AVAudioPCMBuffer`,
    `AVAudioEngineConfigurationChangeNotification`
  - selectors: `attachNode:`, `detachNode:`, `connect:to:format:`,
    `disconnectNodeInput:`, `mainMixerNode`, `outputNode`,
    `startAndReturnError:`, `scheduleBuffer:completionHandler:`,
    `scheduleBuffer:atTime:options:completionHandler:`,
    `installTapOnBus:bufferSize:format:block:`. No manual-rendering selectors, so
    the engine drives the hardware output.
  - classes: `CorePlayback.AudioRenderer`, `CorePlayback.AudioOutputChannel`,
    `CorePlayback.AudioEngineModifierNodes : NSObject`,
    `CorePlayback.DZRAudioRendererAVAudioEngineErrorType`,
    `CorePlayback.DZRAudioRendererConfiguration`,
    `CorePlayback.AudioMixingController : NSObject` / `DZRAudioMixingController`,
    `DZREqualizerAVAudioEngine : NSObject`, `DZRParametricEqualizer`,
    `CorePlayback.DZRGaplessMonitor`. String hints: `crossfade`, `gapless`,
    `normaliz`, `equalizer`.
  - Not the output path:
    - **AudioQueue**: the only queue constructor imported is
      `AudioQueueNewInput` (a recording queue). There is no
      `AudioQueueNewOutput*`. (The report also lists an `ACRCloudBlockingQueue`
      class.)
    - **AVPlayer**: `AVPlayer`/`AVPlayerItem`/`AVURLAsset`/`AVPlayerLayer` are
      imported, but there is no `AVQueuePlayer`, `AVMutableAudioMix` or
      `MTAudioProcessingTap`. The only non-audio player VCs the report lists
      are video ones (`Deezer.VASTVideoPlayerViewController`,
      `Deezer.VideoAdPlayerViewController`), which fits `AVPlayerLayer`.
    - **AVSampleBufferAudioRenderer** and **RemoteIO/AUGraph**: not imported by
      the main binary.
  - Deezer's own speed feature most likely goes through this engine:
    `AVAudioUnitTimePitch` is imported and there's a renderer speed action
    `XPlayerRendererActionSetPlaybackSpeed`. `setPitch:` is **not** among the
    selectors and `AVAudioUnitVarispeed` isn't imported, so Deezer changes
    speed with pitch held constant. It never uses varispeed.
- Decoder: **Apple AudioToolbox, in Deezer's own code.** Imports
  `AudioFileStreamOpen`/`AudioFileStreamParseBytes`, `AudioFileOpenWithCallbacks`,
  `ExtAudioFileWrapAudioFileID`/`ExtAudioFileRead`, `AudioConverterSetProperty`,
  `AVAudioConverter`, `AVAssetReader`. Classes: `CommonAudio.CoreAudioDecoder`,
  `CommonAudio.CoreAudioPacketObject`, `CommonAudio.StereoBufferList`,
  `CorePlayback.AudioDecoder` (ObjC name `AudioDecoder`), `DZRAVAudioFileConverter`.
  Media is decrypted first (`CommonAudioCrypto.ProtectedFile`, `CryptoTools`).
  None of the bundled-decoder string hints (libFLAC, mpg123, minimp3, dr_*,
  ffmpeg, opus, vorbis …) matched.

## Recommended backend: AVAudioEngine

Use the **AVAudioEngine** row of the table below: `AVAudioUnitVarispeed` for
speed with pitch following, `AVAudioUnitReverb` for the reverb, both spliced
into Deezer's own engine with Logos ObjC hooks on `AVAudioEngine`.

Why:

- It's the only output path the report supports. The engine, player node,
  mixer and scheduling selectors are all in the main binary, and every other
  row is ruled out above (AudioQueue is input-only, AVPlayer is
  video/ads-only, no RemoteIO, no sample-buffer renderer).
- Every call we need goes through ObjC methods on `AVAudioEngine`, so it's
  plain Logos `%hook` (the `internal` generator the Makefile already uses).
  **No fishhook needed.**
- Varispeed and reverb are built-in Apple units, so `DZDSP.c` doesn't need a
  hand-written resampler or reverb for v1. The reverb presets map onto
  `AVAudioUnitReverbPreset`, and the mix onto `wetDryMix`.
- Varispeed is the right effect for "slowed". Deezer's own speed feature uses
  `AVAudioUnitTimePitch` with no pitch change, which is the opposite of slowed.
  Deezit's varispeed has to stack with Deezer's speed setting, not replace it.

Where to splice (from the report's facts; to confirm at runtime before writing
the hook):

- Hook `-[AVAudioEngine connect:to:format:]` and `-startAndReturnError:`.
  Deezer builds its graph with `attachNode:` / `connect:to:format:` and has
  crossfade/mixing classes (`AudioMixingController`), so more than one source
  can feed the mixer. Splicing **between `mainMixerNode` and `outputNode`**
  (mixer → varispeed → reverb → output) catches every source in one place.
  Splicing in front of each player node would miss sources.
- Deezer imports `AVAudioEngineConfigurationChangeNotification` and uses
  `detachNode:` / `disconnectNodeInput:`, so expect it to rebuild the graph (route
  changes, crossfade). The splice must be idempotent: re-check after every
  `connect:` and `start`, and never attach our nodes twice.
- Displayed position and duration drift under varispeed. Expected, as the
  table notes.

Open questions for runtime (can't be settled statically): which of
`DZRPlayerViewController` / `DZRPlayerMainViewController` is the full-screen
root; whether Deezer ever connects `mainMixerNode → outputNode` itself or
leaves it implicit; and how `CorePlayback.AudioEngineModifierNodes` (Deezer's
own EQ/normalisation node chain, going by its name) sits in the graph.

### Answered on device (Deezit 0.1.0+4, Deezer 11.27.0, iOS 27.0.1)

From the debug-panel log (probes + engine graph dump):

- **Full-screen player:** `DZRPlayerViewController` is the root, presented
  modally by `Deezer.TabBarController`. It contains a `UINavigationController`
  whose root is `DZRPlayerMainViewController`, which holds
  `DZRPlayerCoverCollectionViewController` / `DZRPlayerOverlayViewController`
  (cover area, 375x327) and pushes `Deezer.LyricsViewController`. The mini
  player is `Deezer.MiniPlayerViewController` (333x48).
- **Settings:** `Deezer.SettingsHostingController` appears at full height.
- **Audio graph:** a single engine. The implicit `mainMixerNode → outputNode`
  connection is the one spliced (at `start`, 44.1 kHz stereo):

  ```
  output <- Deezit reverb <- Deezit varispeed <- AVAudioMixerNode (main)
           <- AVAudioUnitEQ "AUNBandEQ" <- AVAudioMixerNode
              <- AVAudioPlayerNode (bus 0), AVAudioPlayerNode (bus 1)
  attached: AVAudioMixerNode x2, AVAudioPlayerNode x5, AVAudioUnitEQ,
            AVAudioUnitTimePitch "AUNewTimePitch", AVAudioOutputNode
  ```

  The two player nodes on the inner mixer fit the crossfade classes. The
  TimePitch unit is attached but wasn't connected in the graphs seen.
  Engines seen 1, splices 1, failures 0, and the effect is audible.

### Player ••• menu

Method lists (from `__objc_classlist`) of `DZRPlayerMainViewController` include
`contextMenuButtonItem`, `displayContextMenu:`, `showContextMenuFor:` and
`bottomSheetPresenter` (a `Deezer.BottomSheetPresenter`, with
`present:from:detents:completion:`).

On device (Deezit 0.1.0+5) the menu turned out to be **UIKit, not SwiftUI**:
`Deezer.BottomSheetNavigationViewController` whose root is
`Deezer.TrackContextMenuController : UIViewController`. It has a title area
(two `UILabel`s) above a `UITableView` (40 pt
`Deezer.ContextMenuActionTableViewCell` rows; "Create a group on Shaker" is a
SwiftUI-hosting cell, `AddTrackToMusicTogetherGroupHostingTableViewCell`).
The controller's ObjC method list has the table data source/delegate
(`tableView:numberOfRowsInSection:`, `tableView:cellForRowAtIndexPath:`,
`tableView:didSelectRowAtIndexPath:`, no `numberOfSectionsInTableView:`, so
one section) and a `collectionView` data source for the artists row. The cell
class exposes `setActionText:`, `setActionImage:`, `setActionIllustrable:` and
`setDisplaysChevron:`.

`DZPlayerMenu.x` flags the menu opened from the player's ••• and adds one row
at index 0 through those data-source methods (Deezer's rows are passed
through shifted by one). Row 0 is a real `ContextMenuActionTableViewCell` set up
through its setters, so it matches the other rows.

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

## Code built on this

- `DZAudioHook.x`: the AVAudioEngine backend recommended above. It hooks
  `-connect:to:format:`, `-prepare` and `-startAndReturnError:`, and splices
  `AVAudioUnitVarispeed` + Apple Reverb2 (`'rvb2'`, so room size and damping
  are real parameters) between whatever feeds `outputNode` and the output.
  Every graph edit is in `@try`; on failure, Deezer's own connection is
  restored. The units only bypass when the effect is off. **Not yet tested on a
  device.**
- `DZProbes.x` + the backend's graph log answer the open questions above at
  runtime. The debug panel (three-finger double tap) shows which player /
  settings controllers appear (with parents and presenter) and each engine's
  full graph (`output <- … <- AVAudioPlayerNode`, plus every attached node).
- Kill switch: debug panel → ⋯ → "Turn audio hook off" (`audioHook` pref,
  read at launch). With it off, no `AVAudioEngine` method is hooked.
- Still waiting: the Settings-row and Now Playing entry points
  (`DZSettingsEntry.m`, three-finger hold for now), to be placed once the
  probe log confirms the classes. `DZDSP.c` stays pass-through, because the
  AVAudioEngine backend uses Apple's units instead.
