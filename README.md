# DSH on Termux — 升级手册与兼容性记录

在 Android/Termux 上运行与升级 **DeepSeek Harness (dsh)** 的完整流程记录。

上游 `@deepseek-ai/dsh` 没有任何 Android 构建，npm 上的包在 Termux 里跑不起来。
本仓库记录的是：**如何把上游版本重打包成能在 Termux 上正常工作的 `dsh-termux`**，
以及每一次踩坑的根因与验证方法。

- 当前验证版本：`@deepseek-ai/dsh@0.1.7-rc.2` → `dsh-termux@0.1.7-rc.2-termux.1`
- 上一次：`0.1.7-rc.1` → `dsh-termux@0.1.7-rc.1-termux.1`
- 更早：`0.1.6-alpha.2`、`0.1.6-alpha.1`、`0.1.1-rc.2`
- 设备：Termux on Android aarch64，Node v26.4.0（ABI 147）
- 兼容性细节：[`docs/termux-compat-notes.md`](docs/termux-compat-notes.md)
- 诊断经验：[`docs/lessons.md`](docs/lessons.md)
- 平台缺口审计：[`docs/android-audit.md`](docs/android-audit.md)
- **alpha.1 → alpha.2 升级记录：[`docs/alpha2-changes.md`](docs/alpha2-changes.md)**
- **alpha.2 → rc.1 升级记录：[`docs/rc1-changes.md`](docs/rc1-changes.md)**（补丁重导出、重放器扩容、`--version` 语义变更）
- **rc.1 → rc.2 升级记录：[`docs/rc2-changes.md`](docs/rc2-changes.md)**（小版本；零 DRIFT；profile 配置迁移的坑）

---

## 零、新设备一键安装（推荐）

在一台**只装了 Termux** 的新手机上：

```sh
pkg install -y curl
curl -fsSL https://raw.githubusercontent.com/zimu5683/dsh-termux-upgrade/main/install-termux.sh | bash
```

脚本会依次：装系统依赖 → 下载最新 release 的产物 → `npm install -g` →
**逐项验证**（sharp 实现 / ripgrep / 原生 addon / 启动器 shebang）→ 打印启动方式。

仓库已公开，**无需任何认证**；装了 `gh` 会自动用它（更快、可断点重试），没有就用 `curl`。

装完启动：

```sh
cd ~ && dsh web
```

首次会打印带 token 的地址（形如 `http://127.0.0.1:3080/?token=...`），在手机浏览器打开即可。

**这个产物就是当前平板上跑的版本**：475 个 npm 包全部内置，离线可装、
无需解析依赖、无需编译。原生 addon（sharp / flock / node-pty）都已包含，
新设备只要装了 `libvips` 就能直接用。

常用选项：

| 选项 | 作用 |
|---|---|
| `--version v0.1.6-alpha.2-termux.1` | 装指定版本（默认最新） |
| `--no-deps` | 跳过系统依赖安装 |
| `--rebuild-sharp` | 在设备上重新编译原生 sharp（换设备/升级 libvips 后用） |

**网络前提（重要）**：GitHub 与 raw.githubusercontent.com 在大陆直连会超时，
**必须先开代理**。实测：关代理时 `gh release download` 报
`dial tcp 185.199.109.133:443: i/o timeout`；开代理后 50MB 产物约 2 分钟下完。

代理的 fake-ip 模式**不影响** `gh` / `npm` / `git`——它们走普通 HTTPS，连到
`198.18.x.x` 后由代理转发即可。只有 harness 内置的 `web_fetch` 工具会因为
SSRF 地址校验而拒绝 fake-ip，那是另一回事（详见第三节的已知限制）。

**前置条件**：`nodejs`、`libvips`、`ripgrep`。缺 `libvips` 时
sharp 会退回 wasm32（能用，但连续处理 3~4 张大图后会失效）；缺 `ripgrep`
则 `grep`/`glob` 工具不可用。脚本都会处理并验证。

下面第一到四节是**手动流程与原理**，用于排查问题或跟进新版本时参考。

---

## 一、新手机从零开始的完整流程

### 0. 关键前提：`process.platform === "android"`

