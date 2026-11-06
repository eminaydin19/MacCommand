import importlib.util
import time

import pytest


def test_cloud_request_claim_rejects_expiry_and_replay(tmp_path):
    assert importlib.util.find_spec('cloud_worker'), 'CloudKit worker is missing'
    from cloud_worker import claim_job
    now = int(time.time())
    path = tmp_path / 'receipts.sqlite3'
    job = 'a' * 32
    with pytest.raises(ValueError):
        claim_job(path, job, {'deadline': now - 2}, '/terminal/stream')
    with pytest.raises(ValueError):
        claim_job(path, job, {'deadline': now + 200}, '/terminal/stream')
    claim_job(path, job, {'deadline': now + 45}, '/terminal/stream')
    with pytest.raises(ValueError):
        claim_job(path, job, {'deadline': now + 45}, '/terminal/stream')


def test_cloud_helper_pairs_transfers_and_executes_command_only_once(tmp_path):
    import base64
    import json
    from pathlib import Path
    import selectors
    import subprocess
    import sys
    from urllib.parse import urlencode
    import uuid

    from cloud_worker import frames
    from relay_protocol import Cipher, CHUNK_SIZE, channel_key

    child = subprocess.Popen([sys.executable, 'mac_app.py', '--cloud', '--state-dir', str(tmp_path / 'state')],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        with selectors.DefaultSelector() as events:
            events.register(child.stdout, selectors.EVENT_READ)

            def receive():
                assert events.select(6), 'CloudKit worker did not respond'
                return json.loads(child.stdout.readline())

            ready = receive()
            assert ready['event'] == 'ready'
            code = json.loads(ready['pairing'])
            assert code['version'] == 4 and 'relay' not in code

            def call(key, method, path, body=b'', query='', job=None, deadline=None):
                job = job or uuid.uuid4().hex
                work = tmp_path / uuid.uuid4().hex
                work.mkdir()
                incoming = work / 'input.packet'
                derived = channel_key(key, job, code['device_id'])
                cipher = Cipher(derived, job, 'request')
                header = {'kind': 'head', 'method': method, 'path': path, 'query': query, 'length': len(body),
                          'deadline': deadline if deadline is not None else int(time.time()) + 40}
                with incoming.open('wb') as packet:
                    def emit(value):
                        sealed = cipher.seal(value)
                        packet.write(len(sealed).to_bytes(4, 'big') + sealed)
                    emit(header)
                    for i in range(0, len(body), CHUNK_SIZE):
                        emit({'kind': 'data', 'data': base64.b64encode(body[i:i+CHUNK_SIZE]).decode()})
                    emit({'kind': 'end'})
                child.stdin.write(json.dumps({'id': job, 'paths': [str(incoming)], 'folder': str(work)}).encode() + b'\n')
                result = receive()
                if result['event'] == 'paired':
                    result = receive()
                assert result['id'] == job
                cipher = Cipher(derived, job, 'response')
                decoded = [cipher.open(frame) for frame in frames(result['paths'])]
                assert decoded[-1]['kind'] == 'end'
                data = b''.join(base64.b64decode(item['data']) for item in decoded if item['kind'] == 'data')
                return decoded[0]['status'], data

            bootstrap = base64.b64decode(code['key'])
            key = bytes([99]) * 32
            assert call(bootstrap, 'POST', '/pair', json.dumps({'key': base64.b64encode(key).decode()}).encode())[0] == 201
            with pytest.raises(ValueError, match='authenticated frame'):
                call(bootstrap, 'GET', '/info')
            blob = b'\xff' * (CHUNK_SIZE + 1) + b'cloud file'
            params = urlencode({'directory': str(tmp_path), 'name': 'Türkçe + dosya.bin'})
            assert call(key, 'PUT', '/files/upload', blob, params)[0] == 201
            assert call(key, 'PUT', '/files/upload', b'overwrite', params)[0] == 409
            assert call(key, 'GET', '/files/download', query=urlencode({'path': str(tmp_path / 'Türkçe + dosya.bin')})) == (200, blob)
            command_id = uuid.uuid4().hex
            command = json.dumps({'command': 'printf run >> marker', 'cwd': str(tmp_path), 'id': command_id}).encode()
            assert call(key, 'POST', '/terminal/stream', command, job=command_id, deadline=int(time.time()) - 1)[0] == 400
            assert not (tmp_path / 'marker').exists()
            assert call(key, 'POST', '/terminal/stream', command, job=command_id)[0] == 200
            assert call(key, 'POST', '/terminal/stream', command, job=command_id)[0] == 400
            assert (tmp_path / 'marker').read_text() == 'run'
        child.stdin.close()
        assert child.wait(timeout=6) == 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
