#!/usr/bin/env bash
# =============================================================================
# Storage Relay 统一上传脚本
#
# 作用：把任意构建产物按「统一逻辑路径」上传到上传中继（Storage Relay），
#       并等待全部目标渠道进入终态。本脚本是本 CICD 仓库的唯一上传实现，
#       composite action 与 reusable workflow 都只是它的调用壳，
#       因此 GitHub / GitLab / Jenkins / 本地都能直接复用。
#
# 依赖：curl、sha256sum（或 shasum -a 256）、jq（缺失时回退 python3 / python）
#
# 用法：
#   RELAY_BASE=https://relay.example.com \
#   RELAY_ADMIN_KEY=xxx \
#   RELAY_UPLOAD_KEY=yyy \
#   RELAY_FILE=dist/app.zip \
#   RELAY_LOGICAL_PATH=releases/app/v1.0.0/app.zip \
#   scripts/relay-upload.sh
#
# 退出码：
#   0 成功
#   2 参数或统一路径不合法（未发起任何请求）
#   3 缺少运行依赖
#   4 登记统一路径失败
#   5 解析 file_id 失败
#   6 上传正文失败
#   7 任务终态为失败 / 部分失败 / 取消
#   8 等待任务终态超时
#   9 调用方未授权（不在本仓库的调用方白名单内，未发起任何请求）
# =============================================================================
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_DEPENDENCY=3
readonly EXIT_REGISTER=4
readonly EXIT_RESOLVE=5
readonly EXIT_UPLOAD=6
readonly EXIT_TASK=7
readonly EXIT_TIMEOUT=8
readonly EXIT_FORBIDDEN=9

# -----------------------------------------------------------------------------
# 调用方白名单（安全清单）
#
# 只有清单内的 GitHub 仓库才能通过本仓库的 workflow / action 触发上传。
# 这里刻意写死在代码里，不接受任何环境变量、input、secret 或 vars：
#   - 在 composite action 形态下，调用方控制着他们自己 job 的环境变量，
#     任何「可配置的白名单」都等于把授权开关交到调用方手里；
#   - 而 GITHUB_REPOSITORY 由 GitHub 注入，官方明确 GITHUB_* / RUNNER_*
#     默认变量不允许被覆盖，因此它是可信的调用方标识。
#
# 匹配规则：仓库全名精确匹配，或 owner 匹配（该 owner 名下所有仓库放行），
# 大小写不敏感。变更白名单必须修改本文件并重新发布（走 PR / review），
# 这正是「统一管理」想要的效果。
# -----------------------------------------------------------------------------
# 当前清单构成：
#   - yxsj245：本仓库当前所在的个人账号
#   - QVMConsole：整个组织下的全部仓库
#   - GSManagerXZ/GameServerManager：单个仓库精确放行
#
# 纪律：宿主仓库（本仓库自己）所在的组织或仓库全名必须在清单里，
#       否则连本仓库的 CI 自测都会被自己的守卫以退出码 9 拒绝。
readonly ALLOWED_CALLER_OWNERS="yxsj245,QVMConsole"
readonly ALLOWED_CALLER_REPOSITORIES="GSManagerXZ/GameServerManager"

# -----------------------------------------------------------------------------
# 配置读取：全部来自环境变量，脚本内不写死任何地址或密钥
# -----------------------------------------------------------------------------
RELAY_BASE="${RELAY_BASE:-}"
RELAY_ADMIN_KEY="${RELAY_ADMIN_KEY:-}"
RELAY_UPLOAD_KEY="${RELAY_UPLOAD_KEY:-}"
RELAY_FILE="${RELAY_FILE:-}"
RELAY_LOGICAL_PATH="${RELAY_LOGICAL_PATH:-}"
RELAY_IDEMPOTENCY_KEY="${RELAY_IDEMPOTENCY_KEY:-}"
RELAY_CONTENT_TYPE="${RELAY_CONTENT_TYPE:-application/octet-stream}"
RELAY_POLL_INTERVAL="${RELAY_POLL_INTERVAL:-3}"
RELAY_POLL_TIMEOUT="${RELAY_POLL_TIMEOUT:-1800}"
RELAY_HTTP_RETRY="${RELAY_HTTP_RETRY:-2}"
RELAY_CONNECT_TIMEOUT="${RELAY_CONNECT_TIMEOUT:-30}"
RELAY_UPLOAD_TIMEOUT="${RELAY_UPLOAD_TIMEOUT:-0}"
RELAY_DRY_RUN="${RELAY_DRY_RUN:-0}"
RELAY_DEBUG="${RELAY_DEBUG:-0}"
RELAY_CHANNELS="${RELAY_CHANNELS:-}"
RELAY_GUARD_ONLY="${RELAY_GUARD_ONLY:-0}"

