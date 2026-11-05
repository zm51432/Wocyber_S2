#!/usr/bin/env bash
# =============================================================
# sata-led-manager.sh —— 硬盘指示灯管理（精简版）
#
# Confirmed on this board:
#   gpio146 = Disk1 RED,  gpio147 = Disk1 GREEN
#   gpio148 = Disk2 RED,  gpio149 = Disk2 GREEN
#   gpio86  = switch gpio（全局使能，保持拉高）
#   点亮电平：1 = ON，0 = OFF
#
# 【当前策略】有盘亮绿灯、无盘全灭（最朴素的硬盘存在指示）
#   · 检测不到硬盘 → 红灯灭、绿灯灭（全灭）   ← 固定规则
#   · 检测到硬盘   → 绿灯常亮（默认）、红灯灭
#      不再做「未挂载红灯慢闪 / 有 IO 绿灯快闪 / SMART 异常红灯常亮」等
#      状态灯，也不再周期性调用 smartctl（避免频繁唤醒休眠中的硬盘）。
#
#   行为可在 /etc/sata-led.conf 调整：
#      KEEP_OFF_WHEN_PRESENT=1（默认）
#          PRESENT_GREEN=1 / PRESENT_RED=1 → 有盘时绿/红常亮（默认绿）
#          PRESENT_GREEN=0 且 PRESENT_RED=0 → 有盘也强制全灭（即老 v5 行为）
#      KEEP_OFF_WHEN_PRESENT=0   → 有盘时本服务完全不碰 GPIO（交回系统/飞牛）
#   改完： systemctl restart sata-led-manager
#
# 手动覆盖（优先级最高，S2硬件控制台 fpk 使用）
#   /etc/s2hwctl/led-override.conf 里 SATA_LED=off → 红绿全灭（有盘无盘都灭），
#   且压过 KEEP_OFF_WHEN_PRESENT=0 的「交回系统」分支。
#   本服务每个节拍重读该文件，固件升级 / selfheal 重装 / 服务重启均无法改变用户选择。
#   SATA_LED=auto 或文件不存在 = 自动模式。
# =============================================================
set -uo pipefail

# ---------- 可配置参数（/etc/sata-led.conf 可覆盖） ----------
R1=146
G1=147
R2=148
G2=149
SW=86

TICK=1                # 检测节拍（秒）
SYSFS_ROOT=/sys       # 仅测试用，真机不要改

# 有盘时的灯态（默认：绿灯常亮）
KEEP_OFF_WHEN_PRESENT=1   # 1=有盘时由本服务控制灯（按下面 PRESENT_* 电平）；0=有盘时完全不干预 GPIO
PRESENT_RED=0             # KEEP_OFF_WHEN_PRESENT=1 时生效：有盘红灯电平
PRESENT_GREEN=1           # KEEP_OFF_WHEN_PRESENT=1 时生效：有盘绿灯电平（默认 1=亮绿灯）

SLOT1_PATH="${SYSFS_ROOT}/devices/platform/fc400000.sata/ata*/host*/target*:*:*/*:*:*:*/block"
SLOT2_PATH="${SYSFS_ROOT}/devices/platform/fc800000.sata/ata*/host*/target*:*:*/*:*:*:*/block"

LOG_FILE=/var/log/sata-led.log

# fpk 手动覆盖文件（LED_OVERRIDE_CONF 仅测试用）
LED_OVERRIDE_CONF=${LED_OVERRIDE_CONF:-/etc/s2hwctl/led-override.conf}
SATA_LED_OVERRIDE=auto
sata_override() {
    local v=auto
    if [ -r "$LED_OVERRIDE_CONF" ]; then
        v=$( . "$LED_OVERRIDE_CONF" 2>/dev/null; echo "${SATA_LED:-auto}" )
    fi
    if [ "$v" = "off" ]; then SATA_LED_OVERRIDE=off; else SATA_LED_OVERRIDE=auto; fi
}

# conf 里的 SLOT*_PATH / SYSFS_ROOT 会覆盖上面的默认值
# SATA_LED_CONF 仅用于离线自测，真机不用管
SATA_LED_CONF=${SATA_LED_CONF:-/etc/sata-led.conf}
[ -r "$SATA_LED_CONF" ] && . "$SATA_LED_CONF"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null
}

