import os
import logging
from contextlib import asynccontextmanager
from urllib.parse import urlsplit
import threading
import time
from pathlib import Path
from fastapi import FastAPI, Depends, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from .core import Companion, Problem

class Pair(BaseModel):
    code: str = Field(min_length=20,max_length=100)
    name: str = Field(min_length=1,max_length=80)
class Folder(BaseModel):
    path: str = Field(max_length=2048)
class Upload(Folder):
    size: int = Field(ge=0)
    sha256: str = Field(pattern=r'^[0-9a-f]{64}$')


def log_connection_url():
    logger = logging.getLogger('uvicorn.error')
    raw = os.getenv('ASTEROS_CONNECTION_URL', '').strip()
    if not raw:
        logger.info('AsterOS connection URL: not configured. Set ASTEROS_CONNECTION_URL to your HTTPS companion address.')
        return
    try:
        url = urlsplit(raw)
        valid = (url.scheme == 'https' and bool(url.hostname) and url.username is None
                 and url.password is None and not url.query and not url.fragment
                 and not any(ord(c) < 33 or ord(c) == 127 for c in raw))
        if url.port is not None and not 1 <= url.port <= 65535:
            valid = False
    except ValueError:
        valid = False
    if not valid:
        # Never echo malformed settings: they may contain a password or token.
        logger.warning('AsterOS connection URL is invalid. Use HTTPS without credentials, query parameters, or fragments.')
        return
    access = {
        'tailscale': 'Private; Tailscale must be connected on your device.',
        'local': 'Local network or configured VPN required.',
        'public': 'Remote HTTPS endpoint; paired-device authentication required.',
    }.get(os.getenv('ASTEROS_CONNECTION_ACCESS', ''), 'Reachability depends on your proxy or VPN configuration.')
    logger.info('AsterOS connection URL: %s', raw.rstrip('/'))
    logger.info('AsterOS access: %s', access)
    logger.info('Use this URL in AsterOS → Files → companion setup. This companion does not yet provide the server dashboard.')
    logger.info('Generate a one-time pairing code: docker exec asteros-companion python -m companion.admin pair')


def create_app(core=None):
    core = core or Companion(os.getenv('ASTEROS_STATE','/data'),os.getenv('ASTEROS_STORAGE','/storage'),int(os.getenv('ASTEROS_RESERVE_BYTES',str(1024**3))),int(os.getenv('ASTEROS_MAX_UPLOAD_BYTES',str(10*1024**3))))
    @asynccontextmanager
    async def lifespan(app):
        log_connection_url()
        yield
    app = FastAPI(title='AsterOS Companion',version='0.1.1',docs_url=None,redoc_url=None,openapi_url=None,lifespan=lifespan)
    bearer = HTTPBearer(auto_error=False)
    attempts, attempts_lock = [], threading.Lock()

    @app.exception_handler(Problem)
    async def problem_handler(request, error): return JSONResponse({'detail':error.message},status_code=error.status)

    @app.exception_handler(OSError)
    async def storage_handler(request,error): return JSONResponse({'detail':'Storage operation failed. Check permissions and free space.'},status_code=503)

    @app.middleware('http')
    async def headers(request,call_next):
        # JSON admin/pair requests must stay small; upload chunks have their own streaming cap.
        if request.method == 'POST':
            length = request.headers.get('content-length')
            if length is None or not length.isdecimal() or int(length) > 8192:
                return JSONResponse({'detail':'POST requests require a body length of at most 8 KiB.'},status_code=413)
        response = await call_next(request)
        response.headers['Cache-Control']='no-store'
        response.headers['X-Content-Type-Options']='nosniff'
        return response

    def device(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if not credentials: raise Problem(401,'Pair this device first.')
        return core.authenticate(credentials.credentials)

    @app.get('/health')
    def health(): return {'status':'ok','service':'AsterOS Companion','version':'0.1.1'}

    @app.post('/v1/pair')
    def pair(body: Pair):
        # Global bounded limiter; never trust caller-supplied forwarding headers.
        with attempts_lock:
            now = time.monotonic()
            attempts[:] = [t for t in attempts if now-t < 60]
            if len(attempts) >= 10: raise Problem(429,'Pairing rate limit reached. Try again in one minute.')
            attempts.append(now)
        return core.pair(body.code,body.name)

    @app.get('/v1/status')
    def status(device_id=Depends(device)):
        usage = __import__('shutil').disk_usage(core.storage)
        return {'version':'0.1.1','device_id':device_id,'free_bytes':usage.free,'reserve_bytes':core.reserve,'capabilities':['files.list','files.download','folders.create','uploads.resume','uploads.sha256']}

    @app.delete('/v1/device')
    def revoke(device_id=Depends(device)):
        core.revoke(device_id); return {'revoked':True}

    @app.get('/v1/files')
    def files(path: str='',device_id=Depends(device)): return core.listing(path)

    @app.post('/v1/folders')
    def mkdir(body: Folder,device_id=Depends(device)): return core.mkdir(body.path)

    @app.get('/v1/file')
    def download(path: str,device_id=Depends(device)):
        file = core.download(path)
        def chunks():
            try:
                while chunk := file.read(1024*1024): yield chunk
            finally: file.close()
        return StreamingResponse(chunks(),media_type='application/octet-stream',headers={'Content-Disposition':'attachment'})

    @app.post('/v1/uploads')
    def upload(body: Upload,device_id=Depends(device)): return core.create_upload(device_id,body.path,body.size,body.sha256)

    @app.get('/v1/uploads/{task}')
    def upload_status(task: str,device_id=Depends(device)): return core.upload_status(device_id,task)

    @app.put('/v1/uploads/{task}')
    async def chunk(task: str,request: Request,offset: int,device_id=Depends(device)):
        data=bytearray()
        async for part in request.stream():
            data.extend(part)
            if len(data) > core.CHUNK: raise Problem(413,'Chunk exceeds 4 MiB.')
        return await run_in_threadpool(core.append,device_id,task,offset,bytes(data))

    @app.post('/v1/uploads/{task}/complete')
    def complete(task: str,device_id=Depends(device)): return core.complete(device_id,task)

    @app.delete('/v1/uploads/{task}')
    def cancel(task: str,device_id=Depends(device)): return core.cancel(device_id,task)
    return app
