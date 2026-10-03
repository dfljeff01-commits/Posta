# Posta 📮

**AI Agent 团队的收发室与监工台** —— 一套文件优先的多 Agent 协作运行时。

> Posta = 斯瓦希里语"邮局"。本系统的核心隐喻：agent 团队经由收发室协作——包裹、信箱、邮戳、回执。

## 它解决什么问题

多个 AI agent（CLI 的、桌面端的、跨机器的）一起干活时：谁派发、谁审核、谁裁决、出错谁返工、
人怎么知道进展？Posta 的答案是 **文件即状态**——任务、交付、审核、裁决、回执全部是目录里的包裹，
由一个"监工"循环自动驱动，**人类只出现在裁决点**。

## 组件

| 组件 | 文件 | 作用 |
|---|---|---|
| 信箱扫描器 | `src/dispatchd.py` | 扫描信箱目录，包裹分类 / 成员路由 / 状态登记 |
| 状态引擎 | `src/posta_state.py` | 只读状态聚合，供 TUI 与未来 Web 层共用 |
| 监工台 | `src/posta_tui.py` | 人类观察窗（Textual TUI，只读 MVP） |
| 运行手册模板 | `docs/RUNBOOK.template.md` | 监督闭环的状态机 + 审核清单 + 返工协议 |
| 协作手册 | `docs/PLAYBOOK.md` | 实战验证的角色/生命周期/坑与对策 |
| 路线图 | `docs/ROADMAP.md` | 多机 / 多人 / 多线演进规划 |
| 团队注册表示例 | `examples/TEAM_ROSTER.example.json` | 成员互相认识的唯一事实来源（模板） |

## 快速开始

```bash
# 1. 建实例目录（一个实例 = 一个协作工作区）
export POSTA_HOME=$HOME/posta-lab
mkdir -p $POSTA_HOME/{agent,logs,tools,state}

# 2. 装入系统
cp src/*.py $POSTA_HOME/tools/
cp examples/TEAM_ROSTER.example.json $POSTA_HOME/agent/TEAM_ROSTER.json
#    ↑ 编辑它：填入你的团队成员（id/后缀/启动方式/角色/资格边界）

# 3. 建信箱（名字可改，改了同步 tools/dispatchd.py 的 WATCH）
mkdir -p ~/cto-tasks ~/ai-report-inbox ~/cto-handoffs

# 4. 手动跑一次扫描器（纯记录模式，不启动任何 agent）
python3 $POSTA_HOME/tools/dispatchd.py

# 5. 打开监工台
python3 $POSTA_HOME/tools/posta_tui.py     # 键位: q退出 r刷新 l切换跟随

# 6. 装成巡查（cron 每 10 分钟）
# */10 * * * * python3 $POSTA_HOME/tools/dispatchd.py
```

设计要点：扫描器是**唯一的状态写入口**；TUI 与 Web 只读。巡查负责播报与监督闭环
（详见 RUNBOOK 模板），无头执行用 `POSTA_HOME` 同款纪律（见 PLAYBOOK 坑与对策）。

## 设计原则（不可协商）

1. **文件即状态**——不读对话、不靠记忆，盘上有什么就是什么
2. **人只出现在裁决点**——资格冲突、额度授权、终审；其余自动化
3. **证据不可变**——交付物只增不改，审核报告独立目录，历史版本留档
4. **渐进授权**——先只读观察，人信任后再放开动作键
5. **弱模型不做判断**——路由查表、白名单优先，模型只在规则覆盖不了时兜底
6. **一切手动动作必须留痕**——事件流水账是人机共享的眼睛

## 文档

- [docs/PLAYBOOK.md](docs/PLAYBOOK.md) — 多 Agent 协作协议（含十条实战坑与对策）
- [docs/ROADMAP.md](docs/ROADMAP.md) — 单机单线 → 双机双线 → 多机的演进路线
- [docs/RUNBOOK.template.md](docs/RUNBOOK.template.md) — 监督闭环状态机模板

## 来源

脱胎于一个真实的多 agent 软件交付工作流：CTO（Codex 桌面端）拆任务写指令 → 执行者
（opencode / codex / kilo CLI）在隔离 checkout 里干活 → 监工（ZCode）巡查、审核、派返工、
落盘代裁 → 人类只在资格冲突与终审时出场。第一个任务从派发到关闭全程 24 小时，
经历 3 次执行中断复活、1 轮返工、5 份代裁记录，全部机制经实战检验后固化为本项目。

## License

MIT