TMP_DIR=""
CURL_BIN=""
SHA256_BIN=""
SHA256_ARGS=""
SHASUM_BIN=""
JQ_BIN=""
PYTHON_BIN=""

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 日志：用户可见提示统一使用中文，便于排错
# -----------------------------------------------------------------------------
log_info() { printf '[信息] %s\n' "$*" >&2; }
log_warn() { printf '[警告] %s\n' "$*" >&2; }
log_error() { printf '[错误] %s\n' "$*" >&2; }

# GitHub 注解正文需要转义 %、回车与换行，
# 否则服务端返回的文本可能截断消息甚至伪造注解
escape_annotation() {
  local text="$1"
  text="${text//'%'/%25}"
  text="${text//$'\r'/%0D}"
  text="${text//$'\n'/%0A}"
  printf '%s' "$text"
}

# GitHub Actions 里额外输出注解，方便在 UI 上直接看到问题
gh_notice() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::notice::%s\n' "$(escape_annotation "$*")"
  fi
  return 0
}

gh_warning() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s\n' "$(escape_annotation "$*")"
  fi
  return 0
}

die() {
  local code="$1"
  shift
  log_error "$*"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$(escape_annotation "$*")"
  fi
  exit "$code"
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on | y) return 0 ;;
    *) return 1 ;;
  esac
}

# 密钥脱敏：任何回显命令的地方都必须先过这个函数。
# 说明：bash 的模式替换按 glob 解释，中继密钥为十六进制串（openssl rand -hex 24）时安全；
# 若改用含 * ? [ ] 的自定义密钥，请同步调整这里的实现。
redact() {
  local text="$1"
  if [ -n "$RELAY_ADMIN_KEY" ]; then text="${text//$RELAY_ADMIN_KEY/***}"; fi
  if [ -n "$RELAY_UPLOAD_KEY" ]; then text="${text//$RELAY_UPLOAD_KEY/***}"; fi
  printf '%s' "$text"
}

# -----------------------------------------------------------------------------
# 依赖探测
# -----------------------------------------------------------------------------
detect_dependencies() {
  CURL_BIN="$(command -v curl || true)"
  [ -n "$CURL_BIN" ] || die "$EXIT_DEPENDENCY" "缺少依赖 curl，请先安装（例如 apt-get install -y curl）"

  # sha256 计算优先用 sha256sum，其次 shasum -a 256
  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_BIN="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHASUM_BIN="shasum"
  else
    die "$EXIT_DEPENDENCY" "缺少依赖 sha256sum 或 shasum，请先安装 coreutils 或 perl"
  fi

  # JSON 解析优先用 jq，缺失时回退 python（保证 Windows / 精简环境也能跑）；
  # python 需要实际可执行，避免选中 Windows 应用商店的占位程序
  if command -v jq >/dev/null 2>&1; then
    JQ_BIN="jq"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1 && python -c 'pass' >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    die "$EXIT_DEPENDENCY" "缺少依赖 jq（或 python3），无法解析接口返回值。请安装：apt-get install -y jq"
  fi
}

# 从 JSON 文件里按点路径取值，取不到返回空串
json_get_file() {
  local file="$1"
  local expr="$2"
  local value=""
  if [ ! -f "$file" ]; then
    printf ''
    return 0
  fi
  if [ -n "$JQ_BIN" ]; then
    value="$("$JQ_BIN" -r "$expr" "$file" 2>/dev/null || true)"
  else
    value="$("$PYTHON_BIN" - "$file" "$expr" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[2].lstrip('.').split('.')
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        current = json.load(handle)
except Exception:
    print('')
    sys.exit(0)

for key in path:
    if not key:
        continue
    if isinstance(current, dict) and key in current:
        current = current[key]
    elif isinstance(current, list):
        try:
            current = current[int(key)]
        except Exception:
            print('')
            sys.exit(0)
    else:
        print('')
        sys.exit(0)

if current is None:
    print('')
elif isinstance(current, (dict, list)):
    print(json.dumps(current, ensure_ascii=False))
else:
    print(current)
PY
)"
  fi
  case "$value" in
    null) value="" ;;
  esac
  printf '%s' "$value"
}

# 格式化打印 JSON，用于把任务详情落进日志与 Summary
json_pretty_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  if [ -n "$JQ_BIN" ]; then
    "$JQ_BIN" '.' "$file" 2>/dev/null || cat "$file"
  else
    "$PYTHON_BIN" -c 'import json,sys
try:
    print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), ensure_ascii=False, indent=2))
except Exception:
    print(open(sys.argv[1], encoding="utf-8", errors="replace").read())' "$file" 2>/dev/null || cat "$file"
  fi
}

