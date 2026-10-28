#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S2 硬件控制台 —— HTTP 服务（仅用 Python 标准库）

路由
----
GET  /                     静态页面
GET  /api/state            综合状态
POST /api/hw               {op, params}  硬件操作（root 直控 / agent 代理）
POST /api/script/save      {name, content}
POST /api/script/start     {name}
GET  /api/script/poll?job= 任务输出
GET  /api/log?name=        日志尾部
POST /api/restart          {port} 改端口并自重启
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hwctl  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLIC = os.path.join(HERE, "public")
PORT = int(os.environ.get("PORT", "18899"))
TOKEN = os.environ.get("TOKEN", "") or ""
AGENT = os.environ.get("S2_AGENT_URL", "http://127.0.0.1:8899")
VAR_DIR = os.environ.get("S2_VAR_DIR", "/var/apps/wocyber_S2/var")
SCRIPTS_DIR = os.path.join(VAR_DIR, "scripts")
JOBS = {}
JOB_LOCK = threading.Lock()
AGENT_OK = None


# ---------------- pid ----------------
def write_pid():
    p = os.environ.get("S2_PID_FILE")
    if p:
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(str(os.getpid()))
        except Exception:
            pass


# ---------------- 硬件操作分发 ----------------
def agent_call(op, params):
    try:
        req = urllib.request.Request(
            AGENT + "/hw",
            data=json.dumps({"op": op, "params": params}).encode("utf-8"),
            headers={"Content-Type": "application/json"}, timeout=15)
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:  # noqa
        return {"ok": False, "msg": "硬件代理不可用：%s" % e}


def hw_call(op, params):
    global AGENT_OK
    if hwctl.is_root():
        ok, data = hwctl.dispatch(op, params)
        return {"ok": ok, "msg": data if isinstance(data, str) else "",
                "data": data if not isinstance(data, str) else None}
    if AGENT_OK is None:
        try:
            with urllib.request.urlopen(AGENT + "/ping", timeout=2) as r:
                AGENT_OK = (r.status == 200)
        except Exception:
            AGENT_OK = False
    if AGENT_OK:
        return agent_call(op, params)
    if op == "status":
        return {"ok": True, "msg": "readonly", "data": hwctl.collect_status()}
    return {"ok": False, "msg": "当前为应用用户且未部署硬件代理，无法写入硬件；"
                               "请以 root 部署 s2hw-agent，或在应用中心改用 root 安装。"}


# ---------------- 脚本任务 ----------------
def start_job(path):
    job = "j%d" % int(time.time() * 1000)
    with JOB_LOCK:
        JOBS[job] = {"lines": [], "done": False, "rc": None, "t": time.time()}
    def run():
        try:
            p = subprocess.Popen(["bash", path], cwd=os.path.dirname(path),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1)
            for line in iter(p.stdout.readline, ""):
                with JOB_LOCK:
                    JOBS[job]["lines"].append(line.rstrip("\n"))
                    if len(JOBS[job]["lines"]) > 2000:
                        JOBS[job]["lines"] = JOBS[job]["lines"][-2000:]
            p.wait()
            with JOB_LOCK:
                JOBS[job]["rc"] = p.returncode
                JOBS[job]["done"] = True
        except Exception as e:  # noqa
            with JOB_LOCK:
                JOBS[job]["lines"].append("执行异常：%s" % e)
                JOBS[job]["done"] = True
                JOBS[job]["rc"] = 1
    threading.Thread(target=run, daemon=True).start()
    return job


def script_by_name(name):
    for s in hwctl.list_scripts():
        if s["name"] == name:
            return s["path"]
    return None


