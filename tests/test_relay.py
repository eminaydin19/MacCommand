import asyncio
import base64
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import socket
import threading
import time
from urllib.parse import urlencode
import uuid

import pytest
import uvicorn
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from main import create_app
from relay_protocol import Cipher, CHUNK_SIZE, channel_key

DEVICE = 'd' * 32
MAC_TOKEN = '1' * 64
PHONE_TOKEN = '2' * 64
KEY = bytes(range(32))


@contextmanager
def serve(app):
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level='critical', access_log=False,
                                          ws_max_size=100000, ws_max_queue=8))
    thread = threading.Thread(target=lambda: server.run(sockets=[sock]), daemon=True)
    thread.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(.02)
    assert server.started
    try:
        yield f'http://127.0.0.1:{port}'
    finally:
        server.should_exit = True
        thread.join(5)
        sock.close()
        assert not thread.is_alive()


@pytest.fixture
def relay(tmp_path):
    assert importlib.util.find_spec('relay_server'), 'Blind relay has not been implemented'
    from relay_server import create_relay
    registry = tmp_path / 'devices.json'
    registry.write_text(json.dumps({DEVICE: {
        'mac_hash': hashlib.sha256(MAC_TOKEN.encode()).hexdigest(),
        'phone_hash': hashlib.sha256(PHONE_TOKEN.encode()).hexdigest()}}))
    with serve(create_relay(registry)) as base:
        yield base.replace('http:', 'ws:')


async def phone(relay, token=PHONE_TOKEN, rid=None):
    rid = rid or uuid.uuid4().hex
    ws = await connect(f'{relay}/v1/phone/{DEVICE}/{rid}',
                       additional_headers={'Authorization': 'Bearer ' + token}, proxy=None)
    challenge = json.loads(await asyncio.wait_for(ws.recv(), 3))['challenge']
    key = channel_key(KEY, rid, challenge)
    return ws, Cipher(key, rid, 'request'), Cipher(key, rid, 'response')


async def send_request(ws, cipher, method, path, query='', body=b''):
    await ws.send(cipher.seal({'kind': 'head', 'method': method, 'path': path,
                               'query': query, 'length': len(body)}))
    for offset in range(0, len(body), CHUNK_SIZE):
        await ws.send(cipher.seal({'kind': 'data', 'data': base64.b64encode(body[offset:offset+CHUNK_SIZE]).decode()}))
    await ws.send(cipher.seal({'kind': 'end'}))


async def call(relay, method, path, query='', body=b''):
    ws, sender, reader = await phone(relay)
    async with ws:
        sending = asyncio.create_task(send_request(ws, sender, method, path, query, body))
        data = bytearray()
        status = None
        try:
            while True:
                event = reader.open(await asyncio.wait_for(ws.recv(), 4))
                assert event['kind'] != 'error', event
                if event['kind'] == 'head':
                    status = event['status']
                elif event['kind'] == 'data':
                    data.extend(base64.b64decode(event['data'], validate=True))
                elif event['kind'] == 'end':
                    break
            await sending
            return status, bytes(data)
        finally:
            sending.cancel()
            await asyncio.gather(sending, return_exceptions=True)


@contextmanager
def backend():
    with serve(create_app(token='relay-test')) as local:
        yield local


async def with_bridge(relay, local, test, config=None, claim=None):
    from relay_bridge import bridge_connection
    ws = await connect(f'{relay}/v1/mac/{DEVICE}',
                       additional_headers={'Authorization': 'Bearer ' + MAC_TOKEN,
                           'X-MacCommand-Phone-Hash': hashlib.sha256(PHONE_TOKEN.encode()).hexdigest()}, proxy=None)
    if config is None:
        key = base64.b64encode(KEY).decode()
        config = {'key': key, 'phone_key': key}
    task = asyncio.create_task(bridge_connection(ws, config, local, 'relay-test', claim=claim))
    try:
        await test()
    finally:
        await ws.close()
        await asyncio.gather(task, return_exceptions=True)


def test_relay_rejects_unknown_auth_and_offline_mac(relay):
    async def run():
        with pytest.raises(InvalidStatus):
            await phone(relay, token='wrong')
        with pytest.raises(InvalidStatus):
            await phone(relay)
    asyncio.run(run())


