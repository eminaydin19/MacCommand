import os
import sys
import subprocess
import secrets
import json
import re
import threading
import shutil
import psutil
import requests

# ── DAEMON SAFETY: silence stdout/stderr, patch PATH ──────────────────────────
os.environ["PATH"] = (
    "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
    + os.environ.get("PATH", "")
)
sys.stdout = open(os.devnull, "w")
sys.stderr = open(os.devnull, "w")

from fastapi import FastAPI, HTTPException, Security, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
GITHUB_TOKEN = "YOUR_GITHUB_TOKEN_HERE"
GIST_ID = "YOUR_GIST_ID_HERE"

CLOUDFLARED_BIN = "/opt/homebrew/bin/cloudflared"
BACKEND_PORT = 8765
SECURITY_TOKEN = secrets.token_hex(16)

# ── APP SETUP ──────────────────────────────────────────────────────────────────
app = FastAPI(title="MacCommand Pro", version="1.0.0", docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

bearer_scheme = HTTPBearer()


def verify_token(credentials: HTTPAuthorizationCredentials = Security(bearer_scheme)):
    if credentials.credentials != SECURITY_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return credentials.credentials


# ── GIST PATCHING ──────────────────────────────────────────────────────────────
def patch_gist(tunnel_url: str):
    payload = {
        "files": {
            "maccommand.json": {
                "content": json.dumps(
                    {"url": tunnel_url, "token": SECURITY_TOKEN}, indent=2
                )
            }
        }
    }
    headers = {
        "Authorization": f"token {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
    }
    try:
        resp = requests.patch(
            f"https://api.github.com/gists/{GIST_ID}",
            headers=headers,
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
    except requests.RequestException:
        pass


# ── CLOUDFLARE TUNNEL ──────────────────────────────────────────────────────────
def start_cloudflare_tunnel():
    try:
        proc = subprocess.Popen(
            [
                CLOUDFLARED_BIN,
                "tunnel",
                "--url",
                f"http://localhost:{BACKEND_PORT}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        url_pattern = re.compile(r"https://[a-zA-Z0-9\-]+\.trycloudflare\.com")

        for line in iter(proc.stdout.readline, ""):
            match = url_pattern.search(line)
            if match:
                tunnel_url = match.group(0)
                patch_gist(tunnel_url)
                break

        proc.wait()
    except Exception:
        pass


# ── SYSTEM METRICS ─────────────────────────────────────────────────────────────
@app.get("/metrics", dependencies=[Depends(verify_token)])
def get_metrics():
    cpu = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory()
    disk = psutil.disk_usage("/")

    battery = None
    bat = psutil.sensors_battery()
    if bat:
        battery = {
            "percent": bat.percent,
            "charging": bat.power_plugged,
            "seconds_left": bat.secsleft if bat.secsleft != psutil.POWER_TIME_UNLIMITED else -1,
        }

    return {
        "cpu_percent": cpu,
        "ram": {
            "total": ram.total,
            "used": ram.used,
            "available": ram.available,
            "percent": ram.percent,
        },
        "disk": {
            "total": disk.total,
            "used": disk.used,
            "free": disk.free,
            "percent": disk.percent,
        },
        "battery": battery,
    }


# ── TERMINAL ───────────────────────────────────────────────────────────────────
class CommandRequest(BaseModel):
    command: str
    cwd: str = os.path.expanduser("~")


@app.post("/terminal", dependencies=[Depends(verify_token)])
def run_command(req: CommandRequest):
    if not os.path.isdir(req.cwd):
        req.cwd = os.path.expanduser("~")
    try:
        result = subprocess.run(
            req.command,
            shell=True,
            capture_output=True,
            text=True,
            cwd=req.cwd,
            timeout=30,
            executable="/bin/zsh",
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "Command timed out (30s limit).", "returncode": -1}
    except Exception as e:
        return {"stdout": "", "stderr": str(e), "returncode": -1}


# ── FILE EXPLORER ──────────────────────────────────────────────────────────────
@app.get("/files", dependencies=[Depends(verify_token)])
def list_files(path: str = os.path.expanduser("~")):
    expanded = os.path.expanduser(path)
    if not os.path.isdir(expanded):
        raise HTTPException(status_code=400, detail="Not a valid directory")

    entries = []
    try:
        for entry in sorted(os.scandir(expanded), key=lambda e: (not e.is_dir(), e.name.lower())):
            stat = entry.stat(follow_symlinks=False)
            entries.append(
                {
                    "name": entry.name,
                    "path": entry.path,
                    "is_dir": entry.is_dir(follow_symlinks=False),
                    "size": stat.st_size,
                    "modified": stat.st_mtime,
                }
            )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    return {"path": expanded, "entries": entries}


@app.get("/files/read", dependencies=[Depends(verify_token)])
def read_file(path: str):
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="File not found")
    if os.path.getsize(path) > 5 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="File too large (>5MB)")
    try:
        with open(path, "r", errors="replace") as f:
            return {"path": path, "content": f.read()}
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")


class DeleteRequest(BaseModel):
    path: str


@app.delete("/files", dependencies=[Depends(verify_token)])
def delete_file(req: DeleteRequest):
    target = req.path
    if not os.path.exists(target):
        raise HTTPException(status_code=404, detail="Path not found")
    try:
        if os.path.isdir(target):
            shutil.rmtree(target)
        else:
            os.remove(target)
        return {"deleted": target}
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")


# ── HEALTH CHECK ───────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


# ── ENTRY POINT ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    tunnel_thread = threading.Thread(target=start_cloudflare_tunnel, daemon=True)
    tunnel_thread.start()

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=BACKEND_PORT,
        log_level="critical",
        access_log=False,
    )
