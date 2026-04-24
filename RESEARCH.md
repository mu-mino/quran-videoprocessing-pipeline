# Engineering Notes & Findings

*Lessons, discoveries, and problem-solving decisions made during development of
the Quran recitation annotation pipeline. Each section documents what was tried,
what failed, what worked, and why.*

---

## 1. Audio Extraction — Silent Truncation by librosa

**Problem.** Early audio extraction used the Python library `librosa`. On a subset
of the playlist, `librosa.load()` returned audio that was tens of minutes shorter
than the source file. No error was raised; the library simply stopped reading at
an internal buffer boundary.

**Detection.** `diff_length.py` was written to compare two directories of audio
files by shared numeric ID `(n)` in filenames, using `ffprobe` to read durations:

```python
def audio_length(path):
    out = subprocess.check_output(["ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path])
    return float(out.strip())
```

Any pair differing by more than 0.1 s is reported. Running this against the
librosa-extracted set revealed 12 affected surahs with losses of up to ~14 minutes.

**Fix.** Switched to `ffmpeg` subprocess calls for all audio extraction. `ffmpeg`
reads the full container regardless of codec quirks and runs deterministically.
All re-extracted files passed the diff check.

---

## 2. Background Removal — Frame Differencing vs. Chroma Key

**Problem:**The source videos embed the synchronized Arabic text over a static
decorative background image. To composite the text onto a custom frame, the
background must be removed cleanly. Two approaches were evaluated.

**Attempt 1: Chroma key / colorkey filter.**
The background is mostly black (`0x000000`), making `colorkey` the obvious choice:

```bash
colorkey=0x000000:similarity=0.10:blend=0.10
```

Result: near-black Arabic text strokes were partially keyed out, leaving
semi-transparent or missing glyphs. Tuning `similarity` was a trade-off between
glyph preservation and background residue — no single value worked across all surahs.

**Attempt 2: Frame differencing (chosen).**
`video-minus-pic.sh` captures the reference background image (one still frame when
the screen is dark) and subtracts it per-frame via:

```bash
[bg][vid] blend=all_mode=difference → format=gray →
geq=lum='if(gt(lum(X,Y),25),255,0)' → format=yuva420p
```

Any pixel with an absolute difference > 25 is classified as foreground (text).
Output is encoded as VP9 lossless with alpha channel (`.mkv`, `-pix_fmt yuva420p`,
`-lossless 1`). Result: clean, binary text mask even for light-coloured or
anti-aliased strokes.

**Why frame differencing wins.** The background is truly static — no camera
movement, no lighting variation. The difference image reliably isolates motion
and on-screen changes. Chroma key requires colour-based assumptions that break
when text overlaps near-black regions.

---

## 3. Video Segmentation — Black-Screen Transitions

**Problem.** Verse-chunks in the masked videos are separated by brief black-screen
transitions (typically 0.5–1.5 s). Segmenting by these transitions gives one
`FrameWindow` per verse group. However, some transitions are nearly black but
not fully black (ambient noise in encoding), and some actual verse frames have
dark regions.

**Approach.** `videowindow.py` uses two complementary signals per frame:
- **Brightness** — mean pixel intensity over the grayscale frame.
- **MSE** (mean squared error vs. previous frame) — detects scene changes even
  when absolute brightness differs.

Segments shorter than ~2 seconds are discarded (`filter_segments`) to eliminate
false positives from encoding artefacts or very fast transitions.

**Fundamental timing problem.** The circle marker frame and the recitation audio
are structurally offset by one position. A circle frame shows *which* verse is
coming next — the recitation starts only in the following window(s). The correct
timestamp for verse N is therefore not when its own circle appears, but when the
*previous* group's circle appeared. The mapping must shift all verse timestamps
one position backward relative to the circle sequence:

```
Frame sequence:   [circle(1)]  [recitation]  [circle(2)]  [recitation]  [circle(3)] …
Verse timestamp:   verse 2 starts at T₀ (when circle(1) appeared),
                   verse 3 starts at T₁ (when circle(2) appeared), …
```

This one-step shift is the default mode and works correctly as long as the
sequence starts with a black screen followed by the first circle frame.

**Discovery.** For surahs where the first frame is not a black screen (some
surahs open directly on text), the shift has no anchor — there is no "previous
circle" to borrow a timestamp from for verse 1. This required the `unshifted_mode`
flag in `main.py` and four distinct timestamp assignment cases (Fall 1–4)
discovered iteratively during testing on surahs 74, 83, and 98:

