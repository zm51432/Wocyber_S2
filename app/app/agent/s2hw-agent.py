#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
s2hw-agent —— 以 root 常驻的硬件操作代理（可选组件）

用途：当 fpk 应用因平台限制只能以「应用用户」身份运行时，页面无法直接
      写 /sys/class/leds、/etc/*.conf 或重启 systemd 服务。此时把本脚本
      以 root 部署为 systemd 服务（监听 127.0.0.1:8899），页面把 {op, params}
      原样转发过来，由它代执行。

部署（在设备上以 root 执行）：
    install -m 755 s2hw-agent.py /usr/local/sbin/s2hw-agent.py
    install -m 644 s2hw-agent.service /etc/systemd/system/s2hw-agent.service
    systemctl daemon-reload && systemctl enable --now s2hw-agent
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("S2_AGENT_PORT", "8899"))
HWCTL_DIR = os.environ.get("S2_HWCTL_DIR", "/var/apps/wocyber_S2/target/server")
if HWCTL_DIR not in sys.path:
    sys.path.insert(0, HWCTL_DIR)

try:
    import hwctl
except Exception as e:  # noqa
    hwctl = None
    IMPORT_ERR = str(e)


class H(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/ping"):
            self._json({"ok": True, "root": os.geteuid() == 0,
                        "hwctl": hwctl is not None})
        else:
            self._json({"ok": False, "msg": "not found"}, 404)

    def do_POST(self):
        if hwctl is None:
            self._json({"ok": False, "msg": "hwctl 导入失败：%s" % IMPORT_ERR})
            return
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            body = json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            self._json({"ok": False, "msg": "请求体解析失败"})
            return
        ok, data = hwctl.dispatch(body.get("op", ""), body.get("params", {}))
        if isinstance(data, str):
            self._json({"ok": ok, "msg": data})
        else:
            self._json({"ok": ok, "msg": "ok", "data": data})


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.stderr.write("警告：非 root 运行，硬件写入会失败\n")
    sys.stderr.write("s2hw-agent 监听 127.0.0.1:%d\n" % PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
