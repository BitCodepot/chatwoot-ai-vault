#!/usr/bin/env bash
# sync-up.sh —— 把本机当前状态收集进 vault 并 push
# 不动 volumes（用 bundle-volumes.sh）；不动主仓代码（用主仓自己的 git）。
#
# 用法: ./scripts/sync-up.sh "commit message"

source "$(dirname "$0")/_lib.sh"

MSG="${1:-sync: $(hostname -s) @ $(date +%Y-%m-%d_%H:%M)}"

cd "$VAULT_DIR"
assert_standard_paths
require_cmd rsync
require_cmd git
require_cmd git-crypt

log "1/5 收集主仓 .env 文件 → envs/main/"
mkdir -p envs/main
while IFS='|' read -r vname rel; do
  src="$MAIN_REPO/$rel"
  if [[ -f "$src" ]]; then
    cp -p "$src" "envs/main/$vname"
    ok "  $rel → envs/main/$vname"
  else
    warn "  缺: ${src}（跳过）"
  fi
done < <(env_pairs)

log "2/5 镜像 ~/.cwai-patches/ → cwai-patches/"
rsync_mirror "$CWAI_PATCHES" "cwai-patches"

log "3/5 镜像 ~/.cwai-dify/ 配置（排除 volumes/ logs/ certbot/ 等运行时数据）→ cwai-dify-config/"
rsync -a --delete --human-readable \
  --exclude='volumes/' \
  --exclude='logs/' \
  --exclude='certbot/conf/live/' \
  --exclude='certbot/conf/archive/' \
  --exclude='*.log' \
  --exclude='.DS_Store' \
  "$CWAI_DIFY/" "cwai-dify-config/"
ok "  done"

log "4/5 镜像 Claude memory → claude-memory/"
mem_dir="$(claude_memory_dir)"
if [[ -d "$mem_dir" ]]; then
  rsync_mirror "$mem_dir" "claude-memory"
  ok "  $mem_dir → claude-memory/"
else
  warn "  Claude memory 目录不存在: ${mem_dir}（首次跑或路径错位？）"
fi

log "5/5 快照 .remember/ → remember-snapshot/"
if [[ -d "$MAIN_REPO/.remember" ]]; then
  rsync -a --delete --human-readable \
    --exclude='tmp/' \
    --exclude='logs/autonomous/' \
    "$MAIN_REPO/.remember/" "remember-snapshot/"
  ok "  done"
fi

# git-crypt 状态自检
if ! git-crypt status >/dev/null 2>&1; then
  die "git-crypt 未初始化。请先: git-crypt init 或 git-crypt unlock <key>"
fi
# 检查是否处于 locked 状态（status 会报警）
if git-crypt status 2>&1 | grep -qi 'locked'; then
  die "vault 当前是 locked。先 git-crypt unlock 再 sync。"
fi

log "—— 暂存改动 ——"
git add -A
if git diff --cached --quiet; then
  ok "无变化，不创建空 commit"
  exit 0
fi
git status --short

git commit -m "$MSG"
log "推送到远端..."
git push
ok "完成。远端已更新；另一台机器跑 ./scripts/sync-down.sh 拉取。"
