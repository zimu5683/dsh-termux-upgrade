# dsh-termux 0.1.7-rc.1-termux.1 — Termux/Android compatibility record

Device: Termux on Android aarch64, Node v26.4.0 (ABI 147).
`process.platform === "android"`, `process.arch === "arm64"` — **not** `linux`.

Upstream base: `@deepseek-ai/dsh@0.1.7-rc.1` (the `next` dist-tag).
Repack identity: `dsh-termux@0.1.7-rc.1-termux.1`, same scheme as the previous
`dsh-termux@0.1.6-alpha.2-termux.1` install it replaces.

> 本文件描述补丁的**根因与证据**，对每个版本都成立。
> 版本相关的升级记录另见 [`alpha2-changes.md`](alpha2-changes.md) 与 [`rc1-changes.md`](rc1-changes.md)。
> **从 rc.1 起，下面全部 13 条文本补丁都进了幂等重放器 `apply-termux-patches.mjs`** ——
> 以前只有 3 条有兜底，另外 10 条会在任何一次重打包后静默消失。

## Packaging model (unchanged from the 0.1.1 repack)

Every top-level package of the resolved tree is pinned to an exact version and
listed in both `dependencies` and `bundledDependencies` (452 packages), so
`npm install -g <tarball>` vendors the whole tree: no registry access, no
dependency resolution, and no native rebuild on the device.

`npm pack` cannot produce this tarball. Its bundler prunes packages that are
reachable only through `peerDependencies` edges — 14 packages, including the
load-bearing `@deepseek-ai/dsh-settings`, `@deepseek-ai/dsh-session-query` and
`@deepseek-ai/dsh-bash-local`, were silently dropped, and the profile then failed
to boot with `ERR_MODULE_NOT_FOUND`. The tarball is therefore built with `tar`
directly, and `verify-tarball.sh` asserts that every staged package is present.

## Patches applied

| # | Package / file | Why Android needs it |
|---|---|---|
| 1 | `lib/profile-boot-CuwbWsnH.js` | Upstream loads `cordis-plugin-hmr` and its file watchers unconditionally whenever `patchReload === "live"` (the `web` profile). `cordis-plugin-hmr` throws `"--expose-internals is required for HMR service"` without that Node flag, so a plain `dsh web` would fail. The 0.1.1 repack gated this on `process.execArgv.includes("--expose-internals")`; the same gate is ported here. |
| 2 | `node-pty/prebuilds/android-arm64/pty.node` | The published tarball ships darwin/linux/win32 prebuilds only, and its `install` script falls back to `node-gyp rebuild`. This is the same device-built bionic binary the 0.1.1 install uses (identical package version 1.2.0-beta.15), so the terminal keeps working. Verified by a live `pty.spawn`. |
| 3 | `@img/sharp-wasm32` | No Android build of sharp exists. `runtimePlatformArch()` returns `android-arm64`, matches no case in `sharp/dist/sharp.cjs`, and falls through to the documented last-resort `@img/sharp-wasm32` fallback. Installed at the matching 0.35.4. Without it `require("sharp")` throws and `dsh-attachment-local` loses image handling. |
| 4 | `@vscode/ripgrep/lib/index.js` | No `@vscode/ripgrep-android-arm64` is published, so `rgPath` threw and the harness's `grep` tool failed with "ripgrep launch failed" — **this was already broken on 0.1.1**. The loader now falls back to a system `rg` on `PATH` (`pkg install ripgrep`); `DSH_RIPGREP_PATH` overrides. ripgrep 15.2.0's `--json` protocol matches what the tool parses. |
| 5 | `@deepseek-ai/node-addon-system/lib/flock.js` | `loadBinding()` rejected every platform except `linux`/`darwin`, so session persistence died with `flock is not supported on android-arm64`. Android is Linux and bionic exports `flock(2)`, so the guard now accepts `android`. |
| 6 | `@deepseek-ai/node-addon-system-android-arm64/` | The platform package the patched loader resolves. Built **on-device** from the same package's own `src/flock.c`: `clang -shared -fPIC -O2 -o bin/system.node src/flock.c -I$PREFIX/include/node`. Verified for acquire, `EAGAIN` contention, and re-acquire after release. |
| 7 | `@deepseek-ai/dsh-session-persistence-jsonl` (`publishCurrentExclusive`) | Publishes a staged generation with `fs.link` as an atomic create-if-absent. Android refuses hard links in app data with `EACCES`, and the error is not `EEXIST`, so it propagated and aborted the write. Android now uses `copyFile` with `COPYFILE_EXCL`, which keeps all three properties the caller relies on. |
| 8 | `@deepseek-ai/dsh-session-persistence-jsonl` (`materializePosix`) | Same hard-link problem. This restores the exact `if (process.platform === "android") await rename(tmp, finalPath)` branch the 0.1.1 repack carried at this site; 0.1.6 had dropped it. |
| 9 | `@deepseek-ai/dsh-attachment-local` (`publishStagedObject`) | Same hard-link problem for attachment blobs. Also broken on 0.1.1 (no Android branch there either). Same `copyFile` + `COPYFILE_EXCL` treatment. |
| 10 | `@deepseek-ai/dsh-subprocess-local` (`createProcessInspector`) | **This is what broke bash in 极简模式.** The factory accepted only `linux`/`darwin`/`win32` and threw `subprocess-local: terminal inspection is unsupported on platform android` for anything else, so every tool call in the `minimal` preset came back with that error as its result. `minimal` is the only preset that drives the shell through this inspector — it uses `dsh-tool-bash-persistent`, a PTY-backed persistent shell, while every other preset uses `dsh-tool-bash`. Android is Linux and `LinuxProcessInspector` reads only `/proc` (`stat`, `task/*/syscall`, `fd`, `mem`), with `SYSCALLS.arm64` already carrying the correct arm64 numbers, so `android` now takes the same branch. |
| 11 | `@deepseek-ai/dsh-attachment-local` (`ensureDurableDirectory`) | **This is what broke every photo upload.** `ensureDurableHome` passes `parse(home).root` — the filesystem root — as the durability boundary, so this walk fsyncs every ancestor up to `/`. On Android an app cannot open `/data/data`, `/data` or `/`, so it died with `EACCES: permission denied, open '/data/data'` before a single byte was staged. An ancestor this process cannot write to is not ours to make durable (the OS owns it and journaled it before this process existed), so it now ends the walk there. A directory we *can* write but cannot open still throws, so a genuine permission fault inside our own tree is never masked. |

