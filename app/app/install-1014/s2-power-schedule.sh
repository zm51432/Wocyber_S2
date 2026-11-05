#!/bin/bash
# =============================================================
# s2-power-schedule.sh —— S2 定时开关机
#
# 配置 /etc/s2-power-schedule.conf：
#   ENABLED=0|1
#   SHUTDOWN_TIME=HH:MM   (空=不自动关机)
#   BOOT_TIME=HH:MM       (空=不自动开机)
#
# 关机：systemd timer 每日到点触发 poweroff
# 开机：每次启动把"下一次开机时刻"写入 RTC wakealarm，
#       设备软关机(standby)后由 RTC 在设定时刻唤醒（需主板 RTC 常供电，
#       即 NAS 一直插电；彻底断电则 RTC 复位，开机失效）。
#
# 用法： s2-power-schedule.sh apply | status
# =============================================================
set -u

CONF="/etc/s2-power-schedule.conf"
RTC="$(ls /sys/class/rtc/rtc*/wakealarm 2>/dev/null | head -1)"
SHUTDOWN_TIMER="/etc/systemd/system/s2-power-shutdown.timer"
SHUTDOWN_SVC="s2-power-shutdown.service"

read_conf() {
  ENABLED=0; SHUTDOWN_TIME=""; BOOT_TIME=""
  [ -f "$CONF" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      ENABLED)        ENABLED="$v" ;;
      SHUTDOWN_TIME)  SHUTDOWN_TIME="$v" ;;
      BOOT_TIME)      BOOT_TIME="$v" ;;
    esac
  done < "$CONF"
}

# $1=HH:MM -> 今天或明天该时刻的 epoch；若已过期则用明天
next_epoch() {
  local h m now today target
  IFS=':' read -r h m <<< "$1"
  now=$(date +%s)
  today=$(date -d "today ${h}:${m}" +%s 2>/dev/null)
  [ -z "$today" ] && return 1
  if [ "$today" -le "$now" ]; then
    target=$(date -d "tomorrow ${h}:${m}" +%s 2>/dev/null)
  else
    target=$today
  fi
  echo "$target"
}

arm_rtc() {
  local t="$1"
  if [ -z "$RTC" ]; then
    echo "未找到 RTC wakealarm 接口，定时开机不可用"
    return 1
  fi
  # 先清零再写（部分 RTC 不允许重复写未来值）
  echo 0 > "$RTC" 2>/dev/null
  if echo "$t" > "$RTC" 2>/dev/null; then
    echo "已设置 RTC 定时开机: $(date -d "@$t" '+%F %T')"
    return 0
  fi
  # 回退 rtcwake
  if command -v rtcwake >/dev/null 2>&1; then
    if rtcwake -m no -t "$t" >/dev/null 2>&1; then
      echo "已通过 rtcwake 设置定时开机: $(date -d "@$t" '+%F %T')"
      return 0
    fi
  fi
  echo "RTC 定时开机设置失败（硬件可能不支持唤醒）"
  return 1
}

apply() {
  read_conf
  if [ "$ENABLED" != "1" ]; then
    echo "定时开关机未启用，清理已设规则"
    systemctl disable --now "$SHUTDOWN_SVC"      >/dev/null 2>&1 || true
    systemctl disable --now s2-power-shutdown.timer >/dev/null 2>&1 || true
    [ -n "$RTC" ] && echo 0 > "$RTC" 2>/dev/null
    return 0
  fi

  # ---- 定时关机 ----
  if [ -n "$SHUTDOWN_TIME" ]; then
    cat > "$SHUTDOWN_TIMER" <<EOF
[Unit]
Description=S2 定时关机定时器
[Timer]
OnCalendar=*-*-* ${SHUTDOWN_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now s2-power-shutdown.timer >/dev/null 2>&1 \
      && echo "已启用定时关机: 每日 ${SHUTDOWN_TIME}" \
      || echo "定时关机启用失败"
  else
    systemctl disable --now s2-power-shutdown.timer >/dev/null 2>&1 || true
    echo "未设置关机时间，定时关机关闭"
  fi

  # ---- 定时开机 ----
  if [ -n "$BOOT_TIME" ]; then
    local t
    t=$(next_epoch "$BOOT_TIME") && arm_rtc "$t" \
      || echo "未设置有效的开机时间，定时开机关闭"
  else
    [ -n "$RTC" ] && echo 0 > "$RTC" 2>/dev/null
    echo "未设置开机时间，定时开机关闭"
  fi
}

case "${1:-apply}" in
  apply)  apply ;;
  status) read_conf; echo "ENABLED=$ENABLED SHUTDOWN_TIME=$SHUTDOWN_TIME BOOT_TIME=$BOOT_TIME RTC=${RTC:-none}" ;;
  *) echo "usage: $0 [apply|status]"; exit 1 ;;
esac
exit 0
