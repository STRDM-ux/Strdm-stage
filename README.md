# STRDM Stage

A touring show controller for macOS: one cue list runs backing tracks, the live vocal rack (Auto-Tune), DMX lighting and the LED wall or projectors, alongside the stage plot, input list and venue advance for every city.

Built for Armanii's live set and the Stardom Records touring crew.

---

## Build & run (5 minutes)

Requirements: a Mac on macOS 14 (Sonoma) or later, and Xcode 15+ (or just the Command Line Tools: `xcode-select --install`).

```bash
cd STRDMStage
./build.sh --open
```

This builds `dist/STRDM Stage.app`. Drag it into Applications. When you first launch it:

* **Microphone access:** allow it so the vocal rack can hear the mic.
* **Local network access:** allow it so Art-Net/sACN and OSC work.
* If macOS says the app is from an unidentified developer, right-click the app, choose **Open**, then **Open** again. It's ad-hoc signed and you only need to do this once per build.

To work on the code, open `Package.swift` in Xcode, choose the *STRDMStage* scheme and press Run. For anything that uses the microphone, test with the `build.sh` app, because only the bundled app carries the microphone permission text.

---

## What's in it

| Page | What it does |
|---|---|
| **Cue List** | QLab-style show running. **Space = GO**, **Esc = Panic** (2-second fade), ⌘. = Stop All, ⌘↑/⌘↓ moves standby. Each cue has a pre-wait and can auto-continue or auto-follow. Drag audio or video files from Finder straight onto the list. |
| **Audio & Vocals** | Pick the interface and buffer size. Tracks play with fade-in, level, start offset and loop. The **vocal rack** sends a hardware input through any Audio Unit chain (Antares Auto-Tune, Waves Tune, Melodyne, EQ, comp, verb), opens each plugin's own window, and saves plugin settings inside the show file. **Vocal presets** (e.g. "Hard tune", "Ballad – light") can be recalled from cues. |
| **Lighting** | Art-Net or sACN output at 40 fps. A fixture library covers pars, moving heads, strobes, hazers and blinders. Includes a patch with address-conflict checks, a programmer (colour picker, quick colours, per-channel faders), and scenes you record and then recall from cues with timed fades. There's also a grand master and blackout. |
| **Screens** | Full-screen output to any external display (LED processor, projector). Plays video or stills with cross-fades, looping and fill or fit scaling. Includes a test card for lining up the wall, plus preview windows for programming on the bus. |
| **Stage Plot & Inputs** | Drag-and-drop stage plot drawn to scale in metres, plus an editable input list. **Export Tech Rider PDF** produces a stage-plot page and an input-list page, with the venue schedule and contacts printed on them. |
| **Venue Advance** | Load-in, soundcheck, doors, set time, power, PA, lighting desk, LED notes, contacts and hospitality, all saved per show file. |
| **Control & Log** | OSC server for Stream Deck (via Bitfocus Companion), TouchOSC and QLab network cues. MIDI learn lets a footswitch, SPD-SX pad or controller fire GO, stop, panic, blackout or vocal bypass. Also shows a timestamped show log. |

### Live Stage Map
A real-time top-down view of the rig. It shows every beam's colour, brightness and aim (pars, moving heads, haze, and strobe flashes), along with the stage-plot gear and the performers.
* **Drag performers** to wherever they actually are on stage.
* **Movers follow:** pick a performer and every moving head aims at them, following as you drag. You can also double-click a performer to have the movers follow them.
* **Edit rig / Auto-place rig:** drag fixtures to where they really hang, or let the app lay out front truss, mid truss and back truss for you.

### Light Set Builder (auto lights matched to each song's vibe)
1. Click **Analyse song…**, or **Auto-build whole set from cue list** to do every track in the set at once.
2. The app analyses the audio for tempo and beat grid, key (major or minor), bass weight, brightness, hits per second, and the energy of each 2-bar block. From that it marks out **Intro / Verse / Chorus / Drop / Breakdown / Outro**.
3. It picks a **vibe**: Hype, Dancehall Bounce, Dark, Euphoric, Romantic or Chill. From the vibe it builds a look for each section: colour palette, a beat-synced chase (alternate, wave, pulse, breathe, sparkle), mover moves (sweep, fan, ballyhoo, follow the lead performer), strobe hits on drops, and haze.
4. You can change the vibe, the palette or any individual section. Click the timeline to preview from that point.
5. Link the show to the song's audio cue. When you press GO, the lights run locked to the track's beat.

### OSC commands (default UDP port 53535)
```
/go   /stop   /panic   /standby/next   /standby/prev
/cue/{number}/start      e.g. /cue/12/start
/blackout                /vocal/bypass 1|0
/lights/gm 0.0–1.0
```

---

## Touring workflow

1. **Build the set once.** Drop in the tracks, record lighting scenes, add LED content, and put Vocal FX cues where Auto-Tune changes.
2. **Save**, then go to **File → Collect Media Next to Show File**. Every audio and video file is copied into a `<Show> Media` folder beside the show file, so you can zip the folder and it runs on any Mac. The show also autosaves every 60 seconds once it has a file.
3. **Per city:** use *Save As* to make `Armanii – Kingston.strdmshow`, fill in the Venue Advance page, adjust the stage plot to the real stage size, and export the rider PDF to send to the promoter.
4. **At the venue:**
   * Plug in the interface and choose it under Audio.
   * Connect the Art-Net node or the house desk's network, and set the protocol and IP.
   * Plug the LED processor in as an extended display (not mirrored), pick it under Screens and open the output.
   * Before doors, run the **test pattern** and fire a few cues.

### Getting good live vocal latency
* Use one interface for both input and output, at a buffer of 64–128 samples.
* Use Auto-Tune's **low-latency / live** mode (Auto-Tune Pro X "Low Latency", or Auto-Tune Artist / Access).
* Keep heavy reverbs on the FOH desk rather than in the rack.
* The vocal rack mixes into the same outputs as the tracks. If FOH needs the vocal on its own line, send this app's main output to a separate pair on the interface.

---

## Code layout

```
Sources/STRDMStage/
  App/        STRDMStageApp.swift   – app entry, menus, keyboard GO, MIDI/OSC wiring
  Model/      Show, LightingModel, StagePlotModel, ShowStore (JSON file I/O, autosave, collect media)
  Engine/     ShowEngine.swift      – GO / standby / pre-wait / auto-continue / auto-follow / panic
  Audio/      AudioEngine.swift     – AVAudioEngine playback + AU vocal rack; CoreAudioDevices.swift
  Lighting/   DMXOutput.swift       – Art-Net & sACN packets over UDP; LightingEngine.swift – fades, GM, scenes
  Video/      ScreenManager.swift   – full-screen outputs, AVPlayer layers, cross-fades, test card
  Control/    RemoteControl.swift   – CoreMIDI (MIDI learn) + OSC server
  Views/      SwiftUI pages
```

Show files (`.strdmshow`) are plain JSON, so they're easy to diff, back up and version.

---

## Not in v1 yet (suggested next steps)

* **Timecode:** chase LTC/MTC from Ableton or the DJ, and fire cues at timestamps.
* **Several vocal racks:** separate chains for the lead and hype mics, each on its own output.
* **Fixture import:** pull fixture profiles from the Open Fixture Library or GDTF instead of the built-in list.
* **Output to other systems:** MIDI or MSC out to the house lighting desk, and Resolume/Syphon/NDI for video.
* **Backup rig:** a mirrored second Mac that follows GO over the network.
* **iPad remote:** a GO and standby display for the stage manager.
