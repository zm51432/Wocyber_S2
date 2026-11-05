#!/usr/bin/env bash
# ============================================================================
# deploy-autoupdate.sh —— wocyber_S2 一键升级脚本（v1.3.12 → v1.3.13+）
#
# 适用：已经安装了旧版 wocyber_S2 fpk（v1.3.12 及更早）的飞牛 fnOS 设备。
# 用法（两种任选其一，全程无需 SSH）：
#   ① 浏览器打开 wocyber_S2 控制台 → 「脚本修复」卡片 → 把本文件拖进
#      修复窗口 → 自动执行并实时显示日志；
#   ② SSH 到设备执行：sudo bash deploy-autoupdate.sh
#
# 做了什么：
#   1. 检测本机安装目录（/var/apps/wocyber_S2，兼容 target/ 布局）；
#   2. 查询 GitHub zm51432/Wocyber_S2 的最新 Release；
#   3. 下载 wocyber_S2.fpk → 校验（gzip/tar 合法 + manifest 版本高于本机）；
#   4. 整包备份当前应用目录（保留最近 3 份，var/backup_*）；
#   5. 覆盖应用文件 → 执行 upgrade_callback（全量部署硬件固件 +
#      s2-autoupdate 自动更新服务 + 定时器）；
#   6. 自动重启控制台；之后每天 04:30 自动检测 GitHub 新版本并自升级。
#
# 安全：只信任官方仓库 zm51432/Wocyber_S2；下载包校验失败/版本不高于
#       本机时立即中止，不做任何写入。失败可从 var/backup_* 还原。
# ============================================================================
set -u
REPO="zm51432/Wocyber_S2"
ASSET="wocyber_S2.fpk"

say(){ echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 0) 权限检查 ----------
if [ "$(id -u)" != "0" ]; then
  say "ERROR: 请以 root 运行（控制台脚本修复窗口默认已是 root；SSH 请用 sudo bash）"
  exit 1
fi

# ---------- 1) 定位本机安装目录 ----------
APP_ROOT="/var/apps/wocyber_S2"
if   [ -d "$APP_ROOT/server" ];       then :;
elif [ -d "$APP_ROOT/target/server" ]; then APP_ROOT="$APP_ROOT/target";
elif [ -d "$APP_ROOT/app/server" ];   then APP_ROOT="$APP_ROOT/app";
else
  say "ERROR: 未找到 wocyber_S2 安装目录（/var/apps/wocyber_S2）"
  exit 1
fi
VAR_DIR="${TRIM_PKGVAR:-/var/apps/wocyber_S2/var}"
LOG="$VAR_DIR/autoupdate.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
say "本机安装目录: $APP_ROOT"

CURRENT="$(grep -m1 '^version=' "$APP_ROOT/manifest" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
[ -n "$CURRENT" ] || CURRENT="0.0.0"
say "当前版本: $CURRENT"

