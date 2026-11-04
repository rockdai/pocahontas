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
xcodebuild -project pocahontas.xcodeproj -scheme pocahontas-macOS \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" -disableAutomaticPackageResolution \
  "POCAHONTAS_SERVER_URL=${POCAHONTAS_SERVER_URL:-}" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > "$OUTPUT_DIR/build.log" 2>&1
APP="$DERIVED_DATA_PATH/Build/Products/Debug/Pocahontas.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")" == Pocahontas ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" == Pocahontas ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/Pocahontas")" == arm64 ]]
[[ ! -d "$APP/Contents/PlugIns" ]] || { echo 'Unexpected test plug-ins in application.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/Pocahontas/Pocahontas.app"
python3 - "$STAGING/Pocahontas" "$SOURCE_COMMIT" "$ROOT" "$DERIVED_DATA_PATH" <<'PY'
from pathlib import Path
import os, re, shutil, sys
stage, source = Path(sys.argv[1]), sys.argv[2]
root, derived = Path(sys.argv[3]), Path(sys.argv[4])
# Carry the existing notices and the licenses shipped with the linked source trees.
for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'Licenses', 'assets/logo/fonts/OFL.txt', 'Packages/PocahontasKit/Package.resolved', 'Frameworks/build-info.json']:
    original, destination = root / name, stage / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if original.is_dir():
        shutil.copytree(original, destination)
    else:
        shutil.copy2(original, destination)
notice_name = re.compile(r'^(LICENSE|LICENCE|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([._ -].*)?$', re.I)
for label, tree in [('ghostty', root / 'vendor/ghostty'), ('zig-packages', root / '.cache/zig/p'), ('swift-packages', derived / 'SourcePackages/checkouts')]:
    if not tree.is_dir():
        raise SystemExit(f'Missing dependency sources for notices: {tree}')
    for folder, directories, files in os.walk(tree):
        directories[:] = [d for d in directories if d not in {'.git', '.build', '.zig-cache', 'zig-out'}]
        for name in files:
            if notice_name.match(name):
                original = Path(folder) / name
                destination = stage / 'DependencyNotices' / label / original.relative_to(tree)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, destination)
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
账号同步需要打包时配置 Pocahontas server 地址；未配置时使用本地模式。
已配置的测试包可在 Saved Connections → Account & Sync 注册与登录。
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
