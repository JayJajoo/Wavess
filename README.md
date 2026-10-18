# Wavess — Intelligent Video Editor for iPhone

An on-device, SwiftUI + AVFoundation iPhone app that automatically tightens and
stitches your videos. Two flows:

**🎞️ Build a Reel (multiple clips)**
- Import several videos (e.g. 3–5 min scenery/driving clips).
- Wavess analyzes each on-device, detects scenes, and picks the **key scenes** from
  every clip.
- Stitches them into one reel with **cross-dissolve transitions applied
  selectively** — by default only where one clip hands off to the next, not at
  every cut.
- 🎵 **Beat-synced music** — pick a 30s–2min section of a song; Wavess detects its
  beats and tempo and cuts the clips **on the beat**, with the music as the
  soundtrack and the reel running the length of your chosen section.
- ⏩ **Intelligent speed ramps** — adds slow-motion on strong, dynamic beats and
  fast-forward through long static shots, on *selected* beats only (never every
  cut), always keeping the cut locked to the beat.
- 🎨 **Color grading** — apply a look (Vivid, Warm, Cool, Cinematic, B&W, Vintage)
  to the whole reel, or give individual clips their own look to grade just that
  section.

**✂️ Edit one clip**
- 🚗 **Trim still footage** — cut stretches where almost nothing changes (a stopped
  car, a static hold), keeping where the view is actually moving. **No speech
  required** — ideal for scenery, driving, and b-roll.
- 🎬 **Highlights** — detect scenes, score them, and auto-assemble a shorter cut.
- 🔇 **Remove silence** — for *talking* videos: cut the quiet gaps, keep the speech.

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

### Build a Reel

1. On the home screen tap **Build a Reel** and select several videos.
2. Wavess analyzes each clip and auto-picks its key scenes. Expand any clip to
   toggle individual scenes on/off.
3. *(Optional)* **Add music** — pick a song, choose the start and a 30s–2min
   section, set **cut every N beats**, and toggle **speed ramps**. The reel will
   sync to the beat and run the length of the section.
4. Set the **transitions**: style (dissolve / hard cut), when they apply
   (*between clips* — the default — or *every scene*), and the transition length.
   (Without music, also set **key scenes per clip**.)
5. *(Optional)* **Color** — pick a reel-wide look, and/or give any clip its own
   look to grade just that section.
6. Tap **Build reel**, then **Save to Photos** or **Share**.

### Edit one clip

1. On the home screen tap **Edit one clip** and pick a video.
2. Wavess analyzes it (one frame-sampling pass + an audio pass) and shows a
   timeline of what it will keep (accent) vs. cut (dim).
3. Pick a mode:
   - **Still** — removes static/stopped stretches. *This is the one for silent
     scenery / driving footage.*
   - **Highlights** — builds a short cut from the most dynamic scenes.
   - **Silence** — removes quiet gaps (talking videos); flags clips with no audio.
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
| Reel + transitions | Flatten key scenes across clips; alternate two video tracks, overlap selectively, ramp opacity for cross-dissolves, fit each source into a common render size | `Services/ReelBuilder.swift` |
| Beat detection | Decode the music section to PCM → energy-flux onset envelope → autocorrelation for tempo + phase search → an even beat grid (no FFT) | `Services/MusicAnalyzer.swift` |
| Beat-synced reel | Place cuts on the beat grid; center transitions on the beat; apply per-slot speed via `scaleTimeRange` while keeping the slot on-beat; lay the music under it with fades | `Services/MusicReelBuilder.swift` |
| Speed selection | Score each beat by music strength × scene motion; slow-mo on strong dynamic beats, fast-forward through long static shots, never back-to-back | `ViewModels/ReelViewModel.swift` |
| Color grading | Second pass: `AVVideoComposition` with a CIFilter handler that picks a look per time range (whole video or per clip/section) | `Services/ColorGrader.swift` |
| Assembly & export | Build an `AVMutableComposition` (+ `AVVideoComposition` / `AVAudioMix`), preserve orientation, export `.mp4` via `AVAssetExportSession` | `Services/VideoComposer.swift` |

### Project layout

```
Wavess/
├── WavessApp.swift            App entry point
├── Models/
│   ├── AnalysisSettings.swift Tunable thresholds (exposed as sliders)
│   ├── Scene.swift            Scene model + error types
│   ├── ReelClip.swift         One source clip in a reel + its scenes + look
│   ├── TransitionSettings.swift  Transition style / frequency / length
│   └── Look.swift             Color-grading presets
├── Services/
│   ├── FrameSampler.swift     Shared frame sampling + motion signal
│   ├── MotionAnalyzer.swift   Still / low-motion detection (visual)
│   ├── SceneDetector.swift    Scene detection + highlight scoring
│   ├── SilenceDetector.swift  Audio RMS/dB silence analysis
│   ├── MusicAnalyzer.swift    Beat/tempo detection for a music section
│   ├── ReelBuilder.swift      Multi-clip stitch + cross-dissolve transitions
│   ├── MusicReelBuilder.swift Beat-synced stitch + speed ramps + music track
│   ├── ColorGrader.swift      Time-ranged color grading (CIFilter pass)
│   ├── VideoComposer.swift    Composition assembly + export
│   └── PhotoSaver.swift       Save result to the photo library
├── ViewModels/
│   ├── EditorViewModel.swift  Single-clip: analysis, selection, look, export
│   └── ReelViewModel.swift    Reel: per-clip analysis, music plan, speed, grade
├── Views/
│   ├── ContentView.swift      Root + home routing (editor ↔ reel)
│   ├── ImportView.swift       Home screen (two entry points)
│   ├── EditorView.swift       Single-clip editor
│   ├── ReelView.swift         Reel builder (clips, music, transitions, color)
│   ├── TimelineView.swift     Visual keep/cut timeline
│   ├── SharedComponents.swift PlayerCard, LabeledSlider, SceneRow, LookChips…
│   ├── VideoPicker.swift      PHPicker bridge → one local file URL
│   ├── MultiVideoPicker.swift PHPicker bridge → multiple file URLs
│   ├── AudioPicker.swift      Document picker → music file URL
│   └── ShareSheet.swift       UIActivityViewController bridge
└── Utilities/
    ├── TimeRangeMath.swift    Invert / merge / pad CMTimeRanges
    ├── ReelLayout.swift       Plain-reel timeline layout (for grade spans)
    ├── VideoGeometry.swift    Orientation + aspect-fit transforms
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
