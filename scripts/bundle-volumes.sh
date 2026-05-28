#!/usr/bin/env bash
# bundle-volumes.sh —— 打包 ~/.cwai-dify/volumes/ 成加密 tarball，上传到 vault 仓的 GitHub Release
# 必须停容器以拿到一致快照。OpenSSL AES-256-CBC + PBKDF2 加密，password 从 vault.key 派生。
#
# 用法:
#   ./scripts/bundle-volumes.sh                     # 完整：停容器→打包→加密→上传 release
#   ./scripts/bundle-volumes.sh --no-stop           # 不停容器（不一致风险自担）
#   ./scripts/bundle-volumes.sh --local-only        # 只生成本地加密包，不上传

source "$(dirname "$0")/_lib.sh"

STOP_CONTAINERS=1
UPLOAD=1
KEY_PATH="${VAULT_KEY:-$HOME/.config/chatwoot-ai-vault.key}"

for a in "$@"; do
  case "$a" in
    --no-stop)    STOP_CONTAINERS=0 ;;
    --local-only) UPLOAD=0 ;;
    *) die "未知参数: $a" ;;
  esac
done

cd "$VAULT_DIR"
assert_standard_paths
require_cmd tar
require_cmd openssl
require_cmd shasum
[[ "$UPLOAD" -eq 1 ]] && require_cmd gh
[[ -f "$KEY_PATH" ]] || die "vault key 不在 $KEY_PATH —— 设 VAULT_KEY 环境变量或把 key 放过去"

readonly VOLUMES_SRC="$CWAI_DIFY/volumes"
[[ -d "$VOLUMES_SRC" ]] || die "找不到 $VOLUMES_SRC"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TARBALL="$WORK/volumes-$STAMP.tar.zst"
ENC="$WORK/volumes-$STAMP.tar.zst.enc"

if [[ "$STOP_CONTAINERS" -eq 1 ]]; then
  log "停 Dify 容器栈以保数据一致性..."
  (cd "$CWAI_DIFY" && docker compose stop) || warn "docker compose stop 失败（可能本来就没起）"
fi

log "打包 volumes/ → $TARBALL"
# 用 zstd 压缩比 gzip 高，对 plugin_daemon 这种已压缩内容也快。Mac 自带 zstd（Sequoia 起）。
if command -v zstd >/dev/null 2>&1; then
  tar --use-compress-program='zstd -T0 -19' -cf "$TARBALL" -C "$CWAI_DIFY" volumes
else
  warn "zstd 不存在，降级到 gzip"
  TARBALL="$WORK/volumes-$STAMP.tar.gz"
  ENC="$WORK/volumes-$STAMP.tar.gz.enc"
  tar -czf "$TARBALL" -C "$CWAI_DIFY" volumes
fi
SIZE="$(du -h "$TARBALL" | cut -f1)"
ok "压缩完成: $SIZE"

log "AES-256-CBC + PBKDF2 加密..."
# 从 key 文件派生 sha256 当 passphrase——绕开 LibreSSL 对二进制 key file 的 NUL 截断
PASSPHRASE="$(shasum -a 256 "$KEY_PATH" | awk '{print $1}')"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$TARBALL" -out "$ENC" -pass "pass:$PASSPHRASE"
unset PASSPHRASE

SHA="$(shasum -a 256 "$ENC" | awk '{print $1}')"
ASSET_NAME="$(basename "$ENC")"
ok "加密完成: $ASSET_NAME  sha256=${SHA:0:16}…"

if [[ "$STOP_CONTAINERS" -eq 1 ]]; then
  log "重新拉起 Dify 容器栈..."
  (cd "$CWAI_DIFY" && docker compose up -d) || warn "docker compose up 失败，去手动看下"
fi

if [[ "$UPLOAD" -eq 0 ]]; then
  ok "本地包: $ENC"
  echo "（--local-only，未上传。手动上传请用：gh release upload <tag> $ENC --repo <vault-repo>）"
  exit 0
fi

# 取 vault repo 名（从当前 git remote 推断）
VAULT_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$VAULT_REPO" ]] || die "无法识别当前仓的 GitHub repo，先 gh auth login + git push 一次"

TAG="volumes-$STAMP"
log "创建 release $TAG @ $VAULT_REPO"
gh release create "$TAG" "$ENC" \
  --repo "$VAULT_REPO" \
  --title "Volumes snapshot $STAMP" \
  --notes "sha256: $SHA · size: $SIZE · host: $(hostname -s)"

log "写 volumes-manifest.json"
cat > volumes-manifest.json <<EOF
{
  "tag": "$TAG",
  "asset": "$ASSET_NAME",
  "sha256": "$SHA",
  "size": "$SIZE",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname -s)",
  "repo": "$VAULT_REPO"
}
EOF

git add volumes-manifest.json
git commit -m "bundle: volumes $STAMP ($SIZE)"
git push
ok "完成。新机器 restore.sh 会读 volumes-manifest.json 自动找最新包。"
