# Chatwoot-AI-vault

> **私有加密仓**，与 `Chatwoot-AI接待` 主仓配套，存放跨机器迁移所需的全部本地状态：
> .env 密钥、Docker bind-mount 补丁、Dify 栈配置、Claude 长期记忆、对话 handoff。
> Docker volumes 太大不入库，单独以 GitHub Release asset 形式上传。
>
> 全仓默认 git-crypt 加密；README/RESTORE/scripts 保留明文。

## 仓内布局

| 路径 | 还原到机器上的位置 | 内容 |
|---|---|---|
| `envs/main/.env*` | `~/Downloads/代码仓库/Chatwoot-AI接待/` 根 + 各子目录 | 7 个 .env 文件 |
| `cwai-patches/` | `~/.cwai-patches/` | Chatwoot bind-mount 注入补丁 |
| `cwai-dify-config/` | `~/.cwai-dify/`（除 volumes/） | Dify 栈 .env 和 docker-compose 等 |
| `claude-memory/` | `~/.claude/projects/<hash>/memory/` | MEMORY.md 与全部 feedback/project 记忆 |
| `remember-snapshot/` | `~/Downloads/代码仓库/Chatwoot-AI接待/.remember/` | 最新 handoff + 历史日志 |
| `volumes-manifest.json` | （仅元数据，不还原） | volumes bundle 的 release URL + sha256 + 时间戳 |
| `scripts/` | 直接在仓内运行 | restore.sh / sync-up.sh / sync-down.sh / bundle-volumes.sh |

## 关键约束（违反就找不到记忆 / 容器起不来）

1. **主仓必须放在** `~/Downloads/代码仓库/Chatwoot-AI接待/`，路径变了 Claude memory hash 就错位。
2. **解密钥不能进任何 git 仓**。建议用带外通道传：U 盘、AirDrop、1Password 共享、扫码。
3. **macOS Surge/Clash 用户**先确认 `PROBE_ALLOW_PRIVATE_IPS=1`、NO_PROXY 已设——这些是 .env 里的，但代理软件本身要先装好。

## 新机器全流程

参见根目录 [`RESTORE.md`](./RESTORE.md)。一行话版本：
```
brew install git-crypt gh && gh auth login \
  && git clone <vault-url> && cd Chatwoot-AI-vault \
  && git-crypt unlock /path/to/vault.key \
  && ./scripts/restore.sh
```

## 双向同步

- **本机改动推到云端**：`./scripts/sync-up.sh "改了 XXX"`
- **从云端拉另一台的改动**：`./scripts/sync-down.sh`
- **volumes 重新打包上传**：`./scripts/bundle-volumes.sh`（会停容器）

详见 RESTORE.md 末尾的"日常同步"小节。
