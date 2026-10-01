# 使用文档

本仓库把「上传到中继」抽成共享 CICD。本文覆盖：接入准备、两种调用形态、全部参数、统一路径规范、幂等语义、退出码与错误码、排错手册、自测方式，以及维护者需要改哪些地方。

接口契约（登记 / resolve / 上传 / 轮询、错误码、路径规则）来自中继项目，剪存参考见同目录的 [README.md](README.md)；字段级细节以中继项目提供的 `openapi.yaml` 为准。

## 1. 整体设计

```
调用方仓库                          本仓库（Download_Station_CICD）
─────────────                       ──────────────────────────────
                                     .github/workflows/relay-upload.yml   ← reusable workflow（独立 job 形态）
                                     relay-upload/action.yml              ← composite action（就地调用形态）
                                                  │
                                                  ▼
                                     scripts/relay-upload.sh              ← 唯一实现：登记 → resolve → 上传 → 轮询
                                                  │
                                                  ▼
                                        上传中继（Storage Relay）
                                                  │
                                    ┌─────────────┴─────────────┐
                                    ▼                           ▼
                              对象存储渠道                   SFTP 渠道
```

三层结构的用意：

- **脚本层**是唯一实现，GitHub / GitLab / Jenkins / 本地都能直接跑，不被 GitHub 绑死；
- **composite action 层**负责「就地调用」，构建完直接传文件，没有 artifact 往返开销；
- **reusable workflow 层**负责「最省心的调用」，调用方只写几行，产物通过 artifact 交接。

三层共用同一份逻辑，因此修一次 bug、加一条日志、改一次路径规范，所有调用方同时生效。

## 2. 接入前的准备

### 2.1 中继侧

| 项 | 说明 |
| --- | --- |
| 对外地址 | 例如 `https://relay.example.com`，**不带尾斜杠**；经 nginx 反代时带上反代前缀（如 `https://example.com/relay`） |
| 管理员 Key | `SR_ADMIN_API_KEY`，登记统一路径必须用它 |
| 上传 Key | `SR_UPLOAD_API_KEY`，解析 file_id、上传正文、查询任务用它 |
| 网络可达 | GitHub 托管 runner 需要能直连该地址；只在局域网时必须改用自建 runner |

两个 Key 必须非空且互不相同，脚本也会再校验一次并给出中文提示。

### 2.2 GitHub 侧配置

**本仓库侧（一次性）**

1. **可见性保持 public**：private 的个人账号仓库只能被同账号的仓库引用，`QVMConsole`、`GSManagerXZ` 这类组织的仓库引用不到（见 2.4 的容器限制）。
2. **不要在这里配置中继密钥**：本仓库不保存任何凭证。public 仓库的 workflow 任何人都能引用（连历史提交都能）。需要说清楚的是：本仓库的普通（repository）secret 并不会外泄给调用方，**真正的风险路径是 environment**——job 一旦挂上 environment，那里的同名 secret 就会覆盖调用方传入的值，被外部调用者借用。所以这里既不配 secret，也不要建 `relay-production` 之类的 environment。
3. **稳定标签**：`git tag -f v1 && git push -f origin v1`，调用方统一写 `@v1`。

**调用方侧（每个组织配一次）**

在组织级配置 Organization secrets `RELAY_ADMIN_KEY` / `RELAY_UPLOAD_KEY`（可见范围选 All repositories 或指定仓库）与 Organization variable `RELAY_BASE`；调用方 workflow 里写 `secrets: inherit` 即可。这样密钥轮换只改一处，组织下所有仓库共用。

