#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hwctl —— S2 硬件控制台的硬件控制层

设计要点
--------
1) 所有操作统一抽象为 {op, params}，由 OPS 表分发。
   这样「root 直接执行」与「本地 agent 代理执行」两条路径完全同构：
   非 root 时把同样的 op 转发给以 root 常驻的 s2hw-agent 即可。
2) 配置写入采用「保留注释的 KEY=VALUE 就地替换」，不破坏原 conf 文件的说明文字。
3) 任何写操作都不会直接改动系统自带脚本，只改 conf + 重启对应服务，
   保证卸载/回滚后系统仍可自洽。
"""

import glob
import json
import os
import re
import subprocess
import time

# ---------------- 路径 ----------------
ETC_SATA_LED = "/etc/sata-led.conf"
ETC_FAN = "/etc/fan-control.conf"
APP_CONF_DIR = "/etc/s2hwctl"
APP_BEEP_CONF = os.path.join(APP_CONF_DIR, "beep.conf")
LED_OVERRIDE_CONF = os.path.join(APP_CONF_DIR, "led-override.conf")
APP_SCHED_CONF = "/etc/s2-power-schedule.conf"

VAR_DIR = os.environ.get("S2_VAR_DIR", "/var/apps/wocyber_S2/var")
SCRIPTS_DIR = os.path.join(VAR_DIR, "scripts")
SHARE_SCRIPTS = os.environ.get("TRIM_DATA_SHARE_PATHS", "").split(":")[0]

LED_DIR = "/sys/class/leds"
BUZZER_SYSFS = "/sys/devices/platform/gpio_ctrl/buzzer_gpio"
GPIO_BEEPER = 18

HW_SERVICES = [
    "fan-control", "sata-led-manager", "power-led-net",
    "power-key-daemon", "random-mac", "set-hostname",
    "selfheal", "boot-version-guard",
    "s2-power-schedule",
]


# ---------------- 基础工具 ----------------
def sh(cmd, timeout=20, shell=True):
    """执行命令，返回 (rc, output)"""
    try:
        p = subprocess.run(cmd, shell=shell, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:  # noqa
        return 1, str(e)


def is_root():
    return os.geteuid() == 0


def read_kv(path):
    """解析 KEY=VALUE（忽略 # 注释）"""
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                if "=" not in s:
                    continue
                k, v = s.split("=", 1)
                out[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return out


def write_kv(path, updates, header=None):
    """就地替换 KEY=VALUE，保留注释与未涉及的键；文件不存在则新建"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.read().splitlines()
    seen = set()
    new_lines = []
    for line in lines:
        s = line.strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", s)
        if m and m.group(1) in updates:
            k = m.group(1)
            new_lines.append("%s=%s" % (k, updates[k]))
            seen.add(k)
        else:
            new_lines.append(line)
    for k, v in updates.items():
        if k not in seen:
            new_lines.append("%s=%s" % (k, v))
    if header and not lines:
        new_lines.insert(0, header)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")
    os.replace(tmp, path)
    return True


def sysfs_write(path, value):
    try:
        with open(path, "w") as f:
            f.write(str(value))
        return True
    except Exception:
        return False


def sysfs_read(path, default=""):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return default


def service_active(name):
    """
    返回服务状态串，供前端着色：
      active  -> 常驻服务正在运行（绿）
      done    -> 一次性(oneshot)服务已成功执行并退出（绿/中性，非故障）
      unknown -> 服务单元不存在（前端隐藏）
      其它    -> 真正的异常（红）
    关键点：boot-version-guard / s2-power-led 等 oneshot 服务开机跑一次就退出，
    systemd 报 inactive 是其正常终态，不能当作“未运行”标红。
    """
    rc, out = sh("systemctl is-active %s 2>/dev/null" % name, timeout=8)
    st = (out.strip().splitlines() or ["unknown"])[0].strip()
    if st in ("active", "unknown"):
        return st
    # inactive / failed / dead：判断是否为 oneshot 守卫，运行后退出属正常
    rc2, info = sh("systemctl show -p Type,Result %s 2>/dev/null" % name, timeout=8)
    typ = ""
    result = ""
    for line in info.splitlines():
        if line.startswith("Type="):
            typ = line.split("=", 1)[1].strip()
        elif line.startswith("Result="):
            result = line.split("=", 1)[1].strip()
    if typ == "oneshot" and result in ("success", ""):
        return "done"
    return st


def restart_service(name):
    rc, out = sh("systemctl restart %s 2>&1 | head -5" % name, timeout=40)
    if rc != 0 and "not found" in out.lower():
        return False, "服务 %s 不存在" % name
    return True, out.strip() or "已重启"


# ---------------- LED ----------------
def list_leds():
    leds = []
    if not os.path.isdir(LED_DIR):
        return leds
    for name in sorted(os.listdir(LED_DIR)):
        base = os.path.join(LED_DIR, name)
        triggers = sysfs_read(os.path.join(base, "trigger"), "")
        leds.append({
            "name": name,
            "brightness": sysfs_read(os.path.join(base, "brightness"), "0"),
            "max_brightness": sysfs_read(os.path.join(base, "max_brightness"), "255"),
            "trigger": (re.findall(r"\[(.*?)\]", triggers) or ["none"])[0],
        })
    return leds


def apply_led(name, mode="on", brightness=None, on_ms=500, off_ms=500):
    """
    保留供「脚本修复」等后续扩展使用；电源灯已由 power-led-net 常驻接管。
    mode: on | off | blink
    返回 (ok, msg)
    """
    base = os.path.join(LED_DIR, name)
    if not os.path.isdir(base):
        return False, "LED %s 不存在" % name
    maxb = sysfs_read(os.path.join(base, "max_brightness"), "255")
    try:
        maxb = int(maxb) or 255
    except ValueError:
        maxb = 255
    if mode == "blink":
        sysfs_write(os.path.join(base, "trigger"), "timer")
        sysfs_write(os.path.join(base, "delay_on"), str(int(on_ms)))
        sysfs_write(os.path.join(base, "delay_off"), str(int(off_ms)))
        return True, "已设置为闪烁 %sms/%sms" % (on_ms, off_ms)
    sysfs_write(os.path.join(base, "trigger"), "none")
    val = maxb if mode == "on" else 0
    if brightness is not None and mode == "on":
        val = max(0, min(maxb, int(brightness)))
    sysfs_write(os.path.join(base, "brightness"), str(val))
    return True, "已%s" % ("点亮" if val else "熄灭")


def load_app_conf(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_app_conf(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return True


# ---------------- 定时开关机 ----------------
def rtc_wake_supported():
    """检测 RTC 是否支持定时唤醒（wakealarm 可写即认为支持）"""
    for p in glob.glob("/sys/class/rtc/rtc*/wakealarm"):
        if os.access(p, os.W_OK):
            return True
    return False


def op_set_power_schedule(params):
    enabled = 1 if params.get("enabled") else 0
    shutdown_time = (params.get("shutdown_time") or "").strip()
    boot_time = (params.get("boot_time") or "").strip()

    import re
    hhmm = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
    if shutdown_time and not hhmm.match(shutdown_time):
        return False, "关机时间格式应为 HH:MM（24 小时制）"
    if boot_time and not hhmm.match(boot_time):
        return False, "开机时间格式应为 HH:MM（24 小时制）"

    updates = {
        "ENABLED": str(enabled),
        "SHUTDOWN_TIME": shutdown_time,
        "BOOT_TIME": boot_time,
    }
    write_kv(APP_SCHED_CONF, updates)
    # 应用：写 timer / 设 RTC 闹钟
    rc, out = sh("/usr/local/sbin/s2-power-schedule.sh apply 2>&1", timeout=30)
    if not rtc_wake_supported() and boot_time:
        return True, "已保存，但本机未检测到 RTC 唤醒能力，定时开机可能不生效；定时关机正常。"
    return True, "已保存并应用定时开关机配置"


# ---------------- 蜂鸣器 ----------------
def beep(ms=280):
    ms = max(30, min(5000, int(ms)))
    sec = ms / 1000.0
    if os.path.exists(BUZZER_SYSFS) and os.access(BUZZER_SYSFS, os.W_OK):
        rc, out = sh("echo 'buzzer_en:2' > %s && sleep %s && echo 'buzzer_en:0' > %s"
                     % (BUZZER_SYSFS, sec, BUZZER_SYSFS), timeout=max(3, int(sec) + 3))
        return (rc == 0), "gpio_ctrl 蜂鸣 %sms" % ms
    g = "/sys/class/gpio/gpio%d" % GPIO_BEEPER
    if not os.path.exists(g):
        sh("echo %d > /sys/class/gpio/export 2>/dev/null" % GPIO_BEEPER)
    if os.path.exists(os.path.join(g, "direction")):
        sysfs_write(os.path.join(g, "direction"), "out")
        sysfs_write(os.path.join(g, "value"), "1")
        time.sleep(sec)
        sysfs_write(os.path.join(g, "value"), "0")
        sh("echo %d > /sys/class/gpio/unexport 2>/dev/null" % GPIO_BEEPER)
        return True, "GPIO%d 蜂鸣 %sms" % (GPIO_BEEPER, ms)
    return False, "未找到可用蜂鸣器接口（gpio_ctrl / GPIO%d 均不可用）" % GPIO_BEEPER


# ---------------- 状态汇总 ----------------
def collect_status():
    fan_status = {}
    p = "/var/lib/fan-control/status"
    if os.path.exists(p):
        fan_status = read_kv(p)
    st = {
        "root": is_root(),
        "uid": os.geteuid(),
        "hostname": sysfs_read("/proc/sys/kernel/hostname", ""),
        "uptime": (open("/proc/uptime").read().split()[0] if os.path.exists("/proc/uptime") else ""),
        "services": {s: service_active(s) for s in HW_SERVICES},
        "leds": list_leds(),
        "cpu_temp": fan_status.get("cpu_temp", ""),
        "hdd_max_temp": fan_status.get("hdd_max_temp", ""),
        "fan_level": fan_status.get("level", ""),
        "fan_mode": fan_status.get("mode", ""),
        "fan_source": fan_status.get("hdd_source", ""),
        "disks": fan_status.get("disks", ""),
        "conf": {
            "beep": load_app_conf(APP_BEEP_CONF),
            "sata_led": read_kv(ETC_SATA_LED),
            "fan": read_kv(ETC_FAN),
            "led_override": {
                "power": read_kv(LED_OVERRIDE_CONF).get("POWER_LED", "auto"),
                "sata": read_kv(LED_OVERRIDE_CONF).get("SATA_LED", "auto"),
            },
            "power_schedule": {
                "enabled": read_kv(APP_SCHED_CONF).get("ENABLED", "0"),
                "shutdown_time": read_kv(APP_SCHED_CONF).get("SHUTDOWN_TIME", ""),
                "boot_time": read_kv(APP_SCHED_CONF).get("BOOT_TIME", ""),
                "rtc_wake": rtc_wake_supported(),
            },
        },
        "scripts": list_scripts(),
        "port": os.environ.get("PORT", ""),
        "agent": os.environ.get("S2_AGENT_URL", ""),
        "net_link": net_link_info(),
    }
    return st


def net_link_info():
    """电源灯网络状态灯的链路状态（调 power-led-net.sh status，未部署则标 unknown）"""
    out = {"up": None, "iface": "", "deployed": False}
    if not os.path.exists("/usr/local/sbin/power-led-net.sh"):
        return out
    rc, text = sh("/usr/local/sbin/power-led-net.sh status 2>/dev/null", timeout=10)
    if rc != 0:
        return out
    out["deployed"] = True
    for line in text.splitlines():
        if line.startswith("link="):
            out["up"] = line.split("=", 1)[1].split()[0] == "up"
        if "iface=" in line:
            out["iface"] = line.split("iface=", 1)[1].strip()
    return out


def list_scripts():
    out = []
    for d in [SCRIPTS_DIR, SHARE_SCRIPTS]:
        if not d or not os.path.isdir(d):
            continue
        for f in sorted(glob.glob(os.path.join(d, "*.sh"))):
            out.append({"name": os.path.basename(f), "path": f,
                        "builtin": d == SCRIPTS_DIR,
                        "size": os.path.getsize(f),
                        "mtime": int(os.path.getmtime(f))})
    return out


# ---------------- 各 op 实现 ----------------
def op_status(params):
    return True, collect_status()


def op_set_power_led(params):
    # v1.1.4 起电源灯由 power-led-net（网络状态灯）常驻接管；v1.1.5 起用 set_led_override 控制。
    # 保留函数以便旧版前端/CLI 调用时得到明确提示（未注册进 OPS）。
    return False, "电源灯已由网络状态灯接管；全灭/恢复请用「灯光覆盖」(set_led_override)"


def op_set_led_override(params):
    """手动覆盖：power/sata = auto|off。off=强制全灭，优先级最高（固件守护每节拍重读本配置）"""
    updates = {}
    power = params.get("power")
    sata = params.get("sata")
    if power in ("auto", "off"):
        updates["POWER_LED"] = power
    if sata in ("auto", "off"):
        updates["SATA_LED"] = sata
    if not updates:
        return False, "参数应为 power / sata = auto|off"
    write_kv(LED_OVERRIDE_CONF, updates,
             header="# S2硬件控制台 灯光手动覆盖（off=全灭优先级最高，auto=固件自动）")
    msg = []
    if "POWER_LED" in updates:
        v = updates["POWER_LED"]
        restart_service("power-led-net")
        msg.append("电源灯=%s（%s）" % (v, "全灭" if v == "off" else "网络状态自动"))
    if "SATA_LED" in updates:
        v = updates["SATA_LED"]
        restart_service("sata-led-manager")
        msg.append("硬盘灯=%s（%s）" % (v, "全灭" if v == "off" else "有盘绿灯自动"))
    return True, "已保存并立即生效：" + "，".join(msg)


def op_set_fan(params):
    mode = params.get("mode", "auto")
    level = int(params.get("level", 6))
    level = max(0, min(15, level))
    persist = bool(params.get("persist", True))
    hdd = params.get("hdd") or {}
    cpu = params.get("cpu") or {}
    updates = {}
    if persist:
        if not os.path.exists(ETC_FAN):
            return False, "未找到 %s，风扇服务可能未安装" % ETC_FAN
        updates["MODE"] = mode
        updates["MANUAL_LEVEL"] = level
        for k, v in (("HDD_TEMP_OFF", hdd.get("off")), ("HDD_TEMP_LOW", hdd.get("low")),
                     ("HDD_TEMP_MID", hdd.get("mid")), ("HDD_TEMP_MAX", hdd.get("max")),
                     ("TEMP_OFF", cpu.get("off")), ("TEMP_LOW", cpu.get("low")),
                     ("TEMP_MID", cpu.get("mid")), ("TEMP_CRITICAL", cpu.get("crit"))):
            if v not in (None, ""):
                updates[k] = int(v)
        write_kv(ETC_FAN, updates)
    # 立即生效：写运行态文件（与 fanctl 等价）
    run_dir = "/var/lib/fan-control"
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "mode"), "w") as f:
        f.write(mode)
    if mode == "manual":
        with open(os.path.join(run_dir, "level"), "w") as f:
            f.write(str(level))
    msg = "风扇已设为 %s" % ("手动 %d/15 挡" % level if mode == "manual" else "自动温控")
    if persist:
        restart_service("fan-control")
        msg += "（已写入配置，重启后保留）"
    else:
        msg += "（仅本次生效）"
    return True, msg


def op_set_beep(params):
    ms = max(30, min(5000, int(params.get("ms", 280))))
    conf = load_app_conf(APP_BEEP_CONF)
    conf["beep_ms"] = ms
    conf["boot_beep"] = bool(params.get("boot_beep", conf.get("boot_beep", True)))
    save_app_conf(APP_BEEP_CONF, conf)
    return True, "蜂鸣时长已保存为 %d ms" % ms


def op_beep_test(params):
    ms = params.get("ms")
    if ms is None:
        ms = load_app_conf(APP_BEEP_CONF).get("beep_ms", 280)
    ok, msg = beep(ms)
    return ok, msg


def op_service(params):
    name = params.get("name", "")
    action = params.get("action", "restart")
    if name not in HW_SERVICES:
        return False, "不允许操作服务：%s" % name
    rc, out = sh("systemctl %s %s 2>&1 | head -5" % (action, name), timeout=40)
    return rc == 0, out.strip() or ("%s %s 完成" % (action, name))


def op_logs(params):
    name = params.get("name", "sata-led")
    paths = {
        "sata-led": "/var/log/sata-led.log",
        "fan": "/var/log/fan-control.log",
        "selfheal": "/var/log/selfheal-install.log",
        "app": os.path.join(VAR_DIR, "server.log"),
    }
    p = paths.get(name, "")
    if not p or not os.path.exists(p):
        return True, {"lines": ["(暂无日志) %s" % (p or name)]}
    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.read().splitlines()[-int(params.get("n", 120)):]
    return True, {"lines": lines}


def op_set_port(params):
    """改应用自身端口：写 settings.conf 再由 server 触发重启"""
    port = int(params.get("port", 0))
    if port < 1 or port > 65535:
        return False, "端口非法"
    etc = os.environ.get("S2_ETC_DIR", "/var/apps/wocyber_S2/etc")
    settings = os.path.join(etc, "settings.conf")
    write_kv(settings, {"PORT": port})
    return True, "端口已写入 %d，正在重启应用…" % port


OPS = {
    "status": op_status,
    "set_led_override": op_set_led_override,
    "set_fan": op_set_fan,
    "set_beep": op_set_beep,
    "beep_test": op_beep_test,
    "set_power_schedule": op_set_power_schedule,
    "service": op_service,
    "logs": op_logs,
    "set_port": op_set_port,
}


def dispatch(op, params):
    fn = OPS.get(op)
    if not fn:
        return False, "未知操作：%s" % op
    try:
        ok, data = fn(params or {})
        return ok, data
    except Exception as e:  # noqa
        return False, "执行异常：%s" % e
