#!/bin/bash
# =============================================================
# Centerm NAS RK3568 风扇控制脚本（PWM7 占空比分档）
# 参考：https://zhuanlan.zhihu.com/p/5767112601
#
# 版本演进
#   v1  仅 CPU 温度分档
#   v2  温度滤波 / 去抖，避免风扇频繁启停
#   v3  新增【硬盘温度】参与调速（本版重点）
#        - 硬盘安全温度远低于 CPU（40℃ 就该转，CPU 60℃ 才转），
#          所以硬盘与 CPU 各走一条曲线，最终取两者【较高的挡位】，
#          而不是简单取 max(温度) 去比对 CPU 阈值（那样硬盘 50℃ 也不会转）。
#   v4  预留页面手动调节接口
#        - 支持 auto / manual 两种模式
#        - 运行态控制文件 /var/lib/fan-control/{mode,level}，页面后端直接写文件即可
#        - 配套 fanctl 命令行 + fan-api.py（HTTP，默认不启用）
#        - 状态文件 /var/lib/fan-control/status 供页面读取
#
# 取温方式（按优先级）
#   1) drivetemp 内核模块 → /sys/class/hwmon  —— 纯内核态，不唤醒休眠硬盘，首选
#   2) smartctl -A -n standby                 —— 兜底；-n standby 保证不唤醒待机盘
#   3) 取不到硬盘温度 → 退回纯 CPU 温控（日志会提示）
# =============================================================

# ---------- 默认配置（可被 /etc/fan-control.conf 覆盖） ----------
USE_GPIO_FORCE=0     # 1=强制 GPIO；0=PWM 占空比（已确认有效）
PWM_CHIP=0
PWM_CHANNEL=0
PWM_PERIOD=40000     # 25kHz，period=40000ns
PWM_POLARITY="normal"
FAN_DUTY_MIN=60      # 最低占空比 %，此风扇 50% 以下不转
FAN_GPIO=22          # GPIO 备用
CHECK_INTERVAL=3
FACTORY_TEST_CYCLE=10
TEMP_DEBOUNCE_CNT=2  # 连续 N 次目标挡位不同才真正调整

# 模式：auto=温控自动；manual=固定挡位（页面/CLI 可切换）
MODE=auto
MANUAL_LEVEL=6       # manual 模式下的固定挡位 0-15（0=停转）

# 硬盘温控曲线（机械盘/SSD 安全温度比 CPU 低得多）
HDD_TEMP_OFF=40      # < 40℃  停转
HDD_TEMP_LOW=45      # 40-45  低速
HDD_TEMP_MID=55      # 45-55  线性 1→8
HDD_TEMP_MAX=60      # >= 60  全速

# CPU 温控曲线（沿用原版，作为兜底）
TEMP_OFF=60
TEMP_LOW=65
TEMP_MID=80
TEMP_CRITICAL=100

# 硬盘取温：hwmon 可用时不轮询 smartctl；不可用时每 N 个周期问一次
HDD_SMART_CYCLES=10  # 10 × 3s = 30s
HDD_SMART_TIMEOUT=8

# ---------- 运行态目录（页面接口） ----------
RUN_DIR=/var/lib/fan-control
STATUS_FILE="$RUN_DIR/status"
MODE_FILE="$RUN_DIR/mode"      # 内容：auto | manual
LEVEL_FILE="$RUN_DIR/level"    # 内容：0-15

LOG_FILE="/var/log/fan_control.log"

# 载入外部配置（存在则覆盖上面的默认值）
CONF_FILE=/etc/fan-control.conf
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

mkdir -p "$RUN_DIR" 2>/dev/null

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 只保留 1 天内的日志
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    local cutoff
    cutoff=$(date -d '1 day ago' '+%Y-%m-%d %H:%M' 2>/dev/null)
    [ -z "$cutoff" ] && return 0
    awk -v c="$cutoff" '/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/ {
        if (substr($0,2,16) >= c) print; next
    } {print}' "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

# ---------- PWM / GPIO ----------
find_pwm7_chip() {
    local chip path
    for chip in 0 1 2 3 4 5 6 7; do
        path="/sys/class/pwm/pwmchip${chip}"
        [ -d "$path" ] || continue
        if [ -e "${path}/device" ] && readlink -f "${path}/device" 2>/dev/null | grep -q "fe6e0030"; then
            echo $chip
            return 0
        fi
    done
    for chip in 0 1 2 3 4 5 6 7; do
        [ -d "/sys/class/pwm/pwmchip${chip}" ] || continue
        if echo $PWM_CHANNEL > /sys/class/pwm/pwmchip${chip}/export 2>/dev/null; then
            echo $chip
            return 0
        fi
    done
    echo ""
    return 1
}

