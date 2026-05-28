#!/usr/bin/env bash
# restore-named-volumes.sh —— 下载并还原所有 docker「命名卷」(app/chatwoot/fastgpt)
# 配合 bundle-named-volumes.sh。读 named-volumes-manifest.json 找 release，校验 sha→解密→逐卷恢复。
# 默认「不覆盖已存在的卷」(安全)；要覆盖先手动 docker volume rm。
#
# 用法:
#   ./scripts/restore-named-volumes.sh            # 还原（跳过已存在的卷）
#   ./scripts/restore-named-volumes.sh --force     # 覆盖已存在的卷（先删后还原）

source "$(dirname "$0")/_lib.sh"

FORCE=0
KEY_PATH="${VAULT_KEY:-$HOME/.config/chatwoot-ai-vault.key}"
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) die "未知参数: $a" ;;
  esac
done

cd "$VAULT_DIR"
require_cmd docker
require_cmd gh
require_cmd openssl
require_cmd shasum
require_cmd tar
require_cmd python3
[[ -f named-volumes-manifest.json ]] || die "没有 named-volumes-manifest.json —— 老机器先跑 bundle-named-volumes.sh"
[[ -f "$KEY_PATH" ]] || die "vault key 不在 $KEY_PATH"

TAG="$(python3 -c 'import json;print(json.load(open("named-volumes-manifest.json"))["tag"])')"
ASSET="$(python3 -c 'import json;print(json.load(open("named-volumes-manifest.json"))["asset"])')"
EXPECTED_SHA="$(python3 -c 'import json;print(json.load(open("named-volumes-manifest.json"))["sha256"])')"
REPO="$(python3 -c 'import json;print(json.load(open("named-volumes-manifest.json"))["repo"])')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "下载 release $TAG @ $REPO"
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK"

ACTUAL_SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "sha256 不符！期望 $EXPECTED_SHA 实际 $ACTUAL_SHA"
ok "sha256 校验通过"

log "AES-256-CBC 解密"
DEC="$WORK/${ASSET%.enc}"
PASSPHRASE="$(shasum -a 256 "$KEY_PATH" | awk '{print $1}')"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$WORK/$ASSET" -out "$DEC" -pass "pass:$PASSPHRASE"
unset PASSPHRASE

EXDIR="$WORK/ex"; mkdir -p "$EXDIR"
log "解开 bundle"
if [[ "$DEC" == *.zst ]]; then
  require_cmd zstd
  tar --use-compress-program='zstd -d -T0' -xf "$DEC" -C "$EXDIR"
else
  tar -xzf "$DEC" -C "$EXDIR"
fi
SRC="$EXDIR/named-volumes"
[[ -f "$SRC/_VOLUMES.txt" ]] || die "包结构异常：缺 _VOLUMES.txt"

HELPER="$(resolve_helper_image)" || die "找不到含 tar 的辅助镜像，且拉不动 alpine。请 docker pull alpine，或设 HELPER_IMAGE=<本机已有镜像>"
log "辅助镜像: $HELPER"

while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  tarf="$SRC/${v}.tar"
  [[ -f "$tarf" ]] || { warn "包里缺 ${v}.tar，跳过"; continue; }
  if docker volume inspect "$v" >/dev/null 2>&1; then
    if [[ "$FORCE" -eq 1 ]]; then
      warn "卷 $v 已存在 → --force，删除重建"
      docker volume rm "$v" >/dev/null || die "删 $v 失败（可能有容器在用，先停栈）"
    else
      warn "卷 $v 已存在 → 跳过（要覆盖加 --force）"
      continue
    fi
  fi
  log "还原卷 $v"
  docker volume create "$v" >/dev/null
  docker run --rm --entrypoint sh -v "$v":/data -v "$SRC":/in:ro "$HELPER" \
    -c "cd /data && tar xf /in/${v}.tar" || die "还原 $v 失败"
  ok "  $v ✓"
done < "$SRC/_VOLUMES.txt"

echo
ok "命名卷全部还原。下一步起栈："
echo "  cd $MAIN_REPO/infra && docker compose up -d        # chatwoot v3/v4 + FastGPT"
echo "  cd $MAIN_REPO && docker compose -f docker-compose.app.yml up -d   # bridge/admin/notify(若容器化跑)"
