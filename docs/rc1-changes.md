# 0.1.6-alpha.2 → 0.1.7-rc.1 升级记录

设备：Termux on Android aarch64，Node v26.4.0（ABI 147），`process.platform === "android"`。
上游基线：`@deepseek-ai/dsh@0.1.7-rc.1`（npm `next` tag）。
重打包身份：`dsh-termux@0.1.7-rc.1-termux.1`。

---

## 一、上游变化（影响本机适配的）

| 变化 | 影响 |
|---|---|
| 全部 `@deepseek-ai/dsh-*` → `0.1.7-rc.1`，且依赖从 `^` 范围改为**精确版本** | 无兼容影响；重打包的 pin 策略与上游一致了 |
| **`@deepseek-ai/dsh-experimental-agent-team-web-profile` 停更**（最后版本 0.1.6-alpha.2） | **profile 起不来**。它的能力已并入 `dsh-experimental-agent-team-profile@0.1.7-rc.1`（该包现在自己依赖 `dsh-experimental-client-ui-agent-team`，并自行 insert `ui-agent-team` 行）。`~/.dsh/profiles/web/package.json` 的 bundles 必须从 4 个删到 3 个 |
| **`@deepseek-ai/dsh-agent-presets`（复数）停更**，换成 `dsh-agent-preset` + `dsh-agent-preset-registry` | 预设 roster 的挂载点从 CLI 迁到 `dsh-web-app` |
| **CLI manifest 不再有 `dsh.configTrees` 字段** | 重打包的改名步骤仍可用，但 configTrees 段落消失 |
| `dsh-settings-file`、`dsh-client-ui-settings-unarchive-sessions` 停更 | 新树零引用，`dsh-base` 改用 `@deepseek-ai/dsh-settings`。本机配置无需清理 |
| 新增 `dsh-skill-office`、`dsh-tool-workspace-dependencies`、`dsh-experimental-voice-input-bundle` | 新工具/新 bundle，已纳入工具审计 |
| `@deepseek-ai/cordis` ~4.0.4、`schemastery` ~3.18.4、`cordis-plugin-loader` ~1.0.5、`cordis-plugin-include` ~1.0.9、`cordis-plugin-timer` ~1.1.6 | 配置 schema 未收紧；本机 `cordis.patch.yml` 4 行逐条复验通过 |
| `node-addon-require-builtin` 仍锁 `^0.1.6` | **`--expose-internals` 三件套仍然必需**（见第四节） |
| `node-pty` 仍锁 `1.2.0-beta.15`、`sharp` 仍 `^0.35.3` | 设备编译的 `pty.node` 与原生 sharp 绑定可原样复用 |
| **`dsh --version` 的语义变了** | 见第三节 |

**上游这次没有重构任何一条 Termux 补丁涉及的代码路径** —— 26/26 步锚点原样命中，零 DRIFT。

---

## 二、补丁重导出：13 条文本补丁 / 26 步 / 10 文件

### 计数对账（为什么是 13 条，不是「14 条」）

`alpha2-changes.md` 的「补丁全表（14 项）」里，**4 项是原生二进制**，文本重放器在原理上无法处理：

| 表项 | 实物 | 由谁处理 |
|---|---|---|
| #4 | `node-pty/prebuilds/android-arm64/pty.node` | 构建期复制（设备编译件） |
| #5 | `@img/sharp-wasm32` | 构建期复制 |
| #6 | `sharp/src/build/Release/sharp-android-arm64-*.node` | 构建期复制（设备编译件） |
| #9 | `@deepseek-ai/node-addon-system-android-arm64/` | 构建期复制（设备编译件） |

其余 **10 项是构建期手工打的代码补丁**，加上原本就在重放器里的 **3 条热补丁**（`dsh-fs-local` write、`dsh-attachment-local` publishImmutableAlias、`dsh-web-fetch-http` trustedAddressRanges），共 **13 条文本补丁**。10 + 4 = 14，即那张全表。**没有任何一条被静默丢弃。**