init_pwm() {
    if [ -n "$PWM_CHIP" ] && [ -d "/sys/class/pwm/pwmchip${PWM_CHIP}" ]; then
        FOUND_CHIP=$PWM_CHIP
    else
        FOUND_CHIP=$(find_pwm7_chip)
    fi

    if [ -n "$FOUND_CHIP" ]; then
        PWM_PATH="/sys/class/pwm/pwmchip${FOUND_CHIP}/pwm${PWM_CHANNEL}"
        if [ ! -d "$PWM_PATH" ]; then
            echo $PWM_CHANNEL > /sys/class/pwm/pwmchip${FOUND_CHIP}/export 2>/dev/null
        fi
        if [ -d "$PWM_PATH" ]; then
            echo 0 > "${PWM_PATH}/enable" 2>/dev/null
            echo $PWM_PERIOD > "${PWM_PATH}/period" 2>/dev/null
            echo "$PWM_POLARITY" > "${PWM_PATH}/polarity" 2>/dev/null
            log "PWM 初始化成功 (pwmchip${FOUND_CHIP}, ${PWM_PERIOD}ns=25kHz, polarity=$PWM_POLARITY)"
            return 0
        fi
    fi
    log "PWM 不可用，将使用 GPIO${FAN_GPIO} 备用"
    return 1
}

init_gpio() {
    local gpio_path="/sys/class/gpio/gpio${FAN_GPIO}"
    if [ -d "$gpio_path" ]; then
        log "GPIO${FAN_GPIO} 已存在，直接使用"
    else
        echo $FAN_GPIO > /sys/class/gpio/export 2>/dev/null
    fi
    echo out > "${gpio_path}/direction" 2>/dev/null
    echo 0 > "${gpio_path}/value" 2>/dev/null
}

set_fan_speed_pwm() {
    local speed=$1
    local duty=0 duty_pct=0
    if [ $speed -gt 0 ]; then
        duty_pct=$(( FAN_DUTY_MIN + (speed - 1) * (100 - FAN_DUTY_MIN) / 14 ))
        [ $duty_pct -gt 100 ] && duty_pct=100
        if [ "$PWM_POLARITY" = "inversed" ]; then
            duty=$(( PWM_PERIOD * (100 - duty_pct) / 100 ))
        else
            duty=$(( PWM_PERIOD * duty_pct / 100 ))
        fi
        echo $duty > "${PWM_PATH}/duty_cycle" 2>/dev/null
        echo 1 > "${PWM_PATH}/enable" 2>/dev/null
    else
        echo 0 > "${PWM_PATH}/enable" 2>/dev/null
    fi
    LAST_DUTY=$duty_pct
}

set_fan_speed_gpio() {
    local speed=$1
    local gpio_path="/sys/class/gpio/gpio${FAN_GPIO}"
    if [ $speed -gt 0 ]; then
        echo 1 > "${gpio_path}/value" 2>/dev/null
        duty_pct=100
    else
        echo 0 > "${gpio_path}/value" 2>/dev/null
        duty_pct=0
    fi
    LAST_DUTY=$duty_pct
}

# ---------- 温度采集 ----------
get_cpu_temp() {
    local temp_raw
    temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    echo $(( temp_raw / 1000 ))
}

# 列出所有物理磁盘（含 NVMe）
list_disks() {
    local d out=""
    for d in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -b "$d" ] && out="$out $d"
    done
    echo $out
}

# 方式1：drivetemp 内核模块（不唤醒硬盘）。
# 输出格式：每行 "名字=温度"
read_disk_temp_hwmon() {
    local d n v name t
    for d in /sys/class/hwmon/hwmon*; do
        [ -r "$d/name" ] || continue
        n=$(cat "$d/name" 2>/dev/null)
        case "$n" in
            drivetemp) ;;
            *) continue ;;
        esac
        v=$(cat "$d/temp1_input" 2>/dev/null) || continue
        [ -n "$v" ] || continue
        # 尝试反查对应的块设备名，查不到就用 hwmon 编号兜底
        name=$(ls "${d}/device/block" 2>/dev/null | head -1)
        [ -n "$name" ] || name=$(basename "$d")
        t=$(( v / 1000 ))
        echo "${name}=${t}"
    done
}