url_encode() {
  local raw="$1"
  if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$raw"
  elif [ -n "$JQ_BIN" ]; then
    "$JQ_BIN" -rn --arg v "$raw" '$v|@uri'
  else
    printf '%s' "$raw"
  fi
}

calc_sha256() {
  local file="$1"
  if [ -n "$SHA256_BIN" ]; then
    "$SHA256_BIN" <"$file" | awk '{print $1}'
  else
    "$SHASUM_BIN" -a 256 <"$file" | awk '{print $1}'
  fi
}

calc_size() {
  LC_ALL=C wc -c <"$1" | tr -d ' '
}

calc_text_hash8() {
  local text="$1"
  if [ -n "$SHA256_BIN" ]; then
    printf '%s' "$text" | "$SHA256_BIN" | cut -c1-8
  else
    printf '%s' "$text" | "$SHASUM_BIN" -a 256 | cut -c1-8
  fi
}

now_seconds() { date +%s; }

# -----------------------------------------------------------------------------
# 参数校验
# -----------------------------------------------------------------------------
require_value() {
  local name="$1"
  local value="$2"
  local hint="$3"
  if [ -z "$value" ]; then
    die "$EXIT_USAGE" "缺少必填项 $name。$hint"
  fi
}

# 判断某个值是否出现在逗号分隔的清单里（忽略空白与大小写）
value_in_list() {
  local needle="$1"
  local list="$2"
  local item=""
  local old_ifs="$IFS"
  local noglob_was_set=0
  case "$-" in
    *f*) noglob_was_set=1 ;;
  esac
  # 关掉路径名展开：清单里将来若出现 * ? [ 等字符，不会被当成通配符污染匹配
  set -f
  IFS=','
  for item in $list; do
    item="$(printf '%s' "$item" | tr -d ' \t' | tr '[:upper:]' '[:lower:]')"
    if [ -n "$item" ] && [ "$item" = "$needle" ]; then
      IFS="$old_ifs"
      [ "$noglob_was_set" -eq 1 ] || set +f
      return 0
    fi
  done
  IFS="$old_ifs"
  [ "$noglob_was_set" -eq 1 ] || set +f
  return 1
}

# 调用方权限校验：不是白名单内的仓库，一律在发起任何请求之前拦下。
# 非 GitHub Actions 环境（本地、GitLab、Jenkins）没有 GITHUB_REPOSITORY，
# 说明使用者自带凭证，不做限制，只给出提示。
guard_caller() {
  local caller="${GITHUB_REPOSITORY:-}"
  local caller_lc=""
  local owner_lc=""

  if [ -z "$caller" ]; then
    log_warn "未检测到 GITHUB_REPOSITORY（非 GitHub Actions 调用），跳过调用方白名单校验；请确认凭证由可信来源提供。"
    return 0
  fi

  caller_lc="$(printf '%s' "$caller" | tr '[:upper:]' '[:lower:]')"
  owner_lc="${caller_lc%%/*}"

  if value_in_list "$caller_lc" "$ALLOWED_CALLER_REPOSITORIES" || value_in_list "$owner_lc" "$ALLOWED_CALLER_OWNERS"; then
    log_info "调用方校验通过：$caller"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      printf 'caller_repository=%s\n' "$caller" >>"$GITHUB_OUTPUT"
    fi
    return 0
  fi

  die "$EXIT_FORBIDDEN" "调用方未授权：$caller 不在本 CICD 的调用方白名单内，已拒绝。如需接入，请联系本仓库维护者把你的仓库加入 scripts/relay-upload.sh 顶部的 ALLOWED_CALLER_OWNERS 或 ALLOWED_CALLER_REPOSITORIES。"
}

# 统一路径规范校验：与中继侧规则保持一致，先本地拦住，避免无谓请求
guard_logical_path() {
  local path="$1"

  if [ -z "$path" ]; then
    die "$EXIT_USAGE" "统一路径不能为空（示例：releases/app/v1.0.0/app.zip）"
  fi
  case "$path" in
    /*) die "$EXIT_USAGE" "统一路径不能以 / 开头：$path" ;;
    */) die "$EXIT_USAGE" "统一路径不能以 / 结尾，末尾必须是文件名：$path" ;;
  esac
  if printf '%s' "$path" | LC_ALL=C grep -q '[\\:*?"<>|]'; then
    die "$EXIT_USAGE" "统一路径含有禁用字符（\\ : * ? \" < > | 之一）：$path"
  fi
  if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "$EXIT_USAGE" "统一路径含有控制字符：$path"
  fi
  if ! printf '%s' "$path" | LC_ALL=C awk -F/ '{for(i=1;i<=NF;i++) if($i==""||$i=="."||$i==".."||$i ~ /[ .]$/) exit 1}'; then
    die "$EXIT_USAGE" "统一路径存在空段、. 或 .. 段，或以空格 / 点结尾的路径段：$path"
  fi
  if [ "$(printf '%s' "$path" | LC_ALL=C wc -c | tr -d ' ')" -gt 1024 ]; then
    die "$EXIT_USAGE" "统一路径超过 1024 字节上限：$path"
  fi
}

