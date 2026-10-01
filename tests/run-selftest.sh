#!/usr/bin/env bash
# =============================================================================
# 上传中继统一上传脚本的端到端自测
#
# 本地（Git Bash / Linux / macOS）与 GitHub Actions 通用：
#   1. 启动 tests/mock-relay.py 模拟中继；
#   2. 对本仓库的上传脚本跑成功与失败分支；
#   3. 断言退出码、GitHub 输出文件与模拟中继的调用计数。
#
# 有 jq 的环境走 jq 解析分支，没有 jq 的环境走 python 回退分支，
# 两种环境都能覆盖到，便于本地（通常没有 jq）先行验证。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPLOAD_SCRIPT="$ROOT/scripts/relay-upload.sh"
MOCK_SCRIPT="$ROOT/tests/mock-relay.py"

ADMIN_KEY="test-admin-key"
UPLOAD_KEY="test-upload-key"

# -----------------------------------------------------------------------------
# 环境准备
# -----------------------------------------------------------------------------
pick_python() {
  local candidate=""
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'pass' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

# Windows 下的原生 python 不认 MSYS 路径（/c/... 或 /tmp/...），需要转换
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

PYTHON="$(pick_python || true)"
if [ -z "$PYTHON" ]; then
  echo '[错误] 自测需要可用的 python3（用于启动模拟中继与解析计数）。'
  exit 3
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relay-selftest.XXXXXX")"
PORT_FILE="$WORK_DIR/port"
OUTPUT_FILE="$WORK_DIR/gh-output.txt"
SUMMARY_FILE="$WORK_DIR/gh-summary.md"
LAST_LOG="$WORK_DIR/last.log"
MOCK_LOG="$WORK_DIR/mock.log"
MOCK_PID=""
BASE_URL=""

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
LAST_EXIT=0

# -----------------------------------------------------------------------------
# 断言工具
# -----------------------------------------------------------------------------
check_eq() {
  local title="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '[通过] %s\n' "$title"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '[失败] %s（期望：%s，实际：%s）\n' "$title" "$expected" "$actual"
    if [ -f "$LAST_LOG" ]; then
      sed -n '1,30p' "$LAST_LOG" | sed 's/^/    | /'
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_file_contains() {
  local title="$1"
  local needle="$2"
  local file="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
    printf '[通过] %s\n' "$title"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '[失败] %s（文件 %s 中未找到：%s）\n' "$title" "$file" "$needle"
    [ -f "$file" ] && sed -n '1,20p' "$file" | sed 's/^/    | /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# 读取模拟中继的计数
metric() {
  "$PYTHON" -c 'import json,sys,urllib.request
with urllib.request.urlopen(sys.argv[1] + "/__metrics", timeout=10) as resp:
    data = json.load(resp)
print(data["data"].get(sys.argv[2], ""))' "$BASE_URL" "$1" 2>/dev/null || printf ''
}

# 切换模拟中继的测试控制项
control() {
  "$PYTHON" -c 'import json,sys,urllib.request
payload = json.dumps(json.loads(sys.argv[2])).encode("utf-8")
request = urllib.request.Request(sys.argv[1] + "/__control", data=payload,
                                 headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(request, timeout=10) as resp:
    resp.read()' "$BASE_URL" "$1" >/dev/null 2>&1 || true
}

# run_upload <统一路径> <本地文件> [额外的 KEY=VALUE ...]
run_upload() {
  local logical_path="$1"
  local local_file="$2"
  shift 2
  : >"$OUTPUT_FILE"
  : >"$SUMMARY_FILE"
  LAST_EXIT=0
  RELAY_BASE="$BASE_URL" \
    RELAY_ADMIN_KEY="$ADMIN_KEY" \
    RELAY_UPLOAD_KEY="$UPLOAD_KEY" \
    RELAY_FILE="$local_file" \
    RELAY_LOGICAL_PATH="$logical_path" \
    GITHUB_OUTPUT="$OUTPUT_FILE" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    RELAY_POLL_INTERVAL=0 \
    RELAY_POLL_TIMEOUT=30 \
    env "$@" bash "$UPLOAD_SCRIPT" >"$LAST_LOG" 2>&1 || LAST_EXIT=$?
}

# -----------------------------------------------------------------------------
# 启动模拟中继
# -----------------------------------------------------------------------------
"$PYTHON" "$(to_native_path "$MOCK_SCRIPT")" \
  --port 0 \
  --port-file "$(to_native_path "$PORT_FILE")" \
  --admin-key "$ADMIN_KEY" \
  --upload-key "$UPLOAD_KEY" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

for _ in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
if [ ! -s "$PORT_FILE" ]; then
  echo '[错误] 模拟中继未能启动，日志如下：'
  cat "$MOCK_LOG" 2>/dev/null
  exit 3
fi
BASE_URL="http://127.0.0.1:$(cat "$PORT_FILE")"
echo "[信息] 模拟中继已就绪：$BASE_URL"
echo "[信息] python：$PYTHON；jq：$(command -v jq || echo '未安装（走 python 回退分支）')"
echo

# 测试用文件
SMALL_FILE="$WORK_DIR/payload.bin"
BIG_FILE="$WORK_DIR/payload-large.bin"
printf 'storage-relay-selftest-payload\n' >"$SMALL_FILE"
head -c 262144 /dev/urandom >"$BIG_FILE" 2>/dev/null || cp "$SMALL_FILE" "$BIG_FILE"

# -----------------------------------------------------------------------------
# 用例
# -----------------------------------------------------------------------------
echo '--- 参数校验分支 ---'

run_upload 'releases/selftest/dry-run.zip' "$SMALL_FILE" RELAY_DRY_RUN=1
check_eq 'C1 dry-run 通过且不产生任何请求' '0' "$LAST_EXIT"
check_eq 'C1 dry-run 未触发登记接口' '0' "$(metric register_created)"

run_upload '/absolute/path.zip' "$SMALL_FILE"
check_eq 'C2 绝对路径被本地拦截' '2' "$LAST_EXIT"

run_upload 'releases/selftest/bad:name.zip' "$SMALL_FILE"
check_eq 'C3 含禁用字符的路径被本地拦截' '2' "$LAST_EXIT"

run_upload 'releases/selftest/ok.zip' "$SMALL_FILE" RELAY_ADMIN_KEY=
check_eq 'C4 缺少管理员密钥时立即失败' '2' "$LAST_EXIT"

run_upload 'releases/selftest/ok.zip' "$SMALL_FILE" RELAY_CHANNELS=lanzou
check_eq 'C5 指定渠道被明确拒绝（避免误发全渠道）' '2' "$LAST_EXIT"

run_upload 'releases/selftest/missing.zip' "$WORK_DIR/not-exists.zip"
check_eq 'C6 待上传文件不存在时失败' '2' "$LAST_EXIT"

run_upload 'releases/selftest/ok.zip' "$SMALL_FILE" RELAY_IDEMPOTENCY_KEY="$(printf 'x%.0s' $(seq 1 129))"
check_eq 'C7 幂等键超过 128 字节被拒绝' '2' "$LAST_EXIT"

echo
echo '--- 正常上传分支 ---'

run_upload 'releases/selftest/app-1.0.0.zip' "$SMALL_FILE"
check_eq 'C8 正常上传并等待终态成功' '0' "$LAST_EXIT"
check_file_contains 'C8 输出 state=succeeded' 'state=succeeded' "$OUTPUT_FILE"
check_file_contains 'C8 Summary 含中文结果表头' '上传中继结果' "$SUMMARY_FILE"
check_eq 'C8 模拟中继记录了 1 次上传' '1' "$(metric upload_accepted)"

run_upload 'releases/selftest/app-1.0.0.zip' "$SMALL_FILE"
check_eq 'C9 统一路径重复登记自动复用（409）' '0' "$LAST_EXIT"
check_eq 'C9 复用登记未新建记录' '1' "$(metric register_created)"

UPLOAD_BEFORE="$(metric upload_accepted)"
run_upload 'releases/selftest/app-1.0.0.zip' "$SMALL_FILE" RELAY_IDEMPOTENCY_KEY=idem-selftest-fixed
run_upload 'releases/selftest/app-1.0.0.zip' "$SMALL_FILE" RELAY_IDEMPOTENCY_KEY=idem-selftest-fixed
UPLOAD_AFTER="$(metric upload_accepted)"
check_eq 'C10 同一幂等键第二次运行复用任务不重复上传' "$((UPLOAD_BEFORE + 1))" "$UPLOAD_AFTER"

run_upload 'releases/selftest/App-1.0.1.ZIP' "$BIG_FILE"
check_eq 'C11 256KB 文件流式上传成功' '0' "$LAST_EXIT"
check_file_contains 'C11 输出 sha256' 'sha256=' "$OUTPUT_FILE"

run_upload 'releases/selftest/app-1.0.2.zip' "$BIG_FILE" RELAY_IDEMPOTENCY_KEY=''
check_eq 'C12 未显式指定幂等键时自动生成并成功' '0' "$LAST_EXIT"

echo
echo '--- 失败分支 ---'

control '{"task_state": "partial_failed"}'
run_upload 'releases/selftest/app-1.0.3.zip' "$SMALL_FILE"
check_eq 'C13 任务部分失败时以退出码 7 结束' '7' "$LAST_EXIT"
check_file_contains 'C13 输出记录失败终态' 'state=partial_failed' "$OUTPUT_FILE"
control '{"task_state": "succeeded"}'

control '{"force_checksum_mismatch": true}'
run_upload 'releases/selftest/app-1.0.4.zip' "$SMALL_FILE"
check_eq 'C14 正文哈希不匹配时以退出码 6 结束' '6' "$LAST_EXIT"
check_file_contains 'C14 错误提示指出哈希不一致' '服务端声明不一致' "$LAST_LOG"
control '{"force_checksum_mismatch": false}'

# 模拟「登记返回 409 且带上 data.id，但 resolve 查不到」的不一致窗口：
# 错误实现会拿登记响应里的 id 直接上传并成功，正确实现必须以 resolve 为准并以退出码 5 结束
run_upload 'releases/selftest/app-1.0.5.zip' "$SMALL_FILE"
check_eq 'C15 前置：先完成一次登记与上传' '0' "$LAST_EXIT"
control '{"hide_existing_id": false, "resolve_hidden": "releases/selftest/app-1.0.5.zip"}'
run_upload 'releases/selftest/app-1.0.5.zip' "$SMALL_FILE"
check_eq 'C15 登记返回 id 但 resolve 查不到时以退出码 5 结束' '5' "$LAST_EXIT"
check_file_contains 'C15 错误提示指明路径未登记' '未在中继登记' "$LAST_LOG"
control '{"hide_existing_id": false, "resolve_hidden": ""}'

run_upload 'releases/selftest/app-1.0.6.zip' "$SMALL_FILE" RELAY_UPLOAD_KEY=wrong-upload-key
check_eq 'C16 上传密钥错误时以退出码 5 结束' '5' "$LAST_EXIT"

run_upload 'releases/selftest/app-1.0.7.zip' "$SMALL_FILE" RELAY_BASE=http://127.0.0.1:9
check_eq 'C17 中继不可达时以退出码 4 结束' '4' "$LAST_EXIT"

# 历史任务已经失败时，幂等复用必须明确报错，而不是让重跑永远复现同一个失败
control '{"task_state": "partial_failed"}'
run_upload 'releases/selftest/app-1.0.8.zip' "$SMALL_FILE" RELAY_IDEMPOTENCY_KEY=idem-failed-case
check_eq 'C18 首次运行以部分失败结束' '7' "$LAST_EXIT"
control '{"task_state": "succeeded"}'
run_upload 'releases/selftest/app-1.0.8.zip' "$SMALL_FILE" RELAY_IDEMPOTENCY_KEY=idem-failed-case
check_eq 'C18 同一幂等键重跑仍以退出码 7 结束（不复用失败任务）' '7' "$LAST_EXIT"
check_file_contains 'C18 提示改用新的幂等键' '请显式传入新的 idempotency-key' "$LAST_LOG"

# debug 开关必须真的产生调试信息
run_upload 'releases/selftest/app-1.0.9.zip' "$SMALL_FILE" RELAY_DEBUG=1
check_eq 'C19 debug 模式下上传仍然成功' '0' "$LAST_EXIT"
check_file_contains 'C19 输出请求调试行' '[调试]' "$LAST_LOG"

echo
echo '--- 调用方权限分支 ---'

# 未授权仓库必须在发起任何请求之前被拦下（白名单写在脚本里，调用方无法自我授权）
REGISTER_BEFORE="$(metric register_created)"
run_upload 'releases/selftest/guard-1.zip' "$SMALL_FILE" GITHUB_REPOSITORY=evil-org/evil-repo
check_eq 'C20 未授权仓库被拒绝（退出码 9）' '9' "$LAST_EXIT"
check_eq 'C20 未授权调用未发起任何登记请求' "$REGISTER_BEFORE" "$(metric register_created)"
check_file_contains 'C20 提示未授权原因' '不在本 CICD 的调用方白名单内' "$LAST_LOG"

# 仓库名相同但 owner 不同，不能蒙混过关
run_upload 'releases/selftest/guard-2.zip' "$SMALL_FILE" GITHUB_REPOSITORY=evil-org/Download_Station_CICD
check_eq 'C21 同名不同 owner 的仓库被拒绝' '9' "$LAST_EXIT"

# 白名单 owner 下的其它仓库放行，且 owner 匹配大小写不敏感
run_upload 'releases/selftest/guard-3.zip' "$SMALL_FILE" GITHUB_REPOSITORY=yxsj245/any-other-project
check_eq 'C22 白名单 owner 下的仓库放行' '0' "$LAST_EXIT"
run_upload 'releases/selftest/guard-4.zip' "$SMALL_FILE" GITHUB_REPOSITORY=YXSJ245/Some-Repo
check_eq 'C23 owner 匹配大小写不敏感' '0' "$LAST_EXIT"

# guard-only 模式：只校验权限，不需要凭证、文件与统一路径
: >"$OUTPUT_FILE"
LAST_EXIT=0
GITHUB_REPOSITORY=yxsj245/Download_Station_CICD RELAY_GUARD_ONLY=1 GITHUB_OUTPUT="$OUTPUT_FILE" \
  bash "$UPLOAD_SCRIPT" >"$LAST_LOG" 2>&1 || LAST_EXIT=$?
check_eq 'C24 guard-only 模式在授权仓库下通过' '0' "$LAST_EXIT"
check_file_contains 'C24 guard-only 输出调用方仓库' 'caller_repository=yxsj245/Download_Station_CICD' "$OUTPUT_FILE"

LAST_EXIT=0
GITHUB_REPOSITORY=evil-org/evil-repo RELAY_GUARD_ONLY=1 \
  bash "$UPLOAD_SCRIPT" >"$LAST_LOG" 2>&1 || LAST_EXIT=$?
check_eq 'C25 guard-only 模式在未授权仓库下以退出码 9 结束' '9' "$LAST_EXIT"

# 白名单是 readonly 常量：调用方注入同名环境变量也不能自我授权
run_upload 'releases/selftest/guard-5.zip' "$SMALL_FILE" \
  ALLOWED_CALLER_OWNERS=evil-org \
  ALLOWED_CALLER_REPOSITORIES=evil-org/evil-repo \
  GITHUB_REPOSITORY=evil-org/evil-repo
check_eq 'C26 外部注入同名白名单变量不能自我授权' '9' "$LAST_EXIT"

# 默认幂等键含尝试次数：重跑（新 attempt）必须重新上传并覆盖，而不是静默复用旧任务
UPLOAD_BEFORE="$(metric upload_accepted)"
run_upload 'releases/selftest/app-1.1.0.zip' "$SMALL_FILE" GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=1
check_eq 'C27 首次尝试上传成功' '0' "$LAST_EXIT"
run_upload 'releases/selftest/app-1.1.0.zip' "$SMALL_FILE" GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=2
check_eq 'C27 第二次尝试重新上传（覆盖）而非复用旧任务' "$((UPLOAD_BEFORE + 2))" "$(metric upload_accepted)"

# 当前白名单：yxsj245、QVMConsole（整个组织）、GSManagerXZ/GameServerManager（精确仓库）
run_upload 'releases/selftest/guard-6.zip' "$SMALL_FILE" GITHUB_REPOSITORY=QVMConsole/any-project
check_eq 'C28 QVMConsole 组织下的仓库放行' '0' "$LAST_EXIT"
run_upload 'releases/selftest/guard-7.zip' "$SMALL_FILE" GITHUB_REPOSITORY=qvmconsole/lower-case-repo
check_eq 'C29 QVMConsole 组织匹配大小写不敏感' '0' "$LAST_EXIT"
run_upload 'releases/selftest/guard-8.zip' "$SMALL_FILE" GITHUB_REPOSITORY=GSManagerXZ/GameServerManager
check_eq 'C30 白名单里的精确仓库放行' '0' "$LAST_EXIT"
run_upload 'releases/selftest/guard-9.zip' "$SMALL_FILE" GITHUB_REPOSITORY=GSManagerXZ/other-repo
check_eq 'C31 GSManagerXZ 下未列出的仓库仍被拒绝' '9' "$LAST_EXIT"

# -----------------------------------------------------------------------------
# 汇总
# -----------------------------------------------------------------------------
echo
printf '===== 自测结果：通过 %d，失败 %d =====\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
