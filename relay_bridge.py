"""Mac-side authenticated bridge. The relay can route frames, never read them."""
import asyncio
import base64
import binascii
import json
import re
import secrets
from urllib.parse import parse_qsl, urlsplit

import httpx
from websockets.exceptions import ConnectionClosed

from relay_protocol import CHUNK_SIZE, IDENTIFIER, MAX_FRAME, Cipher, channel_key

TRANSFER_LIMIT = 50 * 1024 * 1024
JSON_LIMIT = 96 * 1024
ROUTES = {
    'GET': {'/info', '/metrics', '/files', '/files/read', '/files/download'},
    'POST': {'/terminal/stream', '/pair'},
    'PUT': {'/files/upload'},
    'DELETE': {'/files'},
}


def request_head(frame: dict):
    method, path = frame.get('method'), frame.get('path')
    query, length = frame.get('query', ''), frame.get('length')
    if (frame.get('kind') != 'head' or not isinstance(method, str) or not isinstance(path, str)
            or not isinstance(query, str) or len(query) > 50000 or type(length) is not int):
        raise ValueError('Invalid request head')
    if path not in ROUTES.get(method, set()) and not (
            method == 'DELETE' and re.fullmatch(r'/terminal/[a-f0-9]{32}', path)):
        raise ValueError('Unsupported API path')
    if path == '/pair':
        limit = 512
    elif method == 'PUT':
        limit = TRANSFER_LIMIT
    elif method == 'GET' or (method == 'DELETE' and path.startswith('/terminal/')):
        limit = 0
    else:
        limit = JSON_LIMIT
    if not 0 <= length <= limit:
        raise ValueError('Invalid body length')
    return method, path, parse_qsl(query, keep_blank_values=True, max_num_fields=8, errors='strict'), length


async def request_chunks(queue, cipher, expected):
    total = 0
    while True:
        frame = cipher.open(await asyncio.wait_for(queue.get(), 45))
        if frame['kind'] == 'end':
            if total != expected:
                raise ValueError('Incomplete request body')
            return
        if frame['kind'] != 'data' or not isinstance(frame.get('data'), str):
            raise ValueError('Unexpected body frame')
        chunk = base64.b64decode(frame['data'], validate=True)
        total += len(chunk)
        if not 0 < len(chunk) <= CHUNK_SIZE or total > expected:
            raise ValueError('Invalid body chunk')
        yield chunk


async def forward(queue, request, response, client, send, config, credential, claim, authorize=None):
    head_sent = False

    async def emit(payload):
        await send(response.seal(payload))

    async def reply(status, value):
        body = json.dumps(value).encode()
        await emit({'kind': 'head', 'status': status, 'length': len(body)})
        await emit({'kind': 'data', 'data': base64.b64encode(body).decode()})
        await emit({'kind': 'end'})

    async def failure(status, message):
        if head_sent:
            await emit({'kind': 'error', 'message': message})
        else:
            await reply(status, {'detail': message})

    try:
        async with asyncio.timeout(350):
            header = request.open(await asyncio.wait_for(queue.get(), 15))
            method, path, query, length = request_head(header)
            if authorize is not None:
                authorize(header, path)
            chunks = request_chunks(queue, request, length)
            if path == '/pair':
                payload = json.loads(b''.join([chunk async for chunk in chunks]))
                new_key = payload.get('key') if isinstance(payload, dict) else None
                if not isinstance(new_key, str):
                    raise ValueError('Invalid phone key')
                decoded = base64.b64decode(new_key, validate=True)
                if len(decoded) != 32 or decoded == base64.b64decode(config['key']):
                    raise ValueError('Invalid phone key')
                if claim is None or config.get('phone_key') is not None or credential != config['key']:
                    return await failure(409, 'This QR code has already been used. Reset pairing on your Mac.')
                try:
                    claim(base64.b64encode(decoded).decode())
                except OSError:
                    return await failure(500, 'Your Mac could not save the pairing.')
                return await reply(201, {'paired': True})
            if config.get('phone_key') != credential:
                return await failure(401, 'Pair with your Mac first.')
            if method == 'PUT':
                # The terminating HTTP chunk follows the authenticated end frame. The
                # local API cannot commit an upload whose sender disconnected early.
                content, content_type = chunks, 'application/octet-stream'
            else:
                content = b''.join([chunk async for chunk in chunks])
                content_type = 'application/json'
            async with client.stream(method, path, params=query, content=content,
                                     headers={'Content-Type': content_type}) as result:
                if result.status_code == 200 and path == '/files/download':
                    limit = TRANSFER_LIMIT
                elif result.status_code == 200 and path == '/files/read':
                    limit = 30 * 1024 * 1024 + 65536
                else:
                    limit = 8 * 1024 * 1024
                declared = result.headers.get('content-length')
                count = int(declared) if declared is not None else None
                if count is not None and not 0 <= count <= limit:
                    raise ValueError('Invalid response length')
                await emit({'kind': 'head', 'status': result.status_code, 'length': count})
                head_sent = True
                total = 0
                async for raw in result.aiter_raw():
                    total += len(raw)
                    if total > limit:
                        raise ValueError('Response exceeds limit')
                    for offset in range(0, len(raw), CHUNK_SIZE):
                        await emit({'kind': 'data', 'data': base64.b64encode(raw[offset:offset+CHUNK_SIZE]).decode()})
                if count is not None and count != total:
                    raise ValueError('Incomplete response')
                await emit({'kind': 'end'})
    except (ValueError, binascii.Error):
        await failure(400, 'The MacCommand request is invalid or the transfer is incomplete.')
    except (httpx.HTTPError, TimeoutError):
        await failure(502, 'The connection to your Mac was lost or timed out.')


