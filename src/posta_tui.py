#!/usr/bin/env python3
"""Posta 监工台 TUI（MVP：只读观察）

面板：信箱包裹 | 活跃任务(RUNBOOK登记表) | 实时日志 | 事件流
键位：q 退出  r 立即刷新  l 切换跟随对象(最新日志/事件流)  鼠标可滚
启动：python3 posta_tui.py（建议装进 $POSTA_HOME/tools/ 后运行）
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rich.table import Table
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Footer, Header, RichLog, Static

import posta_state as state

REFRESH_SECONDS = 5


def status_color(status: str) -> str:
    s = status.lower()
    if s.startswith("running"):
        return "cyan"
    if "pass" in s and "待" in status:
        return "green"
    if "fail" in s:
        return "red"
    return "white"


class SummaryBar(Static):
    last_refresh = ""

    def update_last_refresh(self):
        import time
        self.last_refresh = time.strftime("%H:%M:%S")
        self.refresh_summary()

    def refresh_summary(self):
        s = state.summary()
        running = len(s["running"])
        self.update(
            f"[b]信箱[/b] {s['total_packages']} 包裹 "
            f"(任务 {s['by_kind'].get('TASK', 0)} / 报告 {s['by_kind'].get('REPORT', 0)} / "
            f"交接 {s['by_kind'].get('HANDOFF', 0)}) · 待CTO审核 {s['pending_cto']} · "
            f"[cyan]运行中 {running}[/cyan]"
            + (f" · [dim]刷新于 {self.last_refresh}[/dim]" if self.last_refresh else "")
        )


class PackagesTable(DataTable):
    def on_mount(self):
        self.add_columns("类型", "包裹", "目标", "状态/动作", "更新")
        self.cursor_type = "row"
        self.zebra_stripes = True

    def refresh_data(self):
        rows = state.packages(limit_per_box=10)
        self.clear()
        for kind, name, agent, action, mt in rows:
            color = {"TASK": "yellow", "REPORT": "green", "HANDOFF": "magenta"}.get(kind, "white")
            self.add_row(Text(kind, style=color), name[:52], agent, action[:36], mt)


class TasksTable(DataTable):
    def on_mount(self):
        self.add_columns("任务", "状态", "返工", "备注")
        self.cursor_type = "row"
        self.zebra_stripes = True
        key = {str(c.label): k for k, c in self.columns.items()}
        self.columns[key["任务"]].width = 30
        self.columns[key["状态"]].width = 12
        self.columns[key["返工"]].width = 5

    def refresh_data(self):
        self.clear()
        for t in state.runbook_tasks():
            self.add_row(
                t["task"][:30],
                Text(t["short"], style=status_color(t["status"])),
                t["rounds"],
                t["note"][:60],
            )


class SupervisorApp(App):
    TITLE = "Posta 监工台"
    SUB_TITLE = "Supervisor TUI · read-only MVP"
    CSS = """
    #top { height: 1; padding: 0 1; }
    #body { height: 55%; }
    #packages { width: 60%; }
    #tasks { width: 40%; }
    #bottom { height: 1fr; }
    RichLog { border: round $primary; }
    DataTable { border: round $primary; }
    """
    BINDINGS = [
        Binding("q", "quit", "退出", priority=True),
        Binding("r", "refresh_all", "立即刷新", priority=True),
        Binding("l", "switch_follow", "切换跟随", priority=True),
    ]

    follow_mode = "log"  # log | events

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield SummaryBar(id="top")
        with Horizontal(id="body"):
            yield PackagesTable(id="packages")
            yield TasksTable(id="tasks")
        with Vertical(id="bottom"):
            yield RichLog(id="live", highlight=True, markup=True, wrap=True)
        yield Footer()

    def on_mount(self):
        self.query_one("#packages").refresh_data()
        self.query_one("#tasks").refresh_data()
        self.query_one(SummaryBar).refresh_summary()
        self.refresh_live()
        self.set_interval(REFRESH_SECONDS, self.tick)

    def tick(self):
        # 自动刷新静默进行：只刷数据，不弹提示
        self.refresh_data_only()

    def action_refresh_all(self):
        # 手动按 r：刷新 + 明确反馈
        self.refresh_data_only()
        self.notify("已刷新", timeout=2)

    def refresh_data_only(self):
        self.query_one("#packages").refresh_data()
        self.query_one("#tasks").refresh_data()
        self.query_one(SummaryBar).refresh_summary()
        self.refresh_live()
        self.query_one(SummaryBar).update_last_refresh()

    def refresh_live(self):
        live = self.query_one("#live", RichLog)
        if self.follow_mode == "log":
            path, lines = state.active_log_follow_lines(max_lines=40)
            if path:
                live.clear()
                live.write(f"[b]跟随 {path.name}[/b]（{REFRESH_SECONDS}s 刷新）")
                for ln in lines:
                    live.write(Text(ln).plain)
            else:
                live.clear()
                live.write("[dim]无运行中任务的日志。事件流见 l 切换。[/dim]")
        else:
            live.clear()
            live.write("[b]事件流 dispatch.log（尾部30）[/b]")
            events = state.dispatch_events()
            # 滞后检测：最新包裹 mtime 晚于最后一条事件时间 → 提示巡查未跑
            try:
                newest_pkg = max(p.stat().st_mtime for _, root in state.WATCH.items()
                                 if root.is_dir() for p in root.iterdir() if p.is_dir())
                last_evt = events[-1] if events else ""
                m = re.search(r"(\d{2}):(\d{2})", last_evt)
                import time as _t
                if m and _t.time() - newest_pkg > 600:
                    pass  # 包裹 mtime 早于事件 10 分钟以上 = 正常
                elif events and newest_pkg > _t.time() - 120 and m:
                    hh, mm = int(m.group(1)), int(m.group(2))
                    now = _t.localtime()
                    if (now.tm_hour * 60 + now.tm_min) - (hh * 60 + mm) > 10:
                        live.write("[yellow]⚠ 事件流可能滞后：巡查最短间隔10分钟；"
                                   "监工手动动作按纪律应即时补记。[/yellow]")
            except Exception:
                pass
            for ln in events:
                live.write(ln)

    def action_switch_follow(self):
        self.follow_mode = "events" if self.follow_mode == "log" else "log"
        self.refresh_live()


if __name__ == "__main__":
    SupervisorApp().run()
