#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 S2 硬件控制台图标。

直接使用用户提供的设计稿 (tools/icon_source.png)，原样缩放输出，不做任何背景处理，
确保应用里显示的图标 == 用户上传的图片：
  · 根目录 ICON_256.PNG (256×256) 与 ICON.PNG (64×64)   —— fnpack 打包用
  · app/ui/images/icon-256.png 与 icon-64.png           —— 桌面/应用中心用
"""
import os
from PIL import Image

OUT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(OUT, "tools", "icon_source.png")
UI = os.path.join(OUT, "app", "ui", "images")


def main():
    os.makedirs(UI, exist_ok=True)
    src = Image.open(SRC).convert("RGBA")   # 保留原始颜色与（若有）透明通道，不抠底
    big = src.resize((256, 256), Image.LANCZOS)
    small = src.resize((64, 64), Image.LANCZOS)
    big.save(os.path.join(OUT, "ICON_256.PNG"))
    small.save(os.path.join(OUT, "ICON.PNG"))
    big.save(os.path.join(UI, "icon-256.png"))
    small.save(os.path.join(UI, "icon-64.png"))
    print("icon ok ->", OUT)


if __name__ == "__main__":
    main()
