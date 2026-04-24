# Quran Recitation Annotation Pipeline

A multi-stage pipeline that takes raw YouTube recitation videos of the Holy Quran
and produces per-verse, timestamped mapping files — pairing each moment in the
audio with its English verse text.

> **Status:** Transcription & matching phase (`Transcribe-Translation/`) is still
> in active development. All earlier pipeline stages are complete.

---

## Goal

Given a Quran recitation video (reciter: Maher Al-Muaiqly, full 114-surah playlist),
produce for every surah a file of the form:

```
[00:00] :: Al-Bayyina - The Clear Proof\nChapter 98 …
[00:10] :: 1: Those who disbelieve …
[00:22] :: 2: A Messenger from Allah …
[00:42] :: 3: Containing correct and straight laws …
```

Each line maps a wall-clock timestamp inside the recitation audio to a specific
verse (or verse fragment), enabling subtitle generation, study tools, and corpus
research.

---

## Pipeline Overview

```
YouTube playlist (114 surahs)
        │
        ▼  [yt-downloader]
Raw MP4 videos
        │
        ├──► [trunc_dir.sh]          Crop black side-bars, reduce resolution
        │          │
        │          ▼
        │    Cropped MP4s
        │          │
        │    [video-minus-pic.sh]    Frame-differencing: subtract static background
        │          │                  → lossless VP9 RGBA (text layer only)
        │          │
        │    [add_overlay.sh /
        │     rm-black-bg_pos_scale_add-on-overlay.sh]
        │                            Composite text layer onto custom Islamic-art frame
        │                            → presentation-ready MP4
        │
        ├──► [diff_length.py]        QC: detect truncated audio files
        │
        ├──► [read_pdf_to_txt.py]    Split English translation PDF → 114 .txt chunks
        │
        └──► [Transcribe-Translation/]
                    │
                    ├── videowindow.py      Segment video by black-screen transitions
                    ├── recognizecircle.py  Count verse-number ring markers per frame
                    ├── circlelog.py        Build initial timestamped mapping
                    ├── whispertranscribe.py  WhisperX (large-v2, ar) on audio gaps
                    ├── semanticmatch.py    AR→EN word alignment + ROUGE-L span matching
                    └── main.py             Orchestrator
                            │
                            ▼
                    output/<surah>.mapping
```

---

## Sub-projects

### 1. `yt-downloader` *(separate repository)*

Node.js / Selenium tool used to download the complete Maher Al-Muaiqly playlist.
Not published in this repository for legal reasons — YouTube's Terms of Service
prohibit redistribution of downloaded content. 

### 2. Audio QC — `diff_length.py`

During early development the Python library `librosa` was used for audio extraction.
It silently truncated some files. `diff_length.py` compares two directories of audio
files by numeric ID `(n)` embedded in filenames, reporting any pair whose durations
differ by more than 0.1 s:

```
python diff_length.py quran/maher_playlist/ quran/final_maher/
(12) diff=-3.42
(47) diff=-1.10
```

Discovery of these divergences triggered the switch to `ffmpeg`-based extraction,
which preserves full audio lengths deterministically.

### 3. PDF → per-surah text — `read_pdf_to_txt.py`

Extracts all 114 chapters from the English PDF translation using a multi-line regex
that simultaneously captures the Arabic transliterated title, English title, chapter
number, verse count, and revelation location. Each chapter is written to a separate
`.txt` file under `quran/eng_translation/chunked_translation/`.

```
python read_pdf_to_txt.py \
    quran/eng_translation/Noble-Quran_English-Translation-Only.pdf \
    quran/eng_translation/chunked_translation/
```

### 4. Video preprocessing — bash scripts

#### `trunc_dir.sh`
Crops 100 px from each horizontal side of every video in a directory (removes
the side black bars present in the source files). Runs `ffmpeg` with `-vf
"crop=iw-200:ih:100:0"` and 16 threads. Applied first to reduce computation cost
for all subsequent stages.

#### `video-minus-pic.sh`
Isolates the animated Arabic text layer from the static decorative background by
frame-differencing:

```
ffmpeg … [bg][vid] blend=all_mode=difference → geq threshold → VP9 RGBA lossless
```

Takes a reference background image captured from the video itself, subtracts it
per-frame, thresholds at pixel value 25, and encodes to `.mkv` with full alpha
channel. Supports single-pair and parallel batch modes (`JOBS=nproc`).

