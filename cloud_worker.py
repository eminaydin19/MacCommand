"""Execute authenticated CloudKit jobs delivered by the Mac parent's private pipe."""
import asyncio
import base64
import json
from pathlib import Path
import secrets
import sqlite3
import sys
import time

import httpx

import main
from relay_bridge import forward
from relay_protocol import Cipher, IDENTIFIER, MAX_FRAME, channel_key

ASSET_LIMIT = 38 * 1024 * 1024
MAX_JOBS = 8


def claim_job(path, job, header, endpoint):
    now = int(time.time())
    deadline = header.get('deadline')
    maximum = 60 if endpoint in ('/terminal/stream', '/pair') else 300
    if type(deadline) is not int or not now < deadline <= now + maximum:
        raise ValueError('Expired CloudKit request')
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE IF NOT EXISTS received (job TEXT PRIMARY KEY, deadline INTEGER)')
        db.execute('DELETE FROM received WHERE deadline < ?', (now - 86400,))
        try:
            db.execute('INSERT INTO received VALUES (?, ?)', (job, deadline))
        except sqlite3.IntegrityError as error:
            raise ValueError('Repeated CloudKit request') from error


def frames(paths):
    if not 1 <= len(paths) <= 2:
        raise ValueError('Invalid CloudKit asset count')
    for path in paths:
        if not 0 < Path(path).stat().st_size <= ASSET_LIMIT:
            raise ValueError('Invalid CloudKit asset size')
        with open(path, 'rb') as file:
            while prefix := file.read(4):
                length = int.from_bytes(prefix, 'big')
                if len(prefix) != 4 or not 36 <= length <= MAX_FRAME:
                    raise ValueError('Invalid CloudKit frame size')
                frame = file.read(length)
                if len(frame) != length:
                    raise ValueError('Incomplete CloudKit frame')
                yield frame


class PacketInput:
    def __init__(self, paths):
        self.frames = frames(paths)

    async def get(self):
        frame = next(self.frames, None)
        if frame is None:
            raise ValueError('Missing CloudKit end frame')
        return frame


class PacketOutput:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.file = None
        self.paths = []
        self.size = 0

    async def append(self, frame):
        size = len(frame) + 4
        if self.file is None or self.size + size > ASSET_LIMIT:
            self.close()
            if len(self.paths) == 2:
                raise ValueError('CloudKit reply exceeds limit')
            path = self.folder / f'reply-{len(self.paths)}.packet'
            self.file = path.open('xb')
            self.paths.append(str(path))
            self.size = 0
        self.file.write(len(frame).to_bytes(4, 'big'))
        self.file.write(frame)
        self.size += size

    def close(self):
        if self.file:
            self.file.close()
            self.file = None


async def run_cloud(config, state, claim, emit):
    token = secrets.token_hex(32)
    transport = httpx.ASGITransport(app=main.create_app(token=token))
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=16384)
    pipe, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    jobs = {}
    async with httpx.AsyncClient(transport=transport, base_url='http://maccommand.local',
            headers={'Authorization': 'Bearer ' + token, 'Accept-Encoding': 'identity'}) as client:

        async def work(job, paths, folder):
            output = PacketOutput(folder)
            packet = PacketInput(paths)
            credential = config.get('phone_key', config['key'])
            key = channel_key(base64.b64decode(credential, validate=True), job, config['device_id'])
            try:
                await forward(packet, Cipher(key, job, 'request'), Cipher(key, job, 'response'),
                              client, output.append, config, credential, claim,
                              authorize=lambda header, path: claim_job(state / 'cloud-receipts.sqlite3', job, header, path))
                output.close()
                emit('job', id=job, paths=output.paths)
            except (OSError, ValueError, TypeError, sqlite3.Error):
                emit('job', id=job, paths=[])
            finally:
                packet.frames.close()
                output.close()
                jobs.pop(job, None)

        try:
            while line := await reader.readline():
                message = json.loads(line)
                job = message.get('id', '')
                if not isinstance(job, str) or not IDENTIFIER.fullmatch(job) or job in jobs:
                    continue
                if len(jobs) >= MAX_JOBS:
                    emit('job', id=job, paths=[])
                    continue
                jobs[job] = asyncio.create_task(work(job, message['paths'], message['folder']))
        finally:
            pipe.close()
            pending = list(jobs.values())
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
