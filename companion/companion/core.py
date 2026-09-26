import contextlib
import hashlib
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import stat
import threading
import time
import uuid


class Problem(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


class Companion:
    CHUNK = 4 * 1024 * 1024
    def __init__(self, state, storage, reserve=1024**3, max_upload=10*1024**3):
        self.state, self.storage = Path(state), Path(storage)
        self.state.mkdir(parents=True, exist_ok=True)
        self.storage.mkdir(parents=True, exist_ok=True)
        self.tasks = self.state / 'uploads'
        self.tasks.mkdir(exist_ok=True)
        self.reserve, self.max_upload = reserve, max_upload
        self.lock = threading.RLock()
        self.db = self.state / 'companion.sqlite3'
        with self.connection() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS pairs (hash TEXT PRIMARY KEY, expires REAL);
            CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, hash TEXT UNIQUE, name TEXT, created REAL, revoked INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS uploads (id TEXT PRIMARY KEY, device TEXT, path TEXT, size INTEGER, offset INTEGER, digest TEXT, status TEXT, created REAL);
            ''')
        os.chmod(self.db, 0o600)

    @contextlib.contextmanager
    def connection(self):
        db = sqlite3.connect(self.db, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db: yield db
        finally: db.close()

    @staticmethod
    def digest(value): return hashlib.sha256(value.encode()).hexdigest()

    def pair_code(self):
        code = secrets.token_urlsafe(24)
        with self.connection() as db:
            db.execute('DELETE FROM pairs')
            db.execute('INSERT INTO pairs VALUES (?, ?)', (self.digest(code), time.time()+300))
        return code

    def pair(self, code, name):
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT expires FROM pairs WHERE hash=?', (self.digest(code),)).fetchone()
            if not row or row['expires'] < time.time(): raise Problem(401, 'Pairing code is invalid or expired.')
            db.execute('DELETE FROM pairs WHERE hash=?', (self.digest(code),))
            token, device = secrets.token_urlsafe(48), str(uuid.uuid4())
            db.execute('INSERT INTO devices(id,hash,name,created) VALUES (?,?,?,?)', (device,self.digest(token),name,time.time()))
        return {'token':token, 'device_id':device}

    def authenticate(self, token):
        with self.connection() as db:
            row = db.execute('SELECT id FROM devices WHERE hash=? AND revoked=0', (self.digest(token),)).fetchone()
        if not row: raise Problem(401,'Device token is invalid or revoked.')
        return row['id']

    def revoke(self, device):
        with self.connection() as db:
            db.execute('UPDATE devices SET revoked=1 WHERE id=?', (device,))

    @staticmethod
    def parts(path):
        if not isinstance(path,str) or len(path) > 2048 or '\\' in path or '\x00' in path or path.startswith('/'):
            raise Problem(400,'Use a relative path within AsterOS storage.')
        if path == '': return []
        parts = path.split('/')
        if any(p in ('','.', '..') or p.startswith('.asteros-') or len(p.encode()) > 255 for p in parts):
            raise Problem(400,'Invalid path.')
        return parts

    @contextlib.contextmanager
    def directory(self, parts):
        # Hold descriptor-relative access throughout. Reject symlinks in every component.
        fd = os.open(self.storage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in parts:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = next_fd
            yield fd
        except (OSError, ValueError):
            raise Problem(404,'Folder is unavailable or is not an authorized directory.')
        finally: os.close(fd)

    def listing(self, path):
        with self.directory(self.parts(path)) as fd:
            entries = []
            for name in sorted(os.listdir(fd), key=str.casefold):
                if name.startswith('.asteros-'): continue
                try: info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                except OSError: continue
                if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)): continue
                entries.append({'name':name,'path':f'{path}/{name}' if path else name,'directory':stat.S_ISDIR(info.st_mode),'size':info.st_size})
                if len(entries) >= 2000: raise Problem(413,'This folder exceeds the preview listing limit of 2,000 items.')
            return {'path':path,'entries':entries}

    def mkdir(self, path):
        parts = self.parts(path)
        if not parts: raise Problem(400,'Enter a folder name.')
        with self.directory(parts[:-1]) as fd:
            try: os.mkdir(parts[-1], mode=0o750, dir_fd=fd)
            except FileExistsError: raise Problem(409,'That name already exists.')
        return {'path':path}

    def download(self, path):
        parts = self.parts(path)
        if not parts: raise Problem(400,'Choose a file.')
        with self.directory(parts[:-1]) as parent:
            try: fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            except OSError: raise Problem(404,'File is unavailable.')
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd); raise Problem(400,'Only regular files can be downloaded.')
        return os.fdopen(fd,'rb')

    def available(self, path): return shutil.disk_usage(path).free - self.reserve

    def create_upload(self, device, path, size, digest):
        parts = self.parts(path)
        if not parts or size < 0 or size > self.max_upload: raise Problem(400,'Invalid destination or upload size.')
        if not re.fullmatch('[0-9a-f]{64}',digest): raise Problem(400,'A SHA-256 checksum is required.')
        with self.directory(parts[:-1]) as parent:
            try: os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError: pass
            else: raise Problem(409,'Destination exists. Files are never overwritten.')
        with self.lock, self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            reserved = db.execute("SELECT COALESCE(SUM(size),0) FROM uploads WHERE status='uploading'").fetchone()[0]
            active = db.execute("SELECT COUNT(*) FROM uploads WHERE status='uploading'").fetchone()[0]
            # Conservative allowance for both staging and final copy, including existing reservations.
            if active >= 8: raise Problem(429,'Too many pending uploads. Complete or cancel one first.')
            if 2*(reserved+size) > min(self.available(self.state),self.available(self.storage)):
                raise Problem(507,'Not enough free space after the safety reserve.')
            task = str(uuid.uuid4())
            with open(self.tasks/task,'xb'): pass
            try: db.execute('INSERT INTO uploads VALUES (?,?,?,?,?,?,?,?)', (task,device,path,size,0,digest,'uploading',time.time()))
            except Exception:
                (self.tasks/task).unlink(missing_ok=True); raise
        return self.upload_status(device,task)

    def task_row(self, db, device, task):
        row = db.execute('SELECT * FROM uploads WHERE id=? AND device=?',(task,device)).fetchone()
        if not row: raise Problem(404,'Upload not found.')
        return row

    def upload_status(self, device, task):
        with self.connection() as db: row = self.task_row(db,device,task)
        return {key:row[key] for key in ['id','path','size','offset','status']}

    def append(self, device, task, offset, data):
        if len(data) > self.CHUNK: raise Problem(413,'Chunk exceeds 4 MiB.')
        with self.lock, self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self.task_row(db,device,task)
            if row['status'] != 'uploading': raise Problem(409,'Upload is not active.')
            if row['offset'] != offset: raise Problem(409,'Offset mismatch. Read upload status and resume there.')
            if offset+len(data) > row['size']: raise Problem(413,'Chunk exceeds declared file size.')
            if len(data) > self.available(self.state): raise Problem(507,'Storage safety reserve reached.')
            with open(self.tasks/task,'r+b') as file:
                file.truncate(offset); file.seek(offset); file.write(data); file.flush(); os.fsync(file.fileno())
            db.execute('UPDATE uploads SET offset=? WHERE id=?',(offset+len(data),task))
        return self.upload_status(device,task)

    def complete(self, device, task):
        with self.lock, self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self.task_row(db,device,task)
            if row['status'] == 'complete': return self.upload_status(device,task)
            if row['offset'] != row['size']: raise Problem(409,'Upload is incomplete.')
            source = self.tasks/task
            with source.open('rb') as file: digest = hashlib.file_digest(file,'sha256').hexdigest()
            if digest != row['digest']: raise Problem(422,'Checksum mismatch. Cancel this upload and retry.')
            if row['size'] > self.available(self.storage): raise Problem(507,'Not enough destination space after safety reserve.')
            parts = self.parts(row['path'])
            temp = '.asteros-' + task
            with self.directory(parts[:-1]) as parent:
                # A prior interrupted copy is private staging; unlink it without following it.
                try: os.unlink(temp,dir_fd=parent)
                except FileNotFoundError: pass
                fd = os.open(temp, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o640, dir_fd=parent)
                try:
                    with os.fdopen(fd,'wb') as out, source.open('rb') as inp:
                        shutil.copyfileobj(inp,out,1024*1024); out.flush(); os.fsync(out.fileno())
                    try: os.link(temp,parts[-1],src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)
                    except FileExistsError:
                        # Recover when a prior completion linked the file but crashed before committing SQLite.
                        try:
                            existing = os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
                        except OSError: raise Problem(409,'Destination already exists; nothing was overwritten.')
                        with os.fdopen(existing,'rb') as final:
                            info = os.fstat(final.fileno())
                            if not stat.S_ISREG(info.st_mode) or info.st_size != row['size'] or hashlib.file_digest(final,'sha256').hexdigest() != row['digest']:
                                raise Problem(409,'Destination already exists; nothing was overwritten.')
                    os.fsync(parent)
                finally: os.unlink(temp,dir_fd=parent)
            db.execute("UPDATE uploads SET status='complete' WHERE id=?",(task,))
        source.unlink(missing_ok=True)
        return self.upload_status(device,task)

    def cancel(self, device, task):
        with self.lock, self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self.task_row(db,device,task)
            if row['status'] == 'complete': raise Problem(409,'Completed files cannot be removed through upload cancellation.')
            (self.tasks/task).unlink(missing_ok=True)
            db.execute('DELETE FROM uploads WHERE id=?',(task,))
        return {'cancelled':True}
