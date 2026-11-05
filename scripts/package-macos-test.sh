#!/bin/bash
# Local, ad-hoc signed Apple Silicon build for manual testing on another Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/.build/exports}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "$ROOT/.build/mac-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
SOURCE_COMMIT="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit source changes before packaging so the archive identifies its source.' >&2
  exit 1
fi
scripts/generate-project.sh
BUILD_SETTINGS=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
if [[ -n "${POCAHONTAS_SERVER_URL+x}" ]]; then
  BUILD_SETTINGS+=("POCAHONTAS_SERVER_URL=$POCAHONTAS_SERVER_URL")
fi
xcodebuild -project pocahontas.xcodeproj -scheme pocahontas-macOS \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" -disableAutomaticPackageResolution \
  "${BUILD_SETTINGS[@]}" build > "$OUTPUT_DIR/build.log" 2>&1
APP="$DERIVED_DATA_PATH/Build/Products/Debug/Pocahontas.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")" == Pocahontas ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" == Pocahontas ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/Pocahontas")" == arm64 ]]
[[ ! -d "$APP/Contents/PlugIns" ]] || { echo 'Unexpected test plug-ins in application.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/Pocahontas/Pocahontas.app"
python3 - "$STAGING/Pocahontas" "$SOURCE_COMMIT" "$ROOT" "$DERIVED_DATA_PATH" <<'PY'
from pathlib import Path
import importlib.util, plistlib, sys
stage, source = Path(sys.argv[1]), sys.argv[2]
root, derived = Path(sys.argv[3]), Path(sys.argv[4])
app_info = plistlib.loads((derived / 'Build/Products/Debug/Pocahontas.app/Contents/Info.plist').read_bytes())
server_url = app_info.get('PocahontasServerURL', '')
account_instructions = (f'账号服务：{server_url}。可在 Saved Connections → Account & Sync 注册与登录。'
                        if server_url else '此包未配置账号服务，使用本地模式。')
spec = importlib.util.spec_from_file_location('package_macos', root / 'scripts/package-macos.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
package.copy_notices(stage, derived)
(stage / '使用说明.txt').write_text(f'''Pocahontas — MacBook 测试版
源码版本：{source}
平台：Apple Silicon / arm64（M1 或更新），最低系统版本 macOS 14。
Intel Mac 不能使用此安装包；最低系统版本仍需实机验收。

1. 解压，将 Pocahontas.app 拖入“应用程序”，双击打开。不需要安装 Xcode。
2. 此包为本地 ad-hoc 签名，未做 Apple 公证。如果提示无法验证开发者，先尝试打开一次，再到“系统设置 → 隐私与安全性 → 仍要打开”，仅允许此测试 App。
   Apple 说明：https://support.apple.com/en-gb/102445
3. 输入开发服务器的真实 SSH 地址、端口、用户名及密码或 OpenSSH Ed25519 私钥。
   127.0.0.1 指当前 MacBook，不是其他电脑的地址。
4. ＋ / ⌘T 新建会话，⌃Tab / ⌃⇧Tab 切换，标签 × 单独关闭，⌘N 新窗口。

支持 SSH、多会话、本地连接配置、本机 Keychain 凭据保存与服务器指纹信任。
{account_instructions}
远端持续任务请使用 tmux。
本包不包含构建机器的已保存连接、密码、私钥或用户数据。

源码与构建说明：https://github.com/rockdai/pocahontas
''', encoding='utf-8')
PY
ARCHIVE="$OUTPUT_DIR/Pocahontas-AppleSilicon.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Pocahontas" "$ARCHIVE"
mkdir "$STAGING/verify"
ditto -x -k "$ARCHIVE" "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/Pocahontas/Pocahontas.app"
(cd "$OUTPUT_DIR" && shasum -a 256 Pocahontas-AppleSilicon.zip > SHA256SUMS.txt)
echo "Packaged $ARCHIVE from $SOURCE_COMMIT"
