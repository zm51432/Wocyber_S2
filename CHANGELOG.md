# wocyber_S2 改动记录

- **当前版本**：`wocyber_S2.fpk` v1.3.13
- **相对版本**：上一版 v1.3.12
- **改动文件**：`manifest`（`version`、`changelog`）、新增 `firmware/s2-autoupdate.sh`、`firmware/s2-autoupdate.service`、`firmware/s2-autoupdate.timer`（及 `install-1014/` 同步副本）、`firmware/install_all.sh`（及 `install-1014/` 副本）、`server/server.py`、`server/public/index.html`、`server/public/app.js`、`server/public/style.css`

## v1.3.13 改动明细（本次）

### ① GitHub 自动更新（fpk 自升级）
- 新增 `s2-autoupdate.sh`（安装到 `/usr/local/sbin`）：检测本项目 GitHub 最新 Release；若版本高于本机，自动下载 `wocyber_S2.fpk` → 校验（gzip/tar 合法 + manifest 版本确实更新）→ 整包备份（`var/backup_*`，保留 3 份）→ 覆盖 `/var/apps/wocyber_S2` → 重跑 `install_all.sh` 全量部署 → 自动重启控制台。
- 子命令：`status`（读缓存不联网）/ `check`（仅检测）/ `run`（自动升级，`--force` 强制忽略开关）；日志 `var/autoupdate.log`。
- 新增 `s2-autoupdate.timer`：每天 04:30（±30 分钟随机延迟）跑一次 `run`，开机 10 分钟后首查。
- 总开关：`etc/settings.conf` 中 `AUTO_UPDATE=true`（默认）；设为 `false` 则只提醒不升级，「立即升级」按钮可强制。

### ② 控制台「版本与更新」卡片（UI）
- 显示当前版本 / 最新版本；页面打开自动静默检测一次；可点「检查更新」；有更新时「立即升级」按钮可用，点击后全自动升级并自动重启控制台。
- `server.py` 新增 `/api/autoupdate` 端点（`status` / `check` / `upgrade` 三个动作，升级在独立会话后台执行）。

### ③ 既有安装直接升级（修复脚本）
- 对已装 v1.3.12 的设备，可拖入控制台「脚本修复」窗口执行 `deploy-autoupdate.sh`（随 Release 一并发布）：自动下载 v1.3.13 fpk → 备份 → 覆盖 → 全量部署（含 s2-autoupdate 定时器）→ 重启控制台，无需 SSH、无需卸载重装。

## v1.3.12 累计改动（v1.3.6 – v1.3.12）

### ① 自愈（selfheal）全量修复 + 5 分钟自检
- 采用设备正版 `install_all.sh` 全量修复版 `selfheal-check.sh`：检测运行中 DTB 与定制版 DTB 的 MD5 不一致，或关键脚本/服务缺失时，自动重跑 `install_all.sh` 并重启生效。
- `selfheal-hourly.timer` 自检间隔由 1 小时改为 **开机 5 分钟后首跑、之后每 5 分钟一次**（`OnBootSec=5min` / `OnUnitActiveSec=5min`），飞牛 apt 升级覆盖官方 DTB 后能快速自愈。
- 安装/升级回调（`install_callback` / `upgrade_callback`）先刷新 `/home/anna/install-1014`（正版源），再以非交互方式 `bash install_all.sh` 全量部署，确保装 fpk / 飞牛升级后所有现有功能自动恢复，并内置禁用与现用固件冲突的自动化服务（`pwm-fancontrol`、`HDled_monit_v0`、`power-led-solid` 等）。

### ② 风扇新增「手动控温」模式（UI 三模式）
- 模式下拉新增 `auto` / `manual_temp` / `manual` 三选项：仅「手动挡位（manual）」模式下挡位滑块可拖，其余两种模式滑块锁定。
- 自动温控固定阈值：CPU `50/60/70/80℃` 对应 `0/5/10/15` 档（4 段线性），硬盘 `40/50/55/60℃`；手动可调模式放开曲线参数。

