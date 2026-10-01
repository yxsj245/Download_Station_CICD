# Download_Station_CICD（上传中继共享 CICD）

把「构建产物 → 上传中继（Storage Relay）→ 多目标存储分发」这件事从各个项目里抽出来，做成一个独立可复用的 CICD 仓库。

其它项目只需要在自己的 workflow 里写几行 `uses:`，就能复用同一套上传逻辑、同一套统一路径规范、同一套调用方式；上传行为要改，只改这个仓库。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| [scripts/relay-upload.sh](scripts/relay-upload.sh) | 唯一的上传实现：登记统一路径 → 解析 file_id → 上传正文 → 轮询终态，任何 CI 或本地都能直接跑 |
| [relay-upload/action.yml](relay-upload/action.yml) | composite action：在调用方自己的 job 里就地调用，产物不需要 artifact 往返 |
| [.github/workflows/relay-upload.yml](.github/workflows/relay-upload.yml) | reusable workflow：调用方只写几行，产物通过 artifact 交接 |
| [tests/run-selftest.sh](tests/run-selftest.sh) | 端到端自测：拉起模拟中继，覆盖成功与全部失败分支 |
| [tests/mock-relay.py](tests/mock-relay.py) | 模拟中继（仅自测用，不参与部署） |
| [tests/check-yaml.py](tests/check-yaml.py) | workflow / action 的 YAML 结构自检 |
| [.github/workflows/selftest.yml](.github/workflows/selftest.yml) | 在 CI 里跑上面两项自测 |
| [docs/usage.md](docs/usage.md) | 完整使用文档：参数表、退出码、排错、维护者手册 |
| [docs/README.md](docs/README.md) | 从中继项目剪存的接口参考（登记 / resolve / 上传 / 轮询契约与示例脚本），属项目原文，本仓库未作改动 |

## 两种调用形态

| 形态 | 适用场景 | 凭证来源 |
| --- | --- | --- |
| reusable workflow（推荐） | 调用方只想写几行；构建产物通过 artifact 交接 | 调用方传入 `RELAY_ADMIN_KEY` / `RELAY_UPLOAD_KEY`（建议组织级 secret），**本仓库不保存任何中继密钥** |
| composite action | 构建与上传强耦合，希望同一个 job 内直接传文件 | 同上，通过 `with:` 传入（composite action 运行在调用方 job 里） |

## 快速接入（reusable workflow）

### 第一步：本仓库侧配置（一次性）

1. **可见性**：本仓库需要是 **public**。private 的个人账号仓库只能被同账号的仓库引用，`QVMConsole`、`GSManagerXZ` 这类组织的仓库引用不到（原因见「调用权限」的平台层说明）。
2. **不要在这里配置中继密钥**：本仓库不保存任何凭证。public 仓库的 workflow 任何人都能引用（连历史提交都能）。需要说清楚的是：本仓库的普通（repository）secret 并不会外泄给调用方，**真正的风险路径是 environment**——job 一旦挂上 environment，那里的同名 secret 会**覆盖**调用方传入的值，从而被外部调用者借用。所以这里既不配 secret，也不建 environment。密钥一律由调用方自己持有。
3. **稳定标签**：创建并维护 `v1` 标签，调用方统一写 `@v1`。

```bash
git tag -f v1 && git push -f origin v1
```

### 第二步：调用方侧配置（每个组织配一次）

在组织级配置 **Organization secrets** `RELAY_ADMIN_KEY`（中继的 `SR_ADMIN_API_KEY`，登记统一路径必须用它）与 `RELAY_UPLOAD_KEY`（中继的 `SR_UPLOAD_API_KEY`），可见范围选 All repositories 或指定仓库；再配一个 **Organization variable** `RELAY_BASE`（中继对外地址，不带尾斜杠）。

这样密钥轮换只改一处，组织下所有仓库共用；调用方 workflow 里写 `secrets: inherit` 即可。

> 密钥纪律：中继密钥不要写进仓库文件、日志或构建产物；本 CICD 的「凭证来源自检」只报告是否取到，从不打印值。
> 首次接入建议先跑一次 `dry-run: 'true'`：只校验调用权限、参数与统一路径，不发任何请求。

### 第三步：调用方仓库的 workflow

```yaml
name: 发布
on:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: 构建产物
        run: ./build.sh          # 产出 dist/app.zip
      - uses: actions/upload-artifact@v7
        with:
          name: dist
          path: dist/

  upload:
    needs: build
    uses: yxsj245/Download_Station_CICD/.github/workflows/relay-upload.yml@v1
    with:
      artifact-name: dist
      file: app.zip
      logical-path: releases/${{ github.event.repository.name }}/${{ github.ref_name }}/app.zip
    secrets: inherit          # 把组织级 / 仓库级的中继密钥传进去
```

