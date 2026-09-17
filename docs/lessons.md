# 诊断经验

这次升级一共挖出 12 个 Termux 兼容问题。真正值钱的不是补丁本身，而是**怎么找到它们**。
下面是踩过的坑和验证方法，下次升级照着做能省掉大部分试错。

---

## 1. 先找真实报错，不要从症状推测

「极简模式用不了 bash」是个症状。我最初的两次猜测**都是错的**：

- 猜「`dsh-terminal-bash` 硬编码了 `/bin/bash`，Termux 上没有」
- 猜「环境被净化后丢了 `LD_PRELOAD`，导致路径重写失效」

**真实答案在会话日志里。** dsh 把每次工具调用和结果都写进
`~/.dsh/sessions/<workspace>/<session>/session*.jsonl.zstd`，报错原文就在里面：

```
Error: subprocess-local: terminal inspection is unsupported on platform android
```

一句话定位，比任何推理都快。

**做法**：报错先翻会话日志。日志里没有（比如上传失败在进入会话之前就死了），
再查「这条链路本该写出什么文件、那些文件存不存在」。

### 两个读日志的坑

1. **zstd 是多帧的**。一个 1.4MB 的会话文件里有 3400+ 个独立 zstd 帧
   （每次追加一帧）。Node 的 `zstdDecompressSync` / 流式解压**只解第一帧**，
   你会以为会话只有 1 条记录。必须逐帧解：扫描 magic `28 B5 2F FD`，
   从每个位置尝试解压。
2. **会话文件有两种文件名**：老的是 `session.jsonl.zstd`，
   0.1.6 起是 `session.v3.jsonl.zstd`。只找前者会漏掉新会话。

---

## 2. 结论必须实测，推测一律不算数

`/bin/bash` 那次是典型：

```
ls -la /bin/bash          → No such file or directory
/bin/bash -c 'echo ok'    → ok            ← 能跑！
readlink /proc/$$/exe     → /data/.../usr/bin/bash   ← 实际执行的是 Termux 的 bash
```

Termux 下 `/bin -> /system/bin`，但 termux-exec 会在 exec 时重写路径，
所以**看不到 ≠ 不存在**。我如果按最初的猜测去「修」`DEFAULT_BASH_SHELL`，
就是改一个根本没坏的地方——而且会掩盖真正的原因。

**规则**：涉及文件系统/内核行为，用 `existsSync`、`/proc/self/exe`、`readelf`、
真实 spawn 来验证，不要靠 `ls` 或直觉。

---

## 3. Android 平台的三种坑型（按出现频率）

### 型一：平台门控把 Android 排除掉（最常见，占一多半）

上游写 `platform === "linux"` 时没想到 Android，而 **Android 就是 Linux**：
同样的 `/proc`、同样的 syscall 号、bionic 的 `flock()` 都在。

出现过的地方：`createProcessInspector`（极简模式 bash）、`flock.js` 的平台判断。

**排查手法**：全树搜 `platform === "linux"` / `platform !== "linux"`，
逐个问「这里排斥 Android 是必要的吗」。同时看它是**抛错**还是**降级**——
降级的可以不管，抛错的必须修。

### 型二：文件系统语义差异

- **硬链接在 Android 应用目录被完全禁止**（`EACCES`，不是 `EPERM`，也不是 `EEXIST`）。
  凡是「原子地不存在才创建」的写法（`fs.link`）都要改：
  用 `rename`（可覆盖场景）或 `copyFile + COPYFILE_EXCL`（需保持 create-if-absent 语义）。
  注意：**上游曾经有 Android 分支，后来删了**，每次升级都要重新检查。
- **向上遍历到文件系统根的 durability fsync 会撞墙**。
  `dsh-attachment-local` 用 `parse(home).root`（即 `/`）当边界，一路 fsync 到
  `/data/data`、`/data`、`/` —— Android 应用无权 open 这些目录，直接 `EACCES`。
  修法是：**进程无权写入的祖先目录本身就是边界**，到此为止（但要保留
  「能写却打不开」时继续抛错，否则会掩盖真实故障）。

### 型三：没有 Android 预编译件

`sharp`、`ripgrep`、`node-pty`、`koffi` 都属于这类。三种应对：

| 手段 | 适用 | 例子 |
|---|---|---|
| 设备上编译 | 有源码、有工具链 | node-pty、flock、sharp |
| 官方 wasm/JS 回退 | 上游自带兜底 | `@img/sharp-wasm32` |
| 系统包替代 | 有等价系统程序 | `pkg install ripgrep` |