# ---------------- HTTP ----------------
class Handler(BaseHTTPRequestHandler):
    server_version = "S2HW/1.0"

    def log_message(self, fmt, *args):  # 精简访问日志
        sys.stderr.write("[%s] %s\n" % (time.strftime("%F %T"), fmt % args))

    # ---- helpers ----
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not n:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _auth_ok(self):
        if not TOKEN:
            return True
        h = self.headers.get("X-S2-Token", "")
        q = self.path.split("token=")[-1].split("&")[0] if "token=" in self.path else ""
        ck = ""
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            if "s2token=" in part:
                ck = part.split("s2token=", 1)[1].strip()
        return TOKEN in (h, q, ck)

    def _static(self, path):
        if path == "/" or path == "":
            path = "/index.html"
        rel = path.lstrip("/").split("?")[0]
        if ".." in rel:
            self.send_error(403)
            return
        full = os.path.join(PUBLIC, rel)
        if not os.path.isfile(full):
            full = os.path.join(PUBLIC, "index.html")
        ctype = "text/html; charset=utf-8"
        if full.endswith(".js"):
            ctype = "application/javascript; charset=utf-8"
        elif full.endswith(".css"):
            ctype = "text/css; charset=utf-8"
        elif full.endswith(".png"):
            ctype = "image/png"
        elif full.endswith(".svg"):
            ctype = "image/svg+xml"
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    # ---- GET ----
    def do_GET(self):
        path = self.path.split("?")[0]
        if not path.startswith("/api/"):
            self._static(path)
            return
        if not self._auth_ok():
            self._json({"ok": False, "msg": "需要访问口令"}, 401)
            return
        if path == "/api/state":
            self._json(hw_call("status", {}))
        elif path == "/api/log":
            name = self.path.split("name=")[-1].split("&")[0] if "name=" in self.path else "sata-led"
            self._json(hw_call("logs", {"name": name}))
        elif path == "/api/script/poll":
            job = self.path.split("job=")[-1].split("&")[0] if "job=" in self.path else ""
            with JOB_LOCK:
                info = JOBS.get(job, {"lines": [], "done": True, "rc": None})
                self._json({"ok": True, "lines": info["lines"][-400:],
                            "done": info["done"], "rc": info["rc"]})
        else:
            self._json({"ok": False, "msg": "未知接口"}, 404)

    # ---- POST ----
    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._auth_ok():
            self._json({"ok": False, "msg": "需要访问口令"}, 401)
            return
        body = self._body()

        if path == "/api/hw":
            self._json(hw_call(body.get("op", ""), body.get("params", {})))

        elif path == "/api/script/save":
            name = os.path.basename(str(body.get("name", ""))).replace("..", "")
            content = body.get("content", "")
            if not name.endswith(".sh"):
                name += ".sh"
            os.makedirs(SCRIPTS_DIR, exist_ok=True)
            target = os.path.join(SCRIPTS_DIR, name)
            with open(target, "w", encoding="utf-8") as f:
                f.write(content)
            os.chmod(target, 0o755)
            self._json({"ok": True, "msg": "已保存 %s" % name, "scripts": hwctl.list_scripts()})

        elif path == "/api/script/start":
            p = script_by_name(os.path.basename(str(body.get("name", ""))))
            if not p:
                self._json({"ok": False, "msg": "脚本不存在"})
                return
            self._json({"ok": True, "job": start_job(p), "name": os.path.basename(p)})

        elif path == "/api/restart":
            port = body.get("port")
            msg = ""
            if port:
                r = hw_call("set_port", {"port": int(port)})
                msg = r.get("msg", "")
                if not r.get("ok"):
                    self._json(r)
                    return
            cmd = os.environ.get("S2_APP_CMD", "/var/apps/wocyber_S2/cmd/main")
            subprocess.Popen(
                ["bash", "-c", "sleep 1; %s stop >/dev/null 2>&1; sleep 2; %s start >/dev/null 2>&1" % (cmd, cmd)],
                start_new_session=True)
            self._json({"ok": True, "msg": msg or "应用正在重启"})

        else:
            self._json({"ok": False, "msg": "未知接口"}, 404)


def main():
    write_pid()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    sys.stderr.write("S2 硬件控制台 监听 0.0.0.0:%d (root=%s)\n" % (PORT, hwctl.is_root()))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