## Image uploads: the wasm32 ceiling, and the native build that replaced it

Patch 11 removed the unconditional failure, but `sharp` on Android has no
published native build, so it fell through to `@img/sharp-wasm32`, whose
emscripten heap **grows monotonically and never shrinks**. Measured with
4000x3000 (12 MP) JPEGs through the real `prepareImageFile` entry point:

- the first 3-4 images normalised fine, then conversion failed permanently
- RSS climbed to ~2 GB while the JS heap stayed at ~10 MB — wasm-heap growth,
  not a JS leak; `sharp.cache(false)` and `sharp.concurrency(1)` did not help
- after exhaustion, images needing no rescale still passed (a 1080x2400
  screenshot, 2.6 MP, is under the 4.2 MP normalisation limit) while anything
  requiring a downscale failed until the process restarted

### Native sharp, built on-device (patch 12)

No source changes were needed: sharp already ships a global-libvips path, and it
selected it automatically here.

1. `pkg install libvips` — Termux has **8.18.6**, and sharp 0.35.4's
   `minimumLibvipsVersion` is **also 8.18.6**, so `useGlobalLibvips()` returns
   true on version equality. The package ships the C++ headers
   (`vips-cpp`, `VImage8.h`, `VConnection8.h`) sharp's sources need.
2. Because `useGlobalLibvips()` is true, `src/binding.gyp` takes its
   `use_global_libvips == "true"` branch and resolves libvips through
   `pkg-config` (`--cflags-only-I vips-cpp vips glib-2.0`, `--libs vips-cpp`),
   defining `SHARP_USE_GLOBAL_LIBVIPS`. The empty
   `@img/sharp-libvips-dev-*` include/lib vars are never consulted on this path.
3. Build:
   `node-gyp rebuild --nodedir=$PREFIX` in `node_modules/sharp/src`, with
   `$PREFIX/include/node` supplying the headers. It emits
   `src/build/Release/sharp-android-arm64-0.35.4.node` — exactly the name
   sharp's loader probes *first*, ahead of every wasm path.

