#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SMSVideoBG 激活码签发 / 校验工具 (v1.9.0)

算法与插件端 SVBLicense.m 完全一致:
    payload(10B) = 设备码原始5B | 到期天数(uint32 BE) | 格式版本(0x01)
    签名         = HMAC-SHA256(secret, payload) 前 5 字节
    激活码       = Base32(payload + 签名)  -> 24 字符, 显示为 6 组 4 字符
    Base32 字母表 = ABCDEFGHJKLMNPQRSTUVWXYZ23456789 (去 I O 0 1)
    到期天数     = 自 2020-01-01 UTC 起的天数, 0xFFFFFFFF = 永久

密钥来源 (必须与编译时注入的 SVB_LICENSE_SECRET 一致):
    Windows:  set SVB_LICENSE_SECRET=你的密钥
    macOS/Linux: export SVB_LICENSE_SECRET='你的密钥'
    或命令行 --secret 你的密钥

用法:
    python license_gen.py --device ABCD-EFGH --days 365
    python license_gen.py --device ABCD-EFGH --forever
    python license_gen.py --device ABCD-EFGH --days 30 --note 张三
    python license_gen.py --universal --days 7      # 不绑设备的通用码 (慎用)
    python license_gen.py --verify XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
    python license_gen.py --selftest                # 自检: 随机签发+本地验签
