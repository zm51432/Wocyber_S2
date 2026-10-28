<div align="center">

# Wocyber_S2

**飞牛适配 S2 镜像补丁 · 智小惠 S2 刷入 fnOS 操作指南**

[![平台](https://img.shields.io/badge/Platform-RK3568-orange?style=flat-square)](https://github.com/)
[![系统](https://img.shields.io/badge/OS-fnOS-blue?style=flat-square)](https://help.fnnas.com/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](https://opensource.org/licenses/MIT)
[![文档](https://img.shields.io/badge/docs-中文-brightgreen?style=flat-square)](#)

</div>

---

## 📖 目录

- [一、准备工作](#一准备工作)
- [二、驱动安装](#二驱动安装)
- [三、刷机](#三刷机)
  - [Loader 模式烧录（默认）](#loader-模式烧录默认)
  - [MASKROM 模式烧录（需拆机）](#maskrom-模式烧录需拆机)
- [四、安装补丁](#四安装补丁)
- [五、常见问题 FAQ](#五常见问题-faq)
- [附录：拆机说明](#附录拆机说明)

---

## 一、准备工作

准备一台 **Windows 主机**，并下载 / 准备好以下软件与工具：

| # | 名称 | 说明 | 预览 |
|:-:|------|------|:----:|
| 1 | DriverAssitant_v5.1.1 | 瑞芯微 RK 驱动程序包 | <img width="159" height="32" alt="DriverAssitant" src="https://github.com/user-attachments/assets/4e299719-28ae-4881-9e83-dbf486564b3c" /> |
| 2 | 刷机工具包 | 含 RKDevTool 等 | <img width="408" height="53" alt="刷机工具包" src="https://github.com/user-attachments/assets/f3a4a98b-7124-40df-b505-55699db6aa49" /> |
| 3 | 顶针 | 用于按压 Reset 孔 | <img width="85" height="38" alt="顶针" src="https://github.com/user-attachments/assets/4eb4e314-3158-4d0d-be5d-36404649c80b" /> |
| 4 | 刷机包 | 系统镜像文件 | <img width="416" height="40" alt="刷机包" src="https://github.com/user-attachments/assets/976fbeec-c126-42c2-a6dc-bd3519b3db9a" /> |
| 5 | USB A to A 数据线 | 双公头刷机线 | <img width="155" height="140" alt="USB A to A 数据线" src="https://github.com/user-attachments/assets/4c9977c4-9c37-4ba1-817f-936b6b8e2c78" /> |
| 6 | MobaXterm_Personal | SSH 终端工具 | <img width="211" height="35" alt="MobaXterm" src="https://github.com/user-attachments/assets/cfcf0727-6bd6-4f81-bf8e-25d7d001a87b" /> |

> [!IMPORTANT]
> **所有压缩包都需要解压后再使用。**

---

## 二、驱动安装

1. 打开 `DriverAssitant` 文件夹，运行 **DriverInstall.exe**。

   <img width="396" height="200" alt="DriverInstall" src="https://github.com/user-attachments/assets/e7c8a553-8d27-4640-95eb-1c5d93b99927" />

2. 先点击 **【驱动卸载】** 删除旧驱动，处理完成后，再点击 **【驱动安装】**。

   <img width="396" height="200" alt="驱动安装" src="https://github.com/user-attachments/assets/a610e8d3-4e74-4355-a4fd-174d392c02ec" />

---

## 三、刷机

> [!WARNING]
> **刷机全程禁止断电、拔 USB 线，断连可能导致设备变砖！**

### Loader 模式烧录（默认）

1. 运行 **RKDevTool.exe**。
2. **不接电源**，USB 数据线一端先接电脑 USB 口 → 用顶针插入设备后面板的 **Reset 孔**并按压住内部按钮 → 再将 USB 线另一端插入设备的 USB 口。观察 RKDevTool 界面底部，出现提示 **「发现一个 LOADER 设备」** 后，即可松开并取出顶针。
3. 在 **「下载镜像」** 菜单页：
   - 去掉第一行 <kbd>Boot</kbd> 的勾选，**只勾选第二行 <kbd>system</kbd>**；
   - 选择 `update_0822.img` 文件的路径（需先解压 `update_0822.img.zip`）；
   - 勾选 **「强制按地址写」**；
   - 点击 **「执行」**。
4. 等待烧录下载完成，**设备会自动重启**。

**步骤 2、3 图例：**

<img width="555" height="264" alt="Loader 模式烧录步骤" src="https://github.com/user-attachments/assets/e5512658-bc1c-4d93-b683-729f22fa1ffa" />

**成功烧录图例：**

<img width="555" height="264" alt="烧录成功" src="https://github.com/user-attachments/assets/f021343c-546a-49c2-aedc-a55515b7b250" />

### MASKROM 模式烧录（需拆机）

> Loader 模式进不去时，才使用此方法。该方法需要拆机，拆机方法参考 [附录](#附录拆机说明)。

1. 设备拆机后，在板子上找到 **Uboot 按键**位置（若没有按键，可用镊子或导电线短接）。
2. 先按下按键或短接两点，再接入 USB 数据线。待 RKDevTool 界面底部出现 **「发现一个 MASKROM 设备」** 提示后，松开按键或短接工具。
3. 在 RKDevTool 的 **「下载镜像」** 页面：
   - **同时勾选 <kbd>Boot</kbd> 和 <kbd>system</kbd>**；
   - 选择对应文件（Boot 文件位于 `RKDevTool` 文件夹的 `RK3568` 文件夹内）；
   - 勾选 **「强制按地址写」**；
   - 点击 **「执行」**，直到右侧提示下载完成。

**拆机后 Uboot 位置图例：**

<img width="244" height="325" alt="Uboot 位置 1" src="https://github.com/user-attachments/assets/4e7cf57d-ea3e-4e6b-9607-987f98fb051a" />
<img width="243" height="324" alt="Uboot 位置 2" src="https://github.com/user-attachments/assets/8106388c-cdb0-45e4-b73b-a238efef4e98" />

**步骤 3 图例：**

<img width="584" height="278" alt="MASKROM 烧录步骤" src="https://github.com/user-attachments/assets/981f8944-20f9-425d-b797-286cc988816c" />

**烧录成功图例：**

<img width="583" height="278" alt="烧录成功" src="https://github.com/user-attachments/assets/a1bccdbf-bef6-4291-8fb6-99c80c4668ba" />

> [!TIP]
> 至此，**fnOS 刷机完毕** 🎉

---



7. 操作完成后，日后正常进行飞牛系统升级即可。

---

## 五、常见问题 FAQ

<details>
<summary><b>烧录时，是否需要接入电源？</b></summary>

不需要。

</details>

<details>
<summary><b>烧录能否使用普通 Type-C 线？</b></summary>

不能，因为兼容性不统一。请使用 USB A to A（双公头）数据线。

</details>

<details>
<summary><b>烧录有哪些注意事项？</b></summary>

确定设备连接完整，烧录过程中**严禁触碰烧录连接与烧录线**。

</details>

<details>
<summary><b>烧录过程失败，该如何操作？</b></summary>

如遇烧录失败，可按照步骤重新烧录；如果仍然发现不了设备，就需要拆机烧录（MASKROM 模式）。

</details>

<details>
<summary><b>飞牛 App 如何下载？</b></summary>

手机应用商店搜索「飞牛」下载安装。

</details>

<details>
<summary><b>飞牛该如何使用？</b></summary>

可在官网 <https://help.fnnas.com/> 寻找相关使用方法。

</details>

<details>
<summary><b>飞牛升级需要多久？</b></summary>

因网络环境不同而异。参考数值：百兆网络环境下，升级约耗时 **20 分钟**。

</details>

---

## 附录：拆机说明

> 拆机前请先断电，注意保存好螺丝与卡扣，避免损坏外壳卡扣。具体操作以实物为准。

<!-- 待补充：拆机步骤图文 -->

---

<div align="center">

如果本项目对你有帮助，欢迎点个 ⭐ Star 支持一下~

</div>
