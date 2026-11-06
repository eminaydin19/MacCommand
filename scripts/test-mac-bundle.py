"""Verify a copied Mac app contains a working, independent, parent-owned service."""
import asyncio
import base64
import json
from pathlib import Path
import sys
import tempfile
import uuid

from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
from relay_admin import update_registry
from relay_protocol import Cipher, channel_key
from relay_server import create_relay
from test_relay import serve, send_request


async def smoke(executable, state, registry, relay):
    child = await asyncio.create_subprocess_exec(str(executable), '--relay-url', relay,
        '--loopback-test', '--state-dir', str(state), cwd=state.parent,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        ready = json.loads(await asyncio.wait_for(child.stdout.readline(), 15))
        assert ready['event'] == 'ready'
        registration = json.loads(ready['registration'])
        update_registry(registry, registration['device_id'], registration['mac_hash'])
        pairing = json.loads(ready['pairing'])
        while True:
            event = json.loads(await asyncio.wait_for(child.stdout.readline(), 15))
            if event.get('status') == 'connected':
                break
            assert event.get('status') == 'waiting'
        async def request(key, method, path, data=b''):
            request_id = uuid.uuid4().hex
            address = relay.replace('http:', 'ws:', 1) + f'/v1/phone/{registration["device_id"]}/{request_id}'
            async with connect(address, additional_headers={'Authorization': 'Bearer ' + pairing['token']},
                               proxy=None) as phone:
                challenge = json.loads(await asyncio.wait_for(phone.recv(), 4))['challenge']
                derived = channel_key(key, request_id, challenge)
                await send_request(phone, Cipher(derived, request_id, 'request'), method, path, body=data)
                reader = Cipher(derived, request_id, 'response')
                header = reader.open(await asyncio.wait_for(phone.recv(), 4))
                assert header['kind'] == 'head'
                body = bytearray()
                while (event := reader.open(await asyncio.wait_for(phone.recv(), 4)))['kind'] != 'end':
                    assert event['kind'] == 'data'
                    body.extend(base64.b64decode(event['data']))
                return header['status'], json.loads(body)

        bootstrap = base64.b64decode(pairing['key'])
        phone_key = bytes([42]) * 32
        assert (await request(bootstrap, 'GET', '/metrics'))[0] == 401
        assert (await request(bootstrap, 'POST', '/pair',
            json.dumps({'key': base64.b64encode(phone_key).decode()}).encode()))[0] == 201
        status, body = await request(phone_key, 'GET', '/metrics')
        assert status == 200 and 'cpu_percent' in body
        child.stdin.close()
        assert await asyncio.wait_for(child.wait(), 8) == 0
    finally:
        if child.returncode is None:
            child.kill()
            await child.wait()


if __name__ == '__main__':
    executable = Path(sys.argv[1]).resolve() / 'Contents/Helpers/MacCommandService'
    with tempfile.TemporaryDirectory(prefix='maccommand-bundle-test-') as tmp:
        directory = Path(tmp)
        registry = directory / 'devices.json'
        with serve(create_relay(registry)) as relay:
            asyncio.run(smoke(executable, directory / 'state', registry, relay))
    print('Embedded service connected, returned metrics and exited on parent EOF.')
