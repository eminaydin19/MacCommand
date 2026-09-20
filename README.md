<div align="center">

<img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" />
<img src="https://img.shields.io/badge/iOS-000000?style=for-the-badge&logo=apple&logoColor=white" />
<img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" />
<img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" />
<img src="https://img.shields.io/badge/SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white" />
<img src="https://img.shields.io/badge/Cloudflare-F38020?style=for-the-badge&logo=cloudflare&logoColor=white" />

# ⚡ MacCommand Pro

**Zero-touch remote macOS administration — controlled from your iPhone.**

No static IP. No local network. No QR codes. Just open the app and you're in.

</div>

---

## 🧠 How It Works

MacCommand Pro uses a **Service Discovery** architecture to connect your iPhone to your Mac from anywhere in the world:

```
Mac (FastAPI daemon)
    │
    ├─► spawns cloudflared tunnel  →  gets ephemeral HTTPS URL
    │
    └─► patches GitHub Gist (maccommand.json)  →  { url, token }
                                                        │
iPhone (SwiftUI app)                                    │
    │                                                   │
    └─► fetches GitHub Gist  ◄──────────────────────────┘
    │
    └─► connects directly to Mac via Cloudflare URL + Bearer token
```

1. **Mac daemon starts** → generates a random 16-byte security token
2. **cloudflared** creates a secure, ephemeral `trycloudflare.com` tunnel
3. The URL + token are **patched into a private GitHub Gist**
4. The **iOS app fetches the Gist** on launch, instantly discovering the Mac
5. All subsequent API calls go through the **Cloudflare tunnel**, authenticated by the token

---

## ✨ Features

### 🖥️ System Metrics
- Real-time CPU usage with live progress bar
- RAM usage (used / total)
- Disk usage (used / free / total)
- Battery level, charging state & time remaining
- Auto-refreshes every 3 seconds

### 💻 Remote Terminal
- Full zsh shell access on your Mac
- Cyberpunk-styled terminal UI with macOS stoplight buttons
- Command history with colour-coded output
- 30-second timeout guard per command

### 📁 File Explorer
- Browse the full macOS filesystem
- Navigate directories, read text files
- Swipe-to-delete files and folders
- Human-readable file sizes and icons by type

### 🔒 Security
- Fresh 16-byte hex token generated on every daemon start
- All API routes protected by `Authorization: Bearer <token>`
- Token delivered out-of-band via private GitHub Gist (never in URL)
- Cloudflare tunnel = no open ports on your Mac

---

## 🗂️ Project Structure

```
MacCommandCore/          ← Python backend (this repo)
│
├── main.py              ← FastAPI daemon + Cloudflare tunnel + Gist patcher
└── .gitignore

Macxiphone/              ← iOS app (separate Xcode project)
│
└── ContentView.swift    ← Full SwiftUI app (discovery + 3 tabs)
```

---

## 🛠️ Setup & Build

### Prerequisites

| Tool | Install |
|---|---|
| Python 3.11+ | `brew install python` |
| cloudflared | `brew install cloudflare/cloudflare/cloudflared` |
| PyInstaller | `pip install pyinstaller` |
| Xcode 15+ | App Store |

### 1 — Configure Credentials

Edit `main.py` and replace the two placeholders:

```python
GITHUB_TOKEN = "YOUR_GITHUB_TOKEN_HERE"   # needs 'gist' scope
GIST_ID      = "YOUR_GIST_ID_HERE"        # your private gist ID
```

Create a private GitHub Gist containing a file named exactly `maccommand.json` (content doesn't matter at first).

### 2 — Python Environment

```bash
cd MacCommandCore
python3 -m venv venv
source venv/bin/activate
pip install fastapi "uvicorn[standard]" requests psutil pyinstaller
```

### 3 — Build the macOS Daemon

```bash
pyinstaller \
  --windowed --onefile --name MacCommandPro \
  --hidden-import uvicorn \
  --hidden-import uvicorn.logging \
  --hidden-import uvicorn.loops \
  --hidden-import uvicorn.loops.auto \
  --hidden-import uvicorn.protocols \
  --hidden-import uvicorn.protocols.http \
  --hidden-import uvicorn.protocols.http.auto \
  --hidden-import uvicorn.lifespan \
  --hidden-import uvicorn.lifespan.on \
  --hidden-import fastapi \
  --hidden-import requests \
  --hidden-import psutil \
  --hidden-import anyio \
  --hidden-import anyio._backends._asyncio \
  main.py
```

The binary lands at `dist/MacCommandPro`. Double-click to launch — it runs silently in the background.

### 4 — (Optional) Auto-Start on Login

```bash
# ~/Library/LaunchAgents/com.maccommand.pro.plist
launchctl load ~/Library/LaunchAgents/com.maccommand.pro.plist
```

### 5 — iOS App

1. Open `Macxiphone.xcodeproj` in Xcode
2. Replace `your_gist_id_here` in `ContentView.swift`
3. Select your Team under **Signing & Capabilities**
4. Deploy target: **iOS 17.0+**
5. Build & run

---

## 🔌 API Reference

All routes (except `/health`) require:
```
Authorization: Bearer <session-token>
```

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Health check (no auth) |
| `GET` | `/metrics` | CPU, RAM, Disk, Battery |
| `POST` | `/terminal` | Execute a zsh command |
| `GET` | `/files` | List directory contents |
| `GET` | `/files/read` | Read a text file |
| `DELETE` | `/files` | Delete file or directory |

---

## 🔐 Security Notes

- **Never commit** `main.py` with real tokens. Use environment variables in production.
- Rotate your GitHub Personal Access Token regularly.
- The `cloudflared` tunnel URL changes on every daemon restart — that's by design.
- For extra hardening, scope your GitHub token to `gist` only.

---

## 📄 License

MIT © [eminaydin19](https://github.com/eminaydin19)