Termux 的 Node 报告的平台是 **`android`**，不是 `linux`。上游代码里大量
`platform === "linux"` 的判断会把 Android 排除掉——**这是本仓库绝大多数补丁的来源**。
记住这一点，后面每个坑几乎都能归到它。

### 1. 装系统依赖

```sh
pkg update
pkg install -y nodejs-lts git gh ripgrep libvips python clang make
```

| 包 | 为什么需要 |
|---|---|
| `nodejs` | 运行 dsh。**实测 v26 可用** |
| `libvips` | 原生 sharp 的图像后端（见第 5 步）。不装也能跑，但图像上传会退化 |
| `ripgrep` | dsh 的 `grep` 工具没有 Android 版预编译件，回退到系统 `rg` |
| `clang` `make` `python` | 编译原生 sharp 与 flock 绑定 |
| `gh` | 拉取/推送本仓库，以及创建仓库 |

登录 GitHub：

```sh
gh auth login          # 需要 repo 权限（创建私有仓库）
git config --global user.name  "<你的用户名>"
git config --global user.email "<你的邮箱>"
```

### 2. 拿到上游版本

先确认要升级到哪个版本，**不要假设 `latest` 就是你要的**：

```sh
npm view @deepseek-ai/dsh dist-tags --json
npm view @deepseek-ai/dsh versions --json | tail -20
```

`0.1.6` 当时只在 `alpha` tag 上（`0.1.6-alpha.1`），`latest` 还停在 `0.1.5-rc.1`。

```sh
mkdir -p ~/dsh-upgrade && cd ~/dsh-upgrade
npm pack @deepseek-ai/dsh@<版本>
mkdir -p up && tar -xzf deepseek-ai-dsh-<版本>.tgz -C up
```

### 3. 建暂存目录并改名

```sh
mkdir -p build/dsh-termux
cp -a up/package/. build/dsh-termux/
cd build/dsh-termux
node -e "
const fs=require('fs');
const p=JSON.parse(fs.readFileSync('package.json','utf8'));
p.name='dsh-termux';
p.version='<上游版本>-termux.1';
p.bin={dsh:'lib/bin.js','dsh-termux':'lib/bin.js'};
fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n');
"
```

### 4. 安装依赖

```sh
npm install --no-audit --no-fund
```

npm 会按 `os`/`cpu` 自动挑 Android 变体（`@esbuild/android-arm64`、
`@koromix/koffi-android-arm64` 等），这一步是对的，不用干预。

**但 npm 12 默认拦截 install script**，被拦的那几个恰好是关键原生模块。
安装完必须手动核对（见下一步和 `docs/termux-compat-notes.md` 的补丁表）：

```sh
# 检查哪些脚本被拦
npm install-scripts ls
```

### 5. 按清单应用 Termux 补丁

**这是整个流程的核心，也是最容易漏的一步**——上游已经不止一次把 Android 分支删掉。
补丁全表与逐条根因见 [`docs/termux-compat-notes.md`](docs/termux-compat-notes.md)。
每次升级都要重新过一遍，不要假设上次打过的这次还在。

**从 rc.1 起，全部 13 条文本补丁都进了一个幂等重放器**（`apply-termux-patches.mjs`），
补丁表由 `gen-patchdefs.mjs` 从 pristine 源码与 known-good 产物**机械派生**并逐字节自证，
不再是手工抄写。升级时只需对暂存树跑一次，再用 `--check` 确认：

```sh
DSH_INSTALL_ROOT=<staging>/dsh-termux node apply-termux-patches.mjs
DSH_INSTALL_ROOT=<staging>/dsh-termux node apply-termux-patches.mjs --check   # 必须退出 0
```

速查（13 条文本补丁 + 4 项原生二进制件）：

