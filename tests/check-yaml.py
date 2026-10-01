#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本仓库 YAML 配置自检。

检查项：
  1. 全部 workflow 与 composite action 能被 YAML 解析；
  2. workflow 具备 name / on / jobs，每个 job 具备 runs-on 或 uses；
  3. composite action 具备 name / description / runs.using=composite，
     且每个 run 步骤都显式声明 shell（composite action 的硬性要求）；
  4. composite action 的 outputs 只引用真实存在的 step id；
  5. workflow 里引用本仓库 action 时，对应目录下确实存在 action.yml；
  6. reusable workflow 的 outputs 只引用真实存在的 job。

依赖：pyyaml（python -m pip install pyyaml）。
"""

import os
import sys

try:
    import yaml
except ImportError:
    print('[错误] 缺少 pyyaml，请先执行：python -m pip install pyyaml')
    sys.exit(3)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF_REPO = 'yxsj245/Download_Station_CICD'
ERRORS = []
CHECKS = 0


def normalize(node):
    """YAML 1.1 会把裸写的 on 解析成布尔 True，这里统一还原成 'on'。"""
    if isinstance(node, dict):
        return {('on' if key is True else key): normalize(value) for key, value in node.items()}
    if isinstance(node, list):
        return [normalize(item) for item in node]
    return node


def load_yaml(path):
    with open(path, encoding='utf-8') as handle:
        return normalize(yaml.safe_load(handle))


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        ERRORS.append(message)


def check_workflow(path):
    rel = os.path.relpath(path, ROOT).replace('\\', '/')
    data = load_yaml(path)
    check(isinstance(data, dict), '%s：顶层结构不是映射' % rel)
    if not isinstance(data, dict):
        return
    check(bool(data.get('name')), '%s：缺少 name' % rel)
    triggers = data.get('on')
    check(triggers is not None, '%s：缺少 on 触发器定义' % rel)

    jobs = data.get('jobs') or {}
    check(isinstance(jobs, dict) and bool(jobs), '%s：jobs 为空' % rel)
    for job_name, job in (jobs or {}).items():
        if not isinstance(job, dict):
            check(False, '%s：job %s 结构异常' % (rel, job_name))
            continue
        has_runner = bool(job.get('runs-on'))
        has_uses = bool(job.get('uses'))
        check(has_runner or has_uses, '%s：job %s 既没有 runs-on 也没有 uses' % (rel, job_name))
        for index, step in enumerate(job.get('steps') or [], start=1):
            if not isinstance(step, dict):
                check(False, '%s：job %s 第 %d 个步骤结构异常' % (rel, job_name, index))
                continue
            check(bool(step.get('uses')) or bool(step.get('run')),
                  '%s：job %s 第 %d 个步骤既没有 uses 也没有 run' % (rel, job_name, index))
            uses = step.get('uses')
            # 支持两种自引用写法：$/ 自仓库语法，以及硬编码本仓库坐标
            if isinstance(uses, str) and (uses.startswith('$/') or uses.startswith(SELF_REPO + '/')):
                relative = uses[2:] if uses.startswith('$/') else uses[len(SELF_REPO) + 1:]
                action_dir = relative.split('@')[0]
                action_file = os.path.join(ROOT, *action_dir.split('/'), 'action.yml')
                check(os.path.isfile(action_file),
                      '%s：引用 %s 但缺少 %s' % (rel, uses, os.path.relpath(action_file, ROOT)))

    if isinstance(triggers, dict) and 'workflow_call' in triggers:
        call = triggers['workflow_call'] or {}
        outputs = call.get('outputs') or {}
        for output_name, output in outputs.items():
            value = (output or {}).get('value', '') if isinstance(output, dict) else ''
            check('jobs.' in str(value), '%s：output %s 的 value 未引用 jobs 上下文' % (rel, output_name))
            matched = any('jobs.%s.' % job_name in str(value) for job_name in jobs)
            check(matched, '%s：output %s 引用了不存在的 job（%s）' % (rel, output_name, value))


def check_composite_action(path):
    rel = os.path.relpath(path, ROOT).replace('\\', '/')
    data = load_yaml(path)
    check(isinstance(data, dict), '%s：顶层结构不是映射' % rel)
    if not isinstance(data, dict):
        return
    check(bool(data.get('name')), '%s：缺少 name' % rel)
    check(bool(data.get('description')), '%s：缺少 description' % rel)

    runs = data.get('runs') or {}
    check(isinstance(runs, dict), '%s：runs 结构异常' % rel)
    check(runs.get('using') == 'composite', '%s：runs.using 必须是 composite' % rel)

    step_ids = set()
    for index, step in enumerate(runs.get('steps') or [], start=1):
        if not isinstance(step, dict):
            check(False, '%s：第 %d 个步骤结构异常' % (rel, index))
            continue
        if step.get('id'):
            step_ids.add(step['id'])
        if step.get('run'):
            check(bool(step.get('shell')),
                  '%s：第 %d 个 run 步骤缺少 shell（composite action 必须显式声明）' % (rel, index))
        else:
            check(bool(step.get('uses')), '%s：第 %d 个步骤既没有 uses 也没有 run' % (rel, index))

    for output_name, output in (data.get('outputs') or {}).items():
        value = (output or {}).get('value', '') if isinstance(output, dict) else ''
        check('steps.' in str(value), '%s：output %s 的 value 未引用 steps 上下文' % (rel, output_name))
        referenced = None
        if 'steps.' in str(value):
            referenced = str(value).split('steps.', 1)[1].split('.', 1)[0]
        if referenced:
            check(referenced in step_ids,
                  '%s：output %s 引用了不存在的 step id（%s）' % (rel, output_name, referenced))

    for input_name, spec in (data.get('inputs') or {}).items():
        check(isinstance(spec, dict) and bool(spec.get('description')),
              '%s：input %s 缺少 description' % (rel, input_name))


def main():
    workflow_dir = os.path.join(ROOT, '.github', 'workflows')
    workflows = sorted(
        os.path.join(workflow_dir, name)
        for name in os.listdir(workflow_dir)
        if name.endswith(('.yml', '.yaml'))
    ) if os.path.isdir(workflow_dir) else []
    check(bool(workflows), '未找到任何 workflow 文件')
    for path in workflows:
        check_workflow(path)

    for dirpath, _dirnames, filenames in os.walk(ROOT):
        if os.sep + '.git' in dirpath:
            continue
        for name in filenames:
            if name in ('action.yml', 'action.yaml'):
                check_composite_action(os.path.join(dirpath, name))

    if ERRORS:
        print('[失败] YAML 自检发现 %d 个问题：' % len(ERRORS))
        for item in ERRORS:
            print('  - %s' % item)
        return 1
    print('[通过] YAML 自检完成，共 %d 项检查。' % CHECKS)
    return 0


if __name__ == '__main__':
    sys.exit(main())