# 方式2：smartctl（兜底）。-n standby 保证不会唤醒待机盘。
# 输出格式：每行 "名字=温度"
read_disk_temp_smart() {
    local dev t name out=""
    for dev in $(list_disks); do
        name=$(basename "$dev")
        case "$name" in
            nvme*)
                t=$(timeout "$HDD_SMART_TIMEOUT" smartctl -A -n standby "$dev" 2>/dev/null \
                    | awk '/^[Tt]emperature[:/]/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')
                ;;
            *)
                t=$(timeout "$HDD_SMART_TIMEOUT" smartctl -A -n standby "$dev" 2>/dev/null \
                    | awk '/^ *(190|194) / {print $10; exit}')
                ;;
        esac
        case "${t:-}" in
            ''|*[!0-9]*) continue ;;
        esac
        # 194 的 raw 值有时会带高字节（如 35 显示为 35，个别盘为 大型数），做一次合理性过滤
        [ "$t" -gt 120 ] && continue
        out="$out ${name}=${t}"
    done
    echo $out
}

# ---------- 挡位计算 ----------
# 通用曲线：off/low/mid 三段，返回 0-15
level_from_curve() {
    local temp=$1 off=$2 low=$3 mid=$4
    if [ "$temp" -lt "$off" ]; then
        echo 0
    elif [ "$temp" -lt "$low" ]; then
        echo 1
    elif [ "$temp" -lt "$mid" ]; then
        local range=$(( mid - low ))
        local delta=$(( temp - low ))
        [ "$range" -le 0 ] && { echo 15; return; }
        echo $(( 1 + delta * 7 / range ))
    else
        echo 15
    fi
}

# 硬盘专用曲线：四段平滑，避免在 MID 处从 8 挡一下子跳到 15 挡
#   < OFF(40)            0   停转
#   OFF(40) ~ LOW(45)    1   低速
#   LOW(45) ~ MID(55)    1 → 10   线性
#   MID(55) ~ MAX(60)    10 → 15  线性
#   >= MAX(60)           15  全速
level_from_hdd() {
    local temp=$1 r d
    if [ "$temp" -lt "$HDD_TEMP_OFF" ]; then
        echo 0
    elif [ "$temp" -lt "$HDD_TEMP_LOW" ]; then
        echo 1
    elif [ "$temp" -lt "$HDD_TEMP_MID" ]; then
        r=$(( HDD_TEMP_MID - HDD_TEMP_LOW ))
        d=$(( temp - HDD_TEMP_LOW ))
        [ "$r" -le 0 ] && { echo 15; return; }
        echo $(( 1 + d * 9 / r ))
    elif [ "$temp" -lt "$HDD_TEMP_MAX" ]; then
        r=$(( HDD_TEMP_MAX - HDD_TEMP_MID ))
        d=$(( temp - HDD_TEMP_MID ))
        [ "$r" -le 0 ] && { echo 15; return; }
        echo $(( 10 + d * 5 / r ))
    else
        echo 15
    fi
}

# ---------- 模式 / 挡位解析（页面接口入口） ----------
# 运行态文件优先于配置文件；文件不存在或内容非法则回落配置文件
resolve_mode() {
    local m=""
    [ -r "$MODE_FILE" ] && m=$(tr -d ' \t\r\n' < "$MODE_FILE" 2>/dev/null)
    case "$m" in
        auto|manual) echo "$m" ;;
        *) echo "$MODE" ;;
    esac
}

resolve_manual_level() {
    local lv=""
    [ -r "$LEVEL_FILE" ] && lv=$(tr -d ' \t\r\n' < "$LEVEL_FILE" 2>/dev/null)
    case "$lv" in
        ''|*[!0-9]*) echo "$MANUAL_LEVEL" ;;
        *) [ "$lv" -gt 15 ] && lv=15; echo "$lv" ;;
    esac
}

# ---------- 状态输出（供页面 / fan-api 读取） ----------
write_status() {
    local mode=$1 level=$2 cpu=$3 hddmax=$4 src=$5 disks=$6
    {
        echo "timestamp=$(date +'%Y-%m-%d %H:%M:%S')"
        echo "mode=$mode"
        echo "level=$level"
        echo "duty_pct=${LAST_DUTY:-0}"
        echo "cpu_temp=$cpu"
        echo "hdd_max_temp=$hddmax"
        echo "hdd_source=$src"
        echo "disks=$disks"
    } > "${STATUS_FILE}.tmp" 2>/dev/null && mv "${STATUS_FILE}.tmp" "$STATUS_FILE" 2>/dev/null
}

