#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""上传中继模拟服务（仅用于本仓库自测，不参与生产部署）。

模拟 Storage Relay 的最小接口契约，供 tests/run-selftest.sh 做端到端验证：

    POST /api/v1/admin/files                     登记统一路径
    GET  /api/v1/files/resolve?logical_path=     解析 file_id
    POST /api/v1/uploads?file_id=                上传正文（按幂等键去重）
    GET  /api/v1/tasks/<task_id>                 查询任务终态
    GET  /api/v1/tasks/by-idempotency-key?key=   按幂等键查任务
    POST /__control                              测试控制面（切换任务终态等）
    GET  /__metrics                              调用计数，供断言使用

这个模拟服务只实现脚本真正依赖的字段，字段名以仓库文档记录的接口为准；
真实中继的完整契约请以项目提供的 openapi.yaml 为准。
"""

import argparse
import hashlib
import json
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ADMIN_KEY = ""
UPLOAD_KEY = ""
VERBOSE = False

LOCK = threading.Lock()
FILES = {}       # 归一化统一路径 -> file_id
RAW_PATHS = {}   # file_id -> 原始统一路径
TASKS = {}       # task_id -> 任务详情
IDEM_INDEX = {}  # 幂等键 -> task_id
METRICS = {
    "register_created": 0,
    "register_reused": 0,
    "resolve_ok": 0,
    "resolve_missing": 0,
    "upload_accepted": 0,
    "upload_rejected": 0,
    "idem_reuse": 0,
    "task_poll": 0,
}
CONTROL = {
    "task_state": "succeeded",
    "force_checksum_mismatch": False,
    # 模拟「登记返回 409 但不带 data.id」，用于验证脚本一定走 resolve
    "hide_existing_id": False,
    # 模拟「登记成功但 resolve 查不到」的最终一致性窗口
    "resolve_hidden": "",
}


def normalize_path(logical_path):
    """与中继一致：查重时按路径段做 ASCII 小写比较。"""
    return "/".join(segment.lower() for segment in logical_path.split("/"))


def build_targets(state):
    if state == "succeeded":
        return [
            {"channel": "lanzou", "status": "succeeded"},
            {"channel": "sftp-backup", "status": "succeeded"},
        ]
    if state == "partial_failed":
        return [
            {"channel": "lanzou", "status": "succeeded"},
            {"channel": "sftp-backup", "status": "failed", "error": "渠道连接超时"},
        ]
    return [{"channel": "lanzou", "status": state, "error": "任务未成功完成"}]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockRelay/1.0"

    # ------------------------------------------------------------------ 工具
    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write("[mock-relay] " + (fmt % args) + "\n")

    def send_json(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def bearer_role(self):
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return None
        token = header[len("Bearer "):]
        if token == ADMIN_KEY:
            return "admin"
        if token == UPLOAD_KEY:
            return "upload"
        return None

    # ------------------------------------------------------------------ GET
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path == "/__metrics":
            with LOCK:
                self.send_json(200, {"data": dict(METRICS)})
            return

        if path == "/api/v1/files/resolve":
            if self.bearer_role() != "upload":
                self.send_json(401, {"error": "UNAUTHORIZED"})
                return
            logical_path = (query.get("logical_path") or [""])[0]
            with LOCK:
                hidden = CONTROL["resolve_hidden"]
                if hidden and normalize_path(hidden) == normalize_path(logical_path):
                    METRICS["resolve_missing"] += 1
                    self.send_json(404, {"error": "FILE_NOT_FOUND"})
                    return
                file_id = FILES.get(normalize_path(logical_path))
                if file_id:
                    METRICS["resolve_ok"] += 1
                    self.send_json(200, {"data": {"id": file_id, "logical_path": logical_path}})
                    return
                # 只给文件名且存在多条同名记录时返回 409，模拟真实中继的歧义保护
                if "/" not in logical_path:
                    matches = [fid for fid, raw in RAW_PATHS.items()
                               if raw.split("/")[-1].lower() == logical_path.lower()]
                    if len(matches) > 1:
                        METRICS["resolve_missing"] += 1
                        self.send_json(409, {"error": "FILE_NAME_AMBIGUOUS"})
                        return
                METRICS["resolve_missing"] += 1
            self.send_json(404, {"error": "FILE_NOT_FOUND"})
            return

        if path == "/api/v1/tasks/by-idempotency-key":
            if self.bearer_role() != "upload":
                self.send_json(401, {"error": "UNAUTHORIZED"})
                return
            key = (query.get("key") or [""])[0]
            with LOCK:
                task_id = IDEM_INDEX.get(key)
                if not task_id:
                    self.send_json(404, {"error": "TASK_NOT_FOUND"})
                    return
                METRICS["task_poll"] += 1
                task = TASKS[task_id]
            self.send_json(200, {"data": dict(task)})
            return

        if path.startswith("/api/v1/tasks/"):
            if self.bearer_role() != "upload":
                self.send_json(401, {"error": "UNAUTHORIZED"})
                return
            task_id = path[len("/api/v1/tasks/"):]
            with LOCK:
                task = TASKS.get(task_id)
                if task:
                    METRICS["task_poll"] += 1
            if not task:
                self.send_json(404, {"error": "TASK_NOT_FOUND"})
                return
            self.send_json(200, {"data": dict(task)})
            return

        self.send_json(404, {"error": "NOT_FOUND"})

    # ----------------------------------------------------------------- POST
    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path == "/__control":
            body = self.read_body()
            try:
                payload = json.loads(body.decode("utf-8") or "{}")
            except Exception:
                self.send_json(400, {"error": "BAD_CONTROL_BODY"})
                return
            with LOCK:
                if "task_state" in payload:
                    CONTROL["task_state"] = payload["task_state"]
                if "force_checksum_mismatch" in payload:
                    CONTROL["force_checksum_mismatch"] = bool(payload["force_checksum_mismatch"])
                if "hide_existing_id" in payload:
                    CONTROL["hide_existing_id"] = bool(payload["hide_existing_id"])
                if "resolve_hidden" in payload:
                    CONTROL["resolve_hidden"] = payload["resolve_hidden"] or ""
                if "drop_file" in payload:
                    target = normalize_path(payload["drop_file"])
                    file_id = FILES.pop(target, None)
                    if file_id:
                        RAW_PATHS.pop(file_id, None)
            self.send_json(200, {"data": dict(CONTROL)})
            return

        if path == "/api/v1/admin/files":
            if self.bearer_role() != "admin":
                self.send_json(401, {"error": "UNAUTHORIZED"})
                return
            body = self.read_body()
            try:
                payload = json.loads(body.decode("utf-8") or "{}")
            except Exception:
                self.send_json(400, {"error": "BAD_JSON"})
                return
            logical_path = payload.get("logical_path") or ""
            if not logical_path:
                self.send_json(400, {"error": "LOGICAL_PATH_REQUIRED"})
                return
            with LOCK:
                key = normalize_path(logical_path)
                if key in FILES:
                    METRICS["register_reused"] += 1
                    conflict = {"error": "FILE_PATH_EXISTS"}
                    if not CONTROL["hide_existing_id"]:
                        conflict["data"] = {"id": FILES[key]}
                    self.send_json(409, conflict)
                    return
                file_id = str(uuid.uuid4())
                FILES[key] = file_id
                RAW_PATHS[file_id] = logical_path
                METRICS["register_created"] += 1
            self.send_json(201, {"data": {"id": file_id, "logical_path": logical_path}})
            return

        if path == "/api/v1/uploads":
            if self.bearer_role() != "upload":
                self.send_json(401, {"error": "UNAUTHORIZED"})
                return
            file_id = (query.get("file_id") or [""])[0]
            idem_key = self.headers.get("Idempotency-Key") or ""
            declared_sha = (self.headers.get("X-Content-SHA256") or "").lower()
            content = self.read_body()

            if not idem_key:
                self.send_json(400, {"error": "IDEMPOTENCY_KEY_REQUIRED"})
                return

            with LOCK:
                known_file = file_id in RAW_PATHS
                existing_task = IDEM_INDEX.get(idem_key)
                force_bad = CONTROL["force_checksum_mismatch"]
            if not known_file:
                self.send_json(404, {"error": "FILE_NOT_FOUND"})
                return

            if existing_task:
                with LOCK:
                    METRICS["idem_reuse"] += 1
                    task = dict(TASKS[existing_task])
                self.send_json(200, {"data": task})
                return

            actual_sha = hashlib.sha256(content).hexdigest()
            if force_bad or (declared_sha and declared_sha != actual_sha):
                with LOCK:
                    METRICS["upload_rejected"] += 1
                self.send_json(422, {"error": "CHECKSUM_MISMATCH"})
                return

            with LOCK:
                state = CONTROL["task_state"]
                task_id = str(uuid.uuid4())
                task = {
                    "task_id": task_id,
                    "state": state,
                    "file_id": file_id,
                    "logical_path": RAW_PATHS.get(file_id, ""),
                    "idempotency_key": idem_key,
                    "size": len(content),
                    "sha256": actual_sha,
                    "targets": build_targets(state),
                }
                TASKS[task_id] = task
                IDEM_INDEX[idem_key] = task_id
                METRICS["upload_accepted"] += 1
            self.send_json(202, {"data": dict(task)})
            return

        self.send_json(404, {"error": "NOT_FOUND"})


def main():
    global ADMIN_KEY, UPLOAD_KEY, VERBOSE

    parser = argparse.ArgumentParser(description="上传中继模拟服务（自测用）")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 表示由系统分配空闲端口")
    parser.add_argument("--port-file", default="", help="把实际监听端口写入该文件")
    parser.add_argument("--admin-key", required=True)
    parser.add_argument("--upload-key", required=True)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    ADMIN_KEY = args.admin_key
    UPLOAD_KEY = args.upload_key
    VERBOSE = args.verbose

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    actual_port = server.server_address[1]
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as handle:
            handle.write(str(actual_port))
    sys.stderr.write("[mock-relay] 已启动：http://%s:%d\n" % (args.host, actual_port))
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
