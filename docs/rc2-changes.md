# 0.1.7-rc.1 → 0.1.7-rc.2 升级记录

设备：Termux on Android aarch64，Node v26.4.0，`process.platform === "android"`。
上游基线：`@deepseek-ai/dsh@0.1.7-rc.2`（npm `next` tag）。
重打包身份：`dsh-termux@0.1.7-rc.2-termux.1`。

---

## 一、上游变化（很小）

| 变化 | 影响 |
|---|---|
| 新增 **`@deepseek-ai/dsh-experimental-auto-review@0.1.7-rc.2`** | 新的实验性自动评审包；在 web 组合里**未被挂载**（审计确认） |
| 72 个 `@deepseek-ai/dsh-*` 从 rc.1 → rc.2 | 无 |
| **没有任何 bundle 停更**（对比 rc.1 那次停了 `-web-profile`） | **profile 的 bundles 完全不用改** |
| `node-addon-require-builtin` 仍锁 `^0.1.6` | `--expose-internals` 三件套仍然必需 |
| `node-pty` 仍 `1.2.0-beta.15`、`sharp` 仍 `0.35.4`、`node-addon-system` 仍 `0.1.2`、`@vscode/ripgrep` 仍 `1.18.0` | 设备编译的 4 个原生件**原样复用**，无需重建 |

**被补丁覆盖的文件里，只有 3 个变了**：`dsh-app-boot/lib/index.js`（84 行）、
`dsh-app-boot/lib/worker/profile-resolution-bootstrap.js`（22 行）、`lib/bin.js`（6 行）
—— 正是 `--expose-internals` 那三条（上游已经为它们重构过两次）。
其余 10 条的源文件与 rc.1 **逐字节相同**。

## 二、补丁复核：13 条 / 26 步 / 零 DRIFT

**先在源码层预检**（构建还没开始就跑）：把 rc.1 与 rc.2 的 pristine 源码逐文件比对，
再把重放器里的 26 个锚点逐个喂给 rc.2 源码：

```
rc.2 patch anchors: 13/13 patches, 26 steps, drift=0
```

**再在真实暂存树上验**（权威闸门）：

```
--check BEFORE apply : 13 patch(es) missing   (全 PENDING，零 DRIFT)
apply                : Done: 10 file(s)
--check AFTER apply  : All patches are in place.  exit 0
```

上游没有重构任何被补丁覆盖的代码路径，**这次不需要重新推导任何一条**。

## 三、制品

| 项目 | rc.1 | rc.2 |
|---|---|---|
| 文件 | `dsh-termux-0.1.7-rc.1-termux.1.tgz` | `dsh-termux-0.1.7-rc.2-termux.1.tgz` |
| 大小 | 55,894,642 B | **61,515,270 B** |
| sha256 | `2cda762e…0129ee` | **`662a887dd2bc409231f8f1fedb8b0453976b894cf793d5fd88328796fad81c31`** |
| 顶层包 | 498 | **508** |
| `compare-tree.mjs` | `MISSING: 0` | **`MISSING: 0`** |

npm 12 仍拦截同样 6 个 install script（`dsh-subprocess-local` / `esbuild` / `koffi` /
`node-pty` / `@google/genai` / `protobufjs`），逐条影响仍为无 —— 原生二进制分别来自
`@esbuild/android-arm64`、`@koromix/koffi-android-arm64` 平台包与设备编译件。

### 构建期间踩到的一个坑

第一次 `npm install` 报：

```
npm error notarget No matching version found for
  @deepseek-ai/dsh-experimental-voice-input-bundle@0.1.7-rc.2
```

**该版本其实已发布**（`next` tag 就指向它）。这是 npm 缓存了 rc.2 发布前的 packument。
用 `--prefer-online` 重跑即成功（`added 524 packages in 4m`）。

教训：`npm install` 报 `ETARGET` 时，先 `npm view <pkg>@<ver> version` 复核，
不要直接判定上游漏发。另外这次日志用管道写文件导致 `$?` 是 `tail` 的退出码，
把失败记成了成功 —— 记退出码要用 `${PIPESTATUS[0]}`。

## 四、实测结果

