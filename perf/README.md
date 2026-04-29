# Performance artifacts

Aftertalk samples memory / CPU / thermal / battery once per second the entire foreground app lifetime and writes a CSV per session under `~/Documents/perf/<sessionId>.csv` on the iPhone (the app's `Documents` folder is file-shared via the Files app).

This directory holds the off-device artifacts that ship with the repo: the raw CSVs and the rendered PNGs that the README links to.

## Capturing a profile

1. Charge the iPhone to 100%, enable airplane mode.
2. Cold-launch Aftertalk. The sampler starts on `app_appear`.
3. Record a 30-min meeting (e.g. play a YouTube panel from a second device into the iPhone mic).
4. Run a 10-min Q&A session — at least 10 questions covering the meeting.
5. Open Settings → "Export perf log" (share sheet) and AirDrop / iCloud-Drive the CSV onto the laptop into this directory.

Alternatively pull the file directly via Xcode → **Window** → **Devices and Simulators** → select the device → app row → **Download Container** → look inside `AppData/Documents/perf/`.

## Rendering the chart

```bash
python3 render_chart.py 20260502-141500.csv
# wrote 20260502-141500.png
```

Output is a 4-panel chart:

1. **Memory (MB)** — line + 24/7 peak callout. Target peak < 800 MB.
2. **CPU (% of one core)** — line + average callout. Aggregate across all process threads.
3. **Thermal** — step chart with bands at `nominal / fair / serious / critical`. Target: stays in `fair` or below.
4. **Battery (%)** — line + delta callout. Target Δ < 12% over a 40-min session.

Event markers (`scene_active`, `record_start`, `qa_question_3`, etc.) are emitted by the app and rendered as faint vertical guides on the battery panel.

## Dependencies

```bash
pip3 install matplotlib
```

That's it — `csv` is stdlib.

## Why CSV + matplotlib instead of MetricKit

`MXMetricManager` aggregates per-day and arrives on the *next* app launch via `didReceive payloads:`. For a take-home demo we want same-session numbers we can chart immediately, so the in-process sampler is authoritative; MetricKit is the cross-session sanity check (and is wired separately under `Profiling/PerfMonitor.swift`).
