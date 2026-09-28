#!/usr/bin/env python3
# v1.3 版: 解包 .deb 并打印关键内容 (filter plist / control / 二进制架构 / entitlements)
import io
import os
import re
import sys
import tarfile

ENT_KEYS = [b"platform-application", b"no-sandbox", b"AppDataContainers",
            b"AppBundles", b"get-task-allow"]


def ar_members(data):
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    i, out = 8, []
    while i + 60 <= len(data):
        hdr = data[i:i + 60]
        if hdr[58:60] != b"`\n":
            break
        name = hdr[0:16].decode("latin1").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("latin1").strip())
        except ValueError:
            break
        out.append((name, i + 60, size))
        i = i + 60 + size + (size % 2)
    return out


def main(deb):
    d = open(deb, "rb").read()
    print("=" * 60)
    print("deb:", os.path.basename(deb), len(d), "bytes")
    blobs = {}
    for name, start, size in ar_members(d):
        blobs[name] = d[start:start + size]
        print("  member:", name, size)

    # control
    ctl = [n for n in blobs if n.startswith("control.tar")]
    if ctl:
        tf = tarfile.open(fileobj=io.BytesIO(blobs[ctl[0]]), mode="r:*")
        for m in tf.getmembers():
            if m.name.endswith("control"):
                print("---- control ----")
                print(tf.extractfile(m).read().decode("utf-8", "replace").strip())

    data_name = [n for n in blobs if n.startswith("data.tar")][0]
    tf = tarfile.open(fileobj=io.BytesIO(blobs[data_name]), mode="r:*")
    print("---- data (%s) ----" % data_name)
    for m in tf.getmembers():
        if m.isfile():
            base = os.path.basename(m.name)
            payload = tf.extractfile(m).read()
            arch = "?"
            if payload[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
                arch = "thin"
            elif payload[:4] == b"\xca\xfe\xba\xbe":
                arch = "fat"
            print("  %-70s %8dB %s" % (m.name, len(payload), arch))
            if base.endswith(".plist") and len(payload) < 600:
                print("     >>>", payload.decode("utf-8", "replace").replace("\n", " ")[:500])
            if base == "control" or base.endswith(".dylib") or base == "SMSVideoBGApp":
                found = [e.decode() for e in ENT_KEYS if e in payload]
                if found:
                    print("     entitlements:", found)
    print()


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