> **凭证一律由调用方传入**：reusable workflow 通过 `secrets.RELAY_ADMIN_KEY` / `secrets.RELAY_UPLOAD_KEY` 读取，`relay-base` 留空时读调用方仓库的 `vars.RELAY_BASE`。
> 首次接入建议先跑一次 dry-run 验证链路：
>
> ```yaml
>     uses: yxsj245/Download_Station_CICD/.github/workflows/relay-upload.yml@v1
>     with:
>       file: app.zip
>       logical-path: releases/dry-run/app.zip
>       dry-run: 'true'
>     secrets: inherit
> ```
>
> workflow 里的「凭证来源自检」会报告中继地址与两个 Key 是否取到（只报有无，从不打印值）。两个 secret 是必填契约：完全漏传时 GitHub 会在 job 启动前直接报错，自检步骤负责兜住空值等边缘情况并给出中文提示。

### 2.3 密钥纪律与可选的审批闸门

- 中继密钥不要写进仓库文件、日志、构建产物或 workflow 里的明文 env，只放在 secret 中。
- 所有调用方目前共用中继的同一对 Key（中继只支持一对）：任何一处泄露等于全部泄露。建议中继后续支持按项目签发多 Key，便于单独吊销。
- 需要人工审批时，在**调用方自己的仓库**给触发 workflow 的那个 job 配置 environment 与 Required reviewers。本仓库的 workflow 刻意不挂 environment，以免将来误配同名密钥、静默覆盖掉调用方传入的凭证。

### 2.4 调用权限（重要）

本仓库是共享 CICD，当前采用「**public 仓库 + 密钥由调用方自带**」模式。谁都能引用这份 workflow，但只有拿着中继密钥的调用方才能真正上传，而密钥从不存放在本仓库。

**第一层（真正的边界）：中继凭证不在本仓库**

别人引用本仓库的 workflow 时，`secrets.RELAY_ADMIN_KEY` / `secrets.RELAY_UPLOAD_KEY` 取到的是**他们自己仓库的凭证**（本仓库的 repository secret 根本不会进入被调用 workflow 的 secrets 上下文），所以他们即使能引用、能触发，也上传不到我们的中继。唯一的例外是 environment：job 挂上 environment 后，那里的同名 secret 会覆盖调用方传入的值——这正是本仓库既不配 secret、也不建 environment 的原因。

**平台层的容器限制（决定了仓库必须是 public）**

GitHub 官方规则：private 仓库里的 action 与 reusable workflow「只能共享给**同一个用户或同一个组织**名下的其它私有仓库」（企业账号下可放宽到同一企业）。这意味着被调用的仓库与调用方必须落在同一个容器里：

| 本仓库所在容器 | 能被谁引用 |
| --- | --- |
| 个人账号 `yxsj245` | 只有 `yxsj245` 名下的仓库 |
| 组织 `QVMConsole` | 只有 `QVMConsole` 组织内的仓库 |
| 企业（仓库设为 internal） | 该企业下所有组织的仓库 |

**代码层白名单管不了这一层**：把 `QVMConsole/*` 或 `GSManagerXZ/GameServerManager` 写进白名单，只能保证「如果他们能调用，就会被放行」；跨容器时他们连 `uses:` 都解析不到。跨容器共用有四条路：

1. **保持 public**（**当前采用的方案**）：跨组织零障碍；同时必须把中继密钥改为**调用方自带**，否则任何人都能借用 environment 里的密钥。代价是每个组织各配一份密钥，且代码公开；
2. **把本仓库转移到目标组织下**，Access 选该组织：干净，但只服务这一个组织；
3. **GitHub Enterprise**：仓库放到组织下并设为 `internal`，企业内所有组织通吃，并可以恢复「密钥集中在 CICD 仓库、调用方零配置」的模式（操作清单见下）；
4. **不共享 workflow**：让调用方用细粒度 PAT（只授权 `Actions: write`）触发本仓库的 `workflow_dispatch`，产物由调用方提供下载地址；密钥始终不出本仓库，任何容器都能用，代价是多一层触发与产物传输的改造。

**迁到 internal（企业账号）操作清单**

选定第 2 条路线后，按这个顺序做：

