# 0.1.6-alpha.1 → 0.1.6-alpha.2 升级记录

## 上游变化（影响补丁的）

| 变化 | 影响 |
|---|---|
| `@deepseek-ai/cordis-plugin-hmr` **被移除**，换成新的 `@deepseek-ai/dsh-hmr` | 补丁 #1（HMR 门控）**失效**——它改的 `lib/profile-boot-*.js` 里已无 HMR 代码 |
| `watchUserPatches` 从 `dsh-app-boot` 移除 | 同上 |
| HMR 改由 `dsh-base/cordis.patch.yml` 挂载（`disabled: !!js "!ctx.get('profileContext')"`） | HMR 变成**默认开启**，无法再从 profile-boot 门控 |
| `node-addon-require-builtin` 从「潜伏」变成**启动路径上的硬失败** | 见下 |
| 新增包：`dsh-hmr`、`dsh-plugin-manager`、`dsh-atomic-write`、`dsh-experimental-agent-team-*` | 无兼容影响 |
| 全部 `@deepseek-ai/dsh-*` → `0.1.6-alpha.2` | — |

**上游没有修任何一项 Termux 兼容问题**，除 #1 因重构而失效外，其余 11 项全部需要重新应用。

## 新的启动阻断（alpha.2 引入）

不加任何处理时启动直接失败：

```
dsh: host preparation failed: No usable native binding found for
     node-addon-require-builtin-android-arm64 (auto)
```

链路：`dsh-app-boot` 的 `internalModules()` 直接 `require("node-addon-require-builtin")`，
该 addon 无 Android 构建、require 时即抛错。它被 `installProfileResolution()` 调用，
而后者由 `PluginPackages` 构造时触发——**没有任何降级路径**。

### 尝试过但无效

- `--expose-internals` 单独加**不够**：`cordis-plugin-loader` 的 `requireInternal`
  会先检查这个 flag，但 `dsh-app-boot` 的 `internalModules()` 是**直接**调 addon 的，
  不检查 flag。

### 有效修复（两条一起）

**A. 让 `internalModules()` 优先走 `--expose-internals`**（主机端 + Worker 端各一处）

```js
const require = createRequire(import.meta.url);
const builtin = process.execArgv.includes("--expose-internals")
    ? (id) => require(id)
    : (id) => require("node-addon-require-builtin").requireBuiltin(id);
const esmModule = builtin("internal/modules/esm/loader");
// …其余四个同理
```

- 主机端：`dsh-app-boot/lib/index.js` 的 `internalModules()`
- Worker 端：`dsh-app-boot/lib/worker/profile-resolution-bootstrap.js` 的 `internalModules()`
  （Worker 默认继承 `process.execArgv`，flag 会传过去）

**B. 让启动器带上这个 flag**：`lib/bin.js` 的 shebang 改为

```js
#!/usr/bin/env -S node --expose-internals
```

`env -S` 在 Termux 可用；`NODE_OPTIONS` **不允许**携带 `--expose-internals`，只能走 shebang。

### 为什么这条修复同时解决了 HMR

`dsh-hmr` 构造函数要求 `ctx.loader.internal`，否则抛
`--expose-internals is required for HMR service`。而 `loader.internal` 由
`cordis-plugin-loader` 的 `requireInternal` 填充——它同样优先走 `--expose-internals`。
所以补上 flag 后，HMR 也自然可用，**不再需要禁用 HMR**。

### 已验证 `--expose-internals` 在 Termux 上完整可用

```
✅ internal/modules/esm/loader      ✅ internal/modules/cjs/loader
✅ internal/modules/helpers         ✅ internal/modules/esm/utils
✅ internal/modules/esm/resolve
modern (v2 形态) = true；app-boot 断言的 6 个接口全部存在
```

## alpha.2 补丁全表（14 项）

| # | 位置 | 说明 |
|---|---|---|
| 1 | `dsh-app-boot/lib/index.js` | `internalModules()` 优先 `--expose-internals` **【新】** |
| 2 | `dsh-app-boot/lib/worker/profile-resolution-bootstrap.js` | 同上（Worker 端）**【新】** |
| 3 | `lib/bin.js` | shebang 加 `--expose-internals` **【新】** |
| 4 | `node-pty/prebuilds/android-arm64/pty.node` | 设备编译的 Android PTY 绑定 |
| 5 | `@img/sharp-wasm32` | wasm 回退（原生 sharp 的安全网） |
| 6 | `sharp/src/build/Release/*.node` | 原生 sharp（设备编译） |
| 7 | `@vscode/ripgrep/lib/index.js` | 系统 `rg` 回退 |
| 8 | `node-addon-system/lib/flock.js` | 平台判断放行 `android` |
| 9 | `node-addon-system-android-arm64/` | 设备编译的 flock 绑定（0.1.2，与 alpha.1 同版可复用） |
| 10 | `dsh-session-persistence-jsonl` | 硬链接 → `copyFile+EXCL` |
| 11 | `dsh-session-persistence-jsonl` | 硬链接 → `rename` |
| 12 | `dsh-attachment-local` | 硬链接 → `copyFile+EXCL` |
| 13 | `dsh-attachment-local` | durability 遍历的 EACCES 边界 |
| 14 | `dsh-subprocess-local` | `createProcessInspector` 放行 `android` |

注意：alpha.1 的补丁 #1（profile-boot 的 HMR 门控）在 alpha.2 中**已无对应代码**，
被上面的 #1–#3 取代。

## alpha.2 实测结果

| 项目 | 结果 |
|---|---|
| `dsh --version` | `0.1.6-alpha.2-termux.1` |
| `dsh web` 启动 | ✅ 无报错 |
| GUI | ✅ 首页 200/31KB、前端资源 200/616KB、177 个客户端插件 |
| 端到端 headless | ✅ LLM 调用 + bash 工具执行 + 输出回传 |
| 会话落盘 | ✅ 27 条记录，类型完整，`session.lock` 已建 |
| 图片上传 | ✅ PNG/JPEG/WebP 全通过；连续 20 张 12MP 无退化，RSS 214MB |
| 极简模式 PTY shell | ✅ inspector 构造成功，前台进程组跟踪正常 |
| 打包完整性 | ✅ 475 包，0 缺失 |