| 闸门 | 结果 |
|---|---|
| `dsh --version` | `0.1.7-rc.2`（上游运行时版本）；manifest `0.1.7-rc.2-termux.1` |
| `--dump-config` | **exit 0 / stderr 0 字节 / 185 行**（rc.1 是 180） |
| `tool-probe.mjs` | **18/18 required，exit 0** |
| `verify-patches.mjs` | **88/88，exit 0** |
| `verify-runtime-behavior.mjs` | **23 passed / 0 failed，exit 0** |
| 隔离实例 GUI | BOUND；首页 **200 / 34,863 B**；**4/4 资源 200**（含 629 KB 与 740 KB 两个 bundle） |
| 会话落盘 | `session.v4.jsonl.zstd`，**15/15 帧**，47,967 B，**34 条合法 JSON，0 非法**；同一文件 naive 解码只给 **214 B / 1 行**（多帧陷阱复现） |
| 端到端（真实模型） | bash 写入 → 读取 → `cat`，`proof.txt` = `RC2-A12-77`，模型最后一行**精确一致** |
| 全工具审计 | **185 行：可用 182 / 平台不适用 2 / 已知降级 1 / 损坏 0**，exit 0 |

### 工具 roster 对比 rc.1

| | rc.1 | rc.2 |
|---|---|---|
| 组合行数 | 180 | **185** |
| 新增行 | — | `llm-deepseek-account`、`time-context`、`schedule`、`shortcuts`、`ui-shortcuts` |
| 删除行 | — | **0** |
| **模型可见工具名** | **28** | **28（完全一致）** |
| `tool-execute` / `service-call` / `plugin-mount` / `preset-roster` | 5 / 3 / 8 / 1 | **5 / 3 / 8 / 1（一致）** |
| 损坏 | 0 | **0** |

**结论：rc.2 新增的 5 行全是 UI/配置行，模型能用的 28 个工具一个没多、一个没少。**

## 五、profile 状态（本次特别注意）

rc.1 升级之后（2026-09-24 14:20–14:26，以及 09-26 00:36），本机的配置发生了一次
**架构性迁移**：模型路由从 `~/.dsh/settings.yaml` 搬进了 profile 的 `cordis.patch.yml`，
`settings.yaml` 被改名为 `settings.yaml.imported` 退役。

现在 `~/.dsh/profiles/web/cordis.patch.yml` 承载 **7 行**：

| # | 行 | 作用 |
|---|---|---|
| 1 | `permission` | 沙箱预设收敛为仅 `danger-full-access` |
| 2 | `web-fetch-http` | `trustedAddressRanges: [198.18.0.0/15]` |
| 3 | `agent-team` | `maxMembers: 16` 等 5 键 |
| 4 | `subagent` | `maxActiveSubagents: 8` / `maxDepth: 1` |
| 5 | `agent-default-model` | `opencode-go` / `deepseek-v4.1-flash` / `reasoningEffort: max` |
| 6 | `llm-pi-ai` | **31 个模型 / 3 条路由**（opencode-go、-messages、-responses） |
| 7 | `ui-settings-general` | `welcomeNoticeVersion` |

**所以 rc.2 的替换脚本只换安装树，绝不写 profile。** 目标脚本 `perform-swap-rc2.sh` 会：

1. 备份 profile（只读快照 + sha256），**不修改**；
2. 断言 bundles 恰好 3 个且不含已停更的 `-web-profile`；
3. 断言关键行（`llm-pi-ai` / `agent-default-model` / `permission` / `web-fetch-http`）在位
   —— **行数不写死**（这个文件在 09-26 00:36 还被改过），改为运行时快照；
4. 替换前后比对**行集合 + 内容 sha256**，并发编辑会被抓出来并中止。

实测替换后 profile 的 sha256 与替换前**完全相同**：
`7c1db2290d3d284af39b426e0db24393eaa75e7666524043536ef95689c16581`。

> 教训：上一次（rc.1）的 `perform-swap.sh` 会拿 `~/dsh-upgrade/rc1-profile/` 覆盖线上 profile。
> 如果这次直接复用它，会**静默销毁 31 个模型配置**。升级脚本必须假设「用户在上次升级之后
> 又改过配置」，而不是假设「上一次我写的版本还是最新的」。

## 六、回滚

```
$PREFIX/lib/node_modules/dsh-termux.old-20260926-010301  -> 0.1.7-rc.1-termux.1
~/dsh-upgrade/dsh-termux-0.1.7-rc.1-termux.1.tgz
~/.dsh/profiles/web/backup-swap-20260926-010301/          （profile 快照，从未被写回）
```