1. **转移仓库**：把本仓库从个人账号转移到一个组织（internal 只能用于组织下的仓库）：`Settings → General → Danger Zone → Transfer ownership`。转移后 GitHub 会重定向旧的 git/API 地址，但 `uses:` 引用要显式改成新坐标。
2. **设可见性**：`Settings → General → Danger Zone → Change visibility → internal`。
3. **放开 Access**：`Settings → Actions → General → Access` 选企业级授权（"Accessible from repositories in the '<企业>' enterprise"），这样企业下所有组织的仓库都能引用本仓库的 workflow 与 action。
4. **更新白名单里的宿主组织**：把新宿主组织加进 `ALLOWED_CALLER_OWNERS`，否则连本仓库的 CI 自测都会被自己的守卫拒绝（[selftest.yml](../.github/workflows/selftest.yml) 里有一步专门做这个自检）。
5. **决定密钥归属**：可以继续让调用方自带密钥（组织级 secret），也可以把密钥收回 CICD 仓库的 `relay-production` environment、恢复调用方零配置——internal 模式下别人引用不到本仓库，这种收回才是安全的。
6. **更新坐标**：所有调用方的 `uses:`（`<新组织>/Download_Station_CICD/...@v1`）、[README.md](../README.md) 与本文档示例、本地 `git remote`。workflow 内部用 `$/relay-upload` 自仓库语法，**不受转移影响，无需改动**（该语法需要 runner ≥ 2.336.0，且 GitHub Enterprise Server 暂不支持，若目标实例是 GHES 则要改回显式坐标）。
7. **通知调用方组织**：各组织的 Actions 策略需允许使用企业内的 actions（"Allow all actions and reusable workflows" 或相应放行），否则同样引用不到。

**第二层：代码里的调用方白名单**

[scripts/relay-upload.sh](../scripts/relay-upload.sh) 顶部：

```bash
readonly ALLOWED_CALLER_OWNERS="yxsj245,QVMConsole"                    # 这些 owner 名下所有仓库放行
readonly ALLOWED_CALLER_REPOSITORIES="GSManagerXZ/GameServerManager"   # 精确放行个别仓库，逗号分隔
```

判定依据是 `GITHUB_REPOSITORY`：它由 GitHub 注入，平台不允许被 workflow 的 `env:` 或 `GITHUB_ENV` 覆盖。reusable workflow 形态下 job 与 steps 全由本仓库定义、校验固定跑在托管 runner 上，调用方无从干预；composite action 形态下调用方控制着自己 job 的进程环境（例如用 `BASH_ENV` 就能在 bash 进程内改写这个变量），但那种形态的凭证本来就由调用方自带，改写守卫换不到任何中继凭证——所以**代码层只防误用，不防恶意**。

白名单**不接受**任何 `input` / `secret` / `vars`：在 composite action 形态下调用方控制着自己 job 的环境变量，任何「可配置白名单」都等于把授权开关交给调用方。脚本里的 `readonly` 常量也不受外部同名环境变量影响；若外部经 `BASH_ENV` 抢先把它设成 readonly，脚本会在赋值处直接失败退出，属于 fail-closed，而不是被绕过。

命中规则：仓库全名精确匹配，或 owner 匹配；大小写不敏感。未命中时：

- 以退出码 9 结束，给出中文「调用方未授权」提示；
- **不会发起任何网络请求**，也不会接触中继凭证（校验排在读取凭证之前）；
- reusable workflow 形态下，上传 job 因为 `needs: guard` 根本不会启动。

**为什么校验固定跑在托管 runner 上**

workflow 暴露 `runs-on` 输入，是为了让内网项目把**上传**放到自建 runner 上执行；但权限校验那一步固定在 `ubuntu-latest`。原因：如果调用方能把校验也放到自己控制的 runner 上，恶意 runner 可以篡改脚本或伪造环境变量，代码层校验就形同虚设。换句话说，**代码层只防误用，不防恶意**——当前 public 模式下真正防恶意的是「中继凭证根本不在本仓库」，切到 private / internal 模式后则由平台层直接拦住跨容器引用。

