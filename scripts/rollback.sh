#!/data/data/com.termux/files/usr/bin/bash
# 用某个 tarball 完整替换全局 dsh-termux 安装（原子替换）。
# 用法: ./rollback.sh <目标 tarball>
set -euo pipefail

TGZ=${1:?用法: rollback.sh <要回退到的 tarball>}
G=/data/data/com.termux/files/usr/lib/node_modules/dsh-termux
STAGE=$(mktemp -d)

[ -f "$TGZ" ] || { echo "rollback: tarball 不存在: $TGZ" >&2; exit 1; }

echo "rollback: 解包 $TGZ ..."
mkdir -p "$STAGE/extract"
tar -xzf "$TGZ" -C "$STAGE/extract"
SRC="$STAGE/extract/package"
[ -f "$SRC/package.json" ] || { echo "rollback: tarball 结构不对（缺 package/package.json）" >&2; exit 1; }

echo "rollback: 原子替换 $G ..."
if [ -d "$G" ]; then mv "$G" "$G.replaced-$(date +%s)"; fi
mv "$SRC" "$G"
rm -rf "$STAGE"

echo "rollback: 完成，版本 = $(node -e "console.log(require('$G/package.json').version)")"
echo "rollback: 重启 dsh web 生效。"