| # | 位置 | 要做什么 |
|---|---|---|
| 1 | `dsh-app-boot/lib/index.js` | `internalModules()` 优先走 `--expose-internals` |
| 2 | `dsh-app-boot/lib/worker/profile-resolution-bootstrap.js` | 同上（Worker 端） |
| 3 | `lib/bin.js` | shebang 改为 `#!/usr/bin/env -S node --expose-internals` |
| 4 | `@vscode/ripgrep/lib/index.js` | 加系统 `rg` 回退 |
| 5 | `node-addon-system/lib/flock.js` | 平台判断放行 `android` |
| 6 | `dsh-session-persistence-jsonl` | 硬链接 → `copyFile+EXCL`（exclusive publish） |
| 7 | `dsh-session-persistence-jsonl` | 硬链接 → `rename`（materialize） |
| 8 | `dsh-attachment-local` | 硬链接 → `copyFile+EXCL`（publishStagedObject） |
| 9 | `dsh-attachment-local` | 硬链接 → `copyFile+EXCL`（publishImmutableAlias） |
| 10 | `dsh-attachment-local` | durability 遍历的 EACCES 边界 |
| 11 | `dsh-subprocess-local` | `createProcessInspector` 放行 `android` |
| 12 | `dsh-fs-local` | `writeFileAtomic` 的 `createIfAbsent` → `copyFile+EXCL` |
| 13 | `dsh-web-fetch-http` | `trustedAddressRanges` 白名单（fake-IP VPN） |
| — | `node-pty/prebuilds/android-arm64/pty.node` | 放入设备编译的 Android PTY 绑定（**二进制，重放器无法处理**） |
| — | `@img/sharp-wasm32` | wasm 回退包（**已确认实际不可用**，见 rc1-changes §六） |
| — | `sharp/src/build/Release/*.node` | 原生 sharp（设备编译，见第 6 步） |
| — | `node-addon-system-android-arm64/` | 设备上编译 flock 绑定 |

补丁 1–3 是 **alpha.2 新增**的：上游把 `cordis-plugin-hmr` 换成 `dsh-hmr` 并移除了
`watchUserPatches`，alpha.1 用的「在 profile-boot 里门控 HMR」已无对应代码；
同时 `node-addon-require-builtin` 从潜伏问题变成启动阻断。

补丁 8–10、12 的位置在 **rc.1 复核时修正**过：`createProcessInspector` 实际在
`dsh-subprocess-local/lib/runner-launch-*.js`（不在 `lib/index.js`），
而 `publishStagedObject` / `ensureDurableDirectory` / `publishImmutableAlias` 是
`dsh-attachment-local` 里三处独立的硬链接缺陷。rc.1 复核结论：**26/26 步锚点全部命中，零 DRIFT**。
详见 [`docs/alpha2-changes.md`](docs/alpha2-changes.md)。

### 6. 编译原生 sharp（强烈建议）

不装 libvips 时 sharp 会走 wasm32，**连续处理 3~4 张大图后堆耗尽、图像功能永久失效**
（详见文档）。原生编译后彻底解决，且无需改任何代码：

```sh
cd build/dsh-termux/node_modules/sharp/src
node $(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js rebuild \
     --nodedir=$PREFIX
```

成功标志：生成 `src/build/Release/sharp-android-arm64-<版本>.node`，
且 `node -e "console.log(require('sharp').versions)"` **不含 `emscripten` 字段**。

### 7. 锁定依赖 + 打包

**不要用 `npm pack`**——它会静默丢掉只经由 `peerDependencies` 可达的包，
实测丢掉 14 个（含 `dsh-settings`、`dsh-session-query`、`dsh-bash-local`），
结果是启动时 `ERR_MODULE_NOT_FOUND`。

用仓库里的脚本：

```sh
cd ~/dsh-upgrade
node scripts/pin-manifest.mjs build/dsh-termux        # 452 个包全部锁定版本
cd build/dsh-termux
tar -czf ~/dsh-upgrade/dsh-termux-<版本>-termux.1.tgz \
    --transform 's,^,package/,' --owner=0 --group=0 --numeric-owner \
    lib package.json README.md README.zh.md README.i18n.yaml LICENSE node_modules
```

### 8. 严格校验（必做，不可跳过）

```sh
cd ~/dsh-upgrade
tar -tzf dsh-termux-<版本>-termux.1.tgz > new-tgz-list.txt
node scripts/compare-tree.mjs build/dsh-termux/node_modules new-tgz-list.txt
```

必须输出 `MISSING from tarball: 0`。**不是 0 就不要装。**

### 9. 隔离验证，再替换

**不要直接 `npm install -g`**——那是 7 分钟的窗口，正在跑的服务会坏。
装到独立前缀，验证通过后用两次 `rename` 原子替换：

