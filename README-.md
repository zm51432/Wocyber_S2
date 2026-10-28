<div align="center">

# wocyber_S2 硬件控制台

**安装与使用说明书 · 精简版**

[![版本](https://img.shields.io/badge/版本-v1.3.3-blue?style=flat-square)](https://github.com/zm51432/Wocyber_S2)
[![系统](https://img.shields.io/badge/fnOS-0.9.0+-orange?style=flat-square)](https://help.fnnas.com/)
[![架构](https://img.shields.io/badge/arch-RK3568-green?style=flat-square)](https://github.com/zm51432/Wocyber_S2)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](./LICENSE)

把电源灯、硬盘灯、风扇、蜂鸣器、定时开关机收进一个可视化 Web 控制台，无需 SSH 即可调节。

</div>

---

## 📖 目录

- [一、产品简介](#一产品简介)
- [二、安装前准备](#二安装前准备)
- [三、安装步骤](#三安装步骤)
- [四、快速上手](#四快速上手)
- [五、功能速查](#五功能速查)
- [六、SSH 命令行速查](#六ssh-命令行速查)
- [七、配置文件与优先级](#七配置文件与优先级)
- [八、系统升级与自愈](#八系统升级与自愈)
- [九、卸载](#九卸载)
- [十、常见问题](#十常见问题)
- [附录：版本演进](#附录版本演进)

---

## 一、产品简介

`wocyber_S2`（包名、显示名、应用账号三者同名）是面向飞牛 fnOS 定制固件的硬件控制台应用。
主板上原本需要逐条敲命令调参的底层硬件能力，全部收进一个可视化 Web 控制台，并内置**「脚本拖放修复窗口」**用于应急排障。

### 版本信息

| 项目 | 内容 |
|---|---|
| 应用名称 | `wocyber_S2` |
| 当前版本 | **v1.3.3** |
| 安装包 | `wocyber_S2.fpk`（约 143 KB） |
| 包 MD5 | `58384932dec72e46d92cdca918b16cad` |
| 运行身份 | root（硬件操作必需） |
| 默认端口 | `18899`（可自定义） |
| 适用平台 | arm（RK3568 / 智小惠 S2） |
| 最低系统 | fnOS 0.9.0 及以上 |
| 开发者 | Ben |

### 核心特点

- **安装即部署** —— 包内嵌了全部硬件定制脚本（49 个固件文件 + `deploy.sh`），安装时自动部署到系统并启用服务。即使设备刷的是从未打过补丁的干净 fnOS，装上即获得完整硬件行为；**卸载时这些硬件行为会保留**，不会失效。
- **零第三方依赖** —— 服务端仅用 Python 标准库，界面为纯本地资源，无外链字体与 CDN，适用于完全离线的内网环境。

---

## 二、安装前准备

| 检查项 | 要求 | 说明 |
|---|---|---|
| 系统版本 | fnOS 0.9.0 及以上 | manifest 中 `os_min_version=0.9.0` |
| CPU 架构 | arm / arm64 | 若应用中心提示架构不匹配，可将 manifest 改为 `platform=all` 重新打包 |
| 安装权限 | 管理员权限 | 第三方 root 应用只能「手动安装」，不能上架应用商店，自用无影响 |
| 端口占用 | 18899 未被占用 | 若已占用，安装向导第一步可改成其他端口 |
| 网络 | 无要求 | 应用不联网，纯本地运行 |

**校验安装包完整性：**

```bash
md5sum wocyber_S2.fpk
# 正确输出：58384932dec72e46d92cdca918b16cad
```

---

## 三、安装步骤

### 方法一：应用中心手动安装（推荐）

1. 登录 fnOS 桌面，打开 **应用中心**。
2. 点击右上角 **设置 → 手动安装应用**。
3. 选中 `wocyber_S2.fpk` 并打开。
4. 按向导完成两步配置（见下方），点击安装，等待提示成功。

**向导第一步 · 访问端口**

| 字段 | 默认值 | 说明 |
|---|---|---|
| Web 管理端口 | `18899` | 桌面图标与浏览器都通过该端口打开控制台；取值 1-65535 |

**向导第二步 · 安全与自启动**

| 字段 | 默认值 | 说明 |
|---|---|---|
| 启用访问口令 | 关闭 | 开启后访问控制台需输入口令，适合不可信网络 |
| 访问口令 | 空 | 仅在上一项开启时生效 |
| 开机自动应用灯光设置 | 开启 | 安装 `s2-power-led.service`，开机自动套用已保存的电源灯配置 |

> 以上两项安装后仍可在「应用设置 → 配置」中修改。

### 方法二：命令行安装（备选）

SSH 登录设备（如 MobaXterm 连 IP、端口 22），把 fpk 上传到设备任意目录后执行：

```bash
appcenter-cli install-fpk wocyber_S2.fpk
appcenter-cli start wocyber_S2
```

> [!WARNING]
> **从旧版升级必读**：若此前安装过旧版 `s2hwctl`，由于本版包名已变更为 `wocyber_S2`，飞牛会将其视为另一个应用，**不会原地升级**。
> 请先在应用中心**卸载旧的 `s2hwctl`**，再安装 `wocyber_S2.fpk`。
> 硬件守护服务本就随固件运行，卸载旧应用不会导致硬件功能中断。

### 安装后验证

```bash
# ① 桌面出现 wocyber_S2 图标，点击可直接打开控制台

# ② 服务全部就绪（定时开关机默认关闭，显示 inactive 属正常）
systemctl is-active fan-control sata-led-manager power-led-net s2-power-schedule

# ③ 风扇状态可读（应能读到 CPU 温度、硬盘温度与当前挡位）
fanctl status

# ④ 硬件脚本已落盘
ls /usr/local/sbin/ | grep -E "power-led-net|sata-led-manager|random-mac"
ls /usr/local/bin/  | grep -E "fanctl|boot-version-guard"
```

---

## 四、快速上手

### 三种打开方式

| 方式 | 操作 |
|---|---|
| 桌面图标 | fnOS 桌面点击 `wocyber_S2` 图标 |
| 应用中心 | 应用中心 → 已安装 → wocyber_S2 → 打开 |
| 浏览器直连 | 地址栏输入 `http://设备IP:18899`（端口以安装时设定为准） |

### 界面布局

12 栅格自适应布局，共 **8 张功能卡片**（手机竖屏下单列显示，操作元素已做触控优化）：

| 卡片 | 栅格 | 用途 |
|:--|:-:|---|
| 运行总览 | 12 | CPU / 硬盘温度、风扇挡位仪表，温度趋势曲线，服务状态矩阵 |
| 电源灯 | 4 | 网络链路状态显示，灯光覆盖（自动 / 全灭） |
| 硬盘灯 | 4 | 硬盘灯状态显示，灯光覆盖（自动 / 全灭） |
| 蜂鸣器 | 4 | 鸣叫时长调节、一键试听、保存默认值 |
| 风扇控制 | 8 | 自动 / 手动切换、挡位滑块、8 个温控点微调、可视化扇叶 |
| 定时开关机 | 4 | 启用开关、每日关机时间、每日开机时间 |
| 访问端口 | 4 | 查看与修改 Web 控制台端口 |
| 脚本修复窗口 | 8 | 拖入 `.sh` 执行并实时查看日志 |

### 顶栏状态徽章

从左到右依次为：**运行身份徽章**（`root 直控` 可直接写硬件；`应用用户（需代理）` 时为只读浏览）→ **设备名**（默认 `fnOS-S2`）→ **访问端口** → **实时时钟**。

---

## 五、功能速查

### 运行总览

三枚环形仪表（带刻度环与温度分级变色）+ 温度趋势曲线 + 服务状态矩阵（每 10 秒自动刷新）：

| 仪表 | 单位 | 数据来源 |
|---|:-:|---|
| CPU 温度 | ℃ | 风扇守护进程实时写入，3 秒刷新 |
| 硬盘温度 | ° | 取所有硬盘的最高温度 |
| 风扇挡位 | 挡 | 当前实际挡位 0-15 |

<details>
<summary><b>服务状态矩阵：9 个核心服务</b></summary>

| 服务 | 作用 |
|---|---|
| `fan-control` | 风扇自动温控 / 手动挡位守护 |
| `sata-led-manager` | 硬盘灯策略守护 |
| `power-led-net` | 电源灯网络状态指示守护 |
| `power-key-daemon` | 电源键长按关机 + 蜂鸣守护 |
| `random-mac` | 随机 MAC 生成与持久化 |
| `set-hostname` | 设备名写入（`fnOS-S2`） |
| `selfheal` | 每小时自检并修复被还原的文件与 DTB |
| `boot-version-guard` | 开机一次性守卫，版本变化后重装硬件配置 |
| `s2-power-schedule` | 定时开关机（默认关闭） |

绿色 = 正常，红色 = 异常。
`boot-version-guard` 是开机才运行的一次性服务，正常显示绿色「已执行」而非「运行中」，属正常现象。

</details>

### 电源灯 / 硬盘灯

| 灯 | 默认行为 | 灯效 |
|---|---|---|
| 电源灯 | 按网络链路（只看 carrier，与实际能否上网无关） | 链路通 → 绿灯常亮；未插 / 断开 → 红灯闪烁（0.5s 亮灭） |
| 硬盘灯 | 按有无硬盘 | 有盘 → 绿灯常亮；无盘 → 红绿全灭 |

**灯光覆盖（优先级最高）**：下拉框可选「自动」或「全灭」，点 **应用** 即刻生效。
配置写入 `/etc/s2hwctl/led-override.conf`，守护进程每个节拍都会重读，**系统升级、自愈重装、设备重启都不会改变你的选择**。

### 蜂鸣器

| 控件 | 说明 |
|---|---|
| 鸣叫时长滑块 | 30 - 3000 毫秒可调，页面同步显示当前毫秒数 |
| 试听按钮 | 用当前时长立即鸣叫一次 |
| 保存按钮 | 写入 `/etc/s2hwctl/beep.conf`，成为开机默认 |

> [!NOTE]
> 蜂鸣通过 `/sys/devices/platform/gpio_ctrl/buzzer_gpio` 驱动，缺失时回退到 GPIO18。
> `beep.conf` 是 **JSON** 格式（如 `{"beep_ms": 280, "boot_beep": true}`），与其他 `KEY=VALUE` 配置不同，手工编辑时请勿混写格式。

### 风扇控制

| 模式 | 行为 |
|---|---|
| 自动（auto） | 按 CPU 与硬盘两条温控曲线分别算出挡位，取较高者执行 |
| 手动（manual） | 锁定在指定挡位，0-15 挡（切换时立即生效） |

- **挡位滑块**：拖动即实时生效（150ms 防抖自动下发），无需点按钮；内置 5 秒保护窗口，避免后台轮询把滑块拽回原值。
- **温控曲线微调**：CPU 四挡（停转以下 / 低速 / 中速 / 临界）、硬盘四挡（停转以下 / 低速 / 中速 / 全速）。
  「应用并保存」写入 `/etc/fan-control.conf` 永久生效；「仅本次生效」重启后回落。
- 卡片带可视化扇叶按实际挡位旋转，可直观确认是否生效。

### 定时开关机

| 控件 | 说明 |
|---|---|
| 启用开关 | 默认 **关闭**，按需开启 |
| 每日关机时间 | 24 小时制 `HH:MM`，例如 `03:00` |
| 每日开机时间 | 24 小时制 `HH:MM`，例如 `08:00` |
| 应用按钮 | 保存并立即应用（写 systemd timer + RTC 唤醒） |

实现：定时关机走 systemd timer（`s2-power-shutdown.timer`）执行 `poweroff`；定时开机写入 RTC 唤醒闹钟（`/sys/class/rtc/rtc*/wakealarm`）。

> [!WARNING]
> **定时开机依赖主板 RTC 保持供电**：设备需**一直插着电源**（关机但不彻底断电）才可靠；
> 彻底断电导致 RTC 复位，定时开机会失效。若设备不支持 RTC 唤醒，应用时页面会明确提示，此时定时关机仍可正常工作。

### 访问端口

显示并可修改当前 Web 控制台端口，修改后应用自动重启并以新端口提供服务，**保存后请用新端口重新打开页面**。

端口三级优先级：应用设置 `settings.conf` → `TRIM_SERVICE_PORT` → 默认 `18899`。

### 脚本修复窗口

应急排障工具：把本地 `.sh` 脚本**拖入虚线区域**（或点击选择文件），脚本自动上传并立即执行，日志实时滚动输出。

| 内置一键脚本 | 用途 |
|---|---|
| 部署全部硬件配置 | 一键重跑 `deploy.sh`，重装全部硬件脚本与服务 |
| 重装定制功能 | 重新安装硬件定制组件 |
| 恢复定制 DTB | 从备份恢复设备树文件 |
| 重启硬件服务 | 重启全部 hardware 相关 systemd 服务 |
| 自检并修复 | 执行一次 selfheal 自检 |
| 收集诊断信息 | 打包输出系统诊断数据 |

> [!CAUTION]
> 该窗口以 **root 身份执行任意脚本**，请只运行你信任的内容。

---

## 六、SSH 命令行速查

不打开 Web 界面时，所有功能均可通过 SSH 完成。

```bash
# ── 灯光 ──────────────────────────────────────────
# 强制全灭（最高优先级）
printf 'POWER_LED=off\nSATA_LED=off\n' > /etc/s2hwctl/led-override.conf
systemctl restart power-led-net sata-led-manager

# 恢复自动
printf 'POWER_LED=auto\nSATA_LED=auto\n' > /etc/s2hwctl/led-override.conf
systemctl restart power-led-net sata-led-manager

# ── 风扇 ──────────────────────────────────────────
fanctl status          # 查看模式、挡位、CPU 与硬盘温度
fanctl manual 8        # 切到手动并设为 8 挡（0-15），立即生效
fanctl auto            # 切回自动温控

# 永久生效：改配置后重启服务
sed -i 's/^MODE=.*/MODE=manual/; s/^MANUAL_LEVEL=.*/MANUAL_LEVEL=8/' /etc/fan-control.conf
systemctl restart fan-control

# ── 蜂鸣器 ────────────────────────────────────────
echo '{"beep_ms": 280, "boot_beep": true}' > /etc/s2hwctl/beep.conf
/usr/local/sbin/beep-short.sh    # 立即试听（固定 0.28 秒）

# ── 定时开关机 ────────────────────────────────────
# 编辑 /etc/s2-power-schedule.conf 写入 ENABLE / SHUTDOWN_TIME / BOOT_TIME，然后：
/usr/local/sbin/s2-power-schedule.sh apply

# ── 状态总览 ──────────────────────────────────────
systemctl is-active power-led-net sata-led-manager fan-control s2-power-schedule
cat /var/lib/fan-control/status          # CPU / 硬盘温度与挡位快照
journalctl -u power-led-net -n 20        # 查看任意服务日志
```

> 守护进程每节拍重读灯光覆盖文件，不重启也会在数秒内生效。

---

## 七、配置文件与优先级

| 功能 | 配置文件 | 格式 | 重启命令 |
|---|---|:-:|---|
| 灯光手动覆盖 | `/etc/s2hwctl/led-override.conf` | KEY=VALUE | `systemctl restart power-led-net sata-led-manager` |
| 电源灯节奏 | `/etc/power-led-net.conf` | KEY=VALUE | `systemctl restart power-led-net` |
| 硬盘灯规则 | `/etc/sata-led.conf` | KEY=VALUE | `systemctl restart sata-led-manager` |
| 风扇模式与曲线 | `/etc/fan-control.conf` | KEY=VALUE | `systemctl restart fan-control` |
| 蜂鸣器 | `/etc/s2hwctl/beep.conf` | JSON | 无需重启，下次调用生效 |
| 定时开关机 | `/etc/s2-power-schedule.conf` | KEY=VALUE | `s2-power-schedule.sh apply` |
| 应用端口 | 应用配置目录 `settings.conf` | KEY=VALUE | 自动重启应用 |

### 灯光优先级（从高到低）

1. **手动覆盖** —— `/etc/s2hwctl/led-override.conf` 中 `POWER_LED=off` / `SATA_LED=off`，压过一切自动逻辑；固件守护每节拍重读，**系统升级、selfheal 重装、重启均不会推翻**。
2. **自动规则** —— 电源灯按网络链路，硬盘灯按有无硬盘。
3. **系统默认** —— 未被上述接管时的原始行为。

> [!CAUTION]
> **切勿修改 `/etc/s2hwctl` 目录名。** 固件中的 `power-led-net.sh` 与 `sata-led-manager.sh` 硬编码读取该目录，改名会导致灯光覆盖与蜂鸣配置立即失效。

### 默认参数速查

| 配置项 | 默认值 | 来源文件 |
|---|---|---|
| 风扇模式 / 手动挡位 | `auto` / `6` | `/etc/fan-control.conf` |
| CPU 温度四挡 | 60 / 65 / 80 / 100 ℃ | `/etc/fan-control.conf` |
| 硬盘温度四挡 | 40 / 45 / 55 / 60 ℃ | `/etc/fan-control.conf` |
| 采样间隔 | 3 秒 | `/etc/fan-control.conf` |
| 蜂鸣时长 | 280 ms | `/etc/s2hwctl/beep.conf` |
| 电源灯检测节拍 | `TICK=0.25` 秒 | `/etc/power-led-net.conf` |
| 硬盘灯检测节拍 | `TICK=1` 秒 | `/etc/sata-led.conf` |
| 硬盘灯有盘表现 | `PRESENT_GREEN=1`（绿灯常亮） | `/etc/sata-led.conf` |
| 默认 Web 端口 | `18899` | manifest `service_port` |

---

## 八、系统升级与自愈机制

飞牛官方升级会覆盖系统分区，可能把硬件脚本还原。固件内置两套自动保护：

| 机制 | 触发时机 | 作用 |
|---|---|---|
| `boot-version-guard` | 每次开机（oneshot） | 比对 fnOS 与内核版本，发现变化则自动重装硬件配置并重启 |
| `selfheal-check` | 每小时定时自检 | 比对关键文件与 DTB，缺失则从 `/usr/local/share/install-1014` 备份目录原样恢复 |

手动触发修复：

```bash
bash /usr/local/share/install-1014/install_all.sh   # 一键重装全部硬件配置
/usr/local/sbin/selfheal-check.sh                   # 自检并修复
```

> [!TIP]
> 日常使用中只需正常进行飞牛系统升级，补丁会在开机时自动恢复，**无需人工干预**。

---

## 九、卸载

**应用中心 → 已安装 → wocyber_S2 → 卸载。**

卸载会移除应用自身文件与桌面图标，并自动移除随应用安装的开机灯光服务；**已部署到系统的硬件脚本与行为会完整保留** —— 灯效、风扇、蜂鸣器、电源键等继续按原规则工作。

<details>
<summary><b>如需彻底清除硬件行为（一般不建议）</b></summary>

```bash
systemctl disable --now power-led-net sata-led-manager fan-control power-key-daemon \
  random-mac set-hostname selfheal boot-version-guard s2-power-schedule
```

</details>

**重装 / 覆盖安装**：同版本可直接覆盖；跨版本建议「先卸载旧版 → 再安装新版」，避免旧配置残留。

---

## 十、常见问题

<details>
<summary><b>提示第三方应用无法安装</b></summary>

需在「应用中心 → 设置 → 手动安装应用」路径安装，第三方 root 应用不走应用商店。

</details>

<details>
<summary><b>提示端口 18899 被占用</b></summary>

安装向导第一步改为其他空闲端口；或在页面「访问端口」卡片中修改。

</details>

<details>
<summary><b>安装后桌面没有图标</b></summary>

检查是否刷新桌面；或直接在浏览器输入 `http://设备IP:端口` 访问。

</details>

<details>
<summary><b>旧版 s2hwctl 与新包共存</b></summary>

包名不同会被视为两个应用，请卸载旧版 `s2hwctl` 后再装 `wocyber_S2`。

</details>

<details>
<summary><b>打开页面是空白 / 加载不出</b></summary>

检查应用是否在运行（`systemctl status` 对应服务）；确认端口未被防火墙拦截。

</details>

<details>
<summary><b>页面能看但不能改</b></summary>

顶栏徽章显示「应用用户（需代理）」，说明未以 root 运行。该包已声明 `run-as root`，请确认安装方式正确。

</details>

<details>
<summary><b>硬盘温度显示异常或不显示</b></summary>

v1.3.1 已修复（原先把每盘温度快照字符串误当盘数渲染）。若仍异常，执行 `systemctl restart fan-control`。

</details>

<details>
<summary><b>风扇拖动滑块有延迟、会弹回</b></summary>

v1.2.1 已修复（150ms 防抖 + 5 秒防轮询回写）。若使用更旧版本请升级。

</details>

<details>
<summary><b>电源灯不按网络状态变化 / 设了全灭升级后又亮了</b></summary>

确认 `/etc/s2hwctl/led-override.conf` 中的取值与路径（必须是 `/etc/s2hwctl/` 下的该文件），并检查 `power-led-net` 是否 active。

</details>

<details>
<summary><b>定时开机不生效</b></summary>

多为 RTC 供电问题：设备需保持插电（关机但未彻底断电），彻底断电会让 RTC 复位。
可用 `cat /sys/class/rtc/rtc*/wakealarm` 确认闹钟是否写入。

</details>

<details>
<summary><b>boot-version-guard 显示红色</b></summary>

v1.3.3 已修复（路径不一致导致 203/EXEC）。若仍红：

```bash
systemctl show -p Type,Result,ExecMainStatus boot-version-guard
journalctl -u boot-version-guard -n 50
# 若日志出现 Failed to locate executable：
cp /usr/local/sbin/boot-version-guard.sh /usr/local/bin/boot-version-guard.sh
chmod 755 /usr/local/bin/boot-version-guard.sh
systemctl reset-failed boot-version-guard
```

该服务为开机一次性服务，修复后下次开机显示绿色「已执行」，不影响当前任何硬件功能。

</details>

<details>
<summary><b>忘了控制台端口</b></summary>

默认 `18899`；可在应用设置中查看，或 SSH 后查看应用配置目录下的 `settings.conf`。

</details>

<details>
<summary><b>MAC 地址运行中变化</b></summary>

v1.3.3 已修复为「首次生成一次 + 按硬件标识持久化」。若仍变化，执行 `systemctl restart random-mac`。

</details>

---

## 附录：版本演进

| 版本 | 主要变化 |
|---|---|
| v1.1.0 | 内嵌全部硬件定制脚本，实现「安装即部署」 |
| v1.1.3 | 新增定时开关机（systemd timer + RTC 唤醒） |
| v1.1.4 | 电源灯改为网络状态指示（有链路绿灯常亮 / 无链路红灯闪） |
| v1.1.5 | 新增灯光手动覆盖，优先级高于一切自动逻辑 |
| v1.1.6 | 界面重排为 12 栅格科技风控制台 |
| v1.1.7 | 界面质感升级：玻璃拟态、环形仪表、温度趋势、粒子背景 |
| v1.1.8 | 开发者署名改为 Ben，替换应用图标 |
| v1.1.9 | 显示名改为 wocyber_S2，图标改为原样缩放 |
| v1.2.0 | 修复图标未生效的根因，重写应用介绍文案 |
| v1.2.1 | 顶栏标题改 wocyber_S2；仪表可读性提升；风扇拖动即时生效 |
| v1.2.2 | 按用户标注精简应用介绍中的技术细节 |
| v1.3.0 | 应用账号与包名统一改为 wocyber_S2 |
| v1.3.1 | 修复硬盘温度显示（去掉盘号、单位改 °）；修正盘数解析导致的误判无盘 |
| v1.3.2 | 修正 boot-version-guard 中残留的开发机路径 `/home/anna/install-1014` |
| v1.3.3 | 修复 boot-version-guard 报 203/EXEC：deploy.sh 安装路径统一为 `/usr/local/bin` |

---

<div align="center">

仓库：<https://github.com/zm51432/Wocyber_S2> · 开发者：Ben

</div>