async def bridge_connection(websocket, config, local_url, api_token, claim=None):
    origin = urlsplit(local_url)
    if (origin.scheme != 'http' or origin.hostname != '127.0.0.1' or not origin.port
            or origin.username is not None or origin.password is not None
            or origin.path or origin.query or origin.fragment):
        raise ValueError('Mac API must be loopback')
    workers = {}
    send_lock = asyncio.Lock()

    async def send(payload):
        async with asyncio.timeout(10), send_lock:
            await websocket.send(payload)

    async with httpx.AsyncClient(base_url=local_url, trust_env=False, follow_redirects=False,
            headers={'Authorization': 'Bearer ' + api_token, 'Accept-Encoding': 'identity'},
            timeout=httpx.Timeout(330, connect=3, write=45, pool=5),
            limits=httpx.Limits(max_connections=8, max_keepalive_connections=4)) as client:

        async def work(request_id, challenge, queue, credential):
            key = base64.b64decode(credential, validate=True)
            derived = channel_key(key, request_id, challenge)
            prefix = bytes.fromhex(request_id)

            async def send_frame(frame):
                await send(prefix + frame)

            try:
                await forward(queue, Cipher(derived, request_id, 'request'),
                              Cipher(derived, request_id, 'response'), client, send_frame, config, credential, claim)
            except (OSError, TimeoutError, ConnectionClosed):
                pass
            finally:
                workers.pop(request_id, None)

        try:
            async for payload in websocket:
                if isinstance(payload, str):
                    if len(payload) > 256:
                        raise ValueError('Invalid relay control')
                    control = json.loads(payload)
                    if control.get('type') == 'connected':
                        continue
                    request_id = control.get('id', '')
                    if not isinstance(request_id, str) or not IDENTIFIER.fullmatch(request_id):
                        raise ValueError('Invalid relay request ID')
                    if control.get('type') == 'open' and request_id not in workers and len(workers) < 8:
                        queue = asyncio.Queue(maxsize=8)
                        challenge = secrets.token_hex(16)
                        credential = config.get('phone_key', config['key'])
                        task = asyncio.create_task(work(request_id, challenge, queue, credential))
                        workers[request_id] = (task, queue)
                        await send(json.dumps({'type': 'ready', 'id': request_id, 'challenge': challenge}))
                    elif control.get('type') == 'close' and request_id in workers:
                        task, _ = workers[request_id]
                        task.cancel()
                        await asyncio.gather(task, return_exceptions=True)
                        workers.pop(request_id, None)
                elif 52 <= len(payload) <= MAX_FRAME + 16:
                    request_id = payload[:16].hex()
                    if request_id in workers:
                        task, queue = workers[request_id]
                        try:
                            await asyncio.wait_for(queue.put(payload[16:]), 5)
                        except TimeoutError:
                            task.cancel()
                            await asyncio.gather(task, return_exceptions=True)
                            workers.pop(request_id, None)
        finally:
            tasks = [task for task, _ in workers.values()]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