# ---------- GPIO ----------
ensure_gpio_out() {
    local n="$1" G="${SYSFS_ROOT}/class/gpio/gpio$1"
    [ -e "$G" ] || echo "$n" > "${SYSFS_ROOT}/class/gpio/export" 2>/dev/null || true
    [ -e "$G" ] || return 1
    echo out > "$G/direction" 2>/dev/null || true
    return 0
}

declare -A led_state
led_set() {
    local n="$1" v="$2"
    if [ "${led_state[$n]:-}" != "$v" ]; then
        echo "$v" > "${SYSFS_ROOT}/class/gpio/gpio$n/value" 2>/dev/null || true
        led_state[$n]="$v"
    fi
}

slot_dev() {
    ls $1 2>/dev/null | head -n 1 || true
}

# ---------- 状态数组（下标 1 / 2 对应两个槽位）----------
declare -a present dev_name mode_now
for i in 1 2; do
    present[$i]=0; dev_name[$i]=""; mode_now[$i]="unknown"
done

update_slot() {
    local idx="$1" path="$2" d
    d=$(slot_dev "$path")
    dev_name[$idx]="$d"
    if [[ -n "$d" && -e "${SYSFS_ROOT}/block/$d/stat" ]]; then
        present[$idx]=1
    else
        present[$idx]=0
    fi
}

render_slot() {
    local idx="$1" r="$2" g="$3" rval=0 gval=0 mode

    if [ "$SATA_LED_OVERRIDE" = "off" ]; then
        mode="override-off"                     # 手动全灭：优先级最高，压过一切自动分支
        rval=0; gval=0
    elif (( present[idx] == 0 )); then
        mode="absent"
        rval=0; gval=0                       # 没有硬盘 → 红、绿全灭
    elif (( KEEP_OFF_WHEN_PRESENT == 1 )); then
        mode="present-off"
        rval=$PRESENT_RED; gval=$PRESENT_GREEN
    else
        mode="present-released"              # 有盘且不干预：不再写 GPIO
        if [ "${mode_now[$idx]}" != "$mode" ]; then
            log "槽位$idx ${dev_name[$idx]:-(空)} → $mode（本服务不再控制灯，交回系统）"
            mode_now[$idx]="$mode"
        fi
        return 0
    fi

    if [ "${mode_now[$idx]}" != "$mode" ]; then
        if (( gval == 1 )); then
            log "槽位$idx ${dev_name[$idx]:-(空)} → $mode（绿灯常亮）"
        elif (( rval == 1 )); then
            log "槽位$idx ${dev_name[$idx]:-(空)} → $mode（红灯常亮）"
        else
            log "槽位$idx ${dev_name[$idx]:-(空)} → $mode（灯全灭）"
        fi
        mode_now[$idx]="$mode"
    fi

    led_set "$r" "$rval"
    led_set "$g" "$gval"
}

# ---------- 初始化 ----------
for g in "$R1" "$G1" "$R2" "$G2" "$SW"; do
    ensure_gpio_out "$g" || log "GPIO$g 导出失败"
done
[ -e "${SYSFS_ROOT}/class/gpio/gpio$SW/value" ] && echo 1 > "${SYSFS_ROOT}/class/gpio/gpio$SW/value" 2>/dev/null || true

log "=== 硬盘指示灯服务启动（无盘全灭；有盘绿灯常亮）==="
log "参数: tick=${TICK}s keep_off_when_present=${KEEP_OFF_WHEN_PRESENT} present_red=${PRESENT_RED} present_green=${PRESENT_GREEN}"
sata_override
log "覆盖: sata_led_override=${SATA_LED_OVERRIDE}（off=手动全灭，优先级最高）"

while true; do
    sata_override
    update_slot 1 "$SLOT1_PATH"
    update_slot 2 "$SLOT2_PATH"
    render_slot 1 "$R1" "$G1"
    render_slot 2 "$R2" "$G2"
    sleep "$TICK"
done
