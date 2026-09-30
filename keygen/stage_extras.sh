#!/bin/bash
# after-stage: 覆盖 Info.plist / 图标 + ldid 伪签名
#   不同 Theos 版本的 staging 布局不同, 这里逐个探测 .app 的真实位置
STAGE="$1"
if [ -z "$STAGE" ]; then
  echo "::error::stage_extras.sh 缺少 staging 目录参数"
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR=""
for p in "$STAGE/Applications/SVBKeyGen.app" \
         "$STAGE/var/jb/Applications/SVBKeyGen.app" \
         "$STAGE/SVBKeyGen.app"; do
  if [ -d "$p" ]; then APP_DIR="$p"; break; fi
done

if [ -z "$APP_DIR" ]; then
  echo "::error::SVBKeyGen.app staging 目录未找到, staging 内容:"
  find "$STAGE" -maxdepth 5 -name "*.app" 2>/dev/null
  exit 1
fi

cp "$DIR/Resources/AppInfo.plist" "$APP_DIR/Info.plist"
cp "$DIR/Resources/Icon.png" "$APP_DIR/Icon.png"

if ! grep -q "授权签发" "$APP_DIR/Info.plist"; then
  echo "::error::Info.plist 覆盖失败"
  exit 1
fi

if command -v ldid >/dev/null 2>&1 && [ -f "$APP_DIR/SVBKeyGen" ]; then
  ldid -S "$APP_DIR/SVBKeyGen" && echo "ldid: signed"
fi

echo "keygen staged: $APP_DIR"