#### `add_overlay.sh` / `rm-black-bg_pos_scale_add-on-overlay.sh`
Two iterations of the same idea: composite the isolated text layer onto a custom
Islamic-art frame image (`finish.png`). The second script (`rm-black-bg_*`) is
the production version:

- Reads bounding-box coordinates (X=313,Y=214 → X=1034,Y=284) from the reference image.
- Scales the text clip by factor 1.3, re-centres it, removes black pixels via
  `colorkey=0x000000`, and overlays onto `finish.png`.
- Encodes with `libx264`, CRF 18, `yuv420p`.

The `finish.png` overlay frame was manually assembled on mobile from screenshots
of the مصحف المدينة App's Islamic border and banner elements using a photo editor.

### 5. `Transcribe-Translation/` — core annotation pipeline

See [`Transcribe-Translation/README.md`](Transcribe-Translation/README.md) for
full module documentation. Summary:

| Module | Role |
|---|---|
| `videowindow.py` | Detect verse-transition black screens → `List[FrameWindow]` |
| `recognizecircle.py` | Count decorative ring markers (= verse count indicators) |
| `circlelog.py` | Build initial `[MM:SS] :: n: verse_text` mapping |
| `whispertranscribe.py` | WhisperX transcription of audio between marker frames |
| `semanticmatch.py` | Word-level Arabic→English alignment + ROUGE-L span matching |
| `main.py` | Full pipeline orchestrator |
| `auto_range_runner.py` | Async batch runner over a surah ID range |

---

## Data Layout

The `quran/` directory is excluded from version control (large binary files).
Structure and provenance:

```
quran/
├── maher_playlist/          Source: yt-downloader. Raw MP4s, ~1080p, full playlist.
│   └── maher_playlist/      Flat directory, filenames contain (n) surah ID.
│
├── maher_workaround/        Intermediate: trunc_dir.sh output.
│   └── Quran_cropped/       Side-bars removed; used as video input to main pipeline.
│
├── final_maher/             Final processed audio files (ffmpeg-extracted, full length).
│   └── …                    Used as --audio input to Transcribe-Translation.
│
├── saud_shureim/            Alternative reciter (Sheikh Saud Al-Shuraim).
│   └── …                    Not yet processed; reserved for future extension.
│
└── eng_translation/
    ├── Noble-Quran_English-Translation-Only.pdf
    └── chunked_translation/                       OUTPUT of read_pdf_to_txt.py.
        ├── 1_Al-Fatihah.txt                       One file per surah, ~114 files.
        ├── 2_Al-Baqarah.txt
        └── …
```

> All raw video and audio files are available on request for private usage, academic or research
> purposes. Contact details in the author section below.

---

## Technologies

| Layer | Tools |
|---|---|
| Download | Node.js, Selenium |
| Video processing | `ffmpeg`, `ffprobe` (frame-diff, alpha extraction, compositing) |
| Computer vision | OpenCV (`cv2`), NumPy |
| Speech-to-text | WhisperX (large-v2, Arabic, CUDA/CPU) |
| NLP / matching | `sentence-transformers`, ROUGE-L, `quran.com` API v4 |
| Text extraction | `pdfplumber`, `regex` |
| Orchestration | Python `asyncio`, Bash |

---

## Output Format

Each processed surah produces a `.mapping` file in `Transcribe-Translation/output/`:

```
[MM:SS] :: <surah title>\n<metadata>
[MM:SS] :: <verse_n>: <English verse text>
[MM:SS] :: <continuation of verse from previous line>
```

---

## Running the Pipeline

> Requires: Python 3.10+, ffmpeg 5+, CUDA-capable GPU recommended for WhisperX.

```bash
# 1. Install dependencies
cd Transcribe-Translation
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 2. Run single surah
python main.py \
    --video  /path/to/quran/maher_workaround/Quran_cropped/(98)\ ….mp4 \
    --audio  /path/to/quran/final_maher/(98)\ ….mp3 \
    --text   quran/eng_translation/chunked_translation/98_Al-Bayyinah.txt \
    --surah  98 \
    --output output/

# 3. Batch run (surah range)
# Edit start_id / end_id in auto_range_runner.py, then:
python auto_range_runner.py
```

---

## Author

Muhammed Emin Eser — Full-stack developer (Django, Python data pipelines, ML tooling). 
Contact: muhammed.emin.eser.1@gmail.com