Verified on-device:

| | wasm32 | native (built here) |
|---|---|---|
| 20x 12 MP JPEG | 3 ok / 17 fail (first failure #4) | **20 ok / 0 fail** |
| RSS after the run | ~2 GB, never released | **131 MB, released** |
| 24 MP / 48 MP | fail | **ok** |
| PNG / JPEG / WebP / GIF | ok | ok |
| 3x 12 MP wall time | — | 2.4 s |

`sharp.versions` now reports `{vips: 8.18.6, sharp: 0.35.4}` with no
`emscripten` key, and `readelf -d` shows the addon linked against
`libvips.so.42` / `libvips-cpp.so.42` plus bionic `liblog`/`libc++_shared`.

**Fail-safe, verified by moving the addon aside:** ⚠️ **这个说法在本机是错的，已于 2026-09-24 更正。**
实测 `@img/sharp-wasm32@0.35.4` 声明 `dependencies: { "@emnapi/runtime": "^1.11.3" }`，而该依赖
**在 0.1.6 已发布的 tarball 里同样不存在**，所以 wasm32 回退从那时起就是死的。补上
`@emnapi/runtime` 后模块能加载，但导出对象不是可调用函数（`sharp is not a function`），
回退链路依然不可用。

**结论**：原生 `sharp-android-arm64-*.node` 是**唯一**生效路径。移动它不会退化到 wasm32，
而是图像功能整体失效。恢复方式只有重跑下面的 node-gyp 命令。
（依据「无法验证的代码不改」，本次升级保持与 0.1.6 的 parity，未引入 `@emnapi/runtime`。）

**Consequence for deployment:** the native addon is only as good as the system
libvips under it. `pkg install libvips` (and its ~28 dependencies) is now part
of the install; `pkg upgrade` of libvips can change the soname and force a
rebuild. The recovery is always `restore-sharp.sh` (wasm32) or a re-run of the
node-gyp command above.

## Verified working after patching

（以下为 **0.1.7-rc.1-termux.1** 的实测结果；0.1.6 的历史结论见 `alpha2-changes.md`。）

- `dsh --version` → `0.1.7-rc.1`（**上游运行时版本**，见 `rc1-changes.md` 第三节；
  重打包身份看 `package.json` → `0.1.7-rc.1-termux.1`）
- `dsh web` boots the full plugin tree and serves the GUI（隔离实例实测：BOUND，
  根 HTTP 200 / 33,582 B，10/10 前端资源 200）
- **调用矩阵**：npm launcher / `node --expose-internals lib/bin.js` / 直接 exec `lib/bin.js`
  三种都能起；`node lib/bin.js`（丢 flag）失败 —— 证明 `--expose-internals` 补丁承重
- Session persistence: `session.lock` created, `session.v4.jsonl.zstd` written
  （**格式从 v3 升到 v4**），多帧 zstd 逐帧解压得到 21–22 条合法 JSONL 记录；
  同一文件用 naive 解码器只得到 210 B / 1 行
- 图片：`sharp` 原生绑定（vips 8.18.6，无 `emscripten`），连续 20 张 12MP 两轮
  raw+encoded 逐字节一致，RSS peak 209 MB
- 极简模式：`LinuxProcessInspector` 构造成功，前台进程组跟踪正确，SIGINT 精确命中
- Native primitives: `node-pty` live PTY spawn（真机 `/dev/pts/*`）、`esbuild` transform、
  `koffi` load、on-device `flock`（acquire → EAGAIN 争用 → 释放后再取）
- 打包：498 包，25,549 文件条目与暂存树**完全相等**（缺失 0 / 多余 0）

### Patch 10 evidence (the 极简模式 bash failure)

`createProcessInspector()` now returns a `LinuxProcessInspector` on `android`.
Exercised against the real `/proc` on this device:

- `snapshot().rows` reads the process table (self + spawned child, with correct
  `parentPid`/`started`/`session`/`state`), `isAlive` flips to `false` after
  `SIGKILL`, `snapshot().tree(pid)` walks the tree.
- Against a live PTY shell, `foregroundPgid(shellPid)` returns the shell's own
  process group, and while a command runs it correctly tracks the foreground
  group moving to the child (`14260` → `14266`). This is the readiness signal
  the persistent-shell loop settles on.
- `/proc/<pid>/task/<tid>/syscall` is readable for own children, and a bash
  `read` reports syscall `63` with arg0 `0` — exactly `SYSCALLS.arm64.read`
  and the `a0 === 0` stdin test.

One residual, and it is **not** Android-specific: Termux's `cat` blocks in
syscall `76` (`vmsplice`-style zero-copy copy) rather than `63`, which
`syscallWaitsOnStdin` does not match, so `isStdinWaiting` reports `false` for
it. That only costs the secondary "exact probe" settle path; the primary
prompt/foreground-group path and the idle-silence fallback both still fire, so
the shell settles normally. The same gap exists on any arm64 Linux.

## Restart requirement

Edits to files under the installation take effect only when the `dsh web`
process is restarted: Node has the old modules in memory. After applying patch
10 the running server still answered every 极简模式 bash call with the old
error until restarted.

## Known, deliberate degradations (not regressions)

- `@deepseek-ai/node-addon-system` landlock launcher: no Android platform
  package, so `probe()` reports `unusable` by design and the sandbox runs
  unconfined. This matches the `danger-full-access` policy in use.
- `node-addon-require-builtin`: throws on Android with no satisfiable
  alternative, which disables the profile-resolution generation path. **This is
  not new**: 0.1.1's `node-addon-require-builtin@0.1.5` throws identically. The
  `web` and `headless` profiles boot without it.
- `@deepseek-ai/dsh-subprocess-local`'s postinstall only chmods a macOS
  `spawn-helper`; a no-op here. npm 12 blocks install scripts by default, which
  is harmless for the rest (koffi 3.3.0 resolves its Android prebuilt from
  `@koromix/koffi-android-arm64`, esbuild from `@esbuild/android-arm64`).

## Rebuilding after a future upstream release

1. `npm pack @deepseek-ai/dsh@<version>` and stage it as `dsh-termux@<version>-termux.1`
2. `npm install` in the staging dir (npm picks the android-arm64 optional deps)
3. **Apply every text patch through the replayer — no hand editing:**
   ```sh
   DSH_INSTALL_ROOT=<staging>/dsh-termux node apply-termux-patches.mjs
   DSH_INSTALL_ROOT=<staging>/dsh-termux node apply-termux-patches.mjs --check   # exit 0, zero DRIFT
   ```
   If `--check` reports **DRIFT**, upstream changed a code path this patch depends on.
   Re-derive that patch in `gen-patchdefs.mjs` (take `old` from the pristine source and
   `neu` from a known-good artifact, then let it prove `applyPending(pristine) === artifact`)
   — do not hand-edit the anchors, and do not delete the patch to make the check pass.
4. Re-copy the four native binaries: `node-pty` `pty.node`, native `sharp` `.node`,
   `@img/sharp-wasm32`, `node-addon-system-android-arm64`. Check each package version first —
   a version bump means the binary must be rebuilt (`node-gyp rebuild --nodedir=$PREFIX`).
5. `node pin-manifest.mjs <dir>` then build the tarball with `tar` (**not** `npm pack`)
6. `scripts/compare-tree.mjs` must report `MISSING from tarball: 0`, then `verify-tarball.sh`
7. Install into an isolated prefix first, run `tool-probe.mjs` / `verify-patches.mjs` /
   `verify-runtime-behavior.mjs` / `tool-audit.mjs` against it, and only then swap the global tree
8. Remember `~/.dsh/profiles/web/package.json`: the **bundle list changes with upstream
   releases**. rc.1 retired `@deepseek-ai/dsh-experimental-agent-team-web-profile` and the
   profile must list exactly the bundles that still exist, or the profile fails to compose.

### rc.1 的经验：上游这次没有重构任何被补丁覆盖的代码路径

26/26 步锚点原样命中、零 DRIFT。但这**不代表可以跳过重放** ——
补丁在包内，`npm install` 会覆盖它们。真正的纪律是「每次升级都跑一遍重放器 + `--check`」，
而不是「上次打过了这次应该还在」。