```sh
npm install -g --prefix ~/dsh-upgrade/stage ~/dsh-upgrade/dsh-termux-*.tgz

# 先用独立 DSH_HOME 和端口试启动，确认能起
DSH_HOME=~/.dsh-test node ~/dsh-upgrade/stage/lib/node_modules/dsh-termux/lib/bin.js \
    web --port 3081 --no-open

# 通过后再换
G=/data/data/com.termux/files/usr/lib/node_modules/dsh-termux
mv "$G" "$G.old-$(date +%s)"
mv ~/dsh-upgrade/stage/lib/node_modules/dsh-termux "$G"
dsh --version
```

### 10. 重启服务

**文件替换后运行中的进程仍用内存里的旧代码**，必须重启 `dsh web` 才生效。
判断方法：

```sh
ps -o etime= -p $(pgrep -f "dsh web" | head -1)   # 运行时长
stat -c '%y' <你刚改的文件>                        # 修改时刻
```

进程启动早于修改 → 需要重启。

---

## 二、验证清单

升级后逐项确认（每条都有踩过坑的记录）：

- [ ] `dsh --version` 是目标版本
- [ ] `dsh web` 能起，GUI 返回 200
- [ ] **极简模式**的 bash 可用（走 PTY 持久 shell，和其他模式不是同一条链路）
- [ ] 标准模式 bash 可用
- [ ] 上传一张截图成功（附件链路 + 原生 sharp）
- [ ] `grep` / `glob` 工具可用（走系统 `rg`）
- [ ] 会话落盘：`~/.dsh/sessions/**/session*.jsonl.zstd` 有内容且可解压出 JSONL
- [ ] `require('sharp').versions` 不含 `emscripten`

---

## 三、出问题时怎么退

| 场景 | 做法 |
|---|---|
| 只想回退 sharp | `scripts/restore-sharp.sh` |
| 想整个回退到上一版 dsh | `scripts/rollback.sh`（回 0.1.1） |
| 想回退到本仓库记录的这一版 | 重装 `dsh-termux-0.1.7-rc.1-termux.1.tgz` |
| 想回退到上一版 | 重装 `dsh-termux-0.1.6-alpha.2-termux.1.tgz` |
| 服务起不来 | 用第 9 步的隔离启动方式看报错，别动全局安装 |

**动手前先建恢复点**，这是这次任务的第一条纪律。

> rc.1 的原子替换会留下 `$PREFIX/lib/node_modules/dsh-termux.old-<时间戳>`，
> 配套的重启脚本 `restart-dsh-web.sh` 在新版 60 秒内没起来时会**自动把旧目录换回并重启旧版**。

---

## 四、这个仓库里有什么

```
README.md                      本手册
docs/termux-compat-notes.md    完整兼容性记录（每个补丁的根因、证据、验证）
docs/alpha2-changes.md         alpha.1 → alpha.2 升级记录
docs/rc1-changes.md            alpha.2 → rc.1 升级记录（补丁重导出、重放器扩容、--version 语义）
docs/lessons.md                诊断经验与踩过的思维陷阱
docs/android-audit.md          495 个 package.json 的平台缺口审计
scripts/pin-manifest.mjs       锁定全部顶层依赖到精确版本
scripts/compare-tree.mjs       暂存树 vs tarball 完整性比对
scripts/verify-tarball.sh      tarball 严格校验
scripts/rollback.sh            回滚到 0.1.1
scripts/restore-sharp.sh       sharp 回退到 wasm32
```

配套的维护脚本在设备本机的工作区（不进本仓库）：

```
tool-probe.mjs                 环境与补丁诊断（只读，覆盖全部 13 条补丁）
apply-termux-patches.mjs       幂等补丁重放器（13 条，--check/--dry-run/--revert）
verify-patches.mjs             补丁自检：锚点唯一可逆、重放逐字节一致、幂等
verify-runtime-behavior.mjs    运行时行为验证（write / 附件 / web_fetch + SSRF）
tool-audit.mjs                 全工具可用性审计器（180 条组合行）
ANDROID-TOOL-AUDIT.md          全工具可用性审计报告
```

仓库里**不含**任何密钥、token 或二进制产物——只放流程、脚本与结论。