### ③ 电源灯 / 硬盘灯手动覆盖（LED override）
- `power-led-net.sh`、`sata-led-manager.sh` 新增 `/etc/s2hwctl/led-override.conf` 读取：`POWER_LED=off` / `SATA_LED=off` 时对应 LED 红绿全灭，且每检测节拍重读，固件升级 / selfheal 重装 / 服务重启均无法改变用户选择；默认 `auto` 完全走原自动逻辑，向后兼容。

### ④ 自动温控界面不再显示数值（UI 微调）
- 选择「自动温控」时，原固定曲线数值块（CPU `50~60℃→5档` 等）改为纯文字说明「系统依据 CPU 与硬盘温度自动调速，无需手动设置」；同时隐藏右侧挡位「X/15」数值，改显示「自动」字样。其余模式（手动控温 / 手动挡位）仍正常显示数值与可调曲线。

## v1.3.5 改动明细（上版）

### 7. 风扇温控逻辑反转 + 固定阈值（`index.html` / `app.js` / `style.css`）
- **自动温控模式（锁定）**：采用固定阈值，**不再显示调节窗口**。阈值固定为 CPU `50 / 60 / 70 / 80 ℃`、硬盘 `40 / 50 / 55 / 60 ℃`。
  - 控制台上改为显示「THERMAL CURVE · 温控曲线（自动锁定）」说明块，仅展示固定阈值、不可编辑。
  - 应用保存时强制写入上述固定值（即便配置文件里是旧值也会被覆盖）。
- **手动调节模式（开放）**：显示可编辑的「THERMAL CURVE · 温控曲线（手动可调）」窗口，8 个参数输入框放开，用户可自行调整（上限仍为 100）。
- **联动逻辑**：`applyFanMode()` 反转——自动时显示锁定说明、隐藏曲线窗口；手动时隐藏锁定说明、显示曲线窗口。自动固定值写入隐藏输入框，避免被配置回写覆盖。

## v1.3.4 改动明细（上版）

### 6. 风扇控制面板改版（`index.html` / `app.js` / `style.css`）
- **自动温控模式**：切换后下方「THERMAL CURVE · 温控曲线」参数设置**自动展开显示**（新增 `applyFanMode()` 联动）。
- **手动挡位模式**：**隐藏 CPU / 硬盘参数调节**，仅保留挡位滑块（0–15）。
- **参数上限**：温控曲线 8 个输入框（硬盘 `f-h0~f-h3`、CPU `f-c0~f-c3`）统一加 `min="0" max="100"`，超出 100 无法输入。

## 历史改动（v1.3.3 及之前）

### 1. 开发者 / 发布者主页链接（`manifest`）
| 字段 | 旧值 | 新值 |
|---|---|---|
| `maintainer_url` | `https://github.com/s2nos` | `https://github.com/zm51432/Wocyber_S2` |
| `distributor_url` | `https://github.com/s2nos` | `https://github.com/zm51432/Wocyber_S2` |

### 2. Web 控制台界面显示文本修复（`app.js`）
- 去除状态文本中误带的开发残留 `// ` 注释符（共 7 处：电源灯手动覆盖、网络状态灯未部署、链路已连接、无网络链路、硬盘灯手动覆盖、硬盘灯自动、无硬盘）。
- 硬盘灯「自动」模式文案：旧 `检测到 N 块硬盘 → 绿灯常亮` → 新 `检测到硬盘 → 绿灯常亮`。

### 3–5. 运行总览改版（`index.html` / `style.css`）
- 三环独立仪表 → 同心环嵌套仪表盘（饼图）。
- THERMAL TREND 移至饼图下方，并与 SERVICE MATRIX 合并为同一区块。
- 最终布局：左 2/3 饼图 + 趋势同框，右 1/3 SERVICE MATRIX 竖排。

## 说明
飞牛应用商店依据 `manifest` 的 `version` 字段判断升级。本版已升到 `1.3.5`，应用商店会向 v1.3.4 用户提示升级。
