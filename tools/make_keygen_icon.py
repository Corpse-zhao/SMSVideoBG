#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「激活码签发」App 图标 (1024x1024 PNG, 纯本地绘制, 不依赖外部素材)

风格与控制 App 一致: 粉(#FA457F) -> 紫(#A052FA) 对角渐变 + 白色钥匙。
用法: python make_keygen_icon.py 输出路径.png
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024          # 输出尺寸
SS = 4            # 超采样倍率 (抗锯齿)
W = S * SS
C1 = (250, 69, 127)     # 粉
C2 = (160, 82, 250)     # 紫


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient(size, c1, c2):
    """对角线性渐变 (左上 -> 右下)"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2.0 * (size - 1))
            px[x, y] = lerp(c1, c2, t)
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Icon.png"

    base = gradient(S, C1, C2).convert("RGBA")

    # 左上柔光, 让平面渐变有层次
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse([-S * 0.35, -S * 0.55, S * 0.85, S * 0.45], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.18))
    base = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), base, glow)

    # 白色钥匙 (超采样绘制后缩放)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    u = SS
    white = (255, 255, 255, 255)

    ring_c = (395 * u, 512 * u)          # 钥匙柄圆心
    R, r = 185 * u, 100 * u
    d.ellipse([ring_c[0] - R, ring_c[1] - R, ring_c[0] + R, ring_c[1] + R], fill=white)
    d.ellipse([ring_c[0] - r, ring_c[1] - r, ring_c[0] + r, ring_c[1] + r], fill=(0, 0, 0, 0))

    def rrect(x0, y0, x1, y1, rad):
        d.rounded_rectangle([x0 * u, y0 * u, x1 * u, y1 * u], radius=rad * u, fill=white)

    rrect(500, 462, 806, 562, 50)        # 钥匙杆
    rrect(660, 540, 716, 660, 22)        # 齿 1
    rrect(752, 540, 806, 618, 22)        # 齿 2

    layer = layer.resize((S, S), Image.LANCZOS)
    base = Image.alpha_composite(base, layer)
    base.convert("RGB").save(out, "PNG", optimize=True)
    print("icon written:", out, base.size)


if __name__ == "__main__":
    main()
