#!/usr/bin/env bash
# 公共函数库，被 restore/sync/bundle 脚本 source。
# 设计目标：在含中文路径下也稳，所有路径都加引号；所有副作用先 echo 计划，--apply 才真执行。

set -euo pipefail

# 项目"标准"路径——主仓必须放这里，否则 Claude memory 的目录 hash 会错位。
readonly MAIN_REPO="$HOME/Downloads/代码仓库/Chatwoot-AI接待"
readonly VAULT_DIR="$HOME/Downloads/代码仓库/Chatwoot-AI-vault"
readonly CWAI_DIFY="$HOME/.cwai-dify"
readonly CWAI_PATCHES="$HOME/.cwai-patches"

# Claude memory 的目录名是把项目绝对路径里 / 和非 ASCII 全部替换成 - 得到的 slug
claude_memory_slug() {
  local p="$MAIN_REPO"
  # 复刻 Claude Code 的命名规则：/ → -，中文等非 ASCII → -
  printf '%s' "$p" | python3 -c '
import sys, re
s = sys.stdin.read()
out = ""
for ch in s:
    if ch == "/" or ord(ch) > 127:
        out += "-"
    else:
        out += ch
print(out, end="")
'
}

claude_memory_dir() {
  printf '%s/.claude/projects/%s/memory' "$HOME" "$(claude_memory_slug)"
}

# 颜色输出（无 TTY 时降级）
if [[ -t 1 ]]; then
  C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

log()  { echo "${C_DIM}[$(date +%H:%M:%S)]${C_RST} $*"; }
ok()   { echo "${C_GRN}✓${C_RST} $*"; }
warn() { echo "${C_YEL}⚠${C_RST} $*" >&2; }
die()  { echo "${C_RED}✗${C_RST} $*" >&2; exit 1; }

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "缺命令: $c —— 装好再来"
}

# 强校验：必须在标准路径下运行，避免 Claude memory hash 错位
assert_standard_paths() {
  [[ -d "$MAIN_REPO" ]] || die "主仓不在标准路径 $MAIN_REPO（这条强制约束见 README）"
  [[ -d "$VAULT_DIR" ]] || die "vault 不在标准路径 $VAULT_DIR"
  if [[ "$PWD" != "$VAULT_DIR" && "$PWD" != "$VAULT_DIR/scripts" ]]; then
    warn "建议在 $VAULT_DIR 内运行脚本（当前 $PWD）"
  fi
}

# Mac 上的 GNU 风格 rsync flags 兼容封装
rsync_mirror() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  rsync -a --delete --human-readable "$src/" "$dst/"
}

# 主仓里的 7 个 .env 在 vault 中以扁平化命名存储，方便 diff 和 review
# 映射表：vault 文件名 ⇄ 主仓相对路径
env_pairs() {
  cat <<'EOF'
root.env|.env
root.env.dev|.env.dev
bridge.env|bridge/.env
admin-backend.env|admin/backend/.env
admin-frontend.env.local|admin/frontend/.env.local
notify.env|notify/.env
infra.env|infra/.env
EOF
}