# 幂等键：优先显式传入；在 GitHub Actions 里用「运行 ID + 尝试次数 + job + 路径哈希」。
# 含尝试次数是有意的：重跑（re-run）会产生新键，从而重新上传并覆盖同一路径，
# 避免「重跑时重新构建了产物、却因为命中旧任务而静默沿用旧内容」；
# 同一次运行内重复上传同一路径仍会命中原任务，起到防重复分发的作用。
default_idempotency_key() {
  local seed=""
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    seed="gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}"
  else
    seed="local-$(date +%Y%m%d%H%M%S)-$$"
  fi
  printf '%s-%s' "$seed" "$(calc_text_hash8 "$RELAY_LOGICAL_PATH")"
}

validate_environment() {
  require_value "RELAY_BASE" "$RELAY_BASE" "请设置中继对外地址，例如 https://relay.example.com（不带尾斜杠）。"
  case "$RELAY_BASE" in
    http://* | https://*) ;;
    *) die "$EXIT_USAGE" "RELAY_BASE 必须是以 http:// 或 https:// 开头的地址，当前值：$RELAY_BASE" ;;
  esac
  case "$RELAY_BASE" in
    */) die "$EXIT_USAGE" "RELAY_BASE 不能带结尾斜杠：$RELAY_BASE" ;;
  esac

  require_value "RELAY_ADMIN_KEY" "$RELAY_ADMIN_KEY" "请提供管理员 Key（中继的 SR_ADMIN_API_KEY），登记统一路径必须使用它。"
  require_value "RELAY_UPLOAD_KEY" "$RELAY_UPLOAD_KEY" "请提供上传 Key（中继的 SR_UPLOAD_API_KEY），上传正文与查询任务必须使用它。"
  if [ "$RELAY_ADMIN_KEY" = "$RELAY_UPLOAD_KEY" ]; then
    die "$EXIT_USAGE" "管理员 Key 与上传 Key 不能相同，请确认密钥来源。"
  fi

  require_value "RELAY_FILE" "$RELAY_FILE" "请提供要上传的本地文件路径。"
  if [ ! -f "$RELAY_FILE" ]; then
    die "$EXIT_USAGE" "待上传文件不存在或不是普通文件：$RELAY_FILE"
  fi
  if [ ! -r "$RELAY_FILE" ]; then
    die "$EXIT_USAGE" "待上传文件不可读：$RELAY_FILE"
  fi

  require_value "RELAY_LOGICAL_PATH" "$RELAY_LOGICAL_PATH" "请提供统一逻辑路径，例如 releases/app/v1.0.0/app.zip。"
  guard_logical_path "$RELAY_LOGICAL_PATH"

  case "$RELAY_POLL_INTERVAL" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "RELAY_POLL_INTERVAL 必须是非负整数秒，当前值：$RELAY_POLL_INTERVAL" ;;
  esac
  case "$RELAY_POLL_TIMEOUT" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "RELAY_POLL_TIMEOUT 必须是非负整数秒，当前值：$RELAY_POLL_TIMEOUT" ;;
  esac
  if [ "$RELAY_POLL_TIMEOUT" -gt 0 ] && [ "$RELAY_POLL_TIMEOUT" -lt 5 ]; then
    die "$EXIT_USAGE" "RELAY_POLL_TIMEOUT 过小（至少 5 秒），当前值：$RELAY_POLL_TIMEOUT"
  fi
  case "$RELAY_HTTP_RETRY" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "RELAY_HTTP_RETRY 必须是非负整数，当前值：$RELAY_HTTP_RETRY" ;;
  esac
  case "$RELAY_CONNECT_TIMEOUT" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "RELAY_CONNECT_TIMEOUT 必须是非负整数秒，当前值：$RELAY_CONNECT_TIMEOUT" ;;
  esac
  case "$RELAY_UPLOAD_TIMEOUT" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "RELAY_UPLOAD_TIMEOUT 必须是非负整数秒（0 表示不限制），当前值：$RELAY_UPLOAD_TIMEOUT" ;;
  esac

  # 上传 Key 固定同步全部启用渠道，无法挑选渠道。这里主动拦截，避免调用方
  # 以为自己只发某个渠道，实际却被分发到全部渠道。
  if [ -n "$RELAY_CHANNELS" ]; then
    die "$EXIT_USAGE" "本 CICD 暂不支持按渠道挑选（收到 RELAY_CHANNELS=$RELAY_CHANNELS）：上传 Key 固定同步全部启用渠道，挑选渠道需要管理员 Key 的两步上传接口，当前缺少该接口契约。请清空渠道参数。"
  fi
}

