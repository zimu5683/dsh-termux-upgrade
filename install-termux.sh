#!/data/data/com.termux/files/usr/bin/bash
# 在一台全新（只装了 Termux）的 Android 设备上安装 DSH。
#
#   pkg install -y curl
#   curl -fsSL https://raw.githubusercontent.com/zimu5683/dsh-termux-upgrade/main/install-termux.sh | bash
#
# 或者把本文件拷到手机上执行： bash install-termux.sh
#
# 选项：
#   --version <tag>   安装指定版本（默认取最新 release）
#   --no-deps         跳过系统依赖安装
#   --rebuild-sharp   强制在设备上重新编译原生 sharp
set -euo pipefail

REPO="zimu5683/dsh-termux-upgrade"
# 内置版本：不依赖 api.github.com 也能装。用 --version 可覆盖。
DEFAULT_VERSION="v0.1.6-alpha.2-termux.1"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WORK="$HOME/.dsh-install"
DO_DEPS=1
FORCE_REBUILD=0
VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --no-deps) DO_DEPS=0; shift ;;
    --rebuild-sharp) FORCE_REBUILD=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m失败: %s\033[0m\n' "$1" >&2; exit 1; }

[ -n "${TERMUX_VERSION:-}" ] || [ -d "$PREFIX" ] || die "这看起来不是 Termux 环境（\$PREFIX=$PREFIX 不存在）"

# ── 1. 系统依赖 ────────────────────────────────────────────────────────────
if [ "$DO_DEPS" = 1 ]; then
  step "安装系统依赖（首次约需几分钟）"
  pkg update -y >/dev/null 2>&1 || warn "pkg update 有警告，继续"
  # libvips 提供原生 sharp 需要的 libvips.so.42；缺它 sharp 会退回 wasm32（能用但大图会失败）
  pkg install -y nodejs git gh ripgrep libvips clang make >/dev/null 2>&1 \
    || die "依赖安装失败，请手动执行: pkg install nodejs git gh ripgrep libvips clang make"
  ok "node $(node -v)  /  libvips $(pkg-config --modversion vips-cpp 2>/dev/null || echo '?')"
else
  step "跳过系统依赖安装"
fi

for c in node npm; do command -v "$c" >/dev/null || die "缺少 $c，请先 pkg install nodejs"; done

# ── 2. GitHub 访问（仓库已公开，无需认证；有 gh 会更快）────────────────────
step "检查 GitHub 访问"
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  ok "使用环境变量中的 token"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ok "gh 已登录，用 gh 下载"
elif command -v gh >/dev/null 2>&1; then
  ok "有 gh（未登录，走公开下载）"
else
  ok "无 gh，走公开下载"
fi

# ── 3. 取得版本号与产物 ────────────────────────────────────────────────────
step "获取版本"
if [ -z "$VERSION" ]; then
  # api.github.com 常常被代理重置；查不到就用内置版本，不让它阻断安装。
  ERR=$(mktemp)
  if command -v gh >/dev/null 2>&1 && VERSION=$(timeout 30 gh release view --repo "$REPO" --json tagName --jq .tagName 2>"$ERR") \
     && printf '%s' "$VERSION" | grep -q '^v'; then
    ok "目标版本（取自最新 release）: $VERSION"
  else
    VERSION="$DEFAULT_VERSION"
    warn "查不到最新 release，改用内置版本: $VERSION"
    warn "  （原因: $(head -1 "$ERR" | cut -c1-100)）"
    warn "  如需指定别的版本: --version vX.Y.Z-termux.N"
  fi
  rm -f "$ERR"
else
  ok "目标版本（指定）: $VERSION"
fi

TARBALL="dsh-termux-${VERSION#v}.tgz"
mkdir -p "$WORK"

step "下载 $TARBALL"
if [ -f "$WORK/$TARBALL" ]; then
  ok "已存在，跳过下载（如需重下请删除 $WORK/$TARBALL）"
else
  # 大文件在移动网络下容易中断，重试三次
  URL="https://github.com/$REPO/releases/download/$VERSION/$TARBALL"
  for attempt in 1 2 3; do
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh release download "$VERSION" --repo "$REPO" --pattern "$TARBALL" --dir "$WORK" --clobber && break
    else
      curl -fL --retry 2 -o "$WORK/$TARBALL" "$URL" && break
    fi
    [ "$attempt" = 3 ] && die "下载失败（已重试 3 次）。检查代理是否可用；GitHub 直连在大陆会超时。"
    warn "第 $attempt 次下载失败，5 秒后重试…"
    sleep 5
  done
  ok "$(du -h "$WORK/$TARBALL" | cut -f1)"
fi

# ── 4. 安装 ────────────────────────────────────────────────────────────────
step "安装（约 6-8 分钟，请勿中断）"
npm install -g "$WORK/$TARBALL" --no-audit --no-fund >/dev/null 2>&1 \
  || npm install -g "$WORK/$TARBALL" --no-audit --no-fund \
  || die "npm 安装失败"
INSTALLED=$(node -e "try{console.log(require('$(npm root -g)/dsh-termux/package.json').version)}catch(e){console.log('')}")
[ -n "$INSTALLED" ] || die "安装后找不到 dsh-termux"
ok "已安装 dsh-termux@$INSTALLED"

# ── 5. 验证 ────────────────────────────────────────────────────────────────
step "验证"
DSH_ROOT="$(npm root -g)/dsh-termux"
FAIL=0

if command -v dsh >/dev/null; then ok "dsh 命令可用: $(dsh --version 2>&1 | head -1)"; else warn "dsh 不在 PATH"; FAIL=1; fi

# 原生 sharp（图片上传的关键；不行就回退 wasm32，大图会失败）
SHARP_KIND=$(cd "$DSH_ROOT" && node -e "
try { const s=require('sharp'); console.log('emscripten' in s.versions ? 'wasm32' : 'native'); }
catch(e){ console.log('broken'); }" 2>/dev/null || echo broken)
case "$SHARP_KIND" in
  native) ok "sharp 原生 (vips 可用) —— 图片上传无内存上限" ;;
  wasm32) warn "sharp 走 wasm32 回退：连续处理 3~4 张大图后会失效，可加 --rebuild-sharp 重试编译" ;;
  *)      warn "sharp 加载失败" ; FAIL=1 ;;