**第三层（可选）：把仓库收紧成 private / internal**

如果不再需要跨组织共用（例如调用方都迁进了同一个组织），可以把仓库改回 private，并在 `Settings → Actions → General → Access` 里只授权该组织；有 GitHub Enterprise 时用 `internal` 可以同时服务企业内所有组织，并能把密钥收回 CICD 仓库、恢复调用方零配置。注意：public 模式下代码层白名单会被「引用历史提交」绕过，而 private / internal 模式下平台层直接挡在前面。

**白名单同时也是一份信任授权**

白名单里的仓库可以让**上传** job 跑在自己的 self-hosted runner 上（`runs-on` 输入），届时进入那台机器的是**他们自己的**中继密钥。如果将来切回「密钥集中在 CICD 仓库」的模式，那台机器上就会是我们维护者的密钥，届时要重新评估这份清单。更细的边界可以交给中继侧的 OIDC 短期凭证。

**验证方式**：调用方首次接入时用 `dry-run: 'true'` 跑一次，日志里会打印调用方仓库；非白名单仓库会在 guard 阶段直接失败。本地或第三方 CI 直接跑脚本时没有 `GITHUB_REPOSITORY`，会跳过白名单校验并给出提示——因为此时凭证由使用者自己提供。

**最终防线**：中继侧的 Key 才是真正的边界。建议定期轮换，并保留中继访问日志用于审计。将来如果中继支持校验 GitHub OIDC token（`job_workflow_ref` 指向本 workflow、`repository` 在白名单内），可以把判断下沉到中继，安全性最好。

## 3. 两种调用形态

### 3.1 形态 B：reusable workflow（推荐）

调用方分两个 job：构建 + 上传。产物用 artifact 交接，上传 job 完全由本仓库托管。

```yaml
name: 发布
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v5
        with:
          node-version: '22'
      - run: npm ci && npm run build
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
    secrets: inherit
```

要点：

- `artifact-path` 默认 `.`，即 artifact 内容解到工作目录根；`file` 要写成解压后的相对路径。
- 该 job 不检出调用方源码，`file` 只能指向 artifact 解出来的文件。
- `secrets: inherit` 把调用方组织级 / 仓库级的 `RELAY_ADMIN_KEY`、`RELAY_UPLOAD_KEY` 传进来。这两个 secret 在 workflow 契约里是**必填**：完全漏传时 GitHub 会在 job 启动前直接报错（英文，指明缺哪一项），自检步骤则负责兜住空值等边缘情况并给中文提示。
- 需要更大超时或自建 runner 时传 `poll-timeout` / `runs-on`。

### 3.2 形态 A：composite action（就地调用）

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: ./build.sh
      - name: 上传到中继
        id: relay
        uses: yxsj245/Download_Station_CICD/relay-upload@v1
        with:
          relay-base: ${{ vars.RELAY_BASE }}
          admin-key: ${{ secrets.RELAY_ADMIN_KEY }}
          upload-key: ${{ secrets.RELAY_UPLOAD_KEY }}
          file: dist/app.zip
          logical-path: releases/my-app/${{ github.ref_name }}/app.zip
      - name: 使用上传结果
        run: echo "task=${{ steps.relay.outputs.task-id }} state=${{ steps.relay.outputs.state }}"
