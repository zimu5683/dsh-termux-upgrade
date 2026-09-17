# Android/Termux Native-Load Audit — `dsh-termux@0.1.6-alpha.1-termux.1`

**Target tree:** `/data/data/com.termux/files/home/dsh-upgrade/build/dsh-termux/node_modules`
**Host:** Termux on Android aarch64 — `process.platform === "android"`, `process.arch === "arm64"`, Node v26.4.0, ABI (`process.versions.modules`) = **147**.

Verified at runtime rather than assumed:

```
$ node -e 'console.log(process.platform, process.arch, process.versions.node, process.versions.modules)'
android arm64 26.4.0 147
```

Everything below was confirmed by reading files, running `readelf`, and executing the modules on this device. Nothing is inferred from package names.

---

## FAILURES

| Package | Version | Why it fails on android-arm64 | Evidence (file : line) |
|---|---|---|---|
| `node-addon-require-builtin` | 0.1.6 | Declares per-platform sibling packages but **no `android-arm64` variant is published or installed**. Its `index.js` calls `createEntryApi(...)` at module top level, which runs `loadEntry()` **synchronously at require time**; every candidate is exhausted (optional package missing, local `build/` absent) and it throws. A bare `require()` throws on this device. | `node-addon-require-builtin/lib/index.js:11` — `const api = createEntryApi(path.resolve(__dirname, '..'))`<br>`node-addon-native-custom-loader/lib/index.js:554` — `const loaded = loadEntry({ packageDir, packagePrefix })`<br>`node-addon-native-custom-loader/lib/index.js:541` — `throw noUsableBindingError(...)`<br>`node-addon-native-custom-loader/lib/index.js:302-304` — `optionalPackageName()` builds `…-android-arm64`<br>`node-addon-native-custom-loader/lib/index.js:413-418` — candidate list is empty → `throw` |

### Proof

The loader is not optional-tolerant. `createEntryApi` runs `loadEntry` eagerly during module evaluation, so the failure is a **hard throw at `require()` time**, not a lazy fallback:

```
$ node -e 'require("node-addon-require-builtin")'
No usable native binding found for node-addon-require-builtin-android-arm64 (auto)
```

`error.attempts` from the same run confirms every resolution path was tried and exhausted:

1. `source: "optional-package"` → `request: "node-addon-require-builtin-android-arm64"` → `MODULE_NOT_FOUND`
   (the package publishes only `-darwin-arm64`, `-darwin-x64`, `-linux-arm64-gnu`, `-linux-x64-gnu`, `-win32-arm64-msvc`, `-win32-x64-msvc`, `-win32-ia32-msvc` — see `node-addon-require-builtin/package.json`, its 7 `optionalDependencies`)
2. `source: "local-build"` → `node-addon-require-builtin/build/nodeabi/node-v147-android-arm64/require_builtin.node` → `MODULE_NOT_FOUND`

Neither an npm-published binary nor a locally compiled one exists, so there is **no Android-satisfiable alternative**. Note the published Linux variants are `-gnu` (glibc) suffixed and would not load against bionic even if present.

### Reachability — this is a LATENT failure, not a startup failure

The default `web` profile **does boot successfully** on this device, because the throwing path is guarded by a config check upstream:

- `@deepseek-ai/dsh-app-boot/lib/index.js:1827` — `if (config.generation === void 0) return;` — the constructor returns early and never calls the loader when no profile-resolution generation is supplied.

The throw becomes live the moment a generation **is** provided. Once past that guard there is **no further tolerance anywhere on the path**:

- `@deepseek-ai/dsh-app-boot/lib/index.js:1828` — `const resolver = installProfileResolution(config.generation, this.behavior);`
- `@deepseek-ai/dsh-app-boot/lib/index.js:1491` — `const { esm, … } = internalModules();` (unconditional)
- `@deepseek-ai/dsh-app-boot/lib/index.js:1423` — `const addon = createRequire(import.meta.url)("node-addon-require-builtin");` (**no `try`/`catch`**)

The same unguarded call is duplicated in the owned-Worker bootstrap:

- `@deepseek-ai/dsh-app-boot/lib/worker/profile-resolution-bootstrap.js:818` — `if (registration !== void 0) installProfileResolution(registration.generation, registration.behavior);`
- `@deepseek-ai/dsh-app-boot/lib/worker/profile-resolution-bootstrap.js:520` → `:452` — `createRequire(import.meta.url)("node-addon-require-builtin")` (**no `try`/`catch`**)