跑完在 Summary 里可以看到统一路径、task_id、SHA-256 以及各渠道结果。

### 就地调用（composite action）

```yaml
      - name: 构建
        run: ./build.sh

      - name: 上传到中继
        uses: yxsj245/Download_Station_CICD/relay-upload@v1
        with:
          relay-base: ${{ vars.RELAY_BASE }}
          admin-key: ${{ secrets.RELAY_ADMIN_KEY }}
          upload-key: ${{ secrets.RELAY_UPLOAD_KEY }}
          file: dist/app.zip
          logical-path: releases/my-app/${{ github.ref_name }}/app.zip
```

composite action 运行在调用方自己的 job 内，凭证同样由调用方提供：把 `RELAY_BASE` 配成组织级 variable、两个 Key 配成组织级 secret，再用 `${{ vars.RELAY_BASE }}` / `${{ secrets.RELAY_ADMIN_KEY }}` 传给 action 即可。

## 调用权限（谁能用、能用到什么程度）

本仓库采用「**public 仓库 + 密钥由调用方自带**」模式：谁都能引用这份 workflow，但只有拿着中继密钥的调用方才能真正上传，而密钥从不存放在本仓库。

| 层 | 做法 | 作用 |
| --- | --- | --- |
| 凭证层（真正的边界） | 中继密钥只存在于各调用方（建议组织级 secret），本仓库不保存任何密钥 | 别人引用本仓库 workflow 时，`secrets.RELAY_ADMIN_KEY` 取到的是**他们自己**的凭证，偷不到我们的东西 |
| 代码层 | [scripts/relay-upload.sh](scripts/relay-upload.sh) 顶部的 `ALLOWED_CALLER_OWNERS` / `ALLOWED_CALLER_REPOSITORIES` | 白名单外的仓库在 guard 阶段直接失败（退出码 9），不发任何请求；用于拦截误用与蹭用 |
| 平台层（可选加固） | 把仓库改为 private 并只授权同一组织，或用 GitHub Enterprise 的 internal | 从平台层面限制「谁能引用」，代价是跨组织 / 跨账号无法共用（见下方说明） |

要点：

- **代码层只防误用，不防恶意**：public 仓库的历史提交同样能被引用，白名单挡不住有意绕过的人。但这不影响安全：恶意者手里没有我们的凭证，能做的最多是用他们自己的密钥上传他们自己的文件。
- 白名单**写死在受控代码里**，不接受任何 `input` / `secret` / `vars`。因为在 composite action 形态下调用方控制着自己 job 的环境变量，任何「可配置白名单」都等于把授权开关交给调用方。
- reusable workflow 里权限校验是独立的 `guard` job，未通过时上传 job 根本不会启动。
- 权限校验 job **固定跑在 GitHub 托管 runner** 上，不跟随 `runs-on` 输入：否则调用方能把这步放到自己控制的 runner 上篡改校验。上传 job 仍可用自建 runner（内网场景）。
- 白名单里的仓库可以让上传 job 跑在自己的 self-hosted runner 上，此时进入那台机器的是**他们自己的**中继密钥；白名单同时也是一份信任清单，只放可信仓库。
- 变更白名单：改上面两行常量 → 提交 → 移动 `v1` 标签，对所有调用方立即生效。

### 平台层的容器限制（为什么必须是 public）

GitHub 规定：private 仓库里的 action 与 reusable workflow 只能被**同一个用户、同一个组织或同一个企业**名下的仓库引用。本仓库在个人账号 `yxsj245` 下，所以 `QVMConsole`、`GSManagerXZ` 这类组织下的仓库引用不到 private 版本，代码层白名单写得再宽也没用。三条替代路：

1. 把本仓库转移到一个组织下（只能服务该组织）；
2. 有 GitHub Enterprise 时把仓库放到组织下并设为 **internal**（企业内所有组织通吃，可恢复「密钥集中在 CICD 仓库」的零配置模式）；
3. **保持 public + 密钥由调用方自带**（当前方案，跨组织零障碍）。

将来若走第 2 条，改法见 [使用文档](docs/usage.md) 的「迁到 internal 操作清单」。

## 参数速查