```

要点：

- composite action 运行在调用方 job 内，凭证同样由调用方提供：把两个 Key 配成组织级 / 仓库级 secret，再用 `${{ secrets.RELAY_ADMIN_KEY }}` 传进来即可。
- 优点是没有 artifact 往返，构建产物就地直传，速度最快。

### 3.3 形态 C：直接调用脚本（非 GitHub CI / 本地）

```bash
RELAY_BASE=https://relay.example.com \
RELAY_ADMIN_KEY=xxx \
RELAY_UPLOAD_KEY=yyy \
RELAY_FILE=dist/app.zip \
RELAY_LOGICAL_PATH=releases/my-app/v1.0.0/app.zip \
bash scripts/relay-upload.sh
```

GitLab CI、Jenkins、本地发布脚本都适用；依赖只有 `curl`、`sha256sum`（或 `shasum -a 256`）、`jq`（缺失时自动回退 `python3` / `python`）。

## 4. 参数全表

### 4.1 reusable workflow（`.github/workflows/relay-upload.yml`）

| 输入 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `file` | string | 是 | - | 待上传文件路径 |
| `logical-path` | string | 是 | - | 统一逻辑路径 |
| `artifact-name` | string | 否 | 空 | 非空时先下载该 artifact |
| `artifact-path` | string | 否 | `.` | artifact 下载目录 |
| `relay-base` | string | 否 | 空 | 留空时读调用方仓库的变量 `RELAY_BASE` |
| `idempotency-key` | string | 否 | 空 | 留空时自动生成 |
| `poll-interval` | string | 否 | `3` | 查询终态间隔秒数 |
| `poll-timeout` | string | 否 | `1800` | 等待终态最长秒数，`0` 表示一直等 |
| `dry-run` | string | 否 | `false` | 只校验不请求 |
| `debug` | string | 否 | `false` | 更详细的日志（密钥始终脱敏） |
| `runs-on` | string | 否 | `ubuntu-latest` | 自建 runner 时改这里 |

secrets：`RELAY_ADMIN_KEY`、`RELAY_UPLOAD_KEY`，**均为必填**，由调用方通过 `secrets: inherit` 或显式传入（建议配成组织级 secret）。本仓库不保存中继密钥。

输出：`caller-repository`、`task-id`、`state`、`file-id`、`sha256`、`size-bytes`、`idempotency-key`。

### 4.2 composite action（`relay-upload/action.yml`）

输入与上表同名（kebab-case），另有 `relay-base`、`admin-key`、`upload-key`、`content-type`、`connect-timeout`、`upload-timeout`，以及 `guard-only`：只校验调用方权限，不读取凭证、不发起请求（reusable workflow 的 guard job 用的就是它）。必填项统一由脚本校验，因此错误提示是中文且能指出缺哪一项。输出名称同上。

### 4.3 脚本环境变量（形态 C 与排错时最有用）

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `RELAY_BASE` | 是 | - | 中继对外地址，`http://` 或 `https://` 开头，不带尾斜杠 |
| `RELAY_ADMIN_KEY` | 是 | - | 管理员 Key |
| `RELAY_UPLOAD_KEY` | 是 | - | 上传 Key |
| `RELAY_FILE` | 是 | - | 待上传文件 |
| `RELAY_LOGICAL_PATH` | 是 | - | 统一逻辑路径 |
| `RELAY_IDEMPOTENCY_KEY` | 否 | 自动 | 幂等键，≤128 字节 |
| `RELAY_CONTENT_TYPE` | 否 | `application/octet-stream` | 上传正文类型 |
| `RELAY_POLL_INTERVAL` | 否 | `3` | 轮询间隔秒数 |
| `RELAY_POLL_TIMEOUT` | 否 | `1800` | 轮询上限秒数，`0` 表示不限 |
| `RELAY_HTTP_RETRY` | 否 | `2` | 登记 / resolve / 查询的 curl 重试次数（上传正文不自动重试） |
| `RELAY_CONNECT_TIMEOUT` | 否 | `30` | 连接超时秒数 |
| `RELAY_UPLOAD_TIMEOUT` | 否 | `0` | 上传正文最长秒数，`0` 表示不限 |
| `RELAY_DRY_RUN` | 否 | `0` | `1` / `true` 时只校验不请求 |
| `RELAY_DEBUG` | 否 | `0` | `1` / `true` 时输出每次请求的方法、地址与 HTTP 状态码（密钥始终脱敏） |
| `RELAY_CHANNELS` | - | - | **非空会被直接拒绝**：上传 Key 无法挑选渠道，避免误发全渠道 |

