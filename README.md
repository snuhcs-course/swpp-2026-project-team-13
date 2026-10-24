# Team 13 — iPad App / Django Backend

An initial project for two developers working separately on the frontend and backend.
The iPad frontend is SORI, a melodic dictation practice app implementing the [v0.2.0 exam contract](docs/sori-api/API-CONTRACT.md). The Django backend currently provides the health endpoint; SORI domain APIs and handwriting recognition remain backend work.

```text
SwiftUI iPad app ← HTTP / JSON → Django REST API → SQLite (local development)
```

| Path | Contents | Owner |
| --- | --- | --- |
| `frontend/` | SORI SwiftUI iPad app, PencilKit, MXL/piano, demo and live API clients | Frontend |
| `backend/` | Django, Django REST Framework, and health API | Backend |
| `docs/api.md` | Agreed request and response formats | Both |
| `.github/workflows/ci.yml` | Backend checks and tests, iPad app build | Both |

## Quick Start

Backend (macOS / Linux, starting from the repository root):

```sh
cd backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
python manage.py migrate
python manage.py runserver
```

`curl http://localhost:8000/api/health/` returns `{"status":"ok"}`.

Frontend:

1. Open `frontend/IPadApp/IPadApp.xcodeproj` in Xcode on a Mac.
2. Select the `IPadApp` scheme and an iPad simulator, then click Run.
3. The app opens a local SORI demo: choose a question, listen, write and submit. No server is required.
4. When SORI backend endpoints are available, use the connection settings to enter the `/api/v1/` base URL and an issued development token.

The demo includes original MXL and piano resources and explicitly labeled example results. Live SORI APIs still need backend implementation.
A physical iPad requires the Mac's LAN IP address instead of `localhost`.
See the [frontend guide](frontend/README.md), [backend guide](backend/README.md), and [API contract](docs/api.md) for details.

## Development Environment

- Frontend: Mac, Xcode 16 or later with a compatible macOS version, iPadOS 17 or later
- Swift language mode: 5.0; UI: SwiftUI; no external Swift packages
- Backend: Python 3.14, Django 5.2 LTS, Django REST Framework
- Direct and transitive Python dependencies are pinned in `backend/requirements.txt`
- Local database: SQLite. Choose the production database before introducing domain models and real data

## Validation

Backend (after preparing `backend/.env`):

```sh
cd backend
source .venv/bin/activate
python manage.py check
python manage.py test api
```

iPad app (on a Mac, from the repository root):

```sh
xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj \
  -scheme IPadApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Frontend validation includes a simulator build, Swift Package contract/transport tests, and iPad-hosted export and submission/recovery integration tests. See `frontend/README.md`.
The health API checks whether the server process responds, not database availability or product functionality.

## Collaboration

- Keep `main` runnable and open pull requests from working branches.
- Example branches: `feat/ipad-editor`, `feat/notes-api`.
- Update `docs/api.md` whenever an API changes.
- Do not commit `.env` files, databases, virtual environments, personal Xcode settings, certificates, or keys.
- Commit Django migration files and the shared Xcode project and scheme.
- Add Docker and production deployment configuration when needed.

## Previous Project

The previous Android code and documentation have been removed from the current project.
Git history is preserved. The state before this replacement is available at commit `465dde2`.
