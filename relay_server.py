"""Single-instance blind WebSocket relay for a closed MacCommand beta."""
import asyncio
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import secrets
import time

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from relay_protocol import IDENTIFIER, MAX_FRAME, TOKEN

MAX_MACS = 16
MAX_REQUESTS = 8
REQUEST_TIMEOUT = 360
SEND_TIMEOUT = 5


def token_hash(header: str) -> str:
    token = header.removeprefix('Bearer ')
    if not header.startswith('Bearer ') or not TOKEN.fullmatch(token):
        return ''
    return hashlib.sha256(token.encode()).hexdigest()


def registered_hash(path: Path, device_id: str) -> str:
    try:
        with path.open('rb') as file:
            raw = file.read(65537)
        if len(raw) > 65536:
            return ''
        entry = json.loads(raw).get(device_id, {})
        result = entry.get('mac_hash', '')
        return result if isinstance(result, str) and TOKEN.fullmatch(result) else ''
    except (OSError, ValueError, AttributeError):
        return ''


@dataclass
class Channel:
    queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=8))
    closed: asyncio.Event = field(default_factory=asyncio.Event)


@dataclass
class Mac:
    socket: WebSocket
    phone_hash: str
    channels: dict = field(default_factory=dict)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send(self, *, data=None, control=None):
        async with asyncio.timeout(SEND_TIMEOUT), self.send_lock:
            if data is not None:
                await self.socket.send_bytes(data)
            else:
                await self.socket.send_json(control)


async def close(socket, code=1000):
    try:
        async with asyncio.timeout(SEND_TIMEOUT):
            await socket.close(code=code)
    except (WebSocketDisconnect, RuntimeError, OSError, TimeoutError):
        pass


def create_relay(devices_file: Path) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    peers: dict[str, Mac] = {}

    @app.get('/health')
    async def health():
        return {'status': 'ok', 'protocol': 1}

    @app.websocket('/v1/mac/{device_id}')
    async def mac(socket: WebSocket, device_id: str):
        claimed = token_hash(socket.headers.get('authorization', ''))
        phone = socket.headers.get('x-maccommand-phone-hash', '')
        if (not IDENTIFIER.fullmatch(device_id) or not claimed or not TOKEN.fullmatch(phone)
                or not secrets.compare_digest(claimed, registered_hash(devices_file, device_id))
                or device_id in peers or len(peers) >= MAX_MACS):
            return await close(socket, 1008)
        peer = Mac(socket, phone)
        peers[device_id] = peer
        try:
            await socket.accept()
            await peer.send(control={'type': 'connected'})
            recheck_at = time.monotonic() + 15
            while True:
                if time.monotonic() >= recheck_at:
                    if not secrets.compare_digest(claimed, registered_hash(devices_file, device_id)):
                        break
                    recheck_at = time.monotonic() + 15
                try:
                    message = await asyncio.wait_for(socket.receive(), timeout=15)
                except TimeoutError:
                    continue
                if message['type'] == 'websocket.disconnect':
                    break
                data, text = message.get('bytes'), message.get('text')
                if data is not None and 52 <= len(data) <= MAX_FRAME + 16:
                    request_id, payload = data[:16].hex(), data[16:]
                elif text is not None and len(text) <= 256:
                    control = json.loads(text)
                    request_id, challenge = control.get('id', ''), control.get('challenge', '')
                    if (control.get('type') != 'ready' or not isinstance(request_id, str)
                            or not isinstance(challenge, str) or not IDENTIFIER.fullmatch(challenge)):
                        break
                    payload = json.dumps({'type': 'ready', 'challenge': challenge})
                else:
                    break
                channel = peer.channels.get(request_id)
                if channel and not channel.closed.is_set():
                    try:
                        await asyncio.wait_for(channel.queue.put(payload), SEND_TIMEOUT)
                    except TimeoutError:
                        channel.closed.set()
        except (WebSocketDisconnect, OSError, RuntimeError, TimeoutError, ValueError, AttributeError):
            pass
        finally:
            peers.pop(device_id, None)
            for channel in peer.channels.values():
                channel.closed.set()
            await close(socket)

    @app.websocket('/v1/phone/{device_id}/{request_id}')
    async def phone(socket: WebSocket, device_id: str, request_id: str):
        peer = peers.get(device_id)
        claimed = token_hash(socket.headers.get('authorization', ''))
        if (peer is None or not claimed or not secrets.compare_digest(claimed, peer.phone_hash)
                or not IDENTIFIER.fullmatch(request_id) or request_id in peer.channels
                or len(peer.channels) >= MAX_REQUESTS):
            return await close(socket, 1008)
        channel = Channel()
        peer.channels[request_id] = channel
        prefix = bytes.fromhex(request_id)
        tasks = []

        async def from_phone():
            while True:
                message = await socket.receive()
                if message['type'] == 'websocket.disconnect':
                    return
                payload = message.get('bytes')
                if payload is None or not 36 <= len(payload) <= MAX_FRAME:
                    return
                await peer.send(data=prefix + payload)

        async def to_phone():
            while True:
                payload = await channel.queue.get()
                async with asyncio.timeout(SEND_TIMEOUT):
                    if isinstance(payload, bytes):
                        await socket.send_bytes(payload)
                    else:
                        await socket.send_text(payload)

        try:
            await socket.accept()
            await peer.send(control={'type': 'open', 'id': request_id})
            tasks = [asyncio.create_task(run()) for run in (from_phone, to_phone, channel.closed.wait)]
            async with asyncio.timeout(REQUEST_TIMEOUT):
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (WebSocketDisconnect, OSError, RuntimeError, TimeoutError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            channel.closed.set()
            if peers.get(device_id) is peer:
                try:
                    await peer.send(control={'type': 'close', 'id': request_id})
                except (WebSocketDisconnect, OSError, RuntimeError, TimeoutError):
                    pass
            peer.channels.pop(request_id, None)
            await close(socket)

    return app


def app_factory() -> FastAPI:
    return create_relay(Path(os.environ.get('MACCOMMAND_DEVICES_FILE', '/data/devices.json')))