脚本还会读取 GitHub 内置变量：`GITHUB_RUN_ID` / `GITHUB_JOB`（生成默认幂等键）、`GITHUB_OUTPUT`（写输出）、`GITHUB_STEP_SUMMARY`（写结果表）、`GITHUB_ACTIONS`（输出注解）。

## 5. 统一路径规范与建议

规范（与中继一致，脚本会先在本地拦截）：

| 规则 | 说明 |
| --- | --- |
| 形式 | 相对 POSIX 路径，`/` 分隔，不带首尾 `/`，末尾必须是文件名 |
| 长度 | ≤ 1024 字节（UTF-8） |
| 禁止 | `\ : * ? " < > |`、控制字符、空路径段、`.`、`..` |
| 路径段 | 不能以空格或点结尾 |
| 大小写 | 保留原写法；查重按逐段 ASCII 小写比较 |
| 同名 | 允许同名不同路径；只给文件名且多条时中继返回 409，不会替你挑一条 |

命名由你的发布策略决定，两种常见做法：

```
# 就地更新：固定路径，每次发布覆盖同一个产物，下载地址永久不变
<项目名>/latest/<文件名>                      例如 download-station/latest/app.zip

# 版本留存：路径带版本或标签，历史产物各自独立
releases/<项目名>/<版本或标签>/<文件名>        例如 releases/download-station/v1.2.3/app.zip
nightly/<项目名>/<分支>/<文件名>               例如 nightly/download-station/main/app.zip
```

**覆盖是预期行为**：同一个统一路径再次上传就是更新该产物（替换旧内容），这正是「固定下载地址 + 就地更新」用法的前提，不需要刻意回避同名。只有当你确实想保留历史版本时，才在路径里带版本号、标签或提交号。

## 6. 幂等语义与重跑

- 默认幂等键为 `gh-<运行ID>-<尝试次数>-<job>-<统一路径哈希>`：
  - 同一个运行内上传多个文件不会互相顶掉（哈希来自统一路径）；
  - **重跑（re-run）会产生新键**，因此会重新上传并覆盖同一路径：这样「重跑时重新构建出的新产物」一定会上传，不会静默沿用旧内容；
  - 同一次运行内对同一路径重复上传仍会命中既有任务，不会重复分发。
- 覆盖是正常语义：跨运行的发布就是「新键 + 就地更新」（见第 5 节）。
- 上传前脚本会先按幂等键查询既有任务；查到就把 `task_id` 接过来继续轮询，不再重复发送正文。
- 上传过程中网络中断或响应丢失时，脚本会在短暂等待后按幂等键恢复任务；恢复不到才以退出码 6 结束，并给出「用幂等键手动查询」的提示。
- 若幂等键对应的历史任务已经是 `partial_failed` / `failed` / `cancelled`，脚本会直接以退出码 7 报错并提示换用新的幂等键：这是刻意设计，避免重跑永远复现同一个失败。
- 想精确控制去重粒度时显式传 `idempotency-key`（例如用提交号做跨运行去重；要在同一次运行内对同一路径连续覆盖两次，就传两个不同的键）。同一个键不要用于不同内容。

## 7. 退出码与错误码对照

| 退出码 | 含义 | 常见原因 |
| --- | --- | --- |
| 0 | 成功 | 任务终态 `succeeded`，或 `dry-run` 校验通过 |
| 2 | 参数 / 路径不合法 | 缺少 Key、文件不存在、路径含禁用字符、幂等键超长、传了 `RELAY_CHANNELS` |
| 3 | 缺少依赖 | 无 `curl`，或既无 `sha256sum` / `shasum`，或既无 `jq` 也无 `python3` |
| 4 | 登记统一路径失败 | 管理员 Key 无效（401/403）、中继不可达、其它 4xx/5xx |
| 5 | 解析 file_id 失败 | 路径未登记（404）、只给文件名导致歧义（409 `FILE_NAME_AMBIGUOUS`）、上传 Key 无效 |
| 6 | 上传正文失败 | 哈希或长度不一致（422 `CHECKSUM_MISMATCH` / `SIZE_MISMATCH`）、权限不足、网络中断且幂等恢复失败 |
| 7 | 任务终态失败 | `partial_failed` / `failed` / `cancelled`（详情见 Summary 里的各渠道结果），也包括「幂等键指向的历史任务已经失败」 |
| 8 | 等待终态超时 | 超过 `poll-timeout`，任务可能仍在执行 |
| 9 | 调用方未授权 | 调用方仓库不在白名单内；校验发生在读取凭证之前，未发起任何请求 |