# -----------------------------------------------------------------------------
# HTTP 封装：同时拿到状态码与响应正文
# -----------------------------------------------------------------------------
# http_request <输出文件> <方法> <URL> <是否允许自动重试 yes|no> [额外的 curl 参数...]
# 说明：上传正文这一步不交给 curl 自动重试，改由脚本按幂等键恢复，
#       避免盲目重发正文；其余幂等查询与登记允许 curl 自动重试。
http_request() {
  local body_file="$1"
  local method="$2"
  local url="$3"
  local allow_retry="$4"
  shift 4
  local code=""
  local -a retry_args=()
  if [ "$allow_retry" = "yes" ] && [ "$RELAY_HTTP_RETRY" -gt 0 ]; then
    retry_args=(--retry "$RELAY_HTTP_RETRY" --retry-delay 2 --retry-connrefused)
  fi

  code="$("$CURL_BIN" -sS -o "$body_file" -w '%{http_code}' \
    -X "$method" \
    --connect-timeout "$RELAY_CONNECT_TIMEOUT" \
    "${retry_args[@]+"${retry_args[@]}"}" \
    "$@" \
    "$url" 2>"$TMP_DIR/curl-error.txt")" || {
    local curl_error=""
    curl_error="$(cat "$TMP_DIR/curl-error.txt" 2>/dev/null || true)"
    log_error "请求失败：$method $(redact "$url")"
    [ -n "$curl_error" ] && log_error "curl 输出：$(redact "$curl_error")"
    printf '000'
    return 0
  }
  if is_truthy "$RELAY_DEBUG"; then
    log_info "[调试] $method $(redact "$url") → HTTP $code"
  fi
  printf '%s' "$code"
}

api_url() { printf '%s%s' "$RELAY_BASE" "$1"; }

# -----------------------------------------------------------------------------
# 业务步骤
# -----------------------------------------------------------------------------
register_logical_path() {
  local body="$TMP_DIR/register.json"
  local payload="{\"logical_path\":\"$RELAY_LOGICAL_PATH\"}"
  local code=""
  local hint=""

  code="$(http_request "$body" POST "$(api_url '/api/v1/admin/files')" yes \
    -H "Authorization: Bearer $RELAY_ADMIN_KEY" \
    -H 'Content-Type: application/json' \
    --data "$payload")"

  case "$code" in
    200 | 201)
      log_info "已登记统一路径：$RELAY_LOGICAL_PATH"
      ;;
    409)
      log_info "统一路径已登记，复用既有登记记录：$RELAY_LOGICAL_PATH"
      ;;
    401 | 403)
      die "$EXIT_REGISTER" "登记统一路径被拒绝（HTTP $code）：管理员 Key 无效或权限不足。$(json_get_file "$body" '.error')"
      ;;
    000)
      die "$EXIT_REGISTER" "登记统一路径时无法连接中继：$(api_url '/api/v1/admin/files')，请检查地址与网络。"
      ;;
    *)
      hint="$(json_get_file "$body" '.error')"
      die "$EXIT_REGISTER" "登记统一路径失败（HTTP $code）。${hint:+服务端返回：$hint}"
      ;;
  esac

  # 即便登记接口顺带返回了 id，也一律以 resolve 结果为准：
  # resolve 的 data.id 语义唯一可靠，避免登记响应字段变化时把正文传到错误的文件记录上。
  return 0
}

resolve_file_id() {
  local body="$TMP_DIR/resolve.json"
  local code=""
  local hint=""

  code="$(http_request "$body" GET "$(api_url '/api/v1/files/resolve')" yes \
    -H "Authorization: Bearer $RELAY_UPLOAD_KEY" \
    -G --data-urlencode "logical_path=$RELAY_LOGICAL_PATH")"

  case "$code" in
    200)
      local file_id=""
      file_id="$(json_get_file "$body" '.data.id')"
      if [ -z "$file_id" ]; then
        die "$EXIT_RESOLVE" "解析 file_id 失败：接口返回 200 但缺少 data.id，响应：$(json_get_file "$body" '.')"
      fi
      printf '%s' "$file_id"
      ;;
    404)
      die "$EXIT_RESOLVE" "统一路径未在中继登记：$RELAY_LOGICAL_PATH。请先确认登记步骤成功（管理员 Key 是否正确），或先用管理员接口登记该路径。"
      ;;
    409)
      hint="$(json_get_file "$body" '.error')"
      die "$EXIT_RESOLVE" "统一路径存在同名歧义（HTTP 409 ${hint:+$hint}）：请使用完整统一路径而不是只用文件名。当前路径：$RELAY_LOGICAL_PATH"
      ;;
    000)
      die "$EXIT_RESOLVE" "解析 file_id 时无法连接中继：$(api_url '/api/v1/files/resolve')"
      ;;
    *)
      hint="$(json_get_file "$body" '.error')"
      die "$EXIT_RESOLVE" "解析 file_id 失败（HTTP $code）。${hint:+服务端返回：$hint}"
      ;;
  esac
}

