"""Private child process of the native MacCommand app."""
import argparse
import asyncio
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import sys
import tempfile
from urllib.parse import urlsplit, urlunsplit

import uvicorn
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

import main
from cloud_worker import run_cloud
from relay_bridge import bridge_connection
from relay_protocol import IDENTIFIER, MAX_FRAME, TOKEN


def load_config(path: Path, rotate=False) -> dict:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        config = {'device_id': secrets.token_hex(16), 'mac_token': secrets.token_hex(32)}
        rotate = True
    else:
        with os.fdopen(fd, 'rb') as file:
            info = os.fstat(file.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('Insecure configuration')
            raw = file.read(8193)
            if len(raw) > 8192:
                raise ValueError('Invalid configuration')
            config = json.loads(raw)
        if (not isinstance(config, dict) or not IDENTIFIER.fullmatch(config.get('device_id', ''))
                or not TOKEN.fullmatch(config.get('mac_token', ''))
                or not TOKEN.fullmatch(config.get('phone_token', ''))
                or len(base64.b64decode(config.get('key', ''), validate=True)) != 32):
            raise ValueError('Invalid configuration')
    if rotate:
        config.pop('phone_key', None)
        config.update(phone_token=secrets.token_hex(32), key=base64.b64encode(secrets.token_bytes(32)).decode())
        save_config(path, config)
    elif 'phone_key' in config and len(base64.b64decode(config['phone_key'], validate=True)) != 32:
        raise ValueError('Invalid phone configuration')
    return config


def save_config(path: Path, config: dict):
    fd, name = tempfile.mkstemp(prefix='.companion-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(config, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def load_companion(state: Path, rotate=False, cloud=False) -> dict:
    marker = state / 'rotate.pending'
    path = state / ('companion-v4.json' if cloud else 'companion-v3.json')
    if cloud and not path.exists() and (state / 'companion-v3.json').exists():
        previous = load_config(state / 'companion-v3.json')
        config = load_config(path)
        config['device_id'] = previous['device_id']
        save_config(path, config)
    config = load_config(path, rotate=rotate or marker.exists())
    marker.unlink(missing_ok=True)
    return config


def public_registration(config: dict) -> dict:
    return {'device_id': config['device_id'], 'mac_hash': hashlib.sha256(config['mac_token'].encode()).hexdigest()}


def phone_pairing(config: dict, relay: str) -> dict:
    return {'version': 3, 'relay': relay, 'device_id': config['device_id'],
            'token': config['phone_token'], 'key': config['key']}


def websocket_origin(relay: str, allow_loopback=False) -> str:
    url = urlsplit(relay)
    valid = url.scheme == 'https' or (allow_loopback and url.scheme == 'http'
                                      and url.hostname == '127.0.0.1' and url.port)
    if (not valid or not url.hostname or url.username is not None or url.password is not None
            or url.path not in ('', '/') or url.query or url.fragment or url.port == 0
            or '?' in relay or '#' in relay or any(c.isspace() for c in relay)):
        raise ValueError('Invalid relay origin')
    return urlunsplit(('wss' if url.scheme == 'https' else 'ws', url.netloc, '', '', ''))


class NoRedirectConnect(connect):
    def process_redirect(self, exc):
        return exc


def emit(event: str, **values):
    print(json.dumps({'event': event, **values}, ensure_ascii=False), flush=True)


async def stay_connected(origin, config, local_url, api_token, claim):
    url = origin + '/v1/mac/' + config['device_id']
    delay = 1
    while True:
        try:
            async with NoRedirectConnect(url, additional_headers={
                'Authorization': 'Bearer ' + config['mac_token'],
                'X-MacCommand-Phone-Hash': hashlib.sha256(config['phone_token'].encode()).hexdigest(),
            }, proxy=None, compression=None, max_size=MAX_FRAME+16, max_queue=8,
                    open_timeout=10, close_timeout=2) as websocket:
                ack = await asyncio.wait_for(websocket.recv(), 10)
                if ack != '{"type":"connected"}':
                    if not isinstance(ack, str) or len(ack) > 128 or json.loads(ack) != {'type': 'connected'}:
                        raise ValueError('Invalid relay handshake')
                delay = 1
                emit('status', status='connected')
                await bridge_connection(websocket, config, local_url, api_token, claim=claim)
        except (OSError, TimeoutError, ValueError, AttributeError, WebSocketException):
            pass
        emit('status', status='waiting')
        await asyncio.sleep(delay)
        delay = min(delay * 2, 15)


async def run(config: dict, origin: str, claim):
    token = secrets.token_hex(32)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    fd = sys.stdin.fileno()

    def parent_input():
        try:
            if os.read(fd, 1):
                return
        except OSError:
            pass
        loop.remove_reader(fd)
        stopped.set()

    loop.add_reader(fd, parent_input)
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
            server = uvicorn.Server(uvicorn.Config(main.create_app(token=token), log_level='critical',
                access_log=False, loop='asyncio', http='h11', ws='none', timeout_graceful_shutdown=2))
            api = asyncio.create_task(server.serve(sockets=[listener]))
            parent = asyncio.create_task(stopped.wait())
            relay = None
            try:
                while not server.started and not api.done() and not stopped.is_set():
                    await asyncio.sleep(.025)
                if not server.started:
                    if api.done():
                        await api
                    return
                relay = asyncio.create_task(stay_connected(origin, config, f'http://127.0.0.1:{port}', token, claim))
                await asyncio.wait([api, parent, relay], return_when=asyncio.FIRST_COMPLETED)
                if relay.done():
                    await relay
            finally:
                for task in [parent, relay]:
                    if task:
                        task.cancel()
                await asyncio.gather(*(task for task in [parent, relay] if task), return_exceptions=True)
                server.should_exit = True
                await api
    finally:
        loop.remove_reader(fd)


def cli():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--relay-url')
    mode.add_argument('--cloud', action='store_true')
    parser.add_argument('--rotate-only', action='store_true')
    parser.add_argument('--state-dir', type=Path, default=main.STATE_DIR)
    parser.add_argument('--loopback-test', action='store_true')
    args = parser.parse_args()
    try:
        origin = None if args.cloud else websocket_origin(args.relay_url, args.loopback_test)
        state = args.state_dir
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        if state.is_symlink() or state.stat().st_uid != os.getuid():
            raise ValueError('Insecure state directory')
        main.STATE_DIR = state
        fd = os.open(state / 'service.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                emit('status', status='alreadyRunning')
                raise SystemExit(2)
            config = load_companion(state, rotate=args.rotate_only, cloud=args.cloud)
            pairing = ({'version': 4, 'device_id': config['device_id'], 'key': config['key']}
                       if args.cloud else phone_pairing(config, args.relay_url))
            code = None if 'phone_key' in config else json.dumps(pairing, separators=(',', ':'))
            emit('ready', pairing=code, device_id=config['device_id'],
                 registration=None if args.cloud else json.dumps(public_registration(config), separators=(',', ':')))

            def claim(key):
                updated = dict(config, phone_key=key)
                save_config(state / ('companion-v4.json' if args.cloud else 'companion-v3.json'), updated)
                config.update(updated)
                emit('paired')

            if not args.rotate_only:
                if args.cloud:
                    asyncio.run(run_cloud(config, state, claim, emit))
                else:
                    asyncio.run(run(config, origin, claim))
    except (OSError, ValueError, TypeError, RuntimeError):
        emit('status', status='error')
        raise SystemExit(1)


if __name__ == '__main__':
    cli()
