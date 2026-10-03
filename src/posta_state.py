#!/usr/bin/env python3
"""posta_state — 监工台共享状态引擎（只读）

供 TUI（posta_tui.py）与将来的 Web 层共用。复用 dispatchd 的
分类/路由逻辑，但绝不写 seen.json/pending.json——状态变更的唯一
写入口是巡查 cron 跑的 dispatchd 本体。
"""
import json, os, re, time
from pathlib import Path

from dispatchd import WATCH, ROSTER, agent_of, load_routes, classify  # noqa: F401

HOME = Path.home()
LAB = Path(os.environ.get("POSTA_HOME", str(HOME / "posta-lab")))
RUNBOOK = LAB / "agent" / "RUNBOOK.md"
DISPATCH_LOG = LAB / "logs" / "dispatch.log"


def packages(limit_per_box: int = 8):
    """三个信箱的最新包裹，按 mtime 降序。返回 [(kind, name, agent, action, mtime_str)]"""
    routes = load_routes()
    out = []
    for kind, root in WATCH.items():
        if not root.is_dir():
            continue
        pkgs = sorted(root.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
        for pkg in pkgs[:limit_per_box]:
            if not pkg.is_dir():
                continue
            agent = agent_of(pkg.name)
            if agent is None:
                for frag, r in routes.items():
                    if frag in pkg.name:
                        agent = r
                        break
            try:
                action = classify(kind, pkg)
            except Exception:
                action = "?"
            mt = time.strftime("%m-%d %H:%M", time.localtime(pkg.stat().st_mtime))
            out.append((kind, pkg.name, agent or "?", action, mt))
    return out


def short_status(status: str) -> str:
    """长状态 → 短标签（供表格窄列显示；原文仍存登记表）"""
    s = status.replace("**", "")
    if "全链关闭" in s:
        return "✅ 已关闭"
    if "收尾" in s and "执行中" in s:
        return "▸ CTO收尾"
    if "待CTO终审" in s:
        return "✓ 待终审"
    if s.startswith("running"):
        if "返工" in s:
            return "▶ 返工中"
        return "▶ 执行中"
    if "FAIL" in s:
        return "✗ FAIL"
    return s[:20]


def runbook_tasks():
    """解析 RUNBOOK 登记表（§活跃任务）。返回 [dict(task,status,short,rounds,note)]"""
    if not RUNBOOK.exists():
        return []
    rows = []
    in_table = False
    for line in RUNBOOK.read_text().splitlines():
        if line.startswith("|") and "任务" in line and "状态" in line:
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                in_table = False
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 4 and cells[0] not in ("任务",) and not set(cells[0]) <= {"-", " ", ":"}:
                rows.append({
                    "task": cells[0], "status": cells[1],
                    "short": short_status(cells[1]),
                    "rounds": cells[2], "note": cells[3],
                })
    return rows


def active_log_follow_lines(max_lines: int = 40):
    """找登记表中 running 任务的最新 session-live*.log，返回 (path, 尾部行列表)"""
    for t in runbook_tasks():
        if not t["status"].startswith("running"):
            continue
        task_dir = HOME / "cto-tasks" / t["task"]
        if not task_dir.is_dir():
            continue
        logs = sorted(task_dir.glob("session-live*.log"),
                      key=lambda p: p.stat().st_mtime)
        if not logs:
            continue
        newest = logs[-1]
        try:
            lines = newest.read_text(errors="replace").splitlines()[-max_lines:]
        except OSError:
            continue
        return newest, lines
    return None, []


def dispatch_events(max_lines: int = 30):
    if not DISPATCH_LOG.exists():
        return []
    return DISPATCH_LOG.read_text(errors="replace").splitlines()[-max_lines:]


def summary():
    pkgs = packages(limit_per_box=200)
    return {
        "total_packages": len(pkgs),
        "by_kind": {k: sum(1 for p in pkgs if p[0] == k) for k in WATCH},
        "pending_cto": sum(1 for p in pkgs if p[0] == "REPORT" and "待审核" in p[3]),
        "running": [t for t in runbook_tasks() if t["status"].startswith("running")],
    }


if __name__ == "__main__":
    print(json.dumps(summary(), ensure_ascii=False, indent=1))
    for row in runbook_tasks():
        print(row["task"], "→", row["status"])