# 按幂等键查询既有任务：存在则复用它，避免重复分发
find_task_by_idempotency_key() {
  local idem_key="$1"
  local body="$TMP_DIR/task-by-key.json"
  local code=""

  code="$(http_request "$body" GET "$(api_url '/api/v1/tasks/by-idempotency-key')" yes \
    -H "Authorization: Bearer $RELAY_UPLOAD_KEY" \
    -G --data-urlencode "key=$idem_key")"

  case "$code" in
    200)
      local task_id=""
      task_id="$(json_get_file "$body" '.data.task_id')"
      if [ -z "$task_id" ]; then
        task_id="$(json_get_file "$body" '.data.id')"
      fi
      printf '%s' "$task_id"
      ;;
    404)
      printf ''
      ;;
    *)
      log_warn "按幂等键查询既有任务失败（HTTP $code），将按新任务继续。"
      printf ''
      ;;
  esac
}

upload_content() {
  local file_id="$1"
  local idem_key="$2"
  local sha256="$3"
  local body="$TMP_DIR/upload.json"
  local code=""
  local hint=""
  local encoded_id=""
  encoded_id="$(url_encode "$file_id")"

  local -a timeout_args=()
  if [ "$RELAY_UPLOAD_TIMEOUT" -gt 0 ]; then
    timeout_args=(--max-time "$RELAY_UPLOAD_TIMEOUT")
  fi

  code="$(http_request "$body" POST "$(api_url "/api/v1/uploads?file_id=$encoded_id")" no \
    -H "Authorization: Bearer $RELAY_UPLOAD_KEY" \
    -H "Idempotency-Key: $idem_key" \
    -H "X-Content-SHA256: $sha256" \
    -H "Content-Type: $RELAY_CONTENT_TYPE" \
    "${timeout_args[@]+"${timeout_args[@]}"}" \
    --upload-file "$RELAY_FILE")"

  case "$code" in
    200 | 201 | 202)
      local task_id=""
      task_id="$(json_get_file "$body" '.data.task_id')"
      if [ -z "$task_id" ]; then
        task_id="$(json_get_file "$body" '.data.id')"
      fi
      if [ -z "$task_id" ]; then
        die "$EXIT_UPLOAD" "上传已受理（HTTP $code）但响应缺少 task_id，无法跟踪任务。响应：$(json_pretty_file "$body")"
      fi
      printf '%s' "$task_id"
      ;;
    409)
      hint="$(json_get_file "$body" '.error')"
      printf '%s' ""
      log_warn "上传返回 409（${hint:-幂等键冲突}）：将按幂等键查询既有任务后继续。"
      ;;
    422)
      hint="$(json_get_file "$body" '.error')"
      die "$EXIT_UPLOAD" "上传被拒绝（HTTP 422 ${hint:+$hint}）：正文哈希或长度与服务端声明不一致。请确认文件在上传过程中没有被修改。"
      ;;
    401 | 403)
      die "$EXIT_UPLOAD" "上传被拒绝（HTTP $code）：上传 Key 无效或权限不足。$(json_get_file "$body" '.error')"
      ;;
    000)
      printf '%s' ""
      log_warn "上传请求未能完成（网络中断或超时），将按幂等键查询既有任务后继续。"
      ;;
    *)
      hint="$(json_get_file "$body" '.error')"
      die "$EXIT_UPLOAD" "上传失败（HTTP $code）。${hint:+服务端返回：$hint}"
      ;;
  esac
}

# 轮询到终态；成功返回 0，失败返回 1，超时返回 2
poll_task() {
  local task_id="$1"
  local body="$TMP_DIR/task.json"
  local start=""
  local state=""
  local code=""
  local elapsed=0
  local encoded_task_id=""

  encoded_task_id="$(url_encode "$task_id")"
  start="$(now_seconds)"
  while :; do
    code="$(http_request "$body" GET "$(api_url "/api/v1/tasks/$encoded_task_id")" yes \
      -H "Authorization: Bearer $RELAY_UPLOAD_KEY")"
    case "$code" in
      200)
        state="$(json_get_file "$body" '.data.state')"
        case "$state" in
          succeeded) return 0 ;;
          partial_failed | failed | cancelled) return 1 ;;
          '')
            log_warn "任务查询未返回 state，响应：$(json_pretty_file "$body")"
            ;;
          *) log_info "任务进行中：$task_id 当前状态 $state" ;;
        esac
        ;;
      404)
        log_warn "任务 $task_id 暂时查不到（HTTP 404），继续等待。"
        ;;
      *)
        log_warn "任务查询异常（HTTP $code），继续等待。"
        ;;
    esac

    elapsed=$(( $(now_seconds) - start ))
    if [ "$RELAY_POLL_TIMEOUT" -gt 0 ] && [ "$elapsed" -ge "$RELAY_POLL_TIMEOUT" ]; then
      log_error "等待任务终态超时：已等待 ${elapsed} 秒，最后状态 ${state:-未知}。"
      return 2
    fi
    log_info "已等待 ${elapsed} 秒，${RELAY_POLL_INTERVAL} 秒后重试。"
    sleep "$RELAY_POLL_INTERVAL"
  done
}

