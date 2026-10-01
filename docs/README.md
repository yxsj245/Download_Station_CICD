# Storage Relay

统一路径、多目标存储文件分发系统。Go + SQLite 服务端与 Python/PySide6 Windows 客户端已完成主要功能实现、缺陷修复和真实前后端联调；真实存储发布仍需按文档的不可逆覆盖风险单独确认。

## 阅读入口

| 文档 | 适合查看的内容 |
| --- | --- |
| [开发规格](<docs/development-spec.md>) | 需求边界、Go/Python 选型、统一路径、SQLite 建表、HTTP API、同步状态机、代码目录、实施顺序与验收 |
| [后端使用指南](<docs/backend-usage.md>) | 本机启动、Docker 配置、无需客户端的 API 闭环、独立测试目录与构建命令 |
| [后端阶段记录](<docs/backend-stage-report.md>) | 首轮实现内容、实际验证与未测项目 |
| [后端审查与准入记录](<docs/backend-review-report.md>) | 独立审查、缺陷修复、294 项顶层测试与客户端开工结论 |
| [OpenAPI](<docs/openapi.yaml>) | 全部后端接口的请求、响应、权限与错误码合同 |
| [客户端开发接手任务书](<docs/client-handoff.md>) | Windows 桌面客户端范围、分阶段任务、API 对接、测试验收与可直接转交的开发指令 |
| [部署与预计使用方式](<docs/deployment-and-usage.md>) | 完整产品的部署和客户端操作设计；客户端相关内容仍待后续阶段实现 |
| [GitHub Actions 镜像发布](<docs/github-actions-cicd.md>) | 手动触发构建后端镜像并推送阿里云容器镜像服务：Secret 配置、触发方式、服务器拉取与排错 |

## 已确定的核心方案

- 服务端：Go + SQLite，独立运行，集中保存渠道、路径和任务。
- 客户端：Python + PySide6，Windows 桌面软件。
- 渠道：S3 兼容对象存储与 SFTP；雨云 ROS 为明确兼容验收对象。
- 路径：统一逻辑路径 + 每渠道前缀；同名冲突用文件 ID 或已登记路径消歧。
- 上传：支持服务端分发和客户端直传；直传不绕过服务端的路径与任务管理。
- 认证：管理员 Key + 上传 Key，允许 HTTP，不引入复杂安全体系。
- 部署：一个容器、一个数据目录，不依赖外部数据库、Redis 或反向代理。

## 当前交付边界

本轮包含后端源码、独立目录测试、依赖锁文件、OpenAPI、单容器部署配置和后端使用文档，并已初始化 Windows Qt 客户端源码、锁文件、测试与 onedir 打包脚本。客户端使用说明见 [客户端使用说明](<docs/client-usage.md>)，阶段边界见 [客户端阶段记录](<docs/client-stage-report.md>)。真实雨云/SFTP 凭证验收和干净 Windows 包启动仍须另行开展；容器构建、启动与接口闭环已在真实 Linux 主机实测通过（见 [后端使用指南](<docs/backend-usage.md>) 第 3 节）。最新后端准入结论见 [后端审查记录](<docs/backend-review-report.md>)，真实客户端/服务端联调与回归边界见 [真实联调报告](<docs/integration-test-report.md>)。

## Docker 部署（服务器）

[compose.yaml](<compose.yaml>) 采用**拉取镜像**方式：镜像由 [GitHub Actions 工作流](<.github/workflows/docker-publish.yml>) 手动构建并推送到阿里云容器镜像服务（ACR），服务器只负责拉取与运行。数据全部落在宿主机 `./data`，不依赖外部数据库、Redis 或反向代理。

### 前提

| 项 | 要求 |
| --- | --- |
| 主机 | Linux x86_64，已安装 Docker Engine 与 Compose v2 |
| 镜像 | `registry.cn-beijing.aliyuncs.com/xiaozhu245/download_station_relay:latest` 已由工作流推送 |
| 网络 | 可访问 `registry.cn-beijing.aliyuncs.com`；私有仓库需先登录 |
| 端口 | 宿主机 8080 空闲，可用 `SR_PORT` 调整 |

### 首次部署

```bash
cd ~/Download_Station_Relay
cp .env.example .env

# 生成两个不同的随机 Key
sed -i "s|^SR_ADMIN_API_KEY=.*|SR_ADMIN_API_KEY=$(openssl rand -hex 24)|" .env
sed -i "s|^SR_UPLOAD_API_KEY=.*|SR_UPLOAD_API_KEY=$(openssl rand -hex 24)|" .env

# 登录私有镜像仓库：用户名=阿里云账号全名，密码=访问凭证页设置的固定密码
docker login --username=yxsj2459561 registry.cn-beijing.aliyuncs.com

# 拉取并启动
docker compose pull
docker compose up -d

# 确认
docker compose ps
curl -sS --fail http://127.0.0.1:8080/healthz
```