补充：`HTTP 202` / `200` / `201` 只代表正文已受理，**不等于分发成功**；必须以轮询到的终态为准。

## 8. 常见产物准备

| 项目类型 | 构建产物典型路径 | 建议 artifact 名 |
| --- | --- | --- |
| Node / 前端 | `dist/`、`build/` | `dist` |
| Python | `dist/*.whl`、`dist/*.tar.gz` | `dist` |
| Go | `bin/<name>`、交叉编译 zip | `bin` |
| Java | `target/*.jar`、`build/libs/*.jar` | `jar` |
| .NET | `publish/` | `publish` |

单文件场景建议 `actions/upload-artifact` 时只上传该文件，`file` 就写文件名；多文件场景建议先打包成 zip 再上传，避免依赖 artifact 内的目录结构。

## 9. 排错手册

| 现象 | 定位与处理 |
| --- | --- |
| 「调用方未授权」（退出码 9） | 白名单里没有这个仓库：在 [scripts/relay-upload.sh](../scripts/relay-upload.sh) 顶部的 `ALLOWED_CALLER_OWNERS` 加 owner，或用 `ALLOWED_CALLER_REPOSITORIES` 精确放行某个仓库，提交后移动 `v1` 标签 |
| 「未找到统一上传脚本」 | action 引用路径必须是 `<owner>/<repo>/relay-upload@<ref>`，且引用的是本仓库根目录 |
| 调用方报错「required secret ... not provided」（英文） | 没写 `secrets: inherit`，或组织/仓库里没有这两个 secret；按 2.2 配置即可 |
| 「未取到管理员 Key / 上传 Key」 | 调用方没传：在调用方仓库（建议组织级）配置同名 secret，并在 workflow 里 `secrets: inherit`；本仓库不保存中继密钥，见 2.2 |
| 「统一路径未在中继登记」 | 登记步骤失败被忽略，或中继侧记录被清理；确认管理员 Key，并检查 4 号退出码相关日志 |
| 「同名歧义（409）」 | 只用文件名定位；改用完整统一路径 |
| 「正文哈希或长度不一致（422）」 | 文件在上传过程中被改动（构建脚本覆盖、清理任务删除）；确保上传前文件已定型 |
| 「任务结束于 partial_failed」 | 至少一个渠道失败；Summary 的「任务详情」里有各渠道错误，去中继侧排查对应渠道凭证与网络 |
| 「幂等键对应的历史任务已结束于 partial_failed」 | 该幂等键上一次分发已经失败；修复渠道问题后，显式传入新的 `idempotency-key` 再重试 |
| 中文路径 / 文件名 | 统一路径支持 UTF-8，但为兼容 SFTP 与 Windows 端，建议只用 ASCII、数字、`-`、`_`、`.` |
| 大文件被 413 拦截 | 反代需要放开 `client_max_body_size`（或设 `0`），并关闭 `proxy_request_buffering` |
| 反代后 404 / 上传丢正文 | `RELAY_BASE` 必须含反代前缀且不带尾斜杠；nginx `location /relay/ { proxy_pass http://127.0.0.1:8080/; }` 的尾斜杠必须保留；请求地址也要带尾斜杠，避免 301 丢掉上传正文 |
| 响应里的 `task_url` / `content_url` 404 | 它们是服务端生成的绝对路径，不含反代前缀；请始终用自己配置的 `RELAY_BASE` 拼接 |
| 传了大文件后超时 | 提高 `poll-timeout`，必要时设置 `upload-timeout`；CI 端注意 job 超时上限 |
| 只想联调不想真发 | `dry-run: 'true'`，脚本只校验参数与路径，不发任何请求 |