# -----------------------------------------------------------------------------
# 结果输出：GitHub Actions 用 outputs + Summary，本地直接打印
# -----------------------------------------------------------------------------
emit_result() {
  local task_id="$1"
  local state="$2"
  local file_id="$3"
  local sha256="$4"
  local size="$5"
  local detail_file="$6"

  printf '\n===== 上传结果 =====\n'
  printf '统一路径 : %s\n' "$RELAY_LOGICAL_PATH"
  printf '本地文件 : %s\n' "$RELAY_FILE"
  printf '文件大小 : %s 字节\n' "$size"
  printf 'SHA-256  : %s\n' "$sha256"
  printf 'file_id  : %s\n' "$file_id"
  printf 'task_id  : %s\n' "$task_id"
  printf '任务终态 : %s\n' "$state"
  printf '幂等键   : %s\n' "$IDEM_KEY"
  if [ -f "$detail_file" ]; then
    printf '任务详情 :\n'
    json_pretty_file "$detail_file"
  fi
  printf '====================\n'

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'task_id=%s\n' "$task_id"
      printf 'state=%s\n' "$state"
      printf 'file_id=%s\n' "$file_id"
      printf 'logical_path=%s\n' "$RELAY_LOGICAL_PATH"
      printf 'sha256=%s\n' "$sha256"
      printf 'size_bytes=%s\n' "$size"
      printf 'idempotency_key=%s\n' "$IDEM_KEY"
    } >>"$GITHUB_OUTPUT"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### 上传中继结果\n\n'
      printf '| 项目 | 值 |\n| --- | --- |\n'
      printf '| 统一路径 | `%s` |\n' "$RELAY_LOGICAL_PATH"
      printf '| 任务终态 | `%s` |\n' "$state"
      printf '| 文件大小 | %s 字节 |\n' "$size"
      printf '| SHA-256 | `%s` |\n' "$sha256"
      printf '| file_id | `%s` |\n' "$file_id"
      printf '| task_id | `%s` |\n' "$task_id"
      printf '| 幂等键 | `%s` |\n\n' "$IDEM_KEY"
    } >>"$GITHUB_STEP_SUMMARY"
    if [ -f "$detail_file" ]; then
      {
        printf '<details><summary>任务详情（各渠道结果）</summary>\n\n'
        printf '```json\n'
        json_pretty_file "$detail_file"
        printf '\n```\n\n</details>\n'
      } >>"$GITHUB_STEP_SUMMARY"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
# 临时目录：存放各步骤的响应正文，退出时自动清理
prepare_tmp_dir() {
  local base="${TMPDIR:-/tmp}"
  local dir=""
  dir="$(mktemp -d "$base/relay-upload.XXXXXX" 2>/dev/null || true)"
  if [ -z "$dir" ]; then
    dir="$base/relay-upload.$$"
    mkdir -p "$dir" || die "$EXIT_DEPENDENCY" "无法创建临时目录：$dir"
  fi
  TMP_DIR="$dir"
}

