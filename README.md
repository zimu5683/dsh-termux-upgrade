# DSH on Termux — 升级手册与兼容性记录

在 Android/Termux 上运行与升级 **DeepSeek Harness (dsh)** 的完整流程记录。

上游 `@deepseek-ai/dsh` 没有任何 Android 构建，npm 上的包在 Termux 里跑不起来。
本仓库记录的是：**如何把上游版本重打包成能在 Termux 上正常工作的 `dsh-termux`**，
以及每一次踩坑的根因与验证方法。

- 当前验证版本：`@deepseek-ai/dsh@0.1.6-alpha.1` → `dsh-termux@0.1.6-alpha.1-termux.1`
- 设备：Termux on Android aarch64，Node v26.4.0（ABI 147）
- 兼容性细节：[`docs/termux-compat-notes.md`](docs/termux-compat-notes.md)
- 诊断经验：[`docs/lessons.md`](docs/lessons.md)
- 平台缺口审计：[`docs/android-audit.md`](docs/android-audit.md)

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

速查（详细做法见文档）：

| # | 位置 | 要做什么 |
|---|---|---|
| 1 | `lib/profile-boot-*.js` | HMR 加载加 `--expose-internals` 门控 |
| 2 | `node-pty/prebuilds/android-arm64/pty.node` | 放入设备编译的 Android PTY 绑定 |
| 3 | `@img/sharp-wasm32` | 装 wasm 回退（原生 sharp 的安全网） |
| 4 | `@vscode/ripgrep/lib/index.js` | 加系统 `rg` 回退 |
| 5 | `node-addon-system/lib/flock.js` | 平台判断放行 `android` |
| 6 | `node-addon-system-android-arm64/` | 设备上编译 flock 绑定 |
| 7 | `dsh-session-persistence-jsonl` | 硬链接 → Android 用 `rename` / `copyFile+EXCL` |
| 8 | `dsh-attachment-local` | 同上，另加 durability 遍历的 EACCES 边界 |
| 9 | `dsh-subprocess-local` | `createProcessInspector` 放行 `android` |

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
| 想回退到本仓库记录的这一版 | 重装 `dsh-termux-0.1.6-alpha.1-termux.1.tgz` |
| 服务起不来 | 用第 9 步的隔离启动方式看报错，别动全局安装 |

**动手前先建恢复点**，这是这次任务的第一条纪律。

---

## 四、这个仓库里有什么

```
README.md                      本手册
docs/termux-compat-notes.md    完整兼容性记录（每个补丁的根因、证据、验证）
docs/lessons.md                诊断经验与踩过的思维陷阱
docs/android-audit.md          495 个 package.json 的平台缺口审计
scripts/pin-manifest.mjs       锁定全部顶层依赖到精确版本
scripts/compare-tree.mjs       暂存树 vs tarball 完整性比对
scripts/verify-tarball.sh      tarball 严格校验
scripts/rollback.sh            回滚到 0.1.1
scripts/restore-sharp.sh       sharp 回退到 wasm32
```

仓库里**不含**任何密钥、token 或二进制产物——只放流程、脚本与结论。