另修正一处长期记录错误：`createProcessInspector` 的补丁实际在 `dsh-subprocess-local/lib/runner-launch-*.js`，**不在** `lib/index.js`（后者与 pristine 逐字节相同）。该文件名每版带哈希（本次从 `DGV26RBf` 变 `B2zsQ1Dz`），重放器改为通配 + 扫描解析，**上游换哈希不再需要人工改脚本**。

### 0.1.7-rc.1 判定

| 项目 | 结果 |
|---|---|
| 文本补丁 | 13 条 / 26 步 / 10 文件 |
| 判定 | **26/26 步「命中」，0 条「需重导」，0 条 DRIFT** |
| 不可恢复的降级 | **无新增** |

### 补丁表是派生的，不是手抄的

`rc1-patchlab/gen-patchdefs.mjs` 从 **pristine 0.1.6 源码**取 `old`、从 **known-good 已打补丁的 0.1.6 产物**取 `neu`，机械提取，然后证明

```
applyPending(pristine, steps) === artifact      （9/9 文件逐字节一致）
```

这消除了「锚点抄错」这一类最危险的失败模式。

### 重放器扩容（本次最大的结构性改进）

**升级前**：`apply-termux-patches.mjs` 只覆盖 **3 条**补丁；另外 10 条是构建期手工打进去的，**没有任何重放器兜底** —— 任何一次 `npm install` / 重打包都会让它们静默消失，而缺陷会在很久以后才暴露。

**升级后**：13 条全部进重放器，并修掉一个潜伏 bug —— 同一文件的多个补丁会用**过期 `src`** 互相覆盖（旧实现在循环里对同一份原始文本反复替换，后一条会把前一条的结果冲掉）。

### 验收（全部 exit 0）

| 命令 | 结果 |
|---|---|
| `apply-termux-patches.mjs --check`（现行安装） | 13/13 ok |
| `verify-patches.mjs` | 84/84 |
| `DSH_PATCH_ORIGIN=origin-0.1.6 verify-patches.mjs` | 94/94（10 文件 pristine 重放逐字节一致） |
| 0.1.7 lab-install + origin-0.1.7-rc.1 | 98/98 |
| `tool-probe.mjs` | 18/18 必需项 |
| builder 暂存树 `--check` / 打包后复跑 | 13/13 ok（幂等） |
| 从**已发布 tarball 内解出**的 10 个文件 `--check` | 13/13 ok |

### lab 七步证明（对真实 0.1.7 源码副本）

```
--check 全 need(13)
  → apply 写 10 文件
  → --check 全 ok(exit 0)
  → 再 apply 逐字节无变化（幂等）
  → --revert 恢复 pristine 逐字节一致 10/10
  → --check 回到 need
  → 再 apply 与首次逐字节相同
```

最强的一步是 `--revert`：不是「锚点找到了」，而是「在真实目标版本上可完全还原」。

---

## 三、`dsh --version` 的语义变更（必读）

| | 0.1.6-alpha.2 | 0.1.7-rc.1 |
|---|---|---|
| 实现 | `lib/bin.js` 的 `readVersion()` 读**自己的 package.json** | `getDshRuntimeVersion()`（`dsh-app-boot/lib/index.js:271`）读 **`@deepseek-ai/dsh-app-boot` 的 package.json** |
| `dsh --version` | `0.1.6-alpha.2-termux.1` | **`0.1.7-rc.1`** |

**这不是回归，而且不能改。** 同一个函数被 `evaluatePluginCompatibility()` 用来校验所有 `@deepseek-ai/dsh-*` 插件的 peer 范围，而这些 peer 写死就是 `"0.1.7-rc.1"`（实测 `dsh-fs-local` peers = `{"@deepseek-ai/cordis":"~4.0.4","@deepseek-ai/dsh-fs":"0.1.7-rc.1"}`）。若把运行时版本强行改成 `0.1.7-rc.1-termux.1`，peer 校验会直接失败、profile 起不来。