"""
import argparse
import hashlib
import hmac
import os
import random
import sys
import time
from datetime import datetime, timezone

B32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
EPOCH = 1577836800          # 2020-01-01 00:00:00 UTC
NO_EXPIRE = 0xFFFFFFFF
FORMAT_VER = 0x01
FALLBACK_SECRET = "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"


# ---------------------------------------------------------------- Base32
def b32_encode(data: bytes) -> str:
    out = []
    buf = 0
    bits = 0
    for b in data:
        buf = ((buf << 8) | b) & 0x1FFFF
        bits += 8
        while bits >= 5:
            bits -= 5
            out.append(B32[(buf >> bits) & 0x1F])
    if bits:
        out.append(B32[(buf << (5 - bits)) & 0x1F])
    return "".join(out)


def b32_decode(s: str) -> bytes:
    s = "".join(ch for ch in s.upper() if ch in B32)
    out = bytearray()
    buf = 0
    bits = 0
    for ch in s:
        buf = ((buf << 5) | B32.index(ch)) & 0x3FFF
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((buf >> bits) & 0xFF)
    return bytes(out)


def device_bytes(device: str) -> bytes:
    """设备码 'ABCD-EFGH' -> 5 字节; 空/None -> 全 0 (通用码)"""
    if not device or not device.strip():
        return b"\x00" * 5
    d = b32_decode(device)
    if len(d) != 5:
        raise SystemExit("设备码不合法: %s (解码得到 %d 字节, 应为 5 字节 / 8 个 Base32 字符)"
                         % (device, len(d)))
    return d


def pretty(code: str) -> str:
    return "-".join(code[i:i + 4] for i in range(0, len(code), 4))


# ---------------------------------------------------------------- 签发
def sign(payload: bytes, secret: str) -> str:
    mac = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).digest()[:5]
    return b32_encode(payload + mac)


def make_license(device, days=None, forever=False, secret=FALLBACK_SECRET):
    dev = device_bytes(device)
    if forever:
        exp_days, exp_text = NO_EXPIRE, "永久"
    else:
        if not days or days <= 0:
            raise SystemExit("--days 需要正整数, 或改用 --forever")
        ts = int(time.time()) + days * 86400
        exp_days = (ts - EPOCH) // 86400
        if exp_days <= 0 or exp_days > NO_EXPIRE:
            raise SystemExit("到期时间超出可表示范围")
        exp_text = datetime.fromtimestamp(EPOCH + exp_days * 86400, timezone.utc).strftime("%Y-%m-%d")
    payload = dev + exp_days.to_bytes(4, "big") + bytes([FORMAT_VER])
    return pretty(sign(payload, secret)), exp_text


# ---------------------------------------------------------------- 校验
def verify_license(code, secret=FALLBACK_SECRET, device=None):
    """返回 (是否通过, 说明)"""
    raw = b32_decode(code)
    if len(raw) != 15:
        return False, "长度不对 (解码 %d 字节, 应为 15)" % len(raw)
    payload, sig = raw[:10], raw[10:]
    expect = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).digest()[:5]
    if not hmac.compare_digest(sig, expect):
        return False, "签名不匹配 (密钥不同或激活码被改过)"
    if payload[9] != FORMAT_VER:
        return False, "格式版本不支持 (0x%02X)" % payload[9]

    bound = payload[:5]
    if any(bound):
        if device is None:
            return True, "签名有效 (绑设备 %s, 未提供设备码无法比对)" % pretty(b32_encode(bound))
        if device_bytes(device) != bound:
            return False, "签名有效但设备不匹配 (码绑 %s)" % pretty(b32_encode(bound))

    exp_days = int.from_bytes(payload[5:9], "big")
    if exp_days == NO_EXPIRE:
        return True, "有效 · 永久"
    exp_ts = EPOCH + exp_days * 86400 + 86399
    exp_text = datetime.fromtimestamp(exp_ts, timezone.utc).strftime("%Y-%m-%d")
    if time.time() > exp_ts + 86400:
        return False, "已过期 (%s)" % exp_text
    return True, "有效 · 至 %s" % exp_text


# ---------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description="SMSVideoBG 激活码签发工具")
    ap.add_argument("--device", "-d", help="目标设备码 (控制App 里显示, 形如 ABCD-EFGH)")
    ap.add_argument("--days", type=int, help="有效期天数 (从现在算起)")
    ap.add_argument("--forever", action="store_true", help="永久有效")
    ap.add_argument("--universal", action="store_true",
                    help="不绑设备 (任何设备都能用, 慎用 —— 泄漏即全线可用)")
    ap.add_argument("--note", help="备注 (只打印, 不进激活码)")
    ap.add_argument("--secret", help="签名密钥 (默认读环境变量 SVB_LICENSE_SECRET)")
    ap.add_argument("--verify", metavar="CODE", help="校验一枚激活码")
    ap.add_argument("--check-device", help="配合 --verify: 校验绑定的设备码")
    ap.add_argument("--selftest", action="store_true", help="自检: 随机签发后本地验签")
    args = ap.parse_args()

    secret = args.secret or os.environ.get("SVB_LICENSE_SECRET") or FALLBACK_SECRET
    using_fallback = (secret == FALLBACK_SECRET)

    if args.selftest:
        dev = pretty(b32_encode(bytes(random.getrandbits(8) for _ in range(5))))
        code, exp = make_license(dev, days=365, secret=secret)
        ok, why = verify_license(code, secret, device=dev)
        print("设备码 :", dev)
        print("激活码 :", code)
        print("到期   :", exp)
        print("验签   :", "通过 ✓" if ok else "失败 ✗", "-", why)
        ok2, why2 = verify_license(code, secret + "X", device=dev)
        print("错密钥 :", "正确拒绝 ✓" if not ok2 else "竟然通过了 ✗", "-", why2)
        return 0 if (ok and not ok2) else 1

    if args.verify:
        ok, why = verify_license(args.verify, secret, device=args.check_device)
        print(("通过 ✓ " if ok else "失败 ✗ ") + why)
        return 0 if ok else 1

    if not args.device and not args.universal:
        ap.error("需要 --device 设备码, 或用 --universal 签发通用码")

    device = None if args.universal else args.device
    code, exp = make_license(device,
                             days=args.days,
                             forever=args.forever,
                             secret=secret)
    print("=" * 52)
    print("  设备码 :", "通用 (不绑设备)" if args.universal else device)
    if args.note:
        print("  备注   :", args.note)
    print("  有效期 :", exp, ("(%d 天)" % args.days) if args.days else "")
    print("  激活码 :", code)
    print("=" * 52)
    if using_fallback:
        print("\n⚠️  正在使用内置兜底密钥。若插件是用 GitHub Secret 编译的,")
        print("    这枚激活码不会被识别 —— 请先设置同一密钥：")
        print("    set SVB_LICENSE_SECRET=你的密钥   (Windows cmd)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
