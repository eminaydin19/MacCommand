"""Authenticated loopback API used by the Mac companion."""
import asyncio
import anyio
from urllib.parse import quote
import tempfile
import stat
import json
import os
from pathlib import Path
import platform
import secrets
import selectors
import signal
import subprocess
import threading
import time

import psutil
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from send2trash import send2trash
from terminal_stream import command_events

VERSION = 2
FILE_LIMIT = 5 * 1024 * 1024
TRANSFER_LIMIT = 50 * 1024 * 1024
OUTPUT_LIMIT = 1024 * 1024
STATE_DIR = Path.home() / 'Library/Application Support/MacCommand'


def execute_command(command: str, cwd: str, timeout=30, output_limit=OUTPUT_LIMIT):
    """Bound both pipes together and kill the shell's process group on timeout."""
    proc = subprocess.Popen(command, shell=True, executable='/bin/zsh', cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    output = {'stdout': bytearray(), 'stderr': bytearray()}
    deadline = time.monotonic() + timeout
    truncated = timed_out = False
    total = 0
    try:
        with selectors.DefaultSelector() as selector:
            for stream, name in [(proc.stdout, 'stdout'), (proc.stderr, 'stderr')]:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    available = output_limit - total
                    output[key.data].extend(chunk[:available])
                    total += min(len(chunk), available)
                    if len(chunk) > available:
                        truncated = True
                        break
                if truncated:
                    break
            if not timed_out and not truncated:
                try:
                    proc.wait(timeout=max(0.01, deadline-time.monotonic()))
                except subprocess.TimeoutExpired:
                    timed_out = True
    finally:
        # The shell may exit before a background child closes the captured pipes.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        proc.stdout.close()
        proc.stderr.close()
    result = {name: bytes(value).decode('utf-8', errors='replace') for name, value in output.items()}
    result.update(returncode=-1 if timed_out or truncated else proc.returncode,
                  timed_out=timed_out, truncated=truncated)
    return result


class CommandRequest(BaseModel):
    command: str = Field(min_length=1, max_length=16384)
    cwd: str = Field(default_factory=lambda: str(Path.home()), max_length=4096)


class StreamRequest(CommandRequest):
    id: str = Field(pattern=r"^[a-f0-9]{32}$")


class DeleteRequest(BaseModel):
    path: str = Field(min_length=1, max_length=4096)


def checked_path(raw: str) -> Path:
    if '\x00' in raw or len(raw) > 4096:
        raise HTTPException(400, 'Invalid file path.')
    return Path(os.path.abspath(os.path.expanduser(raw)))


def create_app(token=None, trash=send2trash):
    security_token = token or secrets.token_hex(32)
    command_lock = threading.Lock()
    active_command = {}
    app = FastAPI(title='MacCommand', version='2.0', docs_url=None,
                  redoc_url=None, openapi_url=None)
    bearer = HTTPBearer(auto_error=False)

    def verify(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if (credentials is None or credentials.scheme.lower() != 'bearer'
                or not secrets.compare_digest(credentials.credentials, security_token)):
            raise HTTPException(401, 'Pairing is invalid. Reconnect to your Mac.',
                                headers={'WWW-Authenticate': 'Bearer'})

    @app.get('/health')
    def health():
        return {'status': 'ok', 'version': VERSION}

    @app.get('/info', dependencies=[Depends(verify)])
    def info():
        return {'version': VERSION, 'name': platform.node(), 'home': str(Path.home()),
                'capabilities': ['metrics', 'terminal', 'files', 'trash', 'transfer', 'terminal_stream'],
                'transfer_limit': TRANSFER_LIMIT}

    @app.get('/metrics', dependencies=[Depends(verify)])
    def metrics():
        ram, disk, battery = psutil.virtual_memory(), psutil.disk_usage('/'), psutil.sensors_battery()
        return {'cpu_percent': psutil.cpu_percent(interval=0.1),
                'ram': {k: getattr(ram, k) for k in ['total', 'used', 'available', 'percent']},
                'disk': {k: getattr(disk, k) for k in ['total', 'used', 'free', 'percent']},
                'battery': None if battery is None else {
                    'percent': battery.percent, 'charging': battery.power_plugged,
                    'seconds_left': max(-1, battery.secsleft)}}

    @app.post('/terminal', dependencies=[Depends(verify)])
    def terminal(req: CommandRequest):
        cwd = checked_path(req.cwd)
        if not cwd.is_dir() or not req.command.strip():
            raise HTTPException(400, 'Invalid command or working directory.')
        if not command_lock.acquire(blocking=False):
            raise HTTPException(409, 'A command is still running. Wait for it to finish.')
        try:
            return execute_command(req.command, str(cwd))
        except OSError:
            raise HTTPException(400, 'Could not start the command. Check the folder permissions.')
        finally:
            command_lock.release()

    @app.post('/terminal/stream', dependencies=[Depends(verify)])
    async def terminal_stream(req: StreamRequest, request: Request):
        cwd = checked_path(req.cwd)
        if not cwd.is_dir() or not req.command.strip():
            raise HTTPException(400, 'Invalid command or working directory.')
        if not command_lock.acquire(blocking=False):
            raise HTTPException(409, 'A command is still running.')
        stop = threading.Event()
        active_command.update(id=req.id, stop=stop)
        async def body():
            events=command_events(req.command,str(cwd),stop)
            try:
                yield json.dumps({'type':'started','id':req.id})+'\n'
                async for event in events:
                    if await request.is_disconnected():
                        stop.set()
                        break
                    yield json.dumps(event)+'\n'
            except OSError:
                yield json.dumps({'type':'error','text':'Could not start the command. Check the folder permissions.'})+'\n'
            finally:
                stop.set()
                try:
                    with anyio.CancelScope(shield=True):
                        await events.aclose()
                finally:
                    active_command.clear()
                    command_lock.release()
        return StreamingResponse(body(),media_type='application/x-ndjson',
            headers={'Cache-Control':'no-store','X-Accel-Buffering':'no'})

    @app.delete('/terminal/{command_id}', dependencies=[Depends(verify)])
    async def stop_command(command_id: str):
        if active_command.get('id') != command_id:
            raise HTTPException(404, 'No running command found.')
        active_command['stop'].set()
        return {'stopping':True}

    @app.get('/files/download', dependencies=[Depends(verify)])
    def download(path: str):
        target=checked_path(path)
        file=None
        try:
            fd=os.open(target,os.O_RDONLY|os.O_NONBLOCK)
            try:
                info=os.fstat(fd)
                if not stat.S_ISREG(info.st_mode):
                    raise HTTPException(400,'Only regular files can be downloaded.')
                if info.st_size>TRANSFER_LIMIT:
                    raise HTTPException(413,'The file transfer limit is 50 MiB.')
                file=os.fdopen(fd,'rb')
                fd=None
            finally:
                if fd is not None: os.close(fd)
        except PermissionError:
            if file: file.close()
            raise HTTPException(403,'You do not have permission to access this file.')
        except FileNotFoundError:
            if file: file.close()
            raise HTTPException(404,'File not found.')
        except BaseException:
            if file: file.close()
            raise
        def chunks():
            try:
                remaining=info.st_size
                while remaining:
                    chunk=file.read(min(65536,remaining))
                    if not chunk: break
                    remaining-=len(chunk)
                    yield chunk
            finally:
                file.close()
        return StreamingResponse(chunks(),media_type='application/octet-stream',
            headers={'Cache-Control':'no-store','Content-Length':str(info.st_size),
                     'Content-Disposition':"attachment; filename*=UTF-8''"+quote(target.name)},
            background=BackgroundTask(file.close))

    @app.put('/files/upload', dependencies=[Depends(verify)])
    async def upload(request: Request, directory: str, name: str):
        if not name or name in ['.','..'] or '/' in name or '\\' in name or '\x00' in name or len(name.encode())>255:
            raise HTTPException(400,'Invalid file name.')
        parent=checked_path(directory).resolve()
        state=STATE_DIR.resolve()
        destination=parent/name
        if state==destination or state in destination.parents or destination in state.parents:
            raise HTTPException(403,'The pairing configuration is protected.')
        if not parent.is_dir():
            raise HTTPException(404,'Destination folder not found.')
        try:
            length=int(request.headers.get('content-length','0'))
        except ValueError:
            raise HTTPException(400,'Invalid file size.')
        if length<0 or length>TRANSFER_LIMIT:
            raise HTTPException(413,'The file transfer limit is 50 MiB.')
        temporary=None
        try:
            fd,temporary=tempfile.mkstemp(prefix='.maccommand-',dir=parent)
            total=0
            with os.fdopen(fd,'wb') as file:
                async for chunk in request.stream():
                    total+=len(chunk)
                    if total>TRANSFER_LIMIT:
                        raise HTTPException(413,'The file transfer limit is 50 MiB.')
                    await asyncio.to_thread(file.write,chunk)
                if length and length!=total:
                    raise HTTPException(400,'The file transfer was incomplete. Select the file again and retry.')
                file.flush()
                os.fsync(file.fileno())
            # Same-volume hard link publishes atomically and never replaces an existing entry.
            os.link(temporary,destination)
            from fastapi.responses import JSONResponse
            return JSONResponse({'path':str(destination),'size':total},status_code=201)
        except FileExistsError:
            raise HTTPException(409,'A file with this name already exists. Rename the file and try again. The existing file was kept.')
        except PermissionError:
            raise HTTPException(403,'You do not have permission to save files in this folder.')
        except OSError:
            raise HTTPException(400,'Could not save the file. Check the available disk space and folder permissions.')
        finally:
            if temporary:
                Path(temporary).unlink(missing_ok=True)

    @app.get('/files', dependencies=[Depends(verify)])
    def files(path: str = str(Path.home())):
        directory = checked_path(path)
        try:
            entries = []
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if len(entries) >= 10000:
                        raise HTTPException(413, 'This folder contains too many items. Open a smaller folder.')
                    try:
                        stat = entry.stat(follow_symlinks=False)
                        entries.append({'name': entry.name, 'path': entry.path,
                            'is_dir': entry.is_dir(follow_symlinks=False),
                            'is_symlink': entry.is_symlink(), 'size': stat.st_size,
                            'modified': stat.st_mtime})
                    except FileNotFoundError:
                        continue
            entries.sort(key=lambda e: (not e['is_dir'], e['name'].casefold()))
            return {'path': str(directory), 'entries': entries}
        except PermissionError:
            raise HTTPException(403, 'You do not have permission to access this folder. Check the privacy settings on your Mac.')
        except (FileNotFoundError, NotADirectoryError):
            raise HTTPException(404, 'Folder not found.')
        except OSError:
            raise HTTPException(400, 'Could not read the folder.')

    @app.get('/files/read', dependencies=[Depends(verify)])
    def read(path: str):
        target = checked_path(path)
        try:
            if not target.is_file():
                raise HTTPException(404, 'File not found.')
            with target.open('rb') as file:
                data = file.read(FILE_LIMIT+1)
            if len(data) > FILE_LIMIT:
                raise HTTPException(413, 'The preview limit is 5 MiB. Choose a smaller file.')
            if b'\x00' in data:
                raise HTTPException(415, 'Only text files can be previewed.')
            return {'path': str(target), 'content': data.decode('utf-8', errors='replace')}
        except PermissionError:
            raise HTTPException(403, 'You do not have permission to access this file.')
        except FileNotFoundError:
            raise HTTPException(404, 'File not found.')
        except OSError:
            raise HTTPException(400, 'Could not read the file.')

    @app.delete('/files', dependencies=[Depends(verify)])
    def remove(req: DeleteRequest):
        target = checked_path(req.path)
        protected = {Path('/'), Path.home(), Path('/System'), Path('/Library'), Path('/Users'),
                     Path('/Applications'), Path('/Volumes'), Path('/usr'), Path('/bin'),
                     Path('/sbin'), Path('/private'), STATE_DIR}
        # Resolve ancestor aliases without following the final entry: trash a link itself.
        canonical = target.parent.resolve() / target.name
        protected = {item.resolve() for item in protected}
        state = STATE_DIR.resolve()
        if canonical in protected:
            raise HTTPException(403, 'This folder is protected and cannot be moved to the Trash.')
        if canonical == state or state in canonical.parents or canonical in state.parents:
            raise HTTPException(403, 'The pairing configuration is protected.')
        if not target.exists() and not target.is_symlink():
            raise HTTPException(404, 'File not found.')
        try:
            trash(str(target))
            return {'trashed': str(target)}
        except PermissionError:
            raise HTTPException(403, 'You do not have permission to move this file to the Trash. The file was kept.')
        except OSError:
            raise HTTPException(400, 'Could not move the file to the Trash. The file was kept.')

    return app
