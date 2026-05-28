# 新机器还原指南

> 给「另一台 Mac」的你（或者给 Claude Code 看，让它代你操作）。
> 完成下列 6 步，环境/数据/账号/Claude 长期记忆/上次对话 handoff 全部回来。

---

## 必备前提

- macOS（脚本里有 `du -h`、`shasum` 等 BSD 风格命令，没在 Linux 上测过）
- 已装 Homebrew、Docker Desktop、Node、pnpm（按主仓 `package.json` 要求的版本）
- 已配同款代理（如 Surge/Clash），或确认无代理；macOS 代理软件会把公网 IP 改成 198.18.x.x，主仓 .env 里的 `PROBE_ALLOW_PRIVATE_IPS=1` 会兜住这种情况

## Step 1 · 装工具链

```bash
brew install git-crypt gh openssl zstd
gh auth login          # 选 GitHub.com, HTTPS, 浏览器认证
```

## Step 2 · 取 vault key

**带外通道**（U 盘 / AirDrop / 1Password 共享 / 加密邮件均可），把 `chatwoot-ai-vault.key` 放到：

```bash
mkdir -p ~/.config
cp /your/secure/source/chatwoot-ai-vault.key ~/.config/chatwoot-ai-vault.key
chmod 600 ~/.config/chatwoot-ai-vault.key
```

> ⚠️ 这把 key 绝对不要 commit、不要发 IM、不要丢 iCloud Drive。同样别走和 vault 仓相同的传输路径——分离才有意义。

## Step 3 · Clone 两个仓（**路径不能改！**）

```bash
mkdir -p ~/Downloads/代码仓库
cd ~/Downloads/代码仓库
# 远端是 ASCII 仓名；本地目录名必须用中文（slug 一致性要求）
gh repo clone <your-username>/chatwoot-ai-reception "Chatwoot-AI接待"
gh repo clone <your-username>/chatwoot-ai-vault     "Chatwoot-AI-vault"
```

**为什么路径必须一致？** Claude Code 用项目绝对路径生成 memory 目录的 slug。路径变了 slug 就变，老记忆找不到。如果你机器上 `$HOME` 不一样（比如用户名不同），脚本会自动适配 `$HOME`，但项目放的相对位置不能变。

## Step 4 · 解锁 vault

```bash
cd ~/Downloads/代码仓库/Chatwoot-AI-vault
git-crypt unlock ~/.config/chatwoot-ai-vault.key
git-crypt status        # 确认所有加密文件状态正常
```

## Step 5 · 跑 restore.sh

```bash
./scripts/restore.sh
```

它会：
1. 把 7 个 .env 还原到主仓
2. 重建 `~/.cwai-patches/` 和 `~/.cwai-dify/`（配置部分）
3. 把 Claude 长期记忆放进 `~/.claude/projects/<slug>/memory/`
4. 把上次的 `.remember/remember.md`（含本次对话 handoff）还原到主仓
5. 从 GitHub Release 下载 volumes 加密包，校验 sha256，AES-256 解密，解压到 `~/.cwai-dify/volumes/`
6. `docker compose up -d` 拉起 Dify 栈

跳过项：
- `--no-volumes` 不下载/不解 478MB 的 volumes 包（你可能想后面再做）
- `--no-docker` 不自动 `docker compose up`

## Step 6 · 验证

```bash
# Dify 栈
cd ~/.cwai-dify && docker compose ps

# 主仓 envs
cd ~/Downloads/代码仓库/Chatwoot-AI接待 && ls -la .env bridge/.env admin/backend/.env

# 启动你常用的 dev server，看 bridge ↔ chatwoot ↔ Dify 是否连通
```

然后在主仓里启动 Claude Code，问它："读 .remember/remember.md 然后告诉我上次我们在做什么"。Claude 应该能精准复述本次会话上下文。

---

## 让 Claude Code 帮你跑（最省事版本）

新机器上做完 Step 1 + Step 2 + Step 3 + Step 4 后，在主仓里打开 Claude Code，对它说：

> 我刚换了新机器。请读 `~/Downloads/代码仓库/Chatwoot-AI-vault/RESTORE.md`，然后执行 Step 5 和 Step 6，最后告诉我环境是否就绪。

Claude 会读这个文件，跑 `restore.sh`，然后 `docker compose ps`、`curl` 检查端点，给你一份 health report。

---

## 日常双向同步

### 老机器 → 云
```bash
cd ~/Downloads/代码仓库/Chatwoot-AI-vault
./scripts/sync-up.sh "改了 bridge 的 AI provider 配置"
```

### 云 → 新机器
```bash
cd ~/Downloads/代码仓库/Chatwoot-AI-vault
./scripts/sync-down.sh            # dry-run，看会改啥
./scripts/sync-down.sh --apply    # 真同步
```

### Volumes 重打包（仅当数据库/账号有更新）
```bash
./scripts/bundle-volumes.sh       # 停容器、tar+zstd+aes、上传到 release、更新 manifest
```

> **冲突处理**：vault 是 git 仓，冲突就 git 冲突。.env 用扁平命名（`bridge.env` 而非嵌套 `bridge/.env`），diff 一目了然。Claude memory 是 markdown，能直接 merge。volumes 不在 git 里，多机轮流 bundle 即可，旧 release 用 `gh release delete` 清理。

---

## 故障排查

| 现象 | 原因 | 解 |
|---|---|---|
| `vault locked` | git-crypt 没 unlock | `git-crypt unlock ~/.config/chatwoot-ai-vault.key` |
| `sha256 不对` | volumes release 损坏或被改 | 重新 `bundle-volumes.sh` |
| Claude 没读到老记忆 | 项目路径与原机不一致 | 检查 `~/.claude/projects/` 下 slug 是不是 `-Users-<你>-Downloads------Chatwoot-AI--` |
| bridge → chatwoot socket hang up | macOS 代理拦截 | 确认 .env 里 `NO_PROXY` 包含 localhost / 127.0.0.1 / host.docker.internal |
| Dify `/console/api/*` 全 502 | nginx DNS 缓存 | `cd ~/.cwai-dify && docker compose restart nginx` |
| bridge 探测被拒 fake IP | Surge/Clash 改了 DNS | .env 设 `PROBE_ALLOW_PRIVATE_IPS=1` |
