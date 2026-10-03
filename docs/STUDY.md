# 研究笔记：herdr 与 Omarchy（2026-10-04）

> 目的：Posta v0.1 发布后，对照两个最值得学习的项目校准方向。
> 一个是最近的对标者（进程层运行时），一个是理念对标者（opinionated 哲学）。

## 一、herdr —— 最近的对标者

### 架构与机制（来自官方文档）

- **后台会话服务器 + 一次性客户端**：pane 活在服务器里，客户端只负责 attach/detach/渲染；
  本地项目目录跑 `herdr` 自动连接；`ctrl+b q` 分离后 agent 继续跑。
- **三层组织**：workspace（建议 one per repo/task，侧边栏状态从内部 agent **roll up** 汇总）
  → tab（布局：agents / logs / server / review，可用 CLI 和 socket API 寻址）→ pane（真实终端，可分割/重命名/读取/发输入）。
- **agent 检测三来源**：前台进程 / screen manifests / 可选集成。
- **五态模型**：blocked（要输入/批准/决定）/ working / done（完成但**人还没看**）/ idle（已看过）/
  unknown。关键细节：每个客户端各自追踪"已看"，在 A 客户端看了不清掉 B 客户端的 done 徽章；
  API 用服务端 seen 状态。
- **远程三路径**：纯 SSH（行为像 tmux）/ 手机任意 SSH 客户端（TUI 自适应窄屏）/
  `herdr --remote <host>`——**本地客户端渲染远程会话**，本地主题和剪贴板桥接到远程；
  多机聚合 `herdr machine add <host> --label`。
- **agent 自动化**：socket API 让 agent 分屏、拉起别的 agent、**阻塞等待对方进入 settled 状态**
  （而不是发按键后盲等）——与 Posta 监工的 "wait until blocked" 同源思想。
- **生态**：skills marketplace、oh-my-herdr（mission command）、fleet 多机管理。

### 对 Posta 的启示

1. **server/client 分离** ↔ 我们的巡查目前是 cron 定时扫描；herdr 是常驻服务器+任意客户端。
   演进方向： posta daemon 化（常驻巡逻守护），TUI/Web 作为一次性客户端 attach。
2. **done/idle 的已读/未读语义**：交付队列需要"人看过没"的位——待审列表去噪的关键。
3. **workspace 级 rollup**：TUI 状态条应按任务线聚合，而不是只有全局一行。
4. **agent skill file 模式**（一个 SKILL.md 教会任何 agent 驱动 herdr）：Posta 需要自己的
   **POSTA SKILL.md**——把信箱协议写成任何 agent 可领取的技能。herdr 验证了这条路可行。
5. **--remote 模式**（状态在远端、观感在本地）正是我们 Web 层的同构思路，再确认方向。

## 二、Omarchy —— 理念对标者（DHH）

### 是什么与怎么运营

- opinionated Arch + Hyprland 发行版（2025-，Omakub 继任者）："convention over configuration"
  从 Rails 应用到整个桌面——替用户做完所有难决定，一条命令装出完整可用的开发环境。
- 4.0（2026-08）把 Waybar/Walker 等桌面组件**吸收进单一常驻 `omarchy-shell`**（Quickshell），
  定位"可塑计算机"（malleable computer）。
- 运营：发版快、起名好记、一条命令安装、DHH 个人喇叭传播、面向 macOS 转移者；
  争议（too opinionated）与采用/赞助**双双增长**（The Register 2026-08）。

### 对 Posta 的启示

1. **一条命令安装器**：现在 quickstart 是 6 步手工 → 应压缩为 `install.sh` 一条命令
   （建 $POSTA_HOME、装 tools、注册巡查 cron、可选拉起 TUI）。
2. **替用户做完所有决定**：信箱名、包裹生命周期、审核阈值都该有强默认值，想改再改。
3. **争议可接受**：opinionated 会被批评，但稀释默认去讨好所有人会失去辨识度。
4. **吸收组件进单一常驻进程**（omarchy-shell 模式）——与 herdr 的 server/client 启示殊途同归。
5. **命名与叙事纪律**：中文原语已有好名字（包裹/信封/回执/监工），英文命名需要统一
   （parcel / mailbox / receipt / foreman）。

## 三、学完之后，Posta 的定位更清晰了

| 层 | 项目 | 管什么 |
|---|---|---|
| 桌面层 | Omarchy | opinionated 的桌面环境 |
| **进程层** | herdr | 终端 pane 多路复用 + agent 互唤 + 断线存活 |
| **协议层** | **Posta** | 文件信箱 + 监工闭环，编排任何 harness 的任何形态（CLI/桌面/跨机） |

三层可叠加：Posta 管协议，herdr 管进程，桌面随便用什么。
**POSTA SKILL.md 是进入 herdr skills 生态的潜在通道**——协议层做成技能，进程层的 agent 就能领它入伙。

## 四、行动项（已并入 ROADMAP）

1. Phase 2 +：`install.sh` 一条命令安装器
2. Phase 2 +：**POSTA SKILL.md**（信箱协议技能化）
3. Phase 3 +：包裹**已读/未读**语义（done vs idle）
4. Phase 3 +：TUI 按任务线 **rollup** 状态条
5. Phase 4 改：**posta daemon 化**（常驻巡逻服务 + 一次性客户端 attach；
   herdr server/client 与 omarchy-shell 的双重启示）
