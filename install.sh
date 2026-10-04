#!/usr/bin/env bash
# install.sh — Posta 一条命令初始化器
#
# 用法：
#   bash install.sh [POSTA_HOME] [--with-cron]
#
#   POSTA_HOME   实例根目录，默认 $HOME/posta-lab（一个实例 = 一个协作工作区）
#   --with-cron  额外向当前用户 crontab 追加"每 10 分钟巡查"行
#                （幂等：只有认得出"本实例的有效巡查项"才跳过——目标脚本须以完整参数词出现、
#                 且紧邻其前是 python 解释器词；注释掉的行、无关命令的引用、别的实例的路径都不算；
#                 已存在但未加引号且含 shell 特殊字符的旧行 → 报错退出，不静默跳过；
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

  # ---------- 查重：什么才算"本实例的有效巡查行" ----------
  # 光做路径子串匹配会两处误判：① 无关命令把本实例脚本当参数引用（/bin/echo <本实例脚本>）；
  # ② 别的实例的路径里包含本实例整条路径（/srv/backup/tmp/posta/... 含 /tmp/posta/...）。
  # 所以逐行切词判定，三条同时成立才算命中：
  #   1) 行非空、非整行注释，且只看剥掉行尾注释后的部分——cron 把 # 之后原样交给 /bin/sh，
  #      只出现在行尾注释里的引用是无关引用（路径里的 # 前面没有空白，不会被误剥）；
  #   2) 本实例 dispatchd.py 在命令部分以**完整参数词**出现（词边界 = 空白/引号/行首行尾），
  #      于是路径前缀碰撞不算命中；
  #   3) 紧邻该词之前是 python 解释器词——认"真在执行"，被 echo 之类引用不算。
  # 新格式（单引号引用）与旧格式（未引用）都认。命中后再分类：
  #   安全行（普通路径，未引用或已引用）→ 照旧幂等跳过；
  #   不安全行（未引用且含 shell 特殊字符，如字面 $）→ 点名报错退出，不写 crontab、
  #   也不宣称已注册。
  CRON_KIND='' CRON_BAD_TOKEN=''

  # 把一行切成参数词：引号内的空白不作分隔符，引号本身从词里剥掉。
  # CRON_TOKEN_Q[i]=1 表示该词未被引用（未引用的词才可能被 shell 特殊字符改掉语义）。
  # 反斜杠**不当转义**：单引号里它本就是字面量，而本安装器写出的路径全用单引号引用，
  # 若在这里把 `\;` 还原成 `;`，含反斜杠的实例路径就永远认不出自己写的那行（幂等被破坏）。
  # 代价是含反斜杠的未引用词会被判为不安全——宁可多报一次、给出改写指引，也不误判已注册。
  # 引号不闭合的行无法判定，返回 1（当作没命中——宁可多追加，也不误报"已注册"）。
  cron_tokenize() {
    local s=$1
    local i=0 c n cur='' q='' quoted=1
    n=${#s}
    CRON_TOKENS=(); CRON_TOKEN_Q=()
    while [ "$i" -lt "$n" ]; do
      c="${s:i:1}"
      if [ -n "$q" ]; then
        if [ "$c" = "$q" ]; then q=''; else cur="$cur$c"; fi
      else
        case "$c" in
          [[:space:]]) if [ -n "$cur" ]; then CRON_TOKENS+=("$cur"); CRON_TOKEN_Q+=("$quoted"); cur=''; quoted=1; fi ;;
          "'"|'"')     q=$c; quoted=0 ;;
          *)           cur="$cur$c" ;;
        esac
      fi
      i=$((i+1))
    done
    [ -z "$q" ] || return 1
    if [ -n "$cur" ]; then CRON_TOKENS+=("$cur"); CRON_TOKEN_Q+=("$quoted"); fi
    return 0
  }

  # 解释器词：python3 / python / python3.12 / /usr/bin/python3 / pypy3 …
  cron_is_python() {
    case "${1##*/}" in
      python|python[0-9]*|pypy|pypy[0-9]*) return 0 ;;
    esac
    return 1
  }

  # 这一行是不是"本实例的有效巡查行"？命中置 CRON_KIND=safe|unsafe（unsafe 时
  # CRON_BAD_TOKEN 指出危险的词）并返回 0；不是则返回 1。
  cron_line_patrol() {
    local line=$1 i j start n tok
    CRON_KIND=''; CRON_BAD_TOKEN=''
    line="${line#"${line%%[![:space:]]*}"}"      # 去行首空白
    [ -n "$line" ] || return 1
    case "$line" in '#'*) return 1 ;; esac        # 整行注释
    line="${line%%[[:space:]]#*}"                 # 去行尾注释
    cron_tokenize "$line" || return 1
    n=${#CRON_TOKENS[@]}
    case "${CRON_TOKENS[0]:-}" in '@'*) start=1 ;; *) start=5 ;; esac   # @reboot 只有 1 个字段
    for ((i = start; i < n; i++)); do
      [ "${CRON_TOKENS[i]}" = "$CRON_TARGET" ] || continue
      [ "$i" -gt "$start" ] || continue            # 解释器词必须在命令部分里，不能是调度字段
      cron_is_python "${CRON_TOKENS[i-1]}" || continue
      # 命中了，再判整行安不安全：未加引号的词里不许出现 shell 特殊字符
      for ((j = start; j < n; j++)); do
        [ "${CRON_TOKEN_Q[j]}" = 0 ] && continue                     # 被引用过 → 字面量，安全
        tok="${CRON_TOKENS[j]}"
        case "$tok" in *[!0-9\<\>\&-]*) ;; *) continue ;; esac       # 纯重定向/描述符，与路径无关
        case "$tok" in
          *[!A-Za-z0-9_@+=:,./~#-]*) CRON_BAD_TOKEN="$tok"; CRON_KIND=unsafe; return 0 ;;
        esac
      done
      CRON_KIND=safe
      return 0
    done
    return 1
  }

  # 未加引号的词里哪些字符会改掉语义（报错时说明原因）
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

  CRON_HIT_SAFE=0 CRON_BAD_LINE=''
  while IFS= read -r line || [ -n "$line" ]; do
    cron_line_patrol "$line" || continue
    # 任何一条命中的行不安全就报错（哪怕同时还有一条安全的新格式行——那条安全行掩不住这条坏行）
    if [ "$CRON_KIND" = unsafe ]; then CRON_BAD_LINE="$line"; break; fi
    CRON_HIT_SAFE=1
  done < <(crontab -l 2>/dev/null || true)

  if [ -n "$CRON_BAD_LINE" ]; then
    echo "install.sh: crontab 里已有本实例的巡查行，但这一行不安全：cron 用 /bin/sh 逐字解释它，" >&2
    echo "        出问题的词里，$(cron_why "$CRON_BAD_TOKEN") —— 它其实没在跑本实例。" >&2
    echo "  crontab 里的那一行：$CRON_BAD_LINE" >&2
    echo "  出问题的词（未加引号）：$CRON_BAD_TOKEN" >&2
    echo "  处理指引：crontab -e 手工删掉上面这行，再重跑本安装器（bash install.sh '$POSTA_HOME' --with-cron）；" >&2
    echo "            或把它替换成下面这行（单引号引用，即本安装器要写的形态）：" >&2
    echo "            $CRON_LINE" >&2
    echo "  未改动 crontab。" >&2
    exit 1
  fi
  if [ "$CRON_HIT_SAFE" = 1 ]; then
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
