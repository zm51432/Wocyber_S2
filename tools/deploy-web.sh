#!/bin/bash
# =============================================================
# deploy-web.sh —— 一键把 S2 硬件控制台 Web 界面部署到飞牛 NAS
#                  【不安装 fpk】直接用 SSH 传程序 + systemd 保活
#
# 在 Windows 的 Git Bash 里运行：
#     bash deploy-web.sh <NAS的IP> [Web端口] [SSH端口]
#
# 例：
#     bash deploy-web.sh 192.168.1.50
#     bash deploy-web.sh 192.168.1.50 18899
#     bash deploy-web.sh 192.168.1.50 18899 22
#
# 依赖：scp / ssh（Git Bash 自带）。会提示输入 root 密码（约 2 次）。
#       想免密可先执行：ssh-copy-id root@<NAS的IP>
# =============================================================
set -e

NAS_IP="${1:-}"
PORT="${2:-18899}"
SSH_PORT="${3:-22}"

if [ -z "$NAS_IP" ]; then
    echo "用法: bash $0 <NAS的IP> [Web端口] [SSH端口]"
    echo "例如: bash $0 192.168.1.50"
    exit 1
fi

# 本脚本放在 fpk 源码的 tools/ 下，Web 程序在 ../app/server
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_SERVER="$(cd "$HERE/../app/server" && pwd)"

if [ ! -f "$SRC_SERVER/server.py" ]; then
    echo "❌ 未找到 $SRC_SERVER/server.py"
    echo "   请确认本脚本位于 fpk 源码目录的 tools/ 下"
    exit 1
fi

SSHOPT="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
TARGET="root@$NAS_IP"

echo "=============================================="
echo " S2 硬件控制台 · Web 界面一键部署（免装 fpk）"
echo "=============================================="
echo " 目标 NAS : $TARGET (SSH $SSH_PORT)"
echo " 源目录   : $SRC_SERVER"
echo " Web 端口 : $PORT"
echo "=============================================="
echo

echo "==> 1/2 上传 Web 程序到 NAS 的 /tmp"
scp -r -P "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$SRC_SERVER" "$TARGET:/tmp"
echo "   上传完成"

echo "==> 2/2 安装到 /opt/s2hwctl 并注册 systemd 服务"
ssh $SSHOPT "$TARGET" "bash -s -- $PORT" <<'REMOTE'
set -e
PORT="$1"

# ---- 找 python3 ----
PY=""
for p in python3 /usr/bin/python3 /usr/local/bin/python3 python; do
    if command -v "$p" >/dev/null 2>&1; then PY="$(command -v "$p")"; break; fi
done
if [ -z "$PY" ]; then
    echo "❌ NAS 上没有 python3，无法部署"
    exit 1
fi
echo "   python3 -> $PY"

# ---- 安装文件 ----
if [ ! -d /tmp/server ]; then
    echo "❌ 未找到上传的 /tmp/server"
    exit 1
fi
mkdir -p /opt/s2hwctl
cp -a /tmp/server/. /opt/s2hwctl/
rm -rf /tmp/server
mkdir -p /opt/s2hwctl/var/scripts /opt/s2hwctl/var/logs
chmod +x /opt/s2hwctl/server.py 2>/dev/null || true

# ---- 校验关键文件 ----
for f in server.py hwctl.py public/index.html public/app.js public/style.css; do
    [ -f "/opt/s2hwctl/$f" ] || { echo "❌ 缺少 /opt/s2hwctl/$f"; exit 1; }
done
echo "   文件校验通过"

# ---- 写 systemd 服务（不用嵌套 heredoc，避免 stdin 冲突）----
printf '%s\n' \
'[Unit]' \
'Description=S2 Hardware Console (standalone web)' \
'After=network.target' \
'' \
'[Service]' \
'Type=simple' \
"Environment=PORT=$PORT" \
'Environment=S2_VAR_DIR=/opt/s2hwctl/var' \
"ExecStart=$PY /opt/s2hwctl/server.py" \
'WorkingDirectory=/opt/s2hwctl' \
'Restart=always' \
'RestartSec=3' \
'' \
'[Install]' \
'WantedBy=multi-user.target' \
> /etc/systemd/system/s2hwctl-web.service

systemctl daemon-reload
systemctl enable s2hwctl-web.service >/dev/null 2>&1 || true
systemctl restart s2hwctl-web.service
sleep 2

# ---- 检查 ----
if systemctl is-active --quiet s2hwctl-web; then
    echo
    echo "✅ 服务已启动"
else
    echo "❌ 服务未能启动，日志如下："
    journalctl -u s2hwctl-web -n 20 --no-pager 2>/dev/null || true
    exit 1
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "=============================================="
echo " 部署完成！浏览器打开："
echo "   http://${IP}:${PORT}"
echo "=============================================="
echo
echo "常用维护命令（SSH 里执行）："
echo "   systemctl status  s2hwctl-web      # 看状态"
echo "   systemctl restart s2hwctl-web      # 重启"
echo "   systemctl stop    s2hwctl-web      # 停止"
echo "   systemctl disable s2hwctl-web      # 取消开机自启"
echo "   journalctl -u s2hwctl-web -f       # 实时日志"
echo "   rm /etc/systemd/system/s2hwctl-web.service && systemctl daemon-reload  # 完全卸载"
REMOTE

echo
echo "全部完成。"