首次启动自动创建并迁移 SQLite，无需手工建表。两个 Key 必须非空且互不相同，否则配置展开与容器启动都会直接失败。

若镜像尚未发布（例如还没跑过工作流），可先本地构建再覆盖镜像地址：

```bash
docker build -f deploy/Dockerfile -t storage-relay:local .
SR_IMAGE=storage-relay:local docker compose up -d
```

### 升级与回滚

```bash
docker compose pull && docker compose up -d      # 拉取新的 latest 并重建容器
docker compose ps
curl -sS --fail http://127.0.0.1:8080/healthz
```

镜像标签固定为 `latest`，ACR 不保留历史标签，回滚请使用工作流每次运行 Summary 输出的清单摘要：

```bash
SR_IMAGE='registry.cn-beijing.aliyuncs.com/xiaozhu245/download_station_relay@sha256:<清单摘要>' docker compose up -d
```

### 数据与备份

- `./data` 保存 SQLite、实例 ID、运行锁和 `spool/` 暂存；`docker compose down` 不会删除它，禁止在运行中只复制数据库主文件充当备份。
- 停机备份（SQLite 使用 WAL，必须停机打包）：

```bash
mkdir -p backups && docker compose stop
tar -czf "backups/relay-$(date +%Y%m%d-%H%M%S).tar.gz" data .env
docker compose start
```

- 恢复：在新目录解压出 `data` 与 `.env`，确认旧服务端与旧直传执行端都已停止后，再执行 `docker compose up -d`。

### 常用运维命令

| 操作 | 命令 |
| --- | --- |
| 查看状态 | `docker compose ps` |
| 跟踪日志 | `docker compose logs -f --tail=100` |
| 修改 `.env` 后生效 | `docker compose up -d --force-recreate` |
| 重启（不重载配置） | `docker compose restart` |
| 停止 / 移除容器 | `docker compose stop` / `docker compose down` |
| 查看展开后的生效配置 | `docker compose config` |

服务端监听 `SR_PORT`（默认 8080）；管理员 Key 填入客户端，上传 Key 给上传脚本或其它程序。完整参数、渠道登记与上传示例见 [后端使用指南](<docs/backend-usage.md>)，备份、升级与验收细节见 [部署与预计使用方式](<docs/deployment-and-usage.md>)，镜像发布与排错见 [GitHub Actions 镜像发布](<docs/github-actions-cicd.md>)。

## 外部程序精准上传（统一路径）

CI、发布脚本等外部程序上传只需三步：**登记统一路径 → 解析文件 ID → 带哈希上传正文**。上传 Key 固定同步全部启用渠道，不能挑选部分渠道；需要挑选时用管理员 Key 的两步接口。

### 统一路径规范

统一路径描述文件在全部渠道中的**相对逻辑位置**（如 `releases/stable/app.zip`），与渠道前缀无关；各渠道的最终落点由「渠道前缀 + 统一路径」拼成，例如雨云前缀 `backup` 得到 `backup/releases/stable/app.zip`。

| 规则 | 说明 |
| --- | --- |
| 形式 | 相对 POSIX 路径，用 `/` 分隔，不带首尾 `/`，末尾必须是文件名 |
| 长度 | 不超过 1024 字节（UTF-8） |
| 禁止 | 反斜杠、控制字符、空路径段、`.`、`..`，以及 Windows 与 SFTP 不友好字符（冒号、星号、问号、双引号、尖括号、竖线） |
| 路径段 | 不能以空格或点结尾 |
| 大小写 | 保留原始写法；查重按逐段 ASCII 小写比较，`App.ZIP` 与 `app.zip` 视为同一路径 |
| 同名 | 允许同名不同路径；只给文件名且存在多条时返回 409 `FILE_NAME_AMBIGUOUS`，服务端绝不自动挑选 |

### Linux 脚本

依赖 `curl`、`jq`、`sha256sum`（或 `shasum -a 256`）；`jq` 缺失时先安装，例如 `apt-get install -y jq` 或 `yum install -y jq`：

