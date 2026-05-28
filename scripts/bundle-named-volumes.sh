#!/usr/bin/env bash
# bundle-named-volumes.sh —— 打包项目所有 docker「命名卷」成加密 tarball，上传 vault 仓 Release
#
# 为什么单独一个脚本：bundle-volumes.sh 只会打包 ~/.cwai-dify/volumes（bind-mount 的目录）。
# 但 app(bridge/admin DB) / chatwoot(v3+v4) / FastGPT 的数据都存在 docker「命名卷」里，
# 命名卷在 Docker VM 内部、不是 host 目录，必须用临时 alpine 容器挂卷导出。
# 加密方式与 bundle-volumes.sh 完全一致（AES-256-CBC + PBKDF2，passphrase = sha256(key)）。
#
# 用法:
#   ./scripts/bundle-named-volumes.sh                 # 全量：停栈→导出→加密→上传 release
#   ./scripts/bundle-named-volumes.sh --no-stop       # 不停容器（快照不一致风险自担）
#   ./scripts/bundle-named-volumes.sh --local-only    # 只生成本地加密包，不上传

source "$(dirname "$0")/_lib.sh"

STOP=1
UPLOAD=1
KEY_PATH="${VAULT_KEY:-$HOME/.config/chatwoot-ai-vault.key}"

for a in "$@"; do
  case "$a" in
    --no-stop)    STOP=0 ;;
    --local-only) UPLOAD=0 ;;
    *) die "未知参数: $a" ;;
  esac
done

cd "$VAULT_DIR"
require_cmd docker
require_cmd tar
require_cmd openssl
require_cmd shasum
[[ "$UPLOAD" -eq 1 ]] && require_cmd gh
[[ -f "$KEY_PATH" ]] || die "vault key 不在 $KEY_PATH —— 设 VAULT_KEY 或把 key 放过去"

# 项目所有命名卷的「声明名」(compose 里的短名)。实际卷名可能带项目前缀（如 infra_cw_next_pg_data）。
DECLARED="
app_pg_data app_redis_data
cw_pg_data cw_redis_data cw_storage
cw_next_pg_data cw_next_redis_data cw_next_storage
fastgpt-pg fastgpt-mongo fastgpt-redis fastgpt-minio fastgpt-aiproxy_pg
"

# 按「精确等于」或「以 _声明名 结尾」匹配真实卷名（兼容任意项目前缀），不会误抓无关卷
log "扫描本机 docker 命名卷..."
FOUND=()
while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  for d in $DECLARED; do
    if [[ "$v" == "$d" || "$v" == *"_$d" ]]; then
      FOUND+=("$v"); ok "  匹配: $v"; break
    fi
  done
done < <(docker volume ls --format '{{.Name}}')

[[ ${#FOUND[@]} -gt 0 ]] || die "没找到任何项目命名卷（栈没建过？或在别的 docker context？先 docker volume ls 看看）"
warn "共匹配 ${#FOUND[@]} 个卷，开始备份"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/named-volumes"
mkdir -p "$STAGE"

if [[ "$STOP" -eq 1 ]]; then
  log "停 infra/app 栈以保数据一致..."
  (cd "$MAIN_REPO/infra" && docker compose stop) 2>/dev/null || warn "  infra compose stop 跳过（可能没起）"
  (cd "$MAIN_REPO" && docker compose -f docker-compose.app.yml stop) 2>/dev/null || warn "  app compose stop 跳过"
fi

# 逐卷用 alpine 容器导出为 tar（卷名写进文件名，还原时一一对应）
for v in "${FOUND[@]}"; do
  log "导出卷 $v"
  docker run --rm -v "$v":/data:ro -v "$STAGE":/out alpine \
    sh -c "cd /data && tar cf /out/${v}.tar ." || die "导出 $v 失败"
done
printf '%s\n' "${FOUND[@]}" > "$STAGE/_VOLUMES.txt"

TARBALL="$WORK/named-volumes-$STAMP.tar.zst"
ENC="$TARBALL.enc"
log "聚合压缩 → $(basename "$TARBALL")"
if command -v zstd >/dev/null 2>&1; then
  tar --use-compress-program='zstd -T0 -19' -cf "$TARBALL" -C "$WORK" named-volumes
else
  warn "zstd 不存在，降级 gzip"
  TARBALL="$WORK/named-volumes-$STAMP.tar.gz"; ENC="$TARBALL.enc"
  tar -czf "$TARBALL" -C "$WORK" named-volumes
fi
SIZE="$(du -h "$TARBALL" | cut -f1)"
ok "压缩完成: $SIZE"

log "AES-256-CBC + PBKDF2 加密..."
PASSPHRASE="$(shasum -a 256 "$KEY_PATH" | awk '{print $1}')"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$TARBALL" -out "$ENC" -pass "pass:$PASSPHRASE"
unset PASSPHRASE
SHA="$(shasum -a 256 "$ENC" | awk '{print $1}')"
ASSET_NAME="$(basename "$ENC")"
ok "加密完成: $ASSET_NAME  sha256=${SHA:0:16}…"

if [[ "$STOP" -eq 1 ]]; then
  log "重新拉起栈..."
  (cd "$MAIN_REPO/infra" && docker compose up -d) 2>/dev/null || warn "  infra up 跳过"
  (cd "$MAIN_REPO" && docker compose -f docker-compose.app.yml up -d) 2>/dev/null || warn "  app up 跳过"
fi

if [[ "$UPLOAD" -eq 0 ]]; then
  ok "本地包: $ENC"
  echo "（--local-only，未上传）"
  exit 0
fi

VAULT_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$VAULT_REPO" ]] || die "无法识别 vault 的 GitHub repo，先 gh auth login + git push 一次"

TAG="named-volumes-$STAMP"
log "创建 release $TAG @ $VAULT_REPO"
gh release create "$TAG" "$ENC" \
  --repo "$VAULT_REPO" \
  --title "Named volumes snapshot $STAMP" \
  --notes "sha256: $SHA · size: $SIZE · host: $(hostname -s) · vols: ${#FOUND[@]}"

log "写 named-volumes-manifest.json"
VOLS_JSON="$(printf '"%s",' "${FOUND[@]}" | sed 's/,$//')"
cat > named-volumes-manifest.json <<EOF
{
  "tag": "$TAG",
  "asset": "$ASSET_NAME",
  "sha256": "$SHA",
  "size": "$SIZE",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname -s)",
  "repo": "$VAULT_REPO",
  "volumes": [$VOLS_JSON]
}
EOF

git add named-volumes-manifest.json
git commit -m "bundle: named-volumes $STAMP ($SIZE, ${#FOUND[@]} vols)"
git push
ok "完成。新机器跑 ./scripts/restore-named-volumes.sh 会读 manifest 自动还原。"