main() {
  prepare_tmp_dir

  # 调用方权限校验放在最前面：未授权的调用不会发起任何网络请求，
  # 也不会接触中继凭证。
  guard_caller

  # 仅校验权限的模式：供 reusable workflow 的 guard job 使用，
  # 此时不要求凭证、文件与统一路径，也不发起任何请求。
  if is_truthy "$RELAY_GUARD_ONLY"; then
    log_info "guard-only 模式：调用方校验完成，未发起任何请求。"
    gh_notice "调用方校验通过：${GITHUB_REPOSITORY:-本地调用}"
    exit "$EXIT_OK"
  fi

  detect_dependencies
  validate_environment

  IDEM_KEY="$RELAY_IDEMPOTENCY_KEY"
  if [ -z "$IDEM_KEY" ]; then
    IDEM_KEY="$(default_idempotency_key)"
  fi
  case "$IDEM_KEY" in
    *[[:cntrl:]]*) die "$EXIT_USAGE" "幂等键不能包含控制字符。" ;;
  esac
  if [ "$(printf '%s' "$IDEM_KEY" | LC_ALL=C wc -c | tr -d ' ')" -gt 128 ]; then
    die "$EXIT_USAGE" "幂等键不得超过 128 字节，当前长度 $(printf '%s' "$IDEM_KEY" | LC_ALL=C wc -c | tr -d ' ') 字节。"
  fi

  local size=""
  local sha256=""
  size="$(calc_size "$RELAY_FILE")"
  sha256="$(calc_sha256 "$RELAY_FILE")"

  log_info "中继地址   ：$RELAY_BASE"
  log_info "统一路径   ：$RELAY_LOGICAL_PATH"
  log_info "本地文件   ：$RELAY_FILE（$size 字节）"
  log_info "SHA-256    ：$sha256"
  log_info "幂等键     ：$IDEM_KEY"

  if is_truthy "$RELAY_DRY_RUN"; then
    log_info "dry-run 模式：仅校验参数与统一路径，不发起任何网络请求。"
    gh_notice "dry-run 通过：$RELAY_LOGICAL_PATH（$size 字节）"
    emit_result "dry-run" "dry_run" "dry-run" "$sha256" "$size" ""
    exit "$EXIT_OK"
  fi

  # 1. 登记统一路径（管理员 Key；409 表示已登记，直接复用）
  register_logical_path

  # 2. 解析 file_id：始终以 resolve 结果为准，保证目标锚定唯一
  local file_id=""
  file_id="$(resolve_file_id)"
  log_info "解析到 file_id：$file_id"

  # 3. 幂等复用：同一次运行的续跑不应重复分发
  local task_id=""
  task_id="$(find_task_by_idempotency_key "$IDEM_KEY")"
  if [ -n "$task_id" ]; then
    # 幂等复用只对「进行中 / 已成功 / 中断」有意义；若历史任务已经失败，
    # 复用只会让重跑永远复现同一个失败，必须让使用者显式换幂等键。
    local existing_state=""
    existing_state="$(json_get_file "$TMP_DIR/task-by-key.json" '.data.state')"
    case "$existing_state" in
      partial_failed | failed | cancelled)
        die "$EXIT_TASK" "幂等键对应的历史任务已结束于 $existing_state，重跑不会重新分发。task_id=$task_id；如需重新上传，请显式传入新的 idempotency-key。"
        ;;
    esac
    log_info "幂等键已存在任务（当前状态 ${existing_state:-未知}），直接复用它继续跟踪：$task_id"
  else
    # 4. 上传正文
    log_info "开始上传正文：$RELAY_FILE"
    task_id="$(upload_content "$file_id" "$IDEM_KEY" "$sha256")"
    if [ -z "$task_id" ]; then
      # 上传未能拿到 task_id（网络中断或 409），按幂等键恢复
      log_info "按幂等键尝试恢复既有任务……"
      sleep 2
      task_id="$(find_task_by_idempotency_key "$IDEM_KEY")"
      if [ -z "$task_id" ]; then
        die "$EXIT_UPLOAD" "上传未取得 task_id，且按幂等键也查不到既有任务。请稍后用幂等键 $IDEM_KEY 手动查询（GET /api/v1/tasks/by-idempotency-key?key=...）后重试。"
      fi
      log_info "已按幂等键恢复任务：$task_id"
    else
      log_info "正文已被中继接收（HTTP 202 只代表落盘受理），task_id=$task_id"
    fi
  fi

  # 5. 轮询到终态
  set +e
  poll_task "$task_id"
  local poll_result=$?
  set -e

  local final_state=""
  final_state="$(json_get_file "$TMP_DIR/task.json" '.data.state')"
  [ -n "$final_state" ] || final_state="unknown"

  case "$poll_result" in
    0)
      emit_result "$task_id" "$final_state" "$file_id" "$sha256" "$size" "$TMP_DIR/task.json"
      gh_notice "上传完成：$RELAY_LOGICAL_PATH（task_id=$task_id）"
      log_info "全部目标渠道成功。"
      return "$EXIT_OK"
      ;;
    1)
      emit_result "$task_id" "$final_state" "$file_id" "$sha256" "$size" "$TMP_DIR/task.json"
      log_error "任务结束于 $final_state，请查看上方任务详情里各渠道的错误信息。"
      return "$EXIT_TASK"
      ;;
    *)
      emit_result "$task_id" "$final_state" "$file_id" "$sha256" "$size" "$TMP_DIR/task.json"
      log_error "等待任务终态超时（超过 ${RELAY_POLL_TIMEOUT} 秒），任务可能仍在执行，请到中继查看 task_id=$task_id。"
      return "$EXIT_TIMEOUT"
      ;;
  esac
}

IDEM_KEY=""

main "$@"