## 10. 自测与本地运行

```bash
# 端到端自测：拉起模拟中继，覆盖成功与全部失败分支（本地 Git Bash / Linux 均可）
bash tests/run-selftest.sh

# YAML 结构自检（需要 pyyaml）
python -m pip install pyyaml
python tests/check-yaml.py

# 仅校验参数与统一路径，不发请求
RELAY_BASE=https://relay.example.com RELAY_ADMIN_KEY=a RELAY_UPLOAD_KEY=b \
RELAY_FILE=README.md RELAY_LOGICAL_PATH=selftest/dry-run/README.md RELAY_DRY_RUN=1 \
bash scripts/relay-upload.sh
```

自测覆盖：dry-run 无副作用、参数与路径校验、正常上传、登记 409 复用、幂等重跑不重复上传、大文件流式上传、任务部分失败、哈希不匹配、路径无法解析、密钥错误、中继不可达；有 `jq` 的环境走 jq 解析分支，没有 `jq` 的环境走 `python` 回退分支。[selftest.yml](../.github/workflows/selftest.yml) 在 CI 里把两条分支都跑一遍。

## 11. 维护者手册

**发布流程**

1. 合并改动到 `main`，CI 自测必须全绿；
2. 兼容改动：`git tag -f v1 && git push -f origin v1`；
3. 不兼容改动：另起 `v2` 标签，老项目继续用 `v1`，在 README 里声明迁移方式。

**仓库改名 / 迁移时必须同步的位置**

- 各调用方的 `uses:` 引用（唯一的外部耦合点）；
- [README.md](../README.md) 与本文档里的示例。

workflow 内部用 `$/relay-upload` 自仓库语法引用本仓库 action：它解析到「正在运行的那个提交」，不需要 checkout，也不写死仓库坐标；调用方把 ref 固定到具体提交时，内部引用也不会漂移到标签的新指向。该语法需要 runner ≥ 2.336.0（GitHub 托管 runner 均满足）。

**变更调用方白名单**

改 [scripts/relay-upload.sh](../scripts/relay-upload.sh) 顶部的 `ALLOWED_CALLER_OWNERS` / `ALLOWED_CALLER_REPOSITORIES` → 提交 → 移动 `v1` 标签。白名单是安全清单，刻意写死在受控代码里，不接受任何环境变量、input、secret 或 vars。

**中继接口契约变化时**

只改 [scripts/relay-upload.sh](../scripts/relay-upload.sh)（真实请求）与 [tests/mock-relay.py](../tests/mock-relay.py)（模拟行为），两边对齐后所有调用方自动生效。若拿到中继项目的 `openapi.yaml`，建议把它放进 `docs/` 作为契约真源。

## 12. 已知边界与后续计划

- **不支持按渠道挑选**：上传 Key 固定同步全部启用渠道；挑渠道需要管理员 Key 的两步上传接口，待接口契约（路径、字段、错误码）确认后补齐，届时会新增 `channels` 输入。
- **不自建 runner**：中继若只在内网，请把 `runs-on` 指向自建 runner 标签。
- **不含真实存储验收**：本仓库只负责把产物交给中继；真实雨云 / SFTP 渠道的凭证仍需单独确认。
- **`$/` 自仓库语法**：需要 GitHub Actions runner ≥ 2.336.0（托管 runner 均满足）；GitHub Enterprise Server 不支持该语法，若将来部署到 GHES，需把 workflow 内部的 `$/relay-upload` 改回显式坐标（`<owner>/<repo>/relay-upload@v1`）。
- **不写业务构建逻辑**：构建始终由调用方项目自己完成，这里只做上传。
