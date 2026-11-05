#!/usr/bin/env bash
# =============================================================
# s2-autoupdate.sh —— wocyber_S2 自动更新（GitHub Release 检测 + 自升级）
#
# 设计目标：
#   检测 GitHub 项目 zm51432/Wocyber_S2 的最新 Release；若版本比当前更新，
#   则下载 wocyber_S2.fpk，校验后覆盖本机文件、重新部署硬件固件（install_all.sh），
#   并重启控制台，实现 fpk 自升级。
#
# 子命令：
#   status   仅输出当前/最新版本 JSON（不联网查询最新时复用上次缓存）
#   check    联网查询 GitHub 最新版本并比对，输出 JSON（不升级）
#   run      联网查询；若发现更新（且 AUTO_UPDATE 未关闭）则自动升级，输出 JSON
#   run --force  忽略 AUTO_UPDATE 开关，强制升级（供「立即升级」按钮使用）
#
# 安全：
#   - 仅信任固定官方仓库；下载后校验 gzip/tar 合法性 + 内含 manifest/install_all.sh
#   - 升级前对当前应用目录做整包备份（VAR_DIR/backup_*）
#   - 尊重 settings.conf 的 AUTO_UPDATE=false 开关（默认 true = 自动升级）
#   日志：VAR_DIR/autoupdate.log
# =============================================================
set -u

APP_NAME="${TRIM_APPNAME:-wocyber_S2}"
APP_ROOT="${TRIM_APPDEST:-/var/apps/${APP_NAME}}"
# fnOS 不同版本布局差异：真实文件可能在根 / target / app 下，双/三路径探测
if   [ -d "$APP_ROOT/server" ];       then :;
elif [ -d "$APP_ROOT/target/server" ]; then APP_ROOT="$APP_ROOT/target";
elif [ -d "$APP_ROOT/app/server" ];   then APP_ROOT="$APP_ROOT/app";
fi
ETC_DIR="${TRIM_PKGETC:-/var/apps/${APP_NAME}/etc}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/${APP_NAME}/var}"
LOG="$VAR_DIR/autoupdate.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
REPO="zm51432/Wocyber_S2"
ASSET="wocyber_S2.fpk"

CURRENT=""; LATEST=""; LATEST_TAG=""; DL_URL=""; UPDATE_AVAILABLE=0
AUTO="true"; LAST_RESULT=""

log(){ echo "$(date '+%F %T') [$1] $2" | tee -a "$LOG" 2>/dev/null; }