| 输入 | 必填 | 说明 |
| --- | --- | --- |
| `file` | 是 | 待上传文件路径（相对工作目录或绝对路径） |
| `logical-path` | 是 | 统一逻辑路径，如 `releases/app/v1.2.3/app.zip` |
| `artifact-name` | 否 | 仅 reusable workflow：先下载该 artifact 再上传 |
| `relay-base` | 否 | 留空时读调用方仓库的变量 `RELAY_BASE` |
| `idempotency-key` | 否 | 留空时按「运行 ID + 尝试次数 + job + 统一路径」自动生成 |
| `poll-timeout` | 否 | 等待任务终态的最长秒数，默认 1800，0 表示一直等 |
| `dry-run` | 否 | 只校验参数与统一路径，不发起任何请求（接入联调首选） |
| `runs-on` | 否 | 默认 `ubuntu-latest`；中继只在局域网时改成自建 runner 标签 |

密钥：调用方通过 `secrets: inherit` 传入 `RELAY_ADMIN_KEY` / `RELAY_UPLOAD_KEY`（reusable workflow 里为必填）。

输出：`task-id`、`state`、`file-id`、`sha256`、`size-bytes`、`idempotency-key`。完整参数、退出码与排错见 [使用文档](docs/usage.md)。

## 统一路径规范（摘要）

- 相对 POSIX 路径，`/` 分隔，不带首尾 `/`，末尾必须是文件名，不超过 1024 字节；
- 禁止 `\ : * ? " < > |` 与控制字符，禁止空段、`.`、`..`，路径段不能以空格或点结尾；
- 查重按路径段做 ASCII 小写比较，`App.ZIP` 与 `app.zip` 视为同一路径；
- 覆盖是预期行为：同一个统一路径再次上传就是就地更新该产物，这是「固定下载地址 + 就地更新」用法的前提；只有需要保留历史版本时，才在路径里带版本号、标签或提交号。

脚本会在本地先按上述规则拦截非法路径，避免无谓请求。

## 幂等与重跑

- 幂等键默认是 `gh-<运行ID>-<尝试次数>-<job>-<统一路径哈希>`：
  - 同一个运行内上传多个文件不会互相冲突；
  - **重跑（re-run）会产生新键，因此会重新上传并覆盖同一路径**，不会出现「重新构建了产物却静默沿用旧内容」；
  - 同一次运行内对同一路径重复上传仍会命中原任务，避免重复分发。
- 上传中断或响应丢失时，脚本会按幂等键查询既有任务并继续跟踪，而不是盲目重发正文。
- 若幂等键指向的历史任务已经是失败终态，重跑会直接报错并提示换用新的幂等键，不会让你反复复现同一个失败。
- 想精确控制去重粒度时显式传 `idempotency-key`（例如用提交号做跨运行去重）。
- `HTTP 202` 只代表正文已落盘受理，必须轮询到 `succeeded` / `partial_failed` / `failed` / `cancelled` 才算结束。

## 维护者须知

- **改动前先跑自测**：`bash tests/run-selftest.sh`（本地 Git Bash / Linux 均可）与 `python tests/check-yaml.py`。
- **发布纪律**：兼容改动移动 `v1` 标签；不兼容改动另起 `v2`，让老项目继续用 `v1`。
- **变更调用方白名单**：改 [scripts/relay-upload.sh](scripts/relay-upload.sh) 顶部的 `ALLOWED_CALLER_OWNERS` / `ALLOWED_CALLER_REPOSITORIES` → 提交 → 移动 `v1` 标签。白名单不接受任何 input / secret / vars，这是刻意设计。
- **仓库改名或迁移**时，只需改各调用方的 `uses:` 与文档示例：workflow 内部用 `$/relay-upload` 自仓库语法引用自己，解析到「正在运行的那个提交」，既不需要 checkout，也不写死仓库坐标（需要 runner ≥ 2.336.0，GitHub 托管 runner 均满足）。
- **中继接口契约变化**时，只需改 [scripts/relay-upload.sh](scripts/relay-upload.sh) 与 [tests/mock-relay.py](tests/mock-relay.py)，所有调用方自动生效。
- **密钥纪律**：本仓库永远不保存中继密钥（不放 environment、不配 secret、不写进文件）。中继密钥由各调用方以组织级 secret 持有，本仓库只提供代码与规范。

## 当前边界

- 上传 Key 固定同步全部启用渠道，**不支持按渠道挑选**；需要挑选时必须改用管理员 Key 的两步上传接口，该能力待中继提供接口契约后再补。
- 中继不在公网时，需要把 `runs-on` 改成自建 runner 标签。
- 首次接入真实渠道前建议先用 `dry-run: 'true'` 联调：只校验参数、调用权限与统一路径，不发任何请求。覆盖旧产物是预期行为，同一路径重复上传即为就地更新。
