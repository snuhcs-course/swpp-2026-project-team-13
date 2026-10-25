# SORI — Iteration 2 Demo (Team 13)

SORI is an iPad app for melodic dictation practice. The student listens to a melody, writes it with Apple Pencil, and gets AI grading with Korean feedback from a Django server.

## Demo Video

▶ **[Watch the demo](https://drive.google.com/file/d/13kJvSPO3Af8R14l6GcGNIS4TVbJKOQwp/view?usp=share_link)**

## How to Run

### Environment

- **iPad app**: Swift / SwiftUI / PencilKit, Xcode 16+, iPadOS 17+
- **Backend**: Python 3.14, Django 5.2 + DRF, PostgreSQL 17, Docker Compose
- **AI grading**: OpenRouter API
- **Tested on**: macOS (Xcode, iPad simulator), Windows (Docker server, Sideloadly install to a physical iPad)

### 1. Run the app (local demo, no server)

```sh
git clone https://github.com/snuhcs-course/swpp-2026-project-team-13.git
cd swpp-2026-project-team-13 && git checkout iteration-2-demo
python3 scripts/fetch_soundfont.py
open frontend/IPadApp/IPadApp.xcodeproj
```

If `fetch_soundfont.py` fails with `CERTIFICATE_VERIFY_FAILED`, run `SSL_CERT_FILE=/etc/ssl/cert.pem python3 scripts/fetch_soundfont.py` instead.

Select the `IPadApp` scheme and an iPad simulator, then press **Run (⌘R)**. The app starts in local demo mode. Results in this mode are example results, not real grading.

### 2. Run the backend (real AI grading)

```sh
python3 scripts/prepare-local.py        # creates backend/.env (your LAN IP is added automatically)
# set OPENROUTER_API_KEY in backend/.env
docker compose --env-file backend/.env up --build -d --wait
```

Check that `http://localhost:8000/api/health/` returns `{"status":"ok"}`.

### 3. Connect the app to the server

In the app, open **연결 설정**, turn **로컬 데모 사용** off, fill in the fields below, and tap **서버 연결**:

- **Server URL**: `http://localhost:8000/api/v1/` (simulator) or `http://<server LAN IP>:8000/api/v1/` (physical iPad)
- **Token**: the value in `backend/.local/connection.txt`

To install on a physical iPad without a Mac, see [docs/WINDOWS-IPAD.md](docs/WINDOWS-IPAD.md).

## What This Demo Demonstrates

### Features

- **Questions**: three dictation questions in 6/8, 4/4 and 3/4.
- **Exam playback**: scale, count-in, the full melody, and segmented replays with timed writing gaps.
- **Handwriting**: PencilKit canvas with pen, eraser, undo/redo and zoom.
- **Submission**: reliable upload with retry and recovery after an app restart.
- **AI results**: score, pitch/rhythm evaluation, per-measure comments and Korean feedback.
- **Answer comparison**: the student's answer shown next to the reference score.
- **Other**: attempt history and a local demo mode that works without a server.

### Major Progress in Iteration 2

- End-to-end AI grading works: iPad → Django API → grading worker → OpenRouter → result in the app.
- Added three real questions, including tuplets, sixteenth notes and ties.
- Redesigned the playback schedule (count-in, writing gaps, tempo) and made audio playback more robust.
- Added answer/reference comparison and measure-level feedback highlighting.
- CI now runs backend and Swift tests and builds an installable iPad IPA.

More details: [docs/VALIDATION.md](docs/VALIDATION.md), [docs/IPAD-SETUP.md](docs/IPAD-SETUP.md), [API contract](docs/sori-api/API-CONTRACT.md)