# -------- 版本解析 / 比较 --------
read_current(){
  CURRENT=""
  local f
  for f in "$APP_ROOT/manifest" "/var/apps/${APP_NAME}/manifest" "/var/apps/${APP_NAME}/target/manifest" "$VAR_DIR/version"; do
    if [ -f "$f" ]; then
      CURRENT="$(grep -m1 '^version=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
      [ -n "$CURRENT" ] && break
    fi
  done
  [ -z "$CURRENT" ] && CURRENT="0.0.0"
}
ver_norm(){ echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
# 返回 0 表示 $1 > $2
ver_gt(){
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  local IFS=.; local ax=($a) bx=($b) i an bn
  for i in 0 1 2; do
    an="${ax[$i]:-0}"; bn="${bx[$i]:-0}"
    [ "$an" -gt "$bn" ] && return 0
    [ "$an" -lt "$bn" ] && return 1
  done
  return 1
}

# -------- 联网取最新 Release --------
fetch_latest(){
  LATEST=""; LATEST_TAG=""; DL_URL=""
  local tmpjson; tmpjson="$(mktemp)"
  python3 - "$REPO" "$ASSET" "$tmpjson" <<'PY'
import json, sys, urllib.request
repo, asset, out = sys.argv[1], sys.argv[2], sys.argv[3]
url = "https://api.github.com/repos/%s/releases/latest" % repo
try:
    req = urllib.request.Request(url, headers={"User-Agent": "wocyber-autoupdate",
                                               "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
except Exception as e:
    open(out, "w").write("ERR %s" % e)
    sys.exit(0)
tag = d.get("tag_name", "")
dl = ""
for a in d.get("assets", []):
    if a.get("name") == asset:
        dl = a.get("browser_download_url", "")
        break
with open(out, "w") as f:
    f.write("TAG %s\nDL %s\n" % (tag, dl))
PY
  if [ ! -s "$tmpjson" ] || grep -q '^ERR' "$tmpjson"; then rm -f "$tmpjson"; return 2; fi
  LATEST_TAG="$(grep '^TAG ' "$tmpjson" | cut -d' ' -f2-)"
  DL_URL="$(grep '^DL ' "$tmpjson" | cut -d' ' -f2-)"
  rm -f "$tmpjson"
  LATEST="$(ver_norm "$LATEST_TAG")"
  [ -n "$LATEST" ] && return 0 || return 1
}

# -------- 下载 / 校验 --------
download(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -sSL -m 120 "$url" -o "$out" 2>/dev/null && [ -s "$out" ]
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 120 -O "$out" "$url" 2>/dev/null && [ -s "$out" ]
  else return 1; fi
}
validate_fpk(){
  local f="$1"
  local magic; magic="$(head -c2 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "1f8b" ] || return 1
  tar -tzf "$f" 2>/dev/null | grep -qE '(^|/)manifest$' || return 1
  tar -tzf "$f" 2>/dev/null | grep -qE 'install_all\.sh$'  || return 1
  return 0
}

# -------- 备份 / 重启 --------
backup_current(){
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local root_parent; root_parent="$(dirname "$APP_ROOT")"
  local root_base;   root_base="$(basename "$APP_ROOT")"
  tar -czf "$VAR_DIR/backup_${root_base}_${ts}.tar.gz" -C "$root_parent" "$root_base" 2>/dev/null
  # 仅保留最近 3 份备份
  ls -1t "$VAR_DIR"/backup_${root_base}_*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
}
restart_console(){
  if [ -x "$APP_ROOT/cmd/main" ]; then
    bash "$APP_ROOT/cmd/main" stop  >> "$LOG" 2>&1
    sleep 1
    bash "$APP_ROOT/cmd/main" start >> "$LOG" 2>&1
    log INFO "控制台已重启"
  else
    log WARN "未找到 cmd/main，跳过控制台重启（请手动重启应用）"
  fi
}

echo_json(){
  cat <<JSON
{"current":"$CURRENT","latest":"$LATEST","update_available":$UPDATE_AVAILABLE,"auto_update":"$AUTO","result":"$LAST_RESULT","time":"$(date '+%F %T')"}
JSON
}
# 状态缓存：status 子命令不联网，直接复用上次 check/run 的结果
save_state(){ echo_json > "$VAR_DIR/autoupdate.state.json" 2>/dev/null; }
load_state(){
  local f="$VAR_DIR/autoupdate.state.json" k
  [ -r "$f" ] || return 1
  LATEST="$(sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' "$f")"
  UPDATE_AVAILABLE="$(sed -n 's/.*"update_available":\([0-9]*\).*/\1/p' "$f")"
  LAST_RESULT="$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' "$f")"
  return 0
}

# -------- 主流程 --------
do_check(){
  read_current
  if ! fetch_latest; then
    LAST_RESULT="GitHub 查询失败（网络不可达或限流）"; UPDATE_AVAILABLE=0; return 1
  fi
  if ver_gt "$LATEST" "$CURRENT"; then
    UPDATE_AVAILABLE=1; LAST_RESULT="发现新版本 $LATEST（当前 $CURRENT）"
  else
    UPDATE_AVAILABLE=0; LAST_RESULT="已是最新（$CURRENT >= $LATEST）"
  fi
  return 0
}

do_upgrade(){
  read_current
  if ! fetch_latest; then
    LAST_RESULT="GitHub 查询失败，跳过升级"; echo_json; return 1
  fi
  if ! ver_gt "$LATEST" "$CURRENT"; then
    LAST_RESULT="已是最新（$CURRENT），无需升级"; echo_json; return 0
  fi
  # AUTO_UPDATE 开关（默认 true）
  AUTO="$(grep -m1 '^AUTO_UPDATE=' "$ETC_DIR/settings.conf" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
  [ -z "$AUTO" ] && AUTO="true"
  if [ "${AUTO}" = "false" ] && [ "${1:-}" != "--force" ]; then
    LAST_RESULT="AUTO_UPDATE=false，已跳过自动升级（用「立即升级」可强制）"; echo_json; return 0
  fi

  log INFO "开始升级 $CURRENT -> $LATEST"
  local tmpd; tmpd="$(mktemp -d)"
  local fpk="$tmpd/$ASSET"
  if ! download "$DL_URL" "$fpk"; then
    LAST_RESULT="下载失败：$DL_URL"; echo_json; rm -rf "$tmpd"; return 1
  fi
  if ! validate_fpk "$fpk"; then
    LAST_RESULT="下载文件校验失败（非合法 fpk）"; echo_json; rm -rf "$tmpd"; return 1
  fi
  # 二次确认版本：解包后比对 manifest 版本
  local ex="$tmpd/unpack"; mkdir -p "$ex"
  tar -xzf "$fpk" -C "$ex"
  local newver; newver="$(grep -m1 '^version=' "$ex/manifest" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
  if [ -z "$newver" ] || ! ver_gt "$newver" "$CURRENT"; then
    LAST_RESULT="下载包版本($newver)未高于当前($CURRENT)，中止"; echo_json; rm -rf "$tmpd"; return 1
  fi

  backup_current
  log INFO "备份完成，开始覆盖本机文件"

  # 解压 app.tgz（与 fnOS 安装一致：扁平落到 APP_ROOT，不做目录剥离）
  local appex="$tmpd/appex"; mkdir -p "$appex"
  tar -xzf "$ex/app.tgz" -C "$appex"
  cp -a "$appex/." "$APP_ROOT/" 2>/dev/null
  cp -a "$ex/cmd/."     "$APP_ROOT/cmd/"     2>/dev/null
  cp -f "$ex/manifest"  "$APP_ROOT/manifest"  2>/dev/null
  cp -a "$ex/config/."  "$APP_ROOT/config/"  2>/dev/null
  cp -a "$ex/wizard/."  "$APP_ROOT/wizard/"  2>/dev/null
  log INFO "文件覆盖完成，开始重新部署硬件固件"

  # 重新部署固件（与原固件自愈同源的 install_all.sh）
  if [ -x "$APP_ROOT/cmd/upgrade_callback" ]; then
    TRIM_APPDEST="$APP_ROOT" bash "$APP_ROOT/cmd/upgrade_callback" >> "$LOG" 2>&1
  fi

  # 重启控制台使新 server.py / public 生效
  restart_console

  # 记录新版本
  echo "$newver" > "$VAR_DIR/version" 2>/dev/null
  LAST_RESULT="升级完成：$CURRENT -> $newver"
  CURRENT="$newver"; UPDATE_AVAILABLE=0
  echo_json
  rm -rf "$tmpd"
  return 0
}

case "${1:-status}" in
  check) do_check; rc=$?; save_state; echo_json; exit $rc ;;
  run|upgrade) do_upgrade "${2:-}"; rc=$?; save_state; exit $rc ;;
  status) read_current; load_state || LAST_RESULT="尚未检测过（用 check 检测）"; echo_json; exit 0 ;;
  *) echo "usage: $0 {status|check|run [--force]}"; exit 1 ;;
esac