优先「设备上编译」——wasm 回退往往有隐性代价（见第 5 条）。

---

## 4. `npm pack` 会静默丢包

这是最阴的一个。`npm pack` 依据 lock 的依赖图裁剪，
**只经由 `peerDependencies` 可达的包会被丢掉**。实测丢了 14 个，包括
`@deepseek-ai/dsh-settings`、`dsh-session-query`、`dsh-bash-local`——
全是运行时必需的，启动直接 `ERR_MODULE_NOT_FOUND`。

试过的无效做法：把包加进根 `dependencies`、删除 `package-lock.json`、
重新 `npm install` —— **都没用**。

**有效做法**：用 `tar` 自己打，然后**逐包比对**：

```sh
tar -tzf x.tgz > list.txt
node scripts/compare-tree.mjs node_modules list.txt   # 必须 0 missing
```

顺带一提，`npm notice bundled files: 0` 这种提示是 npm 的记账怪癖，
不代表真的没打包——**以逐包比对为准，不要信提示**。

---

## 5. 回退方案不等于没有代价

`sharp` 的 wasm32 回退看着很安全（能加载、能编码），但**有隐性上限**：

- emscripten 堆**只增不减**，连续处理 3~4 张 12MP 图后转换永久失败
- RSS 涨到 ~2GB，而 JS 堆只有 10MB —— 说明是 wasm 堆，不是 JS 泄漏
- `sharp.cache(false)` + `sharp.concurrency(1)` 都无效

**所以「能加载」不等于「能用」**。验证回退方案时要**压测**，不能只跑一张图。

另外，原生 sharp 的编译**比预想的简单**：sharp 自带 global-libvips 路径，
只要系统 libvips 版本 ≥ `minimumLibvipsVersion`，
`binding.gyp` 会自动走 `pkg-config` 分支，**一行代码都不用改**。

---

## 6. 时序陷阱：改了文件 ≠ 生效

Node 进程把模块加载进内存后，磁盘上的修改**不会**影响正在运行的进程。

判断方法：

```sh
ps -o etime= -p <pid>        # 反推启动时刻
stat -c '%y' <改过的文件>     # 修改时刻
```

进程启动早于修改 → 必须重启。这次我差点误判过：用 `stat /proc/<pid>` 的
目录 mtime 当成进程启动时间，得出了相反结论。**用 `ps -o etime=` 反推才准。**

---

## 7. 自动化审计：派子智能体做广度扫描

12 个问题里，有几个是靠人眼扫不出来的（495 个 `package.json` 的平台字段、
`.node` 文件的链接目标、syscall 表覆盖）。

**有效分工**：主线做深度诊断（读代码、复现、打补丁），
同时派一个子智能体做**广度审计**（扫全树找平台门控、glibc/bionic 不匹配、
`os`/`cpu` 字段异常），要求它给出「文件路径 + 行号 + 代码引用」级别的证据，
并把覆盖率（扫了多少个文件）写进报告，让结论可审计。

子智能体带回的一个关键发现是 `node-addon-require-builtin` 在 Android 上抛错——
虽然最后确认它是**0.1.1 就有的老问题、不是本次回归**，
但「是不是回归」这个问题本身就是靠对比新旧两版回答的。

---

## 8. 判断「是不是本次升级引入的」

对每个疑点问一句：**旧版本有同样的问题吗？**

```sh
OLD=<旧版安装目录>/node_modules
grep -n "关键字" "$OLD/包名/lib/index.js"
```

这次靠这个区分出了两类问题：

- **回归**（0.1.6 新引入，必须修）：flock 平台门控、硬链接 Android 分支被删、
  `createProcessInspector` 拒绝 android
- **既有问题**（0.1.1 也有，可修可不修）：`node-addon-require-builtin` 抛错、
  `attachment-local` 的硬链接、ripgrep 缺失

**回归优先修**——否则升级会让本来能用的功能坏掉。

---

## 9. 纪律清单

1. **动手前先建恢复点**（原 tarball 就是最好的完整备份）
2. **改文件前先读它**，改完立刻 `node --check` 语法
3. **不要用 `npm install -g` 直接替换正在服务的安装**——装到独立前缀，
   验证后用两次 `rename` 原子替换
4. **校验不通过就不安装**（`MISSING from tarball: 0` 是硬门槛）
5. **验证要用真实入口**，不是自己写的简化版
   （这次用的是 `saveImageFile` / `prepareImageFile` 本体）
6. **压测，不只跑一次**
7. **修完同步三处**：全局安装、构建树、tarball，
   最后用校验和确认三者一致
