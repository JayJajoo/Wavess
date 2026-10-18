# Wavess — Intelligent Video Editor for iPhone

An on-device, SwiftUI + AVFoundation iPhone app that automatically tightens and
highlights your videos. Point it at a clip and it will:

- 🚗 **Trim still footage** — watch the frame for stretches where almost nothing
  changes (a stopped car, a long static hold) and cut them out, keeping the parts
  where the view is actually moving. **No speech required** — ideal for scenery,
  driving, and b-roll.
- 🎬 **Find highlights** — detect scene/shot changes, score each scene by how much
  is happening, and auto-assemble a shorter "best of" cut you can tweak.
- 🔇 **Remove silence** — for *talking* videos: analyze the audio track and cut the
  quiet gaps, keeping the speech.

Everything runs **locally on the phone** — no network, no accounts, no API keys,
and no FFmpeg. It uses only Apple frameworks (AVFoundation, AVKit, CoreMedia,
CoreGraphics, PhotosUI).

> Why native instead of React Native / Flutter? The popular cross-platform
> FFmpeg wrappers (`ffmpeg-kit-react-native`, `ffmpeg_kit_flutter`) were retired
> in 2025 and are unmaintained. iOS ships first-class on-device media APIs, so
> we get motion/scene/silence analysis and video export with zero third-party
> dependencies.

---

## Requirements

- **Xcode 16 or newer** (the project uses Xcode 16 "file system synchronized"
  groups). On older Xcode, regenerate the project with XcodeGen — see below.
- **iOS 17+** device or simulator.
- An Apple Developer account for signing when running on a physical device
  (free personal team is fine).

## Run it

1. Open the project:
   ```sh
   open Wavess.xcodeproj
   ```
2. Select the **Wavess** scheme and a simulator or your connected iPhone.
3. Set your signing team: select the **Wavess** target → **Signing &
   Capabilities** → choose your Team. (The bundle id defaults to
   `com.wavess.app`; change it if it's taken.)
4. Press **▶︎ Run**.

> **Tip:** the Simulator has no camera roll videos by default. Drag a `.mov`/
> `.mp4` onto the simulator window to add one to Photos, or just run on a real
> device where you already have clips.

### Older Xcode? Regenerate with XcodeGen

The committed `Wavess.xcodeproj` targets Xcode 16. If you're on an earlier
version (or the project file gets corrupted), regenerate it from `project.yml`:

```sh
brew install xcodegen
xcodegen generate
open Wavess.xcodeproj
```

## How to use

1. Tap **Choose Video** and pick a clip.
2. Wavess analyzes it on-device (one frame-sampling pass + an audio pass) and
   shows a timeline of what it will keep (accent) vs. cut (dim).
3. Pick a mode:
   - **Still** — removes the static/stopped stretches. Tune the stillness
     threshold and minimum still length. *This is the one for silent scenery /
     driving footage.*
   - **Highlights** — builds a short cut from the most dynamic scenes. Tune the
     target length and scene sensitivity, and toggle individual scenes on/off.
   - **Silence** — removes quiet gaps (talking videos). Flags clips that have no
     audio.
4. Tap **Export edit**, then **Save to Photos** or **Share**.

Slider tweaks recompute instantly from the cached frame sample — no re-scan.

## How it works

| Step | Technique | File |
|------|-----------|------|
| Frame sampling | Sample frames at N fps, downscale each to a 32×32 grayscale signature (one shared pass) | `Services/FrameSampler.swift` |
| Still detection | Measure frame-to-frame visual change; sustained low-change stretches become "still" ranges to cut | `Services/MotionAnalyzer.swift` |
| Scene detection | Big frame-to-frame differences mark cuts; the spans between become scenes | `Services/SceneDetector.swift` |
| Highlight scoring | Score each scene by average visual change × length; auto-select the top scenes to hit a target duration | `Services/SceneDetector.swift`, `ViewModels/EditorViewModel.swift` |
| Silence detection | Decode audio to mono 16 kHz PCM, compute per-window RMS → dBFS, threshold into silent ranges | `Services/SilenceDetector.swift` |
| Assembly & export | Build an `AVMutableComposition` of the kept ranges, preserve orientation, export `.mp4` via `AVAssetExportSession` | `Services/VideoComposer.swift` |

### Project layout

```
Wavess/
├── WavessApp.swift            App entry point
├── Models/
│   ├── AnalysisSettings.swift Tunable thresholds (exposed as sliders)
│   └── Scene.swift            Scene model + error types
├── Services/
│   ├── FrameSampler.swift     Shared frame sampling + motion signal
│   ├── MotionAnalyzer.swift   Still / low-motion detection (visual)
│   ├── SceneDetector.swift    Scene detection + highlight scoring
│   ├── SilenceDetector.swift  Audio RMS/dB silence analysis
│   ├── VideoComposer.swift    Composition assembly + export
│   └── PhotoSaver.swift       Save result to the photo library
├── ViewModels/
│   └── EditorViewModel.swift  Orchestrates analysis, selection, export
├── Views/
│   ├── ContentView.swift      Root (import ↔ editor)
│   ├── ImportView.swift       Landing / empty state
│   ├── EditorView.swift       Preview, controls, timeline, export, result
│   ├── TimelineView.swift     Visual keep/cut timeline
│   ├── VideoPicker.swift      PHPicker bridge → local file URL
│   └── ShareSheet.swift       UIActivityViewController bridge
└── Utilities/
    ├── TimeRangeMath.swift    Invert / merge / pad CMTimeRanges
    ├── CGImage+Pixels.swift   Grayscale signatures + frame diffing
    └── Formatting.swift       Timecode formatting
```

## Roadmap ideas

- **Speed-ramp** boring stretches into a hyperlapse instead of cutting them
  (popular for long drives).
- Thumbnail previews per scene in the highlights list.
- Stabilization pass for shaky handheld / dashcam footage.
- Background rendering with progress notifications for long clips.
- Speech transcription + caption burn-in and text-based editing (for talking
  videos).

## Notes & limitations

- Analysis and export run on-device, so very long or 4K clips take time and
  memory — try a shorter clip first.
- Still/scene detection is a lightweight frame-difference heuristic, not an ML
  model; it's fast and dependency-free. For driving footage it mainly cuts truly
  static moments (stops, held shots) — a moving road still reads as motion, which
  is usually what you want. Use **Highlights** to aggressively condense a long
  drive, and adjust the sliders to taste.
- `AVAssetExportSession.exportAsynchronously`/`progress` are deprecated in
  iOS 18 but still function; a future update can move to the iOS 18
  `export(to:as:)` + `states(updateInterval:)` API.
