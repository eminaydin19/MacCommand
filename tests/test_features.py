import asyncio
import json
import time
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from main import create_app
from terminal_stream import command_events

@pytest.fixture
def client():
    with TestClient(create_app(token='t')) as c:
        c.headers['Authorization']='Bearer t'
        yield c

def test_binary_roundtrip_without_overwriting(client,tmp_path):
    blob=bytes(range(256))*512
    params={'directory':str(tmp_path),'name':'Türkçe file.bin'}
    r=client.put('/files/upload',params=params,content=blob)
    assert r.status_code==201
    path=tmp_path/'Türkçe file.bin'
    assert path.read_bytes()==blob
    r=client.get('/files/download',params={'path':str(path)})
    assert r.status_code==200 and r.content==blob
    assert client.put('/files/upload',params=params,content=b'changed').status_code==409
    assert path.read_bytes()==blob

@pytest.mark.parametrize('name',['../escape','/absolute','', 'folder/name', '.', '..'])
def test_upload_rejects_unsafe_names(client,tmp_path,name):
    assert client.put('/files/upload',params={'directory':str(tmp_path),'name':name},content=b'x').status_code in [400,422]

def test_transfer_limits_and_auth(client,tmp_path):
    params={'directory':str(tmp_path),'name':'large'}
    assert client.put('/files/upload',params=params,headers={'Authorization':'wrong'},content=b'x').status_code==401
    assert client.put('/files/upload',params=params,headers={'Content-Length':str(51*1024*1024)},content=b'x').status_code==413
    assert not (tmp_path/'large').exists()
    assert client.get('/files/download',params={'path':str(tmp_path)}).status_code==400

def test_output_arrives_before_process_exit_and_can_stop(tmp_path):
    async def run():
        import threading
        stop=threading.Event()
        started=time.monotonic()
        gen=command_events("printf first; sleep 10",str(tmp_path),stop,timeout=15)
        events=[]
        async for event in gen:
            events.append(event)
            if event.get('type')=='stdout':
                assert time.monotonic()-started<2
                stop.set()
        assert events[-1]['type']=='exit' and events[-1]['cancelled']
        assert time.monotonic()-started<3
    asyncio.run(run())

def test_stream_endpoint_and_unknown_stop(client,tmp_path):
    r=client.post('/terminal/stream',json={'command':'printf hello','cwd':str(tmp_path),'id':'a'*32})
    assert r.status_code==200
    events=[json.loads(line) for line in r.text.splitlines()]
    assert events[0]['type']=='started'
    assert ''.join(e.get('text','') for e in events if e['type']=='stdout')=='hello'
    assert events[-1]['returncode']==0
    assert client.delete('/terminal/'+'b'*32).status_code==404

@pytest.fixture
def live_server():
    import socket,threading,uvicorn,requests
    sock=socket.socket(); sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    server=uvicorn.Server(uvicorn.Config(create_app(token='live-test'),log_level='critical',access_log=False))
    thread=threading.Thread(target=lambda:server.run(sockets=[sock])); thread.start()
    for _ in range(100):
        if server.started: break
        time.sleep(.02)
    http=requests.Session(); http.headers['Authorization']='Bearer live-test'
    try: yield http,f'http://127.0.0.1:{port}'
    finally: http.close(); server.should_exit=True; thread.join(5); sock.close()

def test_live_stop_and_disconnect_release_shared_command_lock(live_server,tmp_path):
    http,base=live_server
    for index in range(2):
        command_id=str(index)*32
        with http.post(base+'/terminal/stream',json={'id':command_id,'command':'printf ready; sleep 10','cwd':str(tmp_path)},stream=True,timeout=3) as response:
            lines=response.iter_lines(chunk_size=1)
            assert json.loads(next(lines))['type']=='started'
            assert json.loads(next(lines))['text']=='ready'
            assert http.post(base+'/terminal',json={'command':'pwd','cwd':str(tmp_path)}).status_code==409
            if index==0:
                assert http.delete(base+'/terminal/'+command_id).status_code==200
                assert json.loads(next(lines))['cancelled']
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            result=http.post(base+'/terminal',json={'command':'printf done','cwd':str(tmp_path)})
            if result.status_code==200: break
            time.sleep(.05)
        assert result.status_code==200 and result.json()['stdout']=='done'

def test_stream_timeout_and_output_bound(tmp_path):
    import threading
    async def run(command,**limits):
        return [e async for e in command_events(command,str(tmp_path),threading.Event(),**limits)]
    events=asyncio.run(run('sleep 10',timeout=.1))
    assert events[-1]['timed_out']
    events=asyncio.run(run('yes text',output_limit=100))
    assert events[-1]['truncated'] and sum(len(e.get('text','').encode()) for e in events)<=100

def test_disconnect_actually_stops_remote_process(live_server,tmp_path):
    http,base=live_server
    marker=tmp_path/'must-not-run'
    with http.post(base+'/terminal/stream',json={'id':'c'*32,'command':f'printf ready; sleep 1; touch {marker}','cwd':str(tmp_path)},stream=True,timeout=3) as response:
        lines=response.iter_lines(chunk_size=1)
        next(lines); next(lines)
    time.sleep(1.3)
    assert not marker.exists(), 'Disconnected command continued executing on Mac'

def test_download_permission_failure_is_explained(client,tmp_path,monkeypatch):
    import main
    file=tmp_path/'private'; file.write_text('test')
    real_open=main.os.open
    def reject(path,*args,**kwargs):
        if str(path)==str(file): raise PermissionError('test')
        return real_open(path,*args,**kwargs)
    monkeypatch.setattr(main.os,'open',reject)
    assert client.get('/files/download',params={'path':str(file)}).status_code==403
