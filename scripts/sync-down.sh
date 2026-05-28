#!/usr/bin/env bash
# sync-down.sh —— 从 vault 远端拉最新状态，反向铺回本机活动位置
# 安全策略：默认 dry-run，--apply 才真覆盖。Claude memory / .env 都是有价值的，不能默默覆盖。
#
# 用法:
#   ./scripts/sync-down.sh              # dry-run，只列要做的事
#   ./scripts/sync-down.sh --apply      # 真执行
#   ./scripts/sync-down.sh --apply --no-pull   # 跳过 git pull（你已经 pull 过）

source "$(dirname "$0")/_lib.sh"

APPLY=0
DO_PULL=1
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --no-pull) DO_PULL=0 ;;
    *) die "未知参数: $a" ;;
  esac
done

cd "$VAULT_DIR"
assert_standard_paths
require_cmd rsync
require_cmd git

if [[ "$APPLY" -eq 1 ]]; then
  log "模式: APPLY（会真改文件）"
else
  log "模式: DRY-RUN（只打印计划；加 --apply 才生效）"
fi

if [[ "$DO_PULL" -eq 1 ]]; then
  log "git pull --rebase"
  git pull --rebase
fi

# git-crypt 锁定保护
if git-crypt status 2>&1 | grep -qi 'locked' >/dev/null; then
  die "vault 是 locked。先 git-crypt unlock <key>"
fi

run() {
  if [[ "$APPLY" -eq 1 ]]; then "$@"; else echo "  [dry] $*"; fi
}

log "1/5 .env 文件 ← envs/main/"
while IFS='|' read -r vname rel; do
  src="envs/main/$vname"
  dst="$MAIN_REPO/$rel"
  if [[ -f "$src" ]]; then
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      ok "  $rel 已同步"
    else
      log "  $vname → $rel"
      run mkdir -p "$(dirname "$dst")"
      run cp -p "$src" "$dst"
    fi
  fi
done < <(env_pairs)

log "2/5 ~/.cwai-patches/ ← cwai-patches/"
if [[ -d cwai-patches ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    rsync_mirror "cwai-patches" "$CWAI_PATCHES"
  else
    rsync -a --delete --dry-run --itemize-changes "cwai-patches/" "$CWAI_PATCHES/" | head -20
  fi
fi

log "3/5 ~/.cwai-dify/ 配置 ← cwai-dify-config/（不动 volumes/）"
if [[ -d cwai-dify-config ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    rsync -a --human-readable \
      --exclude='volumes/' \
      cwai-dify-config/ "$CWAI_DIFY/"
  else
    rsync -a --dry-run --itemize-changes \
      --exclude='volumes/' \
      cwai-dify-config/ "$CWAI_DIFY/" | head -30
  fi
fi

log "4/5 Claude memory ← claude-memory/"
mem_dir="$(claude_memory_dir)"
if [[ -d claude-memory ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$mem_dir"
    rsync_mirror "claude-memory" "$mem_dir"
    ok "  → $mem_dir"
  else
    echo "  [dry] mkdir -p $mem_dir && rsync claude-memory/ → $mem_dir/"
  fi
fi

log "5/5 .remember/ ← remember-snapshot/"
if [[ -d remember-snapshot ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$MAIN_REPO/.remember"
    # 只覆盖 remember.md 和静态文件，不删除本机生成的 logs/tmp
    rsync -a --human-readable remember-snapshot/ "$MAIN_REPO/.remember/"
  else
    echo "  [dry] rsync remember-snapshot/ → $MAIN_REPO/.remember/"
  fi
fi

ok "完成。"
if [[ "$APPLY" -eq 0 ]]; then
  echo
  warn "这是 dry-run。要真同步: ./scripts/sync-down.sh --apply"
fi
