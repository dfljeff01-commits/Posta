#!/usr/bin/env bash
# install.sh — Posta 一条命令初始化器
#
# 用法：
#   bash install.sh [POSTA_HOME] [--with-cron]
#
#   POSTA_HOME   实例根目录，默认 $HOME/posta-lab（一个实例 = 一个协作工作区）
#   --with-cron  额外向当前用户 crontab 追加"每 10 分钟巡查"行
#                （幂等：已有该实例的**有效**巡查项才跳过，注释掉的行不算；
#                 路径与赋值在 cron 的 /bin/sh 下单引号引用，含空白 / % / 单引号的路径明确拒绝）
#
# 行为：建目录树 · 复制 src/*.py 到 tools/ · 放注册表模板（已存在则跳过不覆盖）·
#       可选注册巡查 · 打印下一步提示。幂等：重复执行无副作用。
set -euo pipefail

usage() {
  cat <<'EOF'
用法：bash install.sh [POSTA_HOME] [--with-cron]
  POSTA_HOME   实例根目录，默认 $HOME/posta-lab（一个实例 = 一个协作工作区）
  --with-cron  额外向当前用户 crontab 追加"每 10 分钟巡查"行（幂等，已注册则跳过）
EOF
}

# ---------- 参数 ----------
WITH_CRON=0
POSTA_HOME_ARG=""
for arg in "$@"; do
  case "$arg" in
    --with-cron) WITH_CRON=1 ;;
    -h|--help)   usage; exit 0 ;;
    --*)         echo "install.sh: 未知选项：$arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$POSTA_HOME_ARG" ]; then
        echo "install.sh: 多余的位置参数：$arg" >&2; usage >&2; exit 2
      fi
      POSTA_HOME_ARG="$arg" ;;
  esac
done

# ---------- 定位仓库与目标 ----------
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -d "$REPO_ROOT/src" ] || [ ! -e "$REPO_ROOT/examples/TEAM_ROSTER.example.json" ]; then
  echo "install.sh: 仓库内容不全（缺 src/ 或 examples/TEAM_ROSTER.example.json）：$REPO_ROOT" >&2
  exit 1
fi

POSTA_HOME="${POSTA_HOME_ARG:-$HOME/posta-lab}"
POSTA_HOME="${POSTA_HOME/#\~/$HOME}"   # 展开 ~ 前缀

# ---------- 建目录树 ----------
mkdir -p -- "$POSTA_HOME"/{agent,logs,tools,state} \
             "$POSTA_HOME"/mailboxes/{tasks,reports,handoffs}
POSTA_HOME="$(cd -- "$POSTA_HOME" && pwd -P)"   # 绝对化，cron 行需要
echo "Posta 安装器 → 实例根：$POSTA_HOME"
echo "✓ 目录就绪：{agent,logs,tools,state} + mailboxes/{tasks,reports,handoffs}"

