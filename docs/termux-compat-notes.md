# dsh-termux 0.1.6-alpha.1-termux.1 — Termux/Android compatibility record

Device: Termux on Android aarch64, Node v26.4.0 (ABI 147).
`process.platform === "android"`, `process.arch === "arm64"` — **not** `linux`.

Upstream base: `@deepseek-ai/dsh@0.1.6-alpha.1` (the `alpha` dist-tag).
Repack identity: `dsh-termux@0.1.6-alpha.1-termux.1`, same scheme as the previous
`dsh-termux@0.1.1-rc.2-termux.1` install it replaces.

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

**Fail-safe, verified by moving the addon aside:** sharp's loader then falls
through to `@img/sharp-wasm32` and still encodes. So a device without libvips,
or a wiped `src/build`, degrades to the old behaviour instead of breaking.

**Consequence for deployment:** the native addon is only as good as the system
libvips under it. `pkg install libvips` (and its ~28 dependencies) is now part
of the install; `pkg upgrade` of libvips can change the soname and force a
rebuild. The recovery is always `restore-sharp.sh` (wasm32) or a re-run of the
node-gyp command above.

## Verified working after patching

- `dsh --version` → `0.1.6-alpha.1-termux.1`
- `dsh web` boots the full plugin tree and serves the GUI (HTTP 200, 29 KB shell,
  content-hashed frontend asset and combined client-plugin bundle both 200)
- End-to-end `--profile headless` against the DeepSeek official API: the model
  called the bash tool, the command ran, and the exact stdout came back
- Session persistence: `session.lock` created, `session.v3.jsonl.zstd` written
  and decompressing to valid JSONL records
- Native primitives: `node-pty` live PTY spawn, `sharp` PNG encode through
  wasm32, `esbuild` transform, `koffi` load, on-device `flock`

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
3. Re-apply patches 1 and 5 by hand; re-copy 2, 3 and 6; re-check 7, 8, 9 —
   upstream has already dropped the Android branch twice
4. `node pin-manifest.mjs <dir>` then build the tarball with `tar`
5. `scripts/verify-tarball.sh` must report 0 missing before installing