```bash
#!/usr/bin/env bash
# 用法：RELAY_BASE=https://relay.example.com ADMIN_KEY=... UPLOAD_KEY=... ./upload.sh app.zip releases/stable/app.zip
set -euo pipefail

# 幂等键只需要唯一且不超过 128 字节，不要求特定格式
gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

RELAY_BASE="${RELAY_BASE:?请设置 RELAY_BASE（对外地址，不带尾斜杠）}"
ADMIN_KEY="${ADMIN_KEY:?请设置 ADMIN_KEY（SR_ADMIN_API_KEY）}"
UPLOAD_KEY="${UPLOAD_KEY:?请设置 UPLOAD_KEY（SR_UPLOAD_API_KEY）}"
LOCAL_FILE="${1:?用法: $0 <本地文件> <统一路径>}"
LOGICAL_PATH="${2:?用法: $0 <本地文件> <统一路径>}"

# 1. 先在本地按规范拦住非法路径，避免无谓请求
if printf '%s' "$LOGICAL_PATH" | grep -qE '^/|/$|[\\:*?"<>|[:cntrl:]]'; then
  echo '统一路径不合法：不带首尾 /，且不含 \ : * ? " < > | 与控制字符' >&2
  exit 2
fi
if ! printf '%s' "$LOGICAL_PATH" | awk -F/ '{for(i=1;i<=NF;i++) if($i==""||$i=="."||$i==".."||$i ~ /[ .]$/) exit 1}'; then
  echo '统一路径不合法：存在空路径段、. / .. 段，或以空格、点结尾的路径段' >&2
  exit 2
fi
if [ "$(printf '%s' "$LOGICAL_PATH" | wc -c)" -gt 1024 ]; then
  echo '统一路径不合法：超过 1024 字节上限' >&2
  exit 2
fi

# 2. 登记统一路径；409 表示已登记，直接复用
REGISTER_CODE=$(curl -sS -o /tmp/relay-register.json -w '%{http_code}' \
  -X POST "$RELAY_BASE/api/v1/admin/files" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"logical_path":"'"$LOGICAL_PATH"'"}')
case "$REGISTER_CODE" in
  201) echo "已登记统一路径：$LOGICAL_PATH" ;;
  409) echo "统一路径已存在，复用登记记录" ;;
  *)   echo "登记失败 HTTP $REGISTER_CODE：$(cat /tmp/relay-register.json)" >&2; exit 1 ;;
esac

# 3. 解析 file_id：精准锚定，杜绝同名歧义
FILE_ID=$(curl -sS -G "$RELAY_BASE/api/v1/files/resolve" \
  -H "Authorization: Bearer $UPLOAD_KEY" \
  --data-urlencode "logical_path=$LOGICAL_PATH" | jq -r '.data.id')
if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
  echo '解析 file_id 失败' >&2
  exit 1
fi

# 4. 幂等键 + 正文哈希
# 用 stdin 读取，避免 sha256sum 在特殊文件名下给哈希加转义前缀
IDEM_KEY="$(gen_uuid)"
SHA256="$(sha256sum < "$LOCAL_FILE" | awk '{print $1}')"

# 5. 一步上传：file_id 定位目标，服务端复核 SHA-256
UPLOAD_CODE=$(curl -sS -o /tmp/relay-upload.json -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer $UPLOAD_KEY" \
  -H "Idempotency-Key: $IDEM_KEY" \
  -H "X-Content-SHA256: $SHA256" \
  -H 'Content-Type: application/octet-stream' \
  --upload-file "$LOCAL_FILE" \
  "$RELAY_BASE/api/v1/uploads?file_id=$FILE_ID")
if [ "$UPLOAD_CODE" != "202" ]; then
  echo "上传失败 HTTP $UPLOAD_CODE：$(cat /tmp/relay-upload.json)" >&2
  exit 1
fi
TASK_ID=$(jq -r '.data.task_id' /tmp/relay-upload.json)
echo "正文已接收，task_id=$TASK_ID"

# 6. 轮询到终态：202 只代表服务端收全，不代表渠道上传成功
while :; do
  STATE=$(curl -sS -H "Authorization: Bearer $UPLOAD_KEY" \
    "$RELAY_BASE/api/v1/tasks/$TASK_ID" | jq -r '.data.state')
  case "$STATE" in
    succeeded) echo '全部目标渠道成功' ; break ;;
    partial_failed|failed|cancelled)
      echo "任务结束于 $STATE，请查看各渠道错误" >&2
      exit 1 ;;
    *) sleep 3 ;;
  esac
done
```

### Windows PowerShell

用 `curl.exe` 发送正文，避免大文件被整体读进内存：

```powershell
$relayBase   = 'https://relay.example.com'    # 对外地址，不带尾斜杠
$adminKey    = $env:SR_ADMIN_API_KEY
$uploadKey   = $env:SR_UPLOAD_API_KEY
$localFile   = 'C:\Downloads\app.zip'
$logicalPath = 'releases/stable/app.zip'

# 1. 登记统一路径；409 表示已存在，直接复用
try {
  Invoke-RestMethod -Method Post -Uri "$relayBase/api/v1/admin/files" `
    -Headers @{ Authorization = "Bearer $adminKey" } `
    -ContentType 'application/json; charset=utf-8' `
    -Body (@{ logical_path = $logicalPath } | ConvertTo-Json -Compress) | Out-Null
} catch {
  if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
}