esac

# ripgrep 回退（grep/glob 工具依赖）
if [ -x "$PREFIX/bin/rg" ]; then ok "ripgrep: $($PREFIX/bin/rg --version | head -1)"; else warn "缺系统 ripgrep，grep 工具会不可用（pkg install ripgrep）"; FAIL=1; fi

# 原生 addon 是否都就位
for f in \
  "node_modules/node-pty/prebuilds/android-arm64/pty.node" \
  "node_modules/@deepseek-ai/node-addon-system-android-arm64/bin/system.node" \
  "node_modules/sharp/src/build/Release/sharp-android-arm64-0.35.4.node"; do
  [ -f "$DSH_ROOT/$f" ] && ok "$(basename "$f")" || warn "缺 $f"
done

# 启动器必须带 --expose-internals（Android 上缺它无法启动）
head -1 "$DSH_ROOT/lib/bin.js" | grep -q "expose-internals" \
  && ok "启动器 shebang 已带 --expose-internals" \
  || { warn "启动器 shebang 缺少 --expose-internals，dsh 将无法启动"; FAIL=1; }

# ── 6. 可选：设备上重新编译 sharp ──────────────────────────────────────────
if [ "$FORCE_REBUILD" = 1 ] || [ "$SHARP_KIND" = wasm32 ]; then
  step "在设备上编译原生 sharp"
  GYP="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
  if [ -f "$GYP" ] && command -v clang >/dev/null && pkg-config --exists vips-cpp 2>/dev/null; then
    ( cd "$DSH_ROOT/node_modules/sharp/src" && node "$GYP" rebuild --nodedir="$PREFIX" >"${TMPDIR:-$PREFIX/tmp}/dsh-gyp.log" 2>&1 ) \
      && ok "编译完成" || warn "编译失败，日志见 ${TMPDIR:-$PREFIX/tmp}/dsh-gyp.log（保持 wasm32 回退）"
    ( cd "$DSH_ROOT" && node -e "const s=require('sharp');console.log('    现在实现:', 'emscripten' in s.versions ? 'wasm32' : '原生')" 2>/dev/null )
  else
    warn "缺 node-gyp / clang / libvips 开发头文件，跳过（不影响基本使用）"
  fi
fi

# ── 7. 完成 ────────────────────────────────────────────────────────────────
step "完成"
cat <<EOF
    启动 Web 界面：
        cd ~ && dsh web

    首次会打印带 token 的地址，形如
        http://127.0.0.1:3080/?token=...
    在手机浏览器打开它即可。

    配置与数据目录： ~/.dsh
    升级： 重新运行本脚本即可（加 --version 可指定版本）
    回滚： 脚本仓库里的 scripts/rollback.sh <目标 tarball>
EOF

[ "$FAIL" = 0 ] || { printf '\n\033[33m注意：上面有带 ! 的告警项，请先处理再使用。\033[0m\n'; exit 0; }
printf '\n\033[32m全部检查通过。\033[0m\n'