所以判据是两条并存：

- `dsh --version` → `0.1.7-rc.1`（**上游运行时版本**，驱动 peer 兼容校验）
- `require('<install>/dsh-termux/package.json').version` → `0.1.7-rc.1-termux.1`（**重打包身份**）

`install-termux.sh` 读的是后者，因此安装脚本不受影响。

---

## 四、`--expose-internals` 仍然承重（调用矩阵实测）

`node-addon-require-builtin` 在 0.1.7 仍锁 `^0.1.6`，而它没有 Android 构建。四条调用方式实测：

| 调用方式 | 结果 |
|---|---|
| npm launcher（走 shebang） | **BOUND**（HTTP 401） |
| `node --expose-internals lib/bin.js` | **BOUND** |
| 直接 exec `lib/bin.js` | **BOUND** |
| `node lib/bin.js`（**丢 flag**） | **NOT BOUND**，进程死于 `dsh: host preparation failed` |

最后一行就是补丁承重的直接证据：`lib/bin.js` 的 shebang 必须是 `#!/usr/bin/env -S node --expose-internals`（`NODE_OPTIONS` 不允许携带该 flag，只能走 shebang）。

---

## 五、制品

| 项目 | 值 |
|---|---|
| 文件 | `dsh-termux-0.1.7-rc.1-termux.1.tgz` |
| 大小 | 55,894,642 B（53.3 MiB） |
| sha256 | `2cda762e25127a690dfc2255eacba00069ed140128ef54b7f94d3543360129ee` |
| 顶层包 | **498**（0.1.6 为 475） |
| 文件条目 | 25,549（与暂存树**完全相等**：缺失 0 / 多余 0） |
| `compare-tree.mjs` | `MISSING from tarball: 0` |
| pin | 498 deps / 498 bundled，全部精确版本 |

原生包版本：node-pty `1.2.0-beta.15` / sharp `0.35.4` / `@img/sharp-wasm32` `0.35.4` / `@deepseek-ai/node-addon-system` `0.1.2`（平台包 0.1.2）/ `@esbuild/android-arm64` `0.28.2` / `@koromix/koffi-android-arm64` `3.3.1` / `@vscode/ripgrep` `1.18.0`。

sharp 绑定文件名由 `runtimePlatformArch()` 的**实测值**推导（本机返回 `"android-arm64"`），不是硬编码猜测。

### npm 12 拦截的 6 个 install script（逐条核实，均无实际影响）

| 包 | 脚本 | 影响 |
|---|---|---|
| `@deepseek-ai/dsh-subprocess-local` | postinstall chmod spawn-helper | 无（macOS 专用；Android 走 forkpty） |
| `@google/genai` | preinstall echo no-op | 无（本来就是空操作） |
| `esbuild` | postinstall | 无（二进制由 `@esbuild/android-arm64` 平台包自带） |
| `koffi` | install cnoke | 无（二进制由 `@koromix/koffi-android-arm64` 平台包自带） |
| `node-pty` | install + postinstall | 无（已手工投放设备编译的 `pty.node`） |
| `protobufjs` | postinstall | 无（运行时不依赖其产物） |

---

## 六、已知降级（既存，非本次引入）

### `@img/sharp-wasm32` 回退链路实际不可用

`@img/sharp-wasm32@0.35.4` 声明 `dependencies: { "@emnapi/runtime": "^1.11.3" }`，但该依赖**在 0.1.6 已发布的 tarball 里同样不存在** —— 也就是说 wasm32 回退在旧版就是死的，实际生效的一直是原生绑定（实测 `sharp.versions` 无 `emscripten`）。

本次实测：补上 `@emnapi/runtime@1.11.3` 后 `require("@img/sharp-wasm32/sharp.node")` 确实能加载，但导出对象**不是可调用函数**（`sharp is not a function`），回退链路依然不可用。按「无法验证的代码不改」原则，本次保持与 0.1.6 的 parity，原样投放该包，并**登记为既存降级**。