**Impact:** any code path that installs a profile-resolution generation (plugin-package inventory, agent presets, the typert loader, or any owned Worker receiving a generation via `setEnvironmentData`) fails with `No usable native binding found for node-addon-require-builtin-android-arm64`. Boot of the default profile is unaffected.

### Verified boot result

```
$ timeout 45 node lib/bin.js --profile web --port 0 --no-open
dsh web: http://127.0.0.1:33045/?token=RZGGGM9Cw60IAaAhEeqyvGLyTSF9tiCMvvA1fiLeIPA
```

Confirms the default path is healthy and the defect is confined to the generation-gated path.

---

## Graceful degradation

| Package | What is disabled / how it degrades | Evidence |
|---|---|---|
| `sharp` 0.35.4 | **No feature loss.** No Android native build exists; `runtimePlatformArch()` returns `"android-arm64"`, which matches none of the `switch` cases (they are `linux-*`, `darwin-*`, `win32-*`, `freebsd-*`), so control falls through to the wasm32 fallback. Verified working end-to-end (real PNG encode). | `sharp/dist/sharp.cjs:104` — `sharp = require("@img/sharp-wasm32/sharp.node")`<br>`sharp/dist/sharp.cjs:18` — `runtimePlatform = runtimePlatformArch()`<br>verified: `runtimePlatformArch()` → `"android-arm64"`; `sharp({create:…}).png().toBuffer()` → 96 bytes |
| `@vscode/ripgrep` 1.18.0 | Falls back to system `ripgrep` on `PATH` (patched locally). All 12 optional platform packages absent. | Covered by the already-known patch; deferred here per instructions. |
| `@deepseek-ai/node-addon-system` 0.1.2 | Loader documents graceful "unusable" degradation; all 4 optional platform packages absent. | Deferred here per instructions. |
| `cordis-plugin-loader` | Node internals helper is optional: `requireInternal` returns `undefined` when the addon is missing, and `fromInternal()` then leaves the loader unclassified, so consumers take their documented "no-internals" path. The addon failure **is** tolerated here. | `@deepseek-ai/cordis-plugin-loader/lib/index.js:14-16` — `try { return require("node-addon-require-builtin").requireBuiltin(id); } catch {}` |
| `chokidar` 4.0.3 & `tsx` 4.23.13 | `fsevents` (darwin-only, optional) is correctly absent; file watching falls back to polling/`fs.watch`. Neither package references `fsevents` in shipped JS — only in `package.json`/README. | `chokidar/package.json` (no `fsevents` in deps); `rg fsevents chokidar/*.js` → no matches |
| `@deepseek-ai/dsh-subprocess-local` | `postinstall` helper only restores a chmod bit and is `existsSync`-guarded; `spawn-helper` is darwin-only and unused on Android. | `@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs:14-15` — `for (const helper of candidates) { if (existsSync(helper)) chmodSync(helper, 0o755) }`<br>`node-pty/lib/unixTerminal.js:31` (helper used by UnixTerminal) |

---

## Checked and clean

**495 `package.json` files inspected** across the entire tree (every file matching `find . -name package.json`, including nested `node_modules`), plus a runtime smoke test that `require()`-ed **all 453 top-level package names**.

What the scans found:

- **`os`/`cpu` constraints: only 2 packages**, and both target this device exactly:
  - `@esbuild/android-arm64@0.28.2` — `os: ["android"]`, `cpu: ["arm64"]`
  - `@koromix/koffi-android-arm64@3.3.0` — `os: ["android"]`, `cpu: ["arm64"]`

  No package in the tree declares `os: ["linux"]` (or darwin/win32-only) — npm's platform filtering already removed those. **The classic "`os: ["linux"]` on Android" trap does not occur in this tree.**
