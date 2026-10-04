#!/usr/bin/env bash
# install.sh — Posta 一条命令初始化器
#
# 用法：
#   bash install.sh [POSTA_HOME] [--with-cron]
#
#   POSTA_HOME   实例根目录，默认 $HOME/posta-lab（一个实例 = 一个协作工作区）
#   --with-cron  额外向当前用户 crontab 追加"每 10 分钟巡查"行
#                （幂等：判据是**确定性整行全等**——crontab 里的某一行去掉首尾空白与行尾 \r 后，
#                 与本安装器会写的那一行、或它历史版本写出的那一行，逐字节完全相等，才算已注册；
#                 不做词法分析：人工改过频率或命令的、被无关命令引用的、别的实例前缀碰撞的、
#                 注释掉的、含引号诡计的行一律不算，认不出就照常追加（保守方向）；
#                 全等命中旧行、但路径未加引号且含 shell 特殊字符 → 报错退出，不静默跳过；
#                 路径与赋值在 cron 的 /bin/sh 下单引号引用，含空白 / % / 单引号的路径明确拒绝）
#
# 行为：建目录树 · 复制 src/*.py 到 tools/ · 放注册表模板（已存在则跳过不覆盖）·
#       可选注册巡查 · 打印下一步提示。幂等：重复执行无副作用。
set -euo pipefail

