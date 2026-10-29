# wocyber_S2 改动记录

- **当前版本**：`wocyber_S2.fpk` v1.3.4
- **相对版本**：Ben 分支上一版 v1.3.3
- **改动文件**：`manifest`（`version`、`changelog`、`maintainer_url`、`distributor_url`）、`server/public/index.html`、`server/public/app.js`、`server/public/style.css`

## v1.3.4 改动明细（本次）

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
飞牛应用商店依据 `manifest` 的 `version` 字段判断升级。本版已升到 `1.3.4`，应用商店会向 v1.3.3 用户提示升级。