# 2. 解析 file_id
$fileId = (Invoke-RestMethod -Method Get `
  -Uri "$relayBase/api/v1/files/resolve?logical_path=$([uri]::EscapeDataString($logicalPath))" `
  -Headers @{ Authorization = "Bearer $uploadKey" }).data.id

# 3. 幂等键 + 正文哈希 + 一步上传
$idemKey = [guid]::NewGuid().ToString()
$sha256  = (Get-FileHash -Algorithm SHA256 -LiteralPath $localFile).Hash.ToLower()

$uploadJson = curl.exe -sS --fail-with-body `
  -X POST `
  -H "Authorization: Bearer $uploadKey" `
  -H "Idempotency-Key: $idemKey" `
  -H "X-Content-SHA256: $sha256" `
  -H 'Content-Type: application/octet-stream' `
  --upload-file $localFile `
  "$relayBase/api/v1/uploads?file_id=$fileId"
$taskId = ($uploadJson | ConvertFrom-Json).data.task_id

# 4. 轮询到终态
while ($true) {
  $state = (Invoke-RestMethod -Method Get -Uri "$relayBase/api/v1/tasks/$taskId" `
    -Headers @{ Authorization = "Bearer $uploadKey" }).data.state
  if ($state -eq 'succeeded') { '全部目标渠道成功'; break }
  if ($state -in @('partial_failed', 'failed', 'cancelled')) { throw "任务结束于 $state" }
  Start-Sleep -Seconds 3
}
```

### 确保“精准”的四个要点

1. **用 `file_id` 或完整统一路径定位目标**：不要只传文件名，同名多条会返回 409 `FILE_NAME_AMBIGUOUS`，服务端不会替你挑一条。
2. **幂等键贯穿重试**：请求中断后先用 `GET /api/v1/tasks/by-idempotency-key?key=<幂等键>` 查询；已有任务就复用它，不要用同一键传另一份内容。
3. **`X-Content-SHA256` 让服务端复核正文**：正文哈希与声明不一致返回 422 `CHECKSUM_MISMATCH`，错误内容不会被分发；正文长度也必须与预约长度一致，否则返回 422 `SIZE_MISMATCH`。
4. **HTTP 202 不等于成功**：它只表示正文已完整落盘、任务可执行，必须轮询到 `succeeded`、`partial_failed`、`failed` 或 `cancelled`。

### 经 nginx 反向代理时

- `RELAY_BASE` 填反代后的对外地址，**含统一路径前缀**，例如 `https://example.com/relay`；脚本自己拼接 `/api/v1/...` 子路径即可。
- nginx 中 `location /relay/ { proxy_pass http://127.0.0.1:8080/; }` 的**尾斜杠必须保留**，否则前缀不会被剥掉；请求地址也要写成带尾斜杠的 `/relay/...`，避免 301 重定向丢掉上传正文。
- 响应里的 `task_url` / `content_url` 是服务端生成的绝对路径（如 `/api/v1/tasks/<id>`），**不包含反代前缀**，直接拼接会 404，请始终用自己配置的 `RELAY_BASE` 拼。
- 大文件必须放开 `client_max_body_size`（或设为 `0`）并关闭 `proxy_request_buffering`，否则会被 413 拦截或先整份落到 nginx 临时盘；上传超时也要相应放宽。

接口字段、权限与错误码以 [OpenAPI](<docs/openapi.yaml>) 为准；两步上传、任务查询、断开后按幂等键重试等更多示例见 [部署与预计使用方式](<docs/deployment-and-usage.md>) 第 8 节。

## 快速运行与测试

使用 PowerShell 7，在根目录运行 [开发脚本](<dev.ps1>)：

```powershell
pwsh -File ./dev.ps1
```

选择 `1` 编译后端，选择 `2` 以开发环境运行，选择 `0` 退出。缺少 API Key 时隐藏输入，不保存密钥。具体配置见 [脚本使用说明](<docs/backend-usage.md>)。

也可手动运行：先安装 Go 1.26.8，并提供两个非空且不同的环境变量 `SR_ADMIN_API_KEY` / `SR_UPLOAD_API_KEY`，再在 `backend` 目录执行：

```powershell
go run ./cmd/relay
go test ./...
```

完整配置、无需客户端的渠道登记和上传示例见 [后端使用指南](<docs/backend-usage.md>)。默认监听 8080；`relay healthcheck --url http://127.0.0.1:8080/healthz` 只发健康请求，不打开服务端数据库。
