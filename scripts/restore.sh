#!/usr/bin/env bash
# restore.sh —— 新机器一键还原
# 前提：已 brew install git-crypt gh openssl zstd；已 gh auth login；
#       已 clone 主仓到 ~/Downloads/代码仓库/Chatwoot-AI接待；
#       已 clone 本 vault 仓到 ~/Downloads/代码仓库/Chatwoot-AI-vault；
#       vault.key 已就位（默认 ~/.config/chatwoot-ai-vault.key 或 $VAULT_KEY）；
#       git-crypt unlock 已执行（或本脚本会提示）
#
# 用法:
#   ./scripts/restore.sh                # 完整还原（含 volumes 下载）
#   ./scripts/restore.sh --no-volumes   # 跳过 volumes
#   ./scripts/restore.sh --no-docker    # 不自动起容器

source "$(dirname "$0")/_lib.sh"

DO_VOLUMES=1
DO_DOCKER=1
KEY_PATH="${VAULT_KEY:-$HOME/.config/chatwoot-ai-vault.key}"

for a in "$@"; do
  case "$a" in
    --no-volumes) DO_VOLUMES=0 ;;
    --no-docker)  DO_DOCKER=0 ;;
    *) die "未知参数: $a" ;;
  esac
done

cd "$VAULT_DIR"
require_cmd git
require_cmd git-crypt
require_cmd rsync
require_cmd openssl
[[ "$DO_VOLUMES" -eq 1 ]] && require_cmd gh
[[ "$DO_VOLUMES" -eq 1 ]] && require_cmd shasum

# === 0. 路径&解锁自检 ===
log "0/6 路径自检"
[[ -d "$MAIN_REPO" ]] || die "主仓不在 $MAIN_REPO —— 请先: git clone <主仓url> '$MAIN_REPO'"
ok "  主仓 ✓"
ok "  vault ✓ ($VAULT_DIR)"

if git-crypt status 2>&1 | grep -qi 'locked' >/dev/null; then
  if [[ -f "$KEY_PATH" ]]; then
    log "  vault locked，自动 unlock 中..."
    git-crypt unlock "$KEY_PATH"
  else
    die "vault locked 且找不到 key（期望 $KEY_PATH）。请先 git-crypt unlock <key 文件路径>"
  fi
fi
ok "  vault unlocked ✓"

# === 1. .env 文件 ===
log "1/6 还原 .env 文件到主仓"
while IFS='|' read -r vname rel; do
  src="envs/main/$vname"
  dst="$MAIN_REPO/$rel"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    ok "  $vname → $rel"
  else
    warn "  缺: $src（vault 里没这个 env，跳过）"
  fi
done < <(env_pairs)

# === 2. ~/.cwai-patches ===
log "2/6 还原 ~/.cwai-patches/"
mkdir -p "$CWAI_PATCHES"
rsync_mirror "cwai-patches" "$CWAI_PATCHES"
ok "  done"

# === 3. ~/.cwai-dify 配置（无 volumes） ===
log "3/6 还原 ~/.cwai-dify/（不含 volumes）"
mkdir -p "$CWAI_DIFY"
rsync -a --human-readable \
  --exclude='volumes/' \
  cwai-dify-config/ "$CWAI_DIFY/"
ok "  done"

# === 4. Claude memory ===
log "4/6 还原 Claude long-term memory"
mem_dir="$(claude_memory_dir)"
mkdir -p "$mem_dir"
rsync_mirror "claude-memory" "$mem_dir"
ok "  → $mem_dir"

# === 5. .remember/ 对话历史 ===
log "5/6 还原 .remember/ 对话 handoff"
mkdir -p "$MAIN_REPO/.remember"
rsync -a --human-readable remember-snapshot/ "$MAIN_REPO/.remember/"
ok "  done"

# === 6. Volumes ===
if [[ "$DO_VOLUMES" -eq 0 ]]; then
  warn "6/6 跳过 volumes（--no-volumes）"
else
  log "6/6 下载并解开 volumes bundle"
  [[ -f volumes-manifest.json ]] || die "vault 里没 volumes-manifest.json —— 老机器先跑 bundle-volumes.sh"
  [[ -f "$KEY_PATH" ]] || die "vault.key 不在 $KEY_PATH —— volumes 解密要它"

  TAG="$(python3 -c 'import json;print(json.load(open("volumes-manifest.json"))["tag"])')"
  ASSET="$(python3 -c 'import json;print(json.load(open("volumes-manifest.json"))["asset"])')"
  EXPECTED_SHA="$(python3 -c 'import json;print(json.load(open("volumes-manifest.json"))["sha256"])')"
  REPO="$(python3 -c 'import json;print(json.load(open("volumes-manifest.json"))["repo"])')"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  log "  gh release download $TAG @ $REPO"
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK"

  ACTUAL_SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
  [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "sha256 不对！期望 $EXPECTED_SHA 实际 $ACTUAL_SHA"
  ok "  sha256 校验通过"

  log "  AES-256-CBC 解密"
  DEC="$WORK/${ASSET%.enc}"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$WORK/$ASSET" -out "$DEC" -pass "file:$KEY_PATH"

  # 备份现有 volumes（若有）
  if [[ -d "$CWAI_DIFY/volumes" ]]; then
    bak="$CWAI_DIFY/volumes.bak.$(date +%Y%m%d-%H%M%S)"
    warn "  发现已有 volumes/，备份到 $bak"
    mv "$CWAI_DIFY/volumes" "$bak"
  fi

  log "  解开到 $CWAI_DIFY/volumes/"
  mkdir -p "$CWAI_DIFY"
  if [[ "$DEC" == *.zst ]]; then
    require_cmd zstd
    tar --use-compress-program='zstd -d -T0' -xf "$DEC" -C "$CWAI_DIFY"
  else
    tar -xzf "$DEC" -C "$CWAI_DIFY"
  fi
  ok "  volumes 还原完成"
fi

# === 7. 起容器 ===
if [[ "$DO_DOCKER" -eq 1 ]]; then
  log "+1 启动 Dify 栈"
  (cd "$CWAI_DIFY" && docker compose up -d) || warn "docker compose up 失败，去手动看下"
fi

echo
ok "全部完成。下一步建议："
echo "  1) 在主仓里 \`git status\`，确认 7 个 .env 已就位"
echo "  2) 跑你的 dev 脚本（bridge / admin / notify），看看能不能起"
echo "  3) 在 Claude Code 里随便提个问题，验证它能读到老记忆（应该会引用 MEMORY.md 里的条目）"
echo "  4) 想验证对话延续？打开主仓，Claude Code 应该从 .remember/remember.md 读到本次 handoff"