# ---------- 2) 查询 GitHub 最新 Release ----------
say "查询 GitHub 最新版本 ..."
TAG=""; DL=""
QUERY="$(mktemp)"
python3 - "$REPO" "$ASSET" "$QUERY" <<'PY'
import json, sys, urllib.request
repo, asset, out = sys.argv[1], sys.argv[2], sys.argv[3]
url = "https://api.github.com/repos/%s/releases/latest" % repo
try:
    req = urllib.request.Request(url, headers={"User-Agent": "wocyber-deploy",
                                                "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    tag = d.get("tag_name", "")
    dl = ""
    for a in d.get("assets", []):
        if a.get("name") == asset:
            dl = a.get("browser_download_url", "")
            break
    open(out, "w").write("TAG %s\nDL %s\n" % (tag, dl))
except Exception as e:
    open(out, "w").write("ERR %s" % e)
PY
if [ ! -s "$QUERY" ] || grep -q '^ERR' "$QUERY"; then
  say "ERROR: GitHub 查询失败（网络不可达或限流），稍后重试"
  cat "$QUERY" 2>/dev/null; rm -f "$QUERY"; exit 1
fi
TAG="$(grep '^TAG ' "$QUERY" | cut -d' ' -f2-)"
DL="$(grep '^DL ' "$QUERY" | cut -d' ' -f2-)"
rm -f "$QUERY"
LATEST="$(echo "$TAG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$LATEST" ] || [ -z "$DL" ]; then
  say "ERROR: 无法解析最新版本号（tag=$TAG）"; exit 1
fi
say "GitHub 最新版本: $LATEST (tag: $TAG)"

# 版本比较：latest > current 才升级
ver_gt(){
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  local IFS=. a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 _ <<< "$(echo "$a" | sed 's/\./ /g')"
  read -r b1 b2 b3 _ <<< "$(echo "$b" | sed 's/\./ /g')"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  if   [ "$a1" -gt "$b1" ]; then return 0
  elif [ "$a1" -lt "$b1" ]; then return 1
  elif [ "$a2" -gt "$b2" ]; then return 0
  elif [ "$a2" -lt "$b2" ]; then return 1
  elif [ "$a3" -gt "$b3" ]; then return 0
  else return 1; fi
}
if ! ver_gt "$LATEST" "$CURRENT"; then
  say "本机已是最新（$CURRENT >= $LATEST），无需升级"
  say "如缺少自动更新服务，运行: install_all.sh 或重装 fpk"
  exit 0
fi

# ---------- 3) 下载 + 校验 ----------
TMPD="$(mktemp -d)"
FPK="$TMPD/$ASSET"
say "下载: $DL"
if command -v curl >/dev/null 2>&1; then
  curl -sSL -m 300 "$DL" -o "$FPK"
elif command -v wget >/dev/null 2>&1; then
  wget -q -T 300 -O "$FPK" "$DL"
else
  say "ERROR: 设备上没有 curl/wget"; rm -rf "$TMPD"; exit 1
fi
if [ ! -s "$FPK" ]; then
  say "ERROR: 下载失败（文件为空）"; rm -rf "$TMPD"; exit 1
fi
say "下载完成: $(wc -c < "$FPK") 字节"
MAGIC="$(head -c2 "$FPK" | od -An -tx1 | tr -d ' \n')"
if [ "$MAGIC" != "1f8b" ]; then
  say "ERROR: 校验失败：不是合法 gzip/fpk"; rm -rf "$TMPD"; exit 1
fi
tar -tzf "$FPK" 2>/dev/null | grep -q manifest  || { say "ERROR: fpk 内无 manifest"; rm -rf "$TMPD"; exit 1; }
tar -tzf "$FPK" 2>/dev/null | grep -qE 'install_all\.sh$' || { say "ERROR: fpk 内无 install_all.sh"; rm -rf "$TMPD"; exit 1; }

EX="$TMPD/unpack"; mkdir -p "$EX"
tar -xzf "$FPK" -C "$EX"
NEWVER="$(grep -m1 '^version=' "$EX/manifest" | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$NEWVER" ] || ! ver_gt "$NEWVER" "$CURRENT"; then
  say "ERROR: 包版本($NEWVER)未高于本机($CURRENT)，中止（防降级）"; rm -rf "$TMPD"; exit 1
fi
say "校验通过，将升级 $CURRENT → $NEWVER"

# ---------- 4) 备份 ----------
TS="$(date +%Y%m%d_%H%M%S)"
ROOT_PARENT="$(dirname "$APP_ROOT")"; ROOT_BASE="$(basename "$APP_ROOT")"
say "备份当前应用 -> var/backup_${ROOT_BASE}_${TS}.tar.gz"
tar -czf "$VAR_DIR/backup_${ROOT_BASE}_${TS}.tar.gz" -C "$ROOT_PARENT" "$ROOT_BASE" 2>/dev/null
ls -1t "$VAR_DIR"/backup_${ROOT_BASE}_*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

# ---------- 5) 覆盖 + 全量部署 ----------
APPEX="$TMPD/appex"; mkdir -p "$APPEX"
tar -xzf "$EX/app.tgz" -C "$APPEX"
cp -a "$APPEX/." "$APP_ROOT/"
mkdir -p "$APP_ROOT/cmd" "$APP_ROOT/config" "$APP_ROOT/wizard" 2>/dev/null
cp -a "$EX/cmd/."     "$APP_ROOT/cmd/"
cp -f "$EX/manifest"  "$APP_ROOT/manifest"
cp -a "$EX/config/."  "$APP_ROOT/config/"  2>/dev/null
cp -a "$EX/wizard/."  "$APP_ROOT/wizard/"  2>/dev/null
say "文件覆盖完成，执行全量部署（install_all.sh / upgrade_callback）..."
if [ -x "$APP_ROOT/cmd/upgrade_callback" ]; then
  TRIM_APPDEST="$APP_ROOT" bash "$APP_ROOT/cmd/upgrade_callback" </dev/null
else
  bash "$APP_ROOT/install-1014/install_all.sh" </dev/null
fi
echo "$NEWVER" > "$VAR_DIR/version"
rm -rf "$TMPD"

# ---------- 6) 重启控制台 ----------
say "重启控制台 ..."
if [ -x "$APP_ROOT/cmd/main" ]; then
  bash "$APP_ROOT/cmd/main" stop  >/dev/null 2>&1
  sleep 1
  bash "$APP_ROOT/cmd/main" start >/dev/null 2>&1
fi
say "升级完成：$CURRENT → $NEWVER"
say "自动更新服务已部署（每天 04:30 检测新版本并自动升级）"
say "请刷新浏览器页面查看新版控制台的「版本与更新」卡片"
echo "$(date '+%F %T') [deploy-autoupdate] $CURRENT -> $NEWVER" >> "$LOG" 2>/dev/null
exit 0