- **`optionalDependencies`: 7 packages**, all resolved above — `@deepseek-ai/node-addon-system`, `@vscode/ripgrep`, `esbuild`, `koffi`, `node-addon-require-builtin`, `sharp`, `tsx`. Every platform family was checked for an actual on-disk android-arm64 variant.
- **Native binaries: 10 `.node` files**, all accounted for; only `node-pty`'s are non-Android (already handled). **No `build/Release` or `build/Debug` directories exist anywhere** — so no stale glibc-linked artifacts.
- **Prebuilt platform directories** are exactly: `@esbuild/android-arm64`, `@koromix/koffi-android-arm64`, and `node-pty/prebuilds/{android-arm64,darwin-arm64,darwin-x64,linux-arm64,linux-x64,win32-arm64,win32-x64}`.

### Native artifacts verified with `readelf`

| Artifact | Verdict |
|---|---|
| `@esbuild/android-arm64/bin/esbuild` | ELF64 aarch64, **no `NEEDED` entries, no `PT_INTERP`** (static/PIE) → bionic-safe. Executes: `./@esbuild/android-arm64/bin/esbuild --version` → `0.28.2` |
| `@koromix/koffi-android-arm64/android_arm64/koffi.node` | `NEEDED: libm.so, libdl.so, libc.so` → Android/bionic. Loads: `require("koffi").version` → `3.3.0` |
| `node-pty/prebuilds/android-arm64/pty.node` | `NEEDED: liblog.so, libc++_shared.so, libm.so, libdl.so, libc.so` → Android/bionic. Live PTY test: `pty.spawn("/bin/sh", …)` → `PTY_OK_20051`, exit 0 |
| `esbuild/bin/esbuild` | `#!/usr/bin/env node` JS shim (not a binary) — resolves the android-arm64 package |
| `@anthropic-ai/sdk/bin/cli`, `open/xdg-open`, `which/bin/node-which` | `#!/usr/bin/env node` / `#!/bin/sh` scripts — no native code |
| `node-pty/prebuilds/{linux,darwin,win32}-*/`, `spawn-helper` | Non-Android, shipped by upstream; not selected on this platform (already-known item) |

### Functional verification (not just load)

| Package | Test | Result |
|---|---|---|
| `esbuild` 0.28.2 | `transformSync` + `buildSync` | `const x = 1;` / `let a = 1;` ✓ |
| `sharp` 0.35.4 | `create` → PNG encode | 96-byte PNG ✓ (wasm32 path) |
| `koffi` 3.3.0 | `require` + FFI load | `3.3.0` ✓ |
| `node-pty` 1.2.0-beta.15 | live `spawn` of `/bin/sh -c` | `PTY_OK_20051`, exit 0 ✓ |
| `@deepseek-ai/dsh-win32-process` | `require` (Windows-only by name/feature) | loads; koffi bindings resolve lazily and are never invoked on Android ✓ |
| `@deepseek-ai/dsh-subprocess-local` | ESM `import` | loads; exports `LocalSubprocessRuntime`, `default` ✓ |

The smoke test surfaced **21 `require()` failures**, of which exactly **1** is platform-related. The other 20 were individually checked and are **not** Android issues — none declares `os`/`cpu`, and each fails identically on every platform for platform-independent reasons (type-only packages with no `main`, subpath-only `exports` that forbid a bare root import, or ESM-only packages `require()`d as CJS):

`@aws-sdk/nested-clients`, `@babel/runtime`, `@deepseek-ai/dsh-web-frontend`, `@deepseek-ai/node-addon-system`, `@earendil-works/pi-ai`, `@earendil-works/pi-telemetry`, `@esbuild/android-arm64`, `@img/sharp-wasm32`, `@octokit/openapi-types`, `@octokit/openapi-webhooks-types`, `@octokit/types`, `@octokit/webhooks-methods`, `@types/js-yaml`, `@types/node`, `@types/retry`, `@types/ws`, `buffer-equal-constant-time`, `ts-algebra`, `undici-types`, `unicorn-magic`.

---

## Summary

- **1 genuine failure:** `node-addon-require-builtin@0.1.6` — hard throw at `require()` time, no Android-satisfiable alternative. **Latent**, not on the default boot path: it triggers only when a profile-resolution generation is supplied (`dsh-app-boot/lib/index.js:1827` guard).
- **0 glibc-vs-bionic mismatches:** no `build/Release`, and every shipped native binary is either genuinely Android-linked or unused on this platform.
- **0 packages gated by `os`/`cpu` away from Android** beyond the two that target it correctly.
- Everything else either has a real android-arm64 variant on disk or degrades gracefully.
