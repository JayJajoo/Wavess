# Wavess — Intelligent Video Editor for iPhone

An on-device, SwiftUI + AVFoundation iPhone app that automatically tightens and
highlights your videos. Point it at a clip and it will:

- 🔇 **Auto-remove silence** — analyze the audio track and cut the dead air,
  keeping only the parts where someone's actually talking.
- 🎬 **Find highlights** — detect scene/shot changes, score each scene by how
  much is happening, and auto-assemble a shorter "best of" cut you can tweak.

Everything runs **locally on the phone** — no network, no accounts, no API keys,
and no FFmpeg. It uses only Apple frameworks (AVFoundation, AVKit, CoreMedia,
CoreGraphics, PhotosUI).

> Why native instead of React Native / Flutter? The popular cross-platform
> FFmpeg wrappers (`ffmpeg-kit-react-native`, `ffmpeg_kit_flutter`) were retired
> in 2025 and are unmaintained. iOS ships first-class on-device media APIs, so
> we get silence/scene analysis and video export with zero third-party
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
2. Wavess analyzes it on-device (silence + scenes) and shows a timeline.
3. Pick a mode:
   - **Tighten** — removes silent gaps. Tune the silence threshold, minimum
     silence length, and how much speech to keep around each cut.
   - **Highlights** — builds a short cut from the best scenes. Tune the target
     length and scene sensitivity, and toggle individual scenes on/off.
4. Tap **Export edit**, then **Save to Photos** or **Share**.

## How it works

| Step | Technique | File |
|------|-----------|------|
| Silence detection | Decode audio to mono 16 kHz PCM, compute per-window RMS → dBFS, threshold into silent ranges | `Services/SilenceDetector.swift` |
| Scene detection | Sample frames at N fps, downscale to grayscale signatures, compare consecutive frames; big differences = cuts | `Services/SceneDetector.swift` |
| Highlight scoring | Score each scene by average visual change weighted by length; auto-select top scenes to hit a target duration | `Services/SceneDetector.swift`, `ViewModels/EditorViewModel.swift` |
| Assembly & export | Build an `AVMutableComposition` of the kept ranges, preserve orientation, export `.mp4` via `AVAssetExportSession` | `Services/VideoComposer.swift` |

### Project layout

```
Wavess/
├── WavessApp.swift            App entry point
├── Models/
│   ├── AnalysisSettings.swift Tunable thresholds (exposed as sliders)
│   └── Scene.swift            Scene model + error types
├── Services/
│   ├── SilenceDetector.swift  Audio RMS/dB silence analysis
│   ├── SceneDetector.swift    Frame-difference scene detection + scoring
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

- Speech transcription + caption burn-in (on-device `Speech` / Whisper).
- Text-based editing (edit the transcript to cut the video).
- Thumbnail previews per scene in the highlights list.
- Background rendering with progress notifications for long clips.
- Filler-word ("um", "uh") detection on top of silence removal.

## Notes & limitations

- Analysis and export run on-device, so very long or 4K clips take time and
  memory — try a shorter clip first.
- `AVAssetExportSession.exportAsynchronously`/`progress` are deprecated in
  iOS 18 but still function; a future update can move to the iOS 18
  `export(to:as:)` + `states(updateInterval:)` API.
- Scene detection is a lightweight frame-difference heuristic, not an ML model;
  it's fast and dependency-free but can miss slow dissolves or over-segment very
  shaky footage. Adjust **Scene sensitivity** to compensate.