| Case | First frame | First circle count | Timestamp strategy |
|---|---|---|---|
| 1 | Has circle(s) | ≥1 | Each group uses its own circle timestamp — no shift |
| 2 | No circle | =1 | Verse 1 at `[00:10]` (fixed), later verses shift by one |
| 3 | No circle | >1 (first sight) | All circles at T₀ in one entry, shift resumes after |
| 4 | No circle | >1 (split needed) | Same as Case 3, continuation as separate sub-line |

---

## 4. Verse-Number Detection — Ring Marker Geometry

**Problem.** The videos display decorative ring-shaped markers that encode the
verse count: one ring = one verse on screen, two rings = two verses, etc. These
markers must be counted reliably to drive the mapping logic.

**Why Hough circles failed.** OpenCV's `HoughCircles` is tuned for solid or
outline circles. The markers are rings (hollow circles with a thick stroke
containing Arabic numerals inside). The interior numerals create additional
contours that confused the Hough detector, producing false counts.

**Custom ring detector.** `recognizecircle.py` implements a geometry-based
pipeline:

1. **Otsu thresholding** — adaptive, no manual threshold needed.
2. **Contour filtering** — area, width, height, aspect ratio bounds.
3. **Circularity** — `4πA/P²`. Rings have lower circularity than solid circles
   but stay above ~0.18.
4. **Stroke ratio** — `ring_pixels / outer_area`. For these markers, empirically
   0.30–0.70.
5. **Hole ratio** — `inner_area / outer_area`. Validates that the centre is empty.
6. **Empirical calibration** — `_derive_empirical_bounds()` computes 5th–95th
   percentile ranges from sample frames, replacing hard-coded thresholds with
   data-driven bounds.

Four detector presets (`base`, `tight`, `stroke_plus`, `stroke_minus`) probe
slightly different stroke kernel sizes to handle rendering variation across surahs.

**Result:** The detector achieves reliable counts on all tested surahs (74, 83,
98) with zero false positives in the ground-truth test set.

---

## 5. Semantic Matching — Arabic Audio to English Verse Span

**Problem:** One WindowFrame/Transition-Frame is not always a verse, but can also 
be part of an incompleted verse.
WhisperX transcribes the Arabic recitation faithfully, but the
output is raw Arabic text. The mapping file requires English verse text with
correct character-position boundaries so that a later UI can highlight the
currently-recited word.

A direct Arabic↔English embedding comparison (cross-lingual sentence-transformers)
was explored but produced low precision on short fragments: a 3-word Arabic
chunk often matched to the wrong quarter of a long verse.

**Chosen approach — word-level alignment via quran.com API.**

```
WhisperX output: "الَّذِينَ آمَنُوا وَعَمِلُوا الصَّالِحَاتِ"
        │
        ▼  quran.com /v4/verses/by_key/98:7 (words=true, cached locally)
Arabic words with word-level English translations:

"الَّذِينَ" → "Those who"

"آمَنُوا" → "believe"

"وَعَمِلُوا" → "and do"

"الصَّالِحَاتِ" → "righteous deeds"
        │
        ▼  concatenate → query: "Those who believe and do righteous deeds"
        │
        ▼  _find_span_by_sequencematcher(query, full_verse_text)
           ROUGE-L sliding window over all word-boundary substrings
        │
        ▼  TextSpan(start=0, end=40, text="Those who believe and do righteous deeds")
```

**Arabic normalisation** (`_normalize_arabic`) is applied before word matching:
removes diacritics (tashkeel), tatweel, maps orthographic variants (`آ→ا`,
`ى→ي`, `ة→ه`, etc.) to canonical forms. This is essential because WhisperX
output and the quran.com word data may use different Unicode representations
of the same letter.

**ROUGE-L** (with β=1.9, recall-weighted) is used instead of exact string match
or cosine similarity because:
- The query is a re-assembled translation string, not guaranteed to match the
  verse text verbatim.
- ROUGE-L rewards long common subsequences, naturally handling re-orderings and
  paraphrasing between translation styles.

**Gap filling.** When multiple chunks are matched sequentially, prefix and inter-chunk
gaps (text not claimed by any chunk) are silently extended into the nearest
adjacent span. The verse suffix (text after the last matched chunk) is left for
the next circle-window entry to claim — this avoids duplicating text.

