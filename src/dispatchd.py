#!/usr/bin/env python3
"""dispatchd — Posta 信箱扫描器（包裹分类/路由/登记）

监视三个信箱目录（默认 ~/cto-tasks 等，可在 WATCH 中改），
识别新包裹、按目录名后缀判定目标 agent，把"应该发生的传递"
写入 lab/logs/dispatch.log 和 lab/state/pending.json。

只有同时满足 (1) agent 在 ROSTER 且 CLI 存在 (2) agent 在 ENABLED 集合
才会真正生成派发命令；ENABLED 默认为空 = 只记录，不启动任何 agent。
"""
import json, os, shutil, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
LAB = Path(os.environ.get("POSTA_HOME", str(HOME / "posta-lab")))
STATE = LAB / "state"
LOGS = LAB / "logs"
SEEN = STATE / "seen.json"
PENDING = STATE / "pending.json"
DISPATCH_LOG = LOGS / "dispatch.log"

WATCH = {
    "TASK": HOME / "cto-tasks",           # CTO → worker 任务包
    "REPORT": HOME / "AI_REPORT_INBOX",   # worker → CTO 报告 / CTO 裁决 / 回执
    "HANDOFF": HOME / "cto-handoffs",     # CTO 交接包
}

# ROSTER 自 TEAM_ROSTER.json 加载（团队注册表=互相认识的唯一事实来源）
# 结构: {suffix: (cli模板或None, 说明, launch_mode)}；launch_mode=cli 才允许被监工无头派发
ROSTER_FILE = LAB / "agent" / "TEAM_ROSTER.json"

def load_roster():
    """从 TEAM_ROSTER.json 构建花名册；文件缺失时回退内置最小表"""
    fallback = {
        "zcode": (["zcode"], "zcode CLI", "cli"),
        "kilo": (["kilo"], "kilo CLI", "cli"),
        "codexl": (["codex", "exec"], "Codex CLI", "desktop-human"),
        "claude": (["claude", "-p"], "Claude Code CLI", "cli"),
        "opencode": (["opencode"], "opencode CLI", "cli"),
        "gemini": (["gemini"], "gemini CLI", "cli"),
        "zl1": (None, "未确认", "unknown"),
    }
    if not ROSTER_FILE.exists():
        return fallback
    roster = {}
    for a in json.loads(ROSTER_FILE.read_text()).get("agents", []):
        sfx = a.get("suffix")
        if not sfx:
            continue  # CTO 等无包裹后缀的成员
        launch = a.get("launch", {})
        cli = launch.get("cli")
        roster[sfx] = (cli, a.get("display", sfx), launch.get("mode", "unknown"))
    return roster or fallback

ROSTER = load_roster()

# 允许真实无头派发的 agent 后缀；空集 = 纯记录模式
ENABLED = set()

# 路由覆盖：目录名（子串匹配）→ agent 后缀。用于 CTO 指令固定了无后缀目录名的情况。
ROUTES_FILE = STATE / "routes.json"

def load_routes():
    if ROUTES_FILE.exists():
        return json.loads(ROUTES_FILE.read_text())
    return {}

def load_seen():
    if SEEN.exists():
        return json.loads(SEEN.read_text())
    return {}

def save_seen(seen):
    STATE.mkdir(parents=True, exist_ok=True)
    SEEN.write_text(json.dumps(seen, ensure_ascii=False, indent=1))

def agent_of(dirname: str):
    """从目录名尾部提取 agent 后缀（最后一段 -xxx 在 ROSTER 中即命中）"""
    parts = dirname.split("-")
    for i in range(len(parts) - 1, 0, -1):
        if parts[i] in ROSTER:
            return parts[i]
    return None

def classify(kind: str, path: Path) -> str:
    """判定包裹里最新发生的事件，决定该通知谁"""
    if kind == "TASK":
        return "worker: 领取任务，按包内指令执行"
    if kind == "HANDOFF":
        return "worker: 接收交接包（含 git bundle + DIRECTIVE）"
    # REPORT 包：空交付占位目录不算待审报告（只看文件，子目录本身不算内容）
    if path.exists() and not any(f for f in path.rglob("*") if f.is_file()):
        return "占位：交付目录已建，任务尚未执行"
    # REPORT 包：看子目录推断最新事件
    subs = sorted(p.name for p in path.iterdir() if p.is_dir()) if path.exists() else []
    has_cto = any("cto" in s.lower() for s in subs)
    has_receipt = any("receipt" in s.lower() for s in subs)
    if has_receipt:
        return "cto: worker 已回执，可推进 NEXT_GATE"
    if has_cto:
        return "worker: CTO 裁决已出，按 disposition 执行"
    return "cto: 有新报告待审核"

def main():
    seen = load_seen()
    routes = load_routes()
    now = time.time()
    events = []
    for kind, root in WATCH.items():
        if not root.is_dir():
            continue
        for pkg in sorted(root.iterdir()):
            if not pkg.is_dir():
                continue
            key = f"{kind}:{pkg.name}"
            mtime = pkg.stat().st_mtime
            if seen.get(key, 0) >= mtime:
                continue
            agent = agent_of(pkg.name)
            if agent is None:  # 后缀识别失败 → 查路由覆盖表
                for frag, r in routes.items():
                    if frag in pkg.name:
                        agent = r
                        break
            action = classify(kind, pkg)
            cmd = None
            roster_note = None
            if agent:
                tmpl, desc, launch_mode = ROSTER[agent]
                if tmpl is None:
                    roster_note = f"花名册未确认: {desc}"
                elif agent in ENABLED and all(shutil.which(t) or t in tmpl for t in tmpl):
                    cmd = tmpl + [f"处理包裹: {pkg} — {action}"]
                elif agent not in ENABLED:
                    roster_note = "纯记录模式（未加入 ENABLED）"
            events.append({
                "kind": kind, "pkg": str(pkg), "agent": agent,
                "action": action, "mtime": time.strftime("%m-%d %H:%M", time.localtime(mtime)),
                "would_dispatch": cmd, "note": roster_note,
            })
            seen[key] = mtime
    if events:
        save_seen(seen)
        PENDING.parent.mkdir(parents=True, exist_ok=True)
        PENDING.write_text(json.dumps(events, ensure_ascii=False, indent=1))
        with DISPATCH_LOG.open("a") as f:
            for e in events:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M')} [{e['kind']}] {Path(e['pkg']).name} → {e['agent'] or '?'} | {e['action']} | {e['note'] or ('WOULD: ' + ' '.join(e['would_dispatch']) if e['would_dispatch'] else '待启用')}\n")
    print(json.dumps({"new_events": len(events)}, ensure_ascii=False))
    for e in events:
        print(f"  [{e['kind']}] {Path(e['pkg']).name} → {e['agent'] or '?'} | {e['action']}")

if __name__ == "__main__":
    main()
