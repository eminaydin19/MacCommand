import sys
import time
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from main import create_app, execute_command


@pytest.fixture
def client(tmp_path):
    app = create_app(token='test-token', trash=lambda p: Path(p).rename(tmp_path / 'trashed'))
    with TestClient(app) as c:
        c.headers['Authorization'] = 'Bearer test-token'
        yield c


def test_every_management_route_requires_auth(client):
    for method, path in [('GET','/info'), ('GET','/metrics'), ('GET','/files'),
                         ('GET','/files/read?path=/tmp/x'), ('POST','/terminal'), ('DELETE','/files')]:
        r = client.request(method, path, headers={'Authorization':'Bearer wrong'}, json={})
        assert r.status_code == 401
    assert client.get('/health', headers={'Authorization':''}).status_code == 200


def test_info_and_metrics_contract(client):
    assert client.get('/info').json()['version'] == 2
    metrics = client.get('/metrics').json()
    assert 0 <= metrics['cpu_percent'] <= 100
    assert metrics['ram']['total'] > 0


def test_read_list_and_recoverable_trash(client, tmp_path):
    file = tmp_path / 'Türkçe dosya.txt'
    file.write_text('Merhaba')
    assert client.get('/files', params={'path':str(tmp_path)}).json()['entries'][0]['name'] == file.name
    assert client.get('/files/read', params={'path':str(file)}).json()['content'] == 'Merhaba'
    r = client.request('DELETE', '/files', json={'path':str(file)})
    assert r.status_code == 200 and (tmp_path/'trashed').read_text() == 'Merhaba'


@pytest.mark.parametrize('path', ['/', str(Path.home()), '/System'])
def test_protected_paths_never_trashed(client, path):
    assert client.request('DELETE','/files',json={'path':path}).status_code == 403


def test_missing_and_oversize_files(client, tmp_path):
    missing = client.get('/files/read', params={'path':str(tmp_path/'missing')})
    assert missing.status_code == 404
    assert missing.json()['detail'] == 'File not found.'
    file = tmp_path/'big'
    with file.open('wb') as f:
        f.truncate(5*1024*1024+1)
    oversized = client.get('/files/read',params={'path':str(file)})
    assert oversized.status_code == 413
    assert oversized.json()['detail'] == 'The preview limit is 5 MiB. Choose a smaller file.'


def test_command_timeout_kills_descendants(tmp_path):
    start=time.monotonic()
    result=execute_command('sleep 5 & wait', str(tmp_path), timeout=0.15)
    assert result['returncode'] == -1 and result['timed_out']
    assert time.monotonic()-start < 2


def test_command_output_is_bounded_and_invalid_cwd_rejected(client, tmp_path):
    result=execute_command("printf 'hello'", str(tmp_path))
    assert result['stdout']=='hello' and result['returncode']==0
    result=execute_command('yes output', str(tmp_path), output_limit=4096, timeout=2)
    assert result['truncated'] and len(result['stdout'].encode()) <= 4096
    assert client.post('/terminal',json={'command':'pwd','cwd':'/does/not/exist'}).status_code == 400
    assert client.post('/terminal',json={'command':''}).status_code == 422


def test_symlink_trash_moves_link_not_target(client, tmp_path):
    original=tmp_path/'original'
    original.write_text('keep')
    link=tmp_path/'link'
    link.symlink_to(original)
    assert client.request('DELETE','/files',json={'path':str(link)}).status_code == 200
    assert original.read_text() == 'keep'
    assert (tmp_path/'trashed').is_symlink()


def test_trash_failure_never_falls_back_to_delete(tmp_path):
    file=tmp_path/'important'
    file.write_text('keep')
    def unavailable(path):
        raise OSError('trash unavailable')
    c=TestClient(create_app(token='t',trash=unavailable))
    assert c.request('DELETE','/files',json={'path':str(file)},headers={'Authorization':'Bearer t'}).status_code == 400
    assert file.read_text() == 'keep'


def test_binary_file_and_permission_failure(client,tmp_path):
    file=tmp_path/'binary'
    file.write_bytes(b'abc\x00def')
    assert client.get('/files/read',params={'path':str(file)}).status_code == 415


def test_pairing_directory_protection_handles_ancestor_alias(monkeypatch,tmp_path):
    import main
    actual=tmp_path/'owner'
    state=actual/'Library'/'Application Support'/'MacCommand'
    state.mkdir(parents=True)
    key=state/'pairing.key'; key.write_bytes(bytes(32))
    alias=tmp_path/'alias'; alias.symlink_to(actual,target_is_directory=True)
    monkeypatch.setattr(main,'STATE_DIR',state)
    trashed=[]
    c=TestClient(create_app(token='t',trash=trashed.append))
    for target in [alias/'Library'/'Application Support'/'MacCommand'/'pairing.key',alias/'Library']:
        assert c.request('DELETE','/files',json={'path':str(target)},headers={'Authorization':'Bearer t'}).status_code == 403
    assert not trashed and key.exists()
