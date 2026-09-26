import hashlib
import os
from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
from companion.core import Companion, Problem
from companion.api import create_app

@pytest.fixture
def setup(tmp_path):
    core=Companion(tmp_path/'state',tmp_path/'storage',reserve=0,max_upload=1024**2)
    client=TestClient(create_app(core))
    paired=client.post('/v1/pair',json={'code':core.pair_code(),'name':'Test phone'}).json()
    client.headers['Authorization']='Bearer '+paired['token']
    return core,client,paired

def begin(core,client,data=b'hello',path='sample.txt'):
    response=client.post('/v1/uploads',json={'path':path,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    assert response.status_code == 200,response.text
    return response.json()['id']

def test_auth_and_revocation(setup):
    core,client,paired=setup
    assert client.get('/v1/status').status_code == 200
    core.revoke(paired['device_id'])
    assert client.get('/v1/files').status_code == 401
    assert client.get('/health').status_code == 200

def test_single_use_pairing(setup):
    core,client,_=setup
    code=core.pair_code()
    payload={'code':code,'name':'Another phone'}
    assert client.post('/v1/pair',json=payload).status_code == 200
    assert client.post('/v1/pair',json=payload).status_code == 401

def test_expired_pairing(setup):
    core,client,_=setup
    code=core.pair_code()
    with core.connection() as db: db.execute('UPDATE pairs SET expires=0')
    assert client.post('/v1/pair',json={'code':code,'name':'Expired'}).status_code == 401

@pytest.mark.parametrize('path',['../secret','/etc/passwd','a/../b','a//b','a\\b','.asteros-private'])
def test_traversal_rejected(setup,path):
    _,client,_=setup
    assert client.get('/v1/files',params={'path':path}).status_code == 400

def test_symlinks_are_never_followed(setup,tmp_path):
    core,client,_=setup
    outside=tmp_path/'outside'; outside.mkdir(); (outside/'secret').write_text('secret')
    (core.storage/'escape').symlink_to(outside,target_is_directory=True)
    (core.storage/'link').symlink_to(outside/'secret')
    assert client.get('/v1/files',params={'path':'escape'}).status_code == 404
    assert client.get('/v1/file',params={'path':'link'}).status_code == 404
    assert client.get('/v1/files').json()['entries'] == []

def test_resume_checksum_and_download(setup):
    core,client,_=setup
    assert client.post('/v1/folders',json={'path':'Backups'}).status_code == 200
    task=begin(core,client,b'hello world','Backups/hello.txt')
    assert client.put('/v1/uploads/'+task,params={'offset':0},content=b'hello ').json()['offset'] == 6
    assert client.put('/v1/uploads/'+task,params={'offset':0},content=b'wrong').status_code == 409
    assert client.get('/v1/uploads/'+task).json()['offset'] == 6
    assert client.put('/v1/uploads/'+task,params={'offset':6},content=b'world').status_code == 200
    assert client.post('/v1/uploads/'+task+'/complete').json()['status'] == 'complete'
    assert client.post('/v1/uploads/'+task+'/complete').status_code == 200
    assert client.get('/v1/file',params={'path':'Backups/hello.txt'}).content == b'hello world'

def test_checksum_mismatch_and_cancel(setup):
    core,client,_=setup
    task=begin(core,client)
    assert client.put('/v1/uploads/'+task,params={'offset':0},content=b'wrong').status_code == 200
    assert client.post('/v1/uploads/'+task+'/complete').status_code == 422
    assert not (core.storage/'sample.txt').exists()
    assert client.delete('/v1/uploads/'+task).status_code == 200
    assert not (core.tasks/task).exists()

def test_no_overwrite_even_after_upload_started(setup):
    core,client,_=setup
    task=begin(core,client)
    client.put('/v1/uploads/'+task,params={'offset':0},content=b'hello')
    (core.storage/'sample.txt').write_text('keep me')
    assert client.post('/v1/uploads/'+task+'/complete').status_code == 409
    assert (core.storage/'sample.txt').read_text() == 'keep me'

def test_device_cannot_read_another_devices_upload(setup):
    core,client,_=setup
    task=begin(core,client)
    other=core.pair(core.pair_code(),'other')
    client.headers['Authorization']='Bearer '+other['token']
    assert client.get('/v1/uploads/'+task).status_code == 404

def test_storage_reserve_and_chunk_bound(setup):
    core,client,_=setup
    task=begin(core,client)
    assert client.put('/v1/uploads/'+task,params={'offset':0},content=b'x'*(core.CHUNK+1)).status_code == 413
    core.reserve=10**30
    assert client.post('/v1/uploads',json={'path':'other','size':5,'sha256':'0'*64}).status_code == 507

def test_concurrent_pairing_only_one_wins(setup):
    core,_,_=setup
    code=core.pair_code()
    def attempt(_):
        try: core.pair(code,'phone'); return True
        except Problem: return False
    with ThreadPoolExecutor(max_workers=4) as pool: assert sum(pool.map(attempt,range(4))) == 1

def test_resume_after_process_restart(setup):
    core,client,paired=setup
    task=begin(core,client)
    client.put('/v1/uploads/'+task,params={'offset':0},content=b'he')
    reopened=Companion(core.state,core.storage,reserve=0)
    assert reopened.authenticate(paired['token']) == paired['device_id']
    assert reopened.upload_status(paired['device_id'],task)['offset'] == 2
    reopened.append(paired['device_id'],task,2,b'llo')
    reopened.complete(paired['device_id'],task)
    assert (core.storage/'sample.txt').read_bytes() == b'hello'