# ---------- 装 tools（刷新为仓库当前版；不动 tools 里的其他文件） ----------
shopt -s nullglob
PY_FILES=("$REPO_ROOT"/src/*.py)
shopt -u nullglob
if [ "${#PY_FILES[@]}" -eq 0 ]; then
  echo "install.sh: $REPO_ROOT/src 下没有 *.py" >&2
  exit 1
fi
for f in "${PY_FILES[@]}"; do
  cp -f -- "$f" "$POSTA_HOME/tools/"
done
echo "✓ tools ← src/*.py（${#PY_FILES[@]} 个脚本）"

# ---------- 团队注册表（已存在则跳过不覆盖） ----------
ROSTER_DST="$POSTA_HOME/agent/TEAM_ROSTER.json"
if [ -e "$ROSTER_DST" ]; then
  echo "✓ 注册表已存在，跳过不覆盖：$ROSTER_DST"
else
  cp -- "$REPO_ROOT/examples/TEAM_ROSTER.example.json" "$ROSTER_DST"
  echo "✓ 注册表模板已就位：$ROSTER_DST（下一步：填入你的团队）"
fi

# ---------- 可选：注册每 10 分钟巡查 ----------
if [ "$WITH_CRON" = 1 ]; then
  if ! command -v crontab >/dev/null 2>&1; then
    echo "install.sh: 找不到 crontab 命令，无法注册巡查" >&2
    exit 1
  fi
  PY3="$(command -v python3 || true)"
  if [ -z "$PY3" ]; then
    echo "install.sh: 找不到 python3，无法注册巡查" >&2
    exit 1
  fi
  # cron 行由 cron 交给 /bin/sh 逐字解释，所以路径与赋值一律单引号引用
  # （POSTA_HOME='...' 是赋值形式）：$ ` ; " \ 空格 等都按字面量传给脚本与解释器。
  # 单引号引用覆盖不了三类字符，注册前点名拒绝、报错退出，绝不写出语义不可靠的 cron 行：
  #   空白   —— cron 行按空白分字段，路径里有空白就换了字段；
  #   %      —— crontab 里 % 由 cron 先行翻成换行（引号内也逃不掉），整行会被截断；
  #   单引号 —— POSIX sh 的单引号内无法转义单引号自身。
  cron_quote_blocker() {  # $1=待检查的值；可安全引用则输出空串，否则输出不可安全引用的原因
    case "$1" in
      *[[:space:]]*) printf '含空白（cron 行按空白分字段）' ;;
      *%*)           printf '含 %%（cron 会先把它翻成换行，整行被截断）' ;;
      *"'"*)         printf "含单引号（sh 的单引号内无法转义单引号自身）" ;;
      *)             printf '' ;;
    esac
  }
  WHY="$(cron_quote_blocker "$POSTA_HOME")"
  if [ -n "$WHY" ]; then
    echo "install.sh: POSTA_HOME $WHY，无法生成可靠 cron 行：$POSTA_HOME" >&2
    exit 1
  fi
  WHY="$(cron_quote_blocker "$PY3")"
  if [ -n "$WHY" ]; then
    echo "install.sh: 解析到的 python3 路径 $WHY，无法生成可靠 cron 行：$PY3" >&2
    exit 1
  fi
  CRON_TARGET="$POSTA_HOME/tools/dispatchd.py"
  CRON_LINE="*/10 * * * * POSTA_HOME='$POSTA_HOME' '$PY3' '$CRON_TARGET' >> '$POSTA_HOME/logs/cron.log' 2>&1"
  # 幂等键：该实例的**有效**巡查项。只认非空、非整行注释、且该路径出现在注释之前的行——
  # 注释掉的巡查行不算已注册（否则装完其实没有定时任务），别的实例的行也不算。
  # 行尾注释要剥掉：cron 把 # 之后原样交给 /bin/sh，路径里的 # 前面没有空白，不会被误剥。
  cron_has_patrol() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"   # 去行首空白
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac    # 整行注释
      line="${line%%[[:space:]]#*}"             # 去行尾注释
      case "$line" in *"$CRON_TARGET"*) return 0 ;; esac
    done < <(crontab -l 2>/dev/null || true)
    return 1
  }
  if cron_has_patrol; then
    echo "✓ 巡查已注册过，跳过（每 10 分钟）"
  else
    (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
    echo "✓ 已注册巡查（每 10 分钟）：$CRON_LINE"
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "⚠ 本机未找到 python3：tools（扫描器/TUI）需要它，请先安装" >&2
fi

# ---------- 下一步 ----------
cat <<EOF

下一步：
  0. export POSTA_HOME=$POSTA_HOME     # 扫描器与 TUI 靠它定位实例（建议写进 shell 配置）
  1. 编辑团队注册表：\${EDITOR:-vi} $POSTA_HOME/agent/TEAM_ROSTER.json
  2. 手动跑一次扫描器（纯记录模式）：python3 $POSTA_HOME/tools/dispatchd.py
  3. 打开监工台：python3 $POSTA_HOME/tools/posta_tui.py    # q 退出 · r 刷新 · l 切换跟随
提示：扫描器默认监视 ~/cto-tasks ~/AI_REPORT_INBOX ~/cto-handoffs（tools/dispatchd.py 的 WATCH）；
      要改用 \$POSTA_HOME/mailboxes/{tasks,reports,handoffs}，把 WATCH 指过去即可。
EOF