def test_relay_binary_roundtrip_no_overwrite_and_fixed_destination(relay, tmp_path):
    blob = bytes(range(256)) * 8192
    query = urlencode({'directory': str(tmp_path), 'name': 'Türkçe.bin'})
    async def test():
        status, content = await call(relay, 'GET', '/info')
        assert status == 200 and json.loads(content)['version'] == 2
        assert (await call(relay, 'PUT', '/files/upload', query, blob))[0] == 201
        assert (tmp_path / 'Türkçe.bin').read_bytes() == blob
        assert (await call(relay, 'PUT', '/files/upload', query, b'overwrite'))[0] == 409
        status, data = await call(relay, 'GET', '/files/download', urlencode({'path': str(tmp_path / 'Türkçe.bin')}))
        assert status == 200 and data == blob
        assert (await call(relay, 'GET', 'https://evil.example/info'))[0] == 400
    with backend() as local:
        asyncio.run(with_bridge(relay, local, test))


def test_relay_live_output_stop_and_disconnect_kill_command(relay, tmp_path):
    async def test():
        for disconnect in [False, True]:
            marker = tmp_path / 'must-not-run'
            ws, sender, reader = await phone(relay)
            async with ws:
                command_id = uuid.uuid4().hex
                body = json.dumps({'command': f'printf ready; sleep 1; touch {marker}',
                                   'cwd': str(tmp_path), 'id': command_id}).encode()
                await send_request(ws, sender, 'POST', '/terminal/stream', body=body)
                received = b''
                while b'ready' not in received:
                    event = reader.open(await asyncio.wait_for(ws.recv(), 2))
                    if event['kind'] == 'data':
                        received += base64.b64decode(event['data'])
                if not disconnect:
                    assert (await call(relay, 'DELETE', '/terminal/' + command_id))[0] == 200
            await asyncio.sleep(1.2)
            assert not marker.exists(), 'Remote shell survived relay cancellation'
            status, output = await call(relay, 'POST', '/terminal/stream', body=json.dumps({
                'command': 'printf done', 'cwd': str(tmp_path), 'id': uuid.uuid4().hex}).encode())
            assert status == 200 and b'done' in output
    with backend() as local:
        asyncio.run(with_bridge(relay, local, test))


def test_relay_disconnect_cleans_partial_upload_and_releases_slots(relay, tmp_path):
    async def test():
        ws, sender, _ = await phone(relay)
        async with ws:
            await ws.send(sender.seal({'kind': 'head', 'method': 'PUT', 'path': '/files/upload',
                'query': urlencode({'directory':str(tmp_path),'name':'partial.bin'}), 'length':100000}))
            await ws.send(sender.seal({'kind':'data','data':base64.b64encode(b'x'*1000).decode()}))
            await asyncio.sleep(.15)
        await asyncio.sleep(.3)
        assert not (tmp_path / 'partial.bin').exists()
        assert not list(tmp_path.glob('.maccommand-*'))
        assert (await call(relay, 'GET', '/info'))[0] == 200
    with backend() as local:
        asyncio.run(with_bridge(relay, local, test))


def test_bootstrap_qr_cannot_control_mac_or_pair_twice(relay):
    config = {'key': base64.b64encode(KEY).decode()}
    fresh_key = bytes([27]) * 32

    def claim(encoded_key):
        config['phone_key'] = encoded_key

    async def request(path, key, method='GET', body=b''):
        rid = uuid.uuid4().hex
        async with connect(f'{relay}/v1/phone/{DEVICE}/{rid}', additional_headers={
                'Authorization': 'Bearer ' + PHONE_TOKEN}, proxy=None) as ws:
            challenge = json.loads(await asyncio.wait_for(ws.recv(), 3))['challenge']
            derived = channel_key(key, rid, challenge)
            await send_request(ws, Cipher(derived, rid, 'request'), method, path, body=body)
            return Cipher(derived, rid, 'response').open(await asyncio.wait_for(ws.recv(), 3))['status']

    async def test():
        assert await request('/info', KEY) == 401
        body = json.dumps({'key': base64.b64encode(fresh_key).decode()}).encode()
        assert await request('/pair', KEY, 'POST', body) == 201
        assert await request('/info', fresh_key) == 200
        with pytest.raises(ValueError):
            await request('/pair', KEY, 'POST', body)

    with backend() as local:
        asyncio.run(with_bridge(relay, local, test, config=config, claim=claim))