# ---------- 主循环 ----------
main() {
    trim_log
    log "=== 风扇控制服务启动（v4：硬盘温度 + 手动挡位接口） ==="
    log "曲线 硬盘: <${HDD_TEMP_OFF}停 ${HDD_TEMP_OFF}-${HDD_TEMP_LOW}1挡 ${HDD_TEMP_LOW}-${HDD_TEMP_MID}1→10挡 ${HDD_TEMP_MID}-${HDD_TEMP_MAX}10→15挡 >=${HDD_TEMP_MAX}全速"
    log "曲线 CPU : <${TEMP_OFF}停 ${TEMP_OFF}-${TEMP_LOW}1挡 ${TEMP_LOW}-${TEMP_MID}1→8挡 >=${TEMP_MID}全速"

    # 尝试加载 drivetemp（失败不影响，走 smartctl 兜底）
    modprobe drivetemp 2>/dev/null && log "drivetemp 模块已加载（硬盘温度走内核 hwmon，不唤醒硬盘）"

    local use_pwm=1
    if [ $USE_GPIO_FORCE -eq 1 ]; then
        use_pwm=0
        init_gpio
    else
        if ! init_pwm; then
            use_pwm=0
            init_gpio
        fi
    fi

    local cycle_count=0
    local debounce_cnt=0
    local last_speed=-1
    LAST_DUTY=0
    local cache_disks=""          # 最近一次硬盘温度快照 "sda=43 sdb=41"
    local hdd_source="none"

    while true; do
        local mode cpu hdd_max=0 hdd_level=0 cpu_level=0 target_speed=0
        local d t name

        mode=$(resolve_mode)
        cpu=$(get_cpu_temp)

        # ---- 硬盘温度：hwmon 优先，否则按周期轮询 smartctl ----
        local disk_snap=""
        if [ -d /sys/class/hwmon ]; then
            disk_snap=$(read_disk_temp_hwmon)
        fi
        if [ -n "$disk_snap" ]; then
            hdd_source="hwmon"
            cache_disks="$disk_snap"
        else
            if [ $((cycle_count % HDD_SMART_CYCLES)) -eq 0 ] || [ -z "$cache_disks" ]; then
                local s
                s=$(read_disk_temp_smart)
                if [ -n "$s" ]; then
                    hdd_source="smartctl"
                    cache_disks="$s"
                fi
            fi
            disk_snap="$cache_disks"
        fi

        # 取所有盘的最高温度
        for d in $disk_snap; do
            name="${d%%=*}"
            t="${d##*=}"
            case "${t:-}" in ''|*[!0-9]*) continue ;; esac
            [ "$t" -gt "$hdd_max" ] && hdd_max=$t
        done

        # ---- 计算目标挡位 ----
        if [ "$mode" = "manual" ]; then
            target_speed=$(resolve_manual_level)
        else
            if [ "$hdd_max" -gt 0 ]; then
                hdd_level=$(level_from_hdd "$hdd_max")
                [ "$hdd_max" -ge "$HDD_TEMP_MAX" ] && log "⚠️  硬盘温度 ${hdd_max}℃ 已达上限阈值 ${HDD_TEMP_MAX}℃，风扇全速"
            fi
            cpu_level=$(level_from_curve "$cpu" "$TEMP_OFF" "$TEMP_LOW" "$TEMP_MID")
            # 两条曲线取较高者：硬盘 45℃ 就该转，CPU 65℃ 也该转，谁更热听谁的
            target_speed=$(( hdd_level > cpu_level ? hdd_level : cpu_level ))
        fi
        [ "$target_speed" -gt 15 ] && target_speed=15

        # ---- 去抖（手动模式立即生效，用户是明确指定的） ----
        if [ "$mode" = "manual" ]; then
            if [ "$target_speed" -ne "$last_speed" ]; then
                last_speed=$target_speed
                if [ $use_pwm -eq 1 ]; then set_fan_speed_pwm "$last_speed"; else set_fan_speed_gpio "$last_speed"; fi
                log "手动模式：挡位设置为 ${last_speed}/15"
            fi
        elif [ "$target_speed" -ne "$last_speed" ]; then
            if [ "$debounce_cnt" -lt "$TEMP_DEBOUNCE_CNT" ]; then
                debounce_cnt=$((debounce_cnt + 1))
            else
                last_speed=$target_speed
                debounce_cnt=0
                if [ $use_pwm -eq 1 ]; then set_fan_speed_pwm "$last_speed"; else set_fan_speed_gpio "$last_speed"; fi
                log "CPU ${cpu}℃ / 硬盘最高 ${hdd_max}℃($hdd_source) → 挡位 ${last_speed}/15 (硬盘档$hdd_level CPU档$cpu_level)"
            fi
        else
            debounce_cnt=0
        fi

        write_status "$mode" "$last_speed" "$cpu" "$hdd_max" "$hdd_source" "$disk_snap"

        cycle_count=$((cycle_count + 1))
        if [ $((cycle_count % FACTORY_TEST_CYCLE)) -eq 0 ]; then
            log "心跳: 模式=$mode CPU=${cpu}℃ 硬盘最高=${hdd_max}℃($hdd_source) 挡位=${last_speed} 占空比=${LAST_DUTY}%"
            trim_log
        fi

        sleep $CHECK_INTERVAL
    done
}

main