usage() {
  cat <<'EOF'
用法：bash install.sh [POSTA_HOME] [--with-cron]
  POSTA_HOME   实例根目录，默认 $HOME/posta-lab（一个实例 = 一个协作工作区）
  --with-cron  额外向当前用户 crontab 追加"每 10 分钟巡查"行
               （幂等：只认本安装器生成的那两种整行，逐字节全等才跳过）
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

  # ---------- 查重：确定性整行全等匹配（不做任何词法分析） ----------
  # 三轮 FAIL 的根因：用 bash 给 cron 行写词法分析器（引号状态机 / 词边界 / 解释器位置判定）
  # 必然存在绕过反例——空引号 `""$USER` 让分词器以为整词被引用、双引号并不禁变量展开、
  # 相邻的 python 词也不等于真在执行。故本版**删除**全部切词 / 引号 / 解释器判定，
  # 只认两条由本安装器自己确定、由 $POSTA_HOME 与安装时解析到的 python3 路径决定的整行：
  #   NEW_LINE    —— 本版要写的形态（路径与赋值单引号引用）
  #   LEGACY_LINE —— 本安装器历史版本曾写出的形态（未加引号），升级时靠它幂等跳过
  # 判据只有一条：把 crontab -l 的每一行去掉首尾空白与行尾 \r 后，与这两条之一**逐字节全等**。
  # 其他任何行（人工改过频率或命令的、被 echo 引用的、别的实例前缀碰撞的、注释掉的、
  # 含引号诡计的）一律不算已注册。方向是"永不误认、只会保守追加"：认不出的行不阻塞注册。
  NEW_LINE="*/10 * * * * POSTA_HOME='$POSTA_HOME' '$PY3' '$CRON_TARGET' >> '$POSTA_HOME/logs/cron.log' 2>&1"
  LEGACY_LINE="*/10 * * * * POSTA_HOME=$POSTA_HOME $PY3 $CRON_TARGET >> $POSTA_HOME/logs/cron.log 2>&1"

  # 行归一：去首尾空白、去行尾 \r。除此之外一个字节都不动——判定必须是整行全等。
  cron_normalize() {
    local s=$1
    while [ "${s%$'\r'}" != "$s" ]; do s="${s%$'\r'}"; done
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
  }

  # LEGACY_LINE 是未加引号的形态：路径里只要有 shell 特殊字符，cron 的 /bin/sh 就会改掉语义，
  # 那一行其实没在跑本实例 → 点名报错退出，不静默跳过、也不宣称已注册。
  # 判据是"这个路径能否原样出现在未加引号的命令行里"：普通词字符集之外的一律算特殊。
  LEGACY_BAD_VALUE=''
  case "$POSTA_HOME" in *[!A-Za-z0-9_@+=:,./~#-]*) LEGACY_BAD_VALUE=$POSTA_HOME ;; esac
  if [ -z "$LEGACY_BAD_VALUE" ]; then
    case "$PY3" in *[!A-Za-z0-9_@+=:,./~#-]*) LEGACY_BAD_VALUE=$PY3 ;; esac
  fi

  # 未加引号时哪些字符会改掉语义（报错时说明原因）
  cron_why() {
    local t=$1 out=''
    case "$t" in *'$'*)        out="$out \$ 会被展开成别的值" ;; esac
    case "$t" in *'`'*)        out="$out 反引号会被当命令替换执行" ;; esac
    case "$t" in *';'*)        out="$out 分号会截断命令、另起一条命令" ;; esac
    case "$t" in *'&'*)        out="$out & 会改写命令的串接方式" ;; esac
    case "$t" in *'|'*)        out="$out | 会把输出接到别的命令" ;; esac
    case "$t" in *'<'*|*'>'*)  out="$out 重定向符会改写文件" ;; esac
    case "$t" in *'('*|*')'*)  out="$out 括号会被当子 shell 语法" ;; esac
    case "$t" in *'{'*|*'}'*)  out="$out 花括号会被当 shell 语法" ;; esac
    case "$t" in *'*'*|*'?'*|*'['*|*']'*) out="$out 通配符会展开成别的文件名" ;; esac
    case "$t" in *'\')         out="$out 反斜杠会吃掉后面的字符" ;; esac
    case "$t" in *"'"*|*'"'*)  out="$out 引号会改变词的切分" ;; esac
    [ -n "$out" ] || out=' 含 shell 特殊字符'
    printf '%s' "${out# }"
  }

  # 现有 crontab 先读成一份快照，查重与追加都用它。
  # 不能写成 `(crontab -l; echo 新行) | crontab -`：那样读端与写端会争抢同一个 crontab
  # 文件（真 crontab 与测试替身 alike），写端先 truncate 就把旧行读丢了——实测会静默
  # 丢掉用户已有的其他任务行。查重认不出的行只会"追加"，绝不能顺带删掉别人的东西。
  CRON_SNAPSHOT="$(crontab -l 2>/dev/null || true)"

  CRON_HIT=0 CRON_BAD_LINE=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$(cron_normalize "$line")" in
      "$NEW_LINE")    CRON_HIT=1 ;;
      "$LEGACY_LINE")
        # 全等命中旧行、但路径未加引号且含特殊字符 → 报错（哪怕同时还有一条安全的新格式行，
        # 那条安全行也掩不住这条坏行）
        if [ -n "$LEGACY_BAD_VALUE" ]; then CRON_BAD_LINE=$line; break; fi
        CRON_HIT=1 ;;
    esac
  done <<< "$CRON_SNAPSHOT"

  if [ -n "$CRON_BAD_LINE" ]; then
    echo "install.sh: crontab 里已有本实例的旧版巡查行，但这一行不安全：cron 用 /bin/sh 逐字解释它，" >&2
    echo "        里面的路径 $LEGACY_BAD_VALUE 里，$(cron_why "$LEGACY_BAD_VALUE") —— 它其实没在跑本实例。" >&2
    echo "  crontab 里的那一行：$CRON_BAD_LINE" >&2
    echo "  出问题的路径（旧行未加引号）：$LEGACY_BAD_VALUE" >&2
    echo "  处理指引：crontab -e 手工删掉上面这行，再重跑本安装器（bash install.sh '$POSTA_HOME' --with-cron）；" >&2
    echo "            或把它替换成下面这行（单引号引用，即本安装器要写的形态）：" >&2
    echo "            $NEW_LINE" >&2
    echo "  未改动 crontab。" >&2
    exit 1
  fi
  if [ "$CRON_HIT" = 1 ]; then
    echo "✓ 巡查已注册过，跳过（每 10 分钟）"
  else
    {
      if [ -n "$CRON_SNAPSHOT" ]; then printf '%s\n' "$CRON_SNAPSHOT"; fi
      printf '%s\n' "$NEW_LINE"
    } | crontab -
    echo "✓ 已注册巡查（每 10 分钟）：$NEW_LINE"
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
