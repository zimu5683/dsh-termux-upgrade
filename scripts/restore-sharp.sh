#!/data/data/com.termux/files/usr/bin/bash
# 把 sharp 回退到 wasm32 状态（放弃原生 addon）。
# 用法: ./restore-sharp.sh [dsh 安装目录]
#   默认自动定位全局 dsh-termux 安装。
set -euo pipefail

G=${1:-$(node -e "
try { console.log(require('path').dirname(require.resolve('dsh-termux/package.json'))); }
catch { process.exit(1); }
" 2>/dev/null || echo /data/data/com.termux/files/usr/lib/node_modules/dsh-termux)}

[ -d "$G/node_modules/sharp" ] || { echo "restore: 找不到 $G/node_modules/sharp" >&2; exit 1; }

echo "restore: 目标安装 = $G"
echo "restore: 移除原生 sharp 构建产物 ..."
rm -rf "$G/node_modules/sharp/src/build"

echo "restore: 确认回退到 wasm32 ..."
cd "$G"
node -e "
const s = require('sharp');
const wasm = 'emscripten' in (s.versions || {});
console.log('  versions =', JSON.stringify(s.versions).slice(0, 120));
console.log('  走 wasm  =', wasm);
s({create:{width:64,height:64,channels:3,background:{r:1,g:2,b:3}}}).png().toBuffer()
  .then(b => console.log('  编码     = OK', b.length, 'bytes'))
  .catch(e => { console.log('  编码     = FAILED', e.message); process.exit(1); });
"
echo "restore: 完成。重启 dsh web 生效。"
