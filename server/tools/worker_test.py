"""워커 창구가 제대로 막고 제대로 받는지 본다."""
import io as _io, os, sys, tarfile, tempfile, types

os.environ["WORKER_SECRET"] = "test-secret"
os.environ["FILE_SIGNING_SECRET"] = "k"

for name in ("psycopg2", "psycopg2.extras", "redis", "celery",
             "celery.schedules", "redis.asyncio"):
    m = types.ModuleType(name); m.__path__ = []
    m.__getattr__ = lambda n: types.SimpleNamespace()
    sys.modules[name] = m
sys.modules["psycopg2"].extras = sys.modules["psycopg2.extras"]
sys.modules["redis"].asyncio = sys.modules["redis.asyncio"]
sys.modules["redis"].Redis = lambda **kw: types.SimpleNamespace(
    ping=lambda: None, publish=lambda *a: None, lrange=lambda *a: [],
    pipeline=lambda: types.SimpleNamespace(
        rpush=lambda *a: None, ltrim=lambda *a: None, delete=lambda *a: None,
        rename=lambda *a: None, execute=lambda: None))
sys.modules["celery"].Celery = lambda *a, **k: types.SimpleNamespace(
    conf=types.SimpleNamespace(update=lambda **kw: None, beat_schedule={}),
    send_task=lambda *a, **k: None, task=lambda *a, **k: (lambda f: f))
sys.modules["celery.schedules"].crontab = lambda **kw: None

sys.path.insert(0, r"c:\Users\rlaal\Desktop\EnsembleSync\server")
os.chdir(r"c:\Users\rlaal\Desktop\EnsembleSync\server")

class _Cur:
    def execute(self, *a, **k): pass
    def fetchone(self): return None
    def fetchall(self): return []
    def close(self): pass
class _Conn:
    def cursor(self, *a, **k): return _Cur()
    def commit(self): pass
    def rollback(self): pass
    def close(self): pass

import database
database.get_db = lambda: _Conn()
import main
for mod in ("worker_api",):
    __import__(mod); sys.modules[mod].get_db = lambda: _Conn()

from fastapi.testclient import TestClient
c = TestClient(main.app)
JOB = "33333333-3333-3333-3333-333333333333"

def tar_bytes(entries):
    buf = _io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in entries:
            info = tarfile.TarInfo(name); info.size = len(data)
            t.addfile(info, _io.BytesIO(data))
    return buf.getvalue()

good = {"X-Worker-Secret": "test-secret"}
fail = 0
def check(label, got, want):
    global fail
    ok = got == want
    fail += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {label:<34} want={want} got={got}")

r = c.post(f"/api/worker/{JOB}/result", content=tar_bytes([("a.wav", b"x"*10)]))
check("열쇠 없이 올리기", r.json().get("status"), 403)

r = c.post(f"/api/worker/{JOB}/result", content=tar_bytes([("a.wav", b"x"*10)]),
           headers={"X-Worker-Secret": "wrong"})
check("틀린 열쇠", r.json().get("status"), 403)

r = c.get(f"/api/worker/{JOB}/input")
check("열쇠 없이 원본 요청", r.json().get("status"), 403)

r = c.post("/api/worker/..%2F..%2Fetc/result", content=b"x", headers=good)
check("작업번호에 경로", r.status_code in (400, 404), True)

r = c.post(f"/api/worker/{JOB}/result",
           content=tar_bytes([("../../escape.wav", b"x"*10)]), headers=good)
check("상위로 빠져나가는 tar", r.json().get("status"), 400)

r = c.post(f"/api/worker/{JOB}/result",
           content=tar_bytes([("evil.sh", b"rm -rf /")]), headers=good)
check("허용 안 된 확장자", r.json().get("status"), 400)

r = c.post(f"/api/worker/{JOB}/result", content=tar_bytes([
    ("htdemucs/song/vocals.wav", b"W"*2048),
    ("htdemucs/song/vocals.mp3", b"M"*512),
    ("analysis.json", b'{"ok":1}')]), headers=good)
body = r.json()
check("제대로 된 묶음", body.get("status"), 200)
check("파일 수", body.get("files"), 3)

root = os.path.join("uploads", "separated", JOB)
check("파일이 놓였나", os.path.isfile(
    os.path.join(root, "htdemucs", "song", "vocals.wav")), True)
check("빠져나간 파일 없나", os.path.exists(
    os.path.join("uploads", "separated", "escape.wav")), False)
check("tar 찌꺼기 지웠나", os.path.exists(
    os.path.join(root, ".incoming.tar")), False)

import shutil; shutil.rmtree(root, ignore_errors=True)
sys.exit(1 if fail else 0)
