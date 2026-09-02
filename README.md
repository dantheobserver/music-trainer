# Music Trainer

A desktop audio learning tool for practicing songs by ear. Load audio files, visualize the waveform with real-time pitch detection, loop sections, adjust speed, and isolate notes by filtering frequency and confidence.

Built with [Odin](https://odin-lang.org/) and [Raylib](https://www.raylib.com/).

![Music Trainer](screenshot.png)

## Features

- **Waveform visualization** — color-coded by detected pitch (each note gets a distinct color)
- **Real-time note detection** — FFT-based pitch analysis with parabolic interpolation
- **Section looping** — click and drag to select a region, auto-loops on release
- **Speed control** — 0.25x to 2.0x playback without pitch correction
- **Detection filters** — adjust sensitivity, min/max frequency to isolate melody from accompaniment
- **Click to seek** — click anywhere on the waveform to jump to that position
- **Zoom and scroll** — Ctrl+wheel to zoom, wheel to scroll horizontally
- **URL download** — paste a URL and download audio via yt-dlp
- **System audio recording** — record audio playing from your system (PulseAudio/PipeWire)
- **File library** — browse, preview, rename, and delete files in your library
- **Drag and drop** — drop audio files directly onto the window

## Prerequisites

- **Odin compiler** — [installation instructions](https://odin-lang.org/docs/install/)
- **Raylib** — included with Odin's vendor collection, no separate install needed
- **GNU Make** — for the build system
- **Liberation Sans font** — usually pre-installed on Linux (`/usr/share/fonts/truetype/liberation/`)

### Optional

- **yt-dlp** — for downloading audio from URLs (`pip install yt-dlp` or your package manager)
- **PulseAudio utilities** (`parecord`, `pactl`) — for system audio recording; included with `pulseaudio-utils` on most Linux distros
- **Node.js** — required by yt-dlp for some extractors

## Building

```sh
make build
```

The binary is output to `build/music_trainer`.

## Running

```sh
make run
```

Or run directly with an optional file argument:

```sh
./build/music_trainer [path/to/audio.wav]
```

## Usage

| Action | Input |
|---|---|
| Play / Pause | Space or Play button |
| Stop | Stop button |
| Seek | Click on waveform |
| Select section | Click and drag on waveform |
| Zoom | Ctrl + mouse wheel |
| Scroll | Mouse wheel |
| Speed up / down | Up / Down arrow keys |
| Seek ±5s | Left / Right arrow keys |
| Clear selection | Escape |
| Record system audio | Record button (pink circle) |
| Load from library | Library button → click file |
| Preview in library | Play icon next to file |
| Rename file | Pencil icon next to file |
| Delete file | Trash icon next to file |

## Music Library

Audio files are stored in `~/Music/music_trainer/`. This directory is created automatically on first use. Downloaded files, recordings, and any files you want in the library should be placed here. The Library panel browses this folder and supports `.wav`, `.mp3`, `.flac`, and `.ogg` formats.

## Keyboard Shortcuts

| Key | Action |
|---|---|
| `Space` | Toggle play/pause |
| `Left` / `Right` | Seek ±5 seconds |
| `Up` / `Down` | Adjust playback speed |
| `Escape` | Clear selection |

## License

MIT
