#!/data/data/com.termux/files/usr/bin/bash
# 严格校验：暂存树里每个包都必须出现在 tarball 中。
# 用法: ./verify-tarball.sh <tarball> <暂存包目录>
#   例: ./verify-tarball.sh ~/dsh-upgrade/dsh-termux-1.2.3-termux.1.tgz \
#                          ~/dsh-upgrade/build/dsh-termux
set -euo pipefail

TGZ=${1:?用法: verify-tarball.sh <tarball> <暂存包目录>}
DIR=${2:?用法: verify-tarball.sh <tarball> <暂存包目录>}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$TGZ" ] || { echo "verify: tarball 不存在: $TGZ" >&2; exit 1; }
[ -d "$DIR/node_modules" ] || { echo "verify: 不是包目录: $DIR" >&2; exit 1; }

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
tar -tzf "$TGZ" > "$LIST"

REPORT=$(node "$HERE/compare-tree.mjs" "$DIR/node_modules" "$LIST")
echo "$REPORT"

MISSING=$(printf '%s\n' "$REPORT" | sed -n 's/^MISSING from tarball: //p')
if [ "${MISSING:-x}" != "0" ]; then
  echo "FAIL: tarball 缺少 ${MISSING:-未知数量} 个包 —— 不要安装" >&2
  exit 1
fi
echo "PASS: tarball 包含全部暂存包"