**后果**：原生 `sharp-android-arm64-0.35.4.node` 是唯一生效路径。`pkg upgrade` 若改变 libvips soname 会导致它失效，届时图像功能会整体不可用（而不是退化到 wasm32）。恢复方式是重跑 `node-gyp rebuild --nodedir=$PREFIX`（见 `termux-compat-notes.md`）。

> ⚠️ 早期版本的 `termux-compat-notes.md` 写过「把原生 addon 移开，sharp 会退回 wasm32 并仍能编码」——**那个说法在本机是错的**，已在本文件更正。

---

## 七、环境注意：VPN fake-IP 是可变的

本机的 `trustedAddressRanges: [198.18.0.0/15]` 只在 **VPN 的 fake-IP 模式**下才是必需的。

- **VPN 开**：`example.com` → `198.18.0.5/.6`（保留段）→ 被 SSRF 守卫判为非公网 → 需要白名单放行
- **VPN 关**（本次升级期间实测到的状态）：`example.com` → `172.66.147.243 / 104.20.23.154 / ...`（真实公网）→ 白名单**完全惰性**，行为与不配置时逐字节相同

`verify-runtime-behavior.mjs` 的 D3 段已改为**按实测环境分支**（而不是写死一种前提）：

- 实测命中白名单 → 断言「无白名单时被拦」「有白名单时放行」
- 实测未命中 → 断言「stock 策略放行真实公网地址」且「配置的白名单惰性」，并把 fake-IP 断言打印为 SKIP 带实测 DNS 证据

这比原来的无条件断言**更严**（两种网络状态都被覆盖），而不是为了让红变绿。

换网络 / 换 VPN 后重测：

```sh
node -e "require('node:dns/promises').lookup('example.com',{all:true}).then(console.log)"
```

段变了就同步改 `~/.dsh/profiles/web/cordis.patch.yml` 的 `trustedAddressRanges`。

---

## 八、profile / 配置适配

`~/.dsh/profiles/web/package.json`：

```json
"bundles": [
  "@deepseek-ai/dsh-base",
  "@deepseek-ai/dsh-web-app",
  "@deepseek-ai/dsh-experimental-agent-team-profile"
]
```

（删除停更的 `@deepseek-ai/dsh-experimental-agent-team-web-profile`；其 `ui-agent-team` 行现由 `-profile` 包自行 insert。）

`~/.dsh/profiles/web/cordis.patch.yml` 的 4 行**语义未变**，逐条用 0.1.7 schema 复验：

| 行 | 0.1.7 schema 来源 | 结论 |
|---|---|---|
| `permission`（defaultPreset + 预设表收敛） | `dsh-permission-presets@0.1.7-rc.1`：`presets: z.dict({sandbox, approval})`、`defaultPreset: z.string()` | 键名不变 |
| `web-fetch-http.trustedAddressRanges` | 本机补丁新增字段（`dsh-web-fetch-http@0.1.7-rc.1` 的 7 个锚点全部命中） | 有效 |
| `agent-team`（5 键） | `dsh-experimental-agent-team@0.1.7-rc.1`：`maxMembers / maxTasks / maxPendingMessagesPerMember / maxMessageBytes / disposalTimeoutMs` | 键名不变 |
| `subagent`（2 键） | `dsh-subagent@0.1.7-rc.1`：`maxDepth` 默认 1、`maxActiveSubagents` 默认 8 | 键名不变 |

`~/.dsh/settings.yaml` 只校验不改语义：`llm-pi-ai` 三路由 31 个模型、8 组 `reasoningEfforts` 映射全部被 0.1.7 schema 接受。

---

## 九、实测结果

见 `ANDROID-TOOL-AUDIT.md`（全工具可用性矩阵）与本仓库 `docs/` 下的验证报告。