---

## 6. Guard Invariants — Forward Monotonicity

**Observation.** Recitation is always forward: a later audio chunk cannot
correspond to earlier text. If the matching step violates this invariant
(e.g., due to WhisperX hallucinations or ambiguous short fragments), the output
mapping would have timestamps that go backward — a hard correctness violation.

**Guard implementation.** `run_guard()` enforces two properties:

1. `span[i].end >= span[i-1].end` — the endpoint of each matched span never
   moves backward.
2. `span[i].start >= span[0].start` — no chunk jumps behind the start of the
   first matched position.

Violations are reported with correction hints explaining which
chunk went backward and why. The guard result is stored in `MatchSession.guard`
and checked before writing the mapping file.

The `completeness_passed` flag (whether every word in the verse was claimed) is
intentionally *not* a hard failure — the unclaimed suffix is handled by the
structural continuation logic in `main.py`.

---

## 7. Compute Cost — Truncation First, Process Later

**Problem.** The raw YouTube videos are ~1080p and 20–90 minutes each. Running
background differencing, alpha extraction, and overlay compositing on unmodified
files would require days of CPU/GPU time.

**Strategy — truncate first.**
`trunc_dir.sh` applies a single lightweight crop:

```bash
ffmpeg -vf "crop=iw-200:ih:100:0" …
```

This removes the empty space all around, reducing frame area by
~85% and processing time proportionally.

**Parallel batch processing.**
`video-minus-pic.sh` distributes work across all CPU cores:

```bash
jobs="${JOBS:-$(nproc)}"
threads_per_job=$(( cores / jobs ))
```

Each `ffmpeg` process receives `threads_per_job` threads, saturating the machine
without over-subscribing. On an 8-core machine, 4 parallel jobs × 2 threads each
was found to be more efficient than 1 job × 8 threads due to decoder I/O
bottlenecks.

---

## 8. Timestamp Ambiguity — Four Cases

**Problem.** The mapping file requires one timestamp per verse entry. The circle
marker appears at the beginning of a "group" frame, but the recitation audio for
the following verse spans the *next* window(s). The correct timestamp for each
verse is therefore not the frame where its circle appears, but the moment the
*previous* group's circle appeared — a one-position shift.

**Four cases discovered during testing (surahs 74, 83, 98):**

| Case | First frame | First circle count | Timestamp strategy |
|---|---|---|---|
| 1 | Has circle(s) | ≥1 | Each group uses own circle timestamp (no shift) |
| 2 | No circle | =1 | Verse 1 at `[00:10]`, subsequent verses shifted by one position |
| 3 | No circle | >1 | All circles at T₀ in one entry, then shift as Case 2 |
| 4 | No circle | >1, split | Same as Case 3 but continuation written as separate line |

The `unshifted_mode` boolean in `main.py` tracks whether the pipeline is in
shift mode or direct-timestamp mode after a Case 3/4 split.

This case analysis emerged from empirical testing, not from upfront design — each
surah structure that failed revealed a new edge case.

---

## 9. Data Integrity — API Response Caching

**Problem.** `semanticmatch.py` calls `quran.com/api/v4` once per (surah, ayah)
pair. Processing 114 surahs with hundreds of verses each would make thousands of
HTTP requests, hitting rate limits and making the pipeline non-reproducible if
the API changes.

**Solution.** All API responses are written to `data/api/<surah>_<ayah>.json`
on first fetch and read from disk on subsequent runs. This makes the pipeline
deterministic, offline-capable after a warm-up run, and resilient to API outages.

---

## Summary of Key Decisions

| Decision | Rejected alternative | Reason |
|---|---|---|
| `ffmpeg` for audio extraction | `librosa` | Silent truncation detected by diff_length.py |
| Frame differencing for BG removal | Chroma key | Chroma key damaged text strokes |
| Geometric ring detector | Hough circles | Interior numerals caused false splits |
| Word-level AR→EN via quran.com | Cross-lingual embeddings alone | Short fragment precision too low |
| ROUGE-L for span matching | Exact string / cosine similarity | Handles paraphrasing between translation editions |
| Forward-monotonicity guard | No guard | Prevents backward timestamps from Whisper hallucinations |
| Crop before differencing | Process full resolution | ~18% frame area reduction, removes edge artefacts |
| Local API cache | Re-fetch each run | Reproducibility + rate-limit resilience |
