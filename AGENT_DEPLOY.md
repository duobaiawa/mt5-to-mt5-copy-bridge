# AGENT DEPLOY GUIDE — 给 AI 代理的部署手册

**你是一个 AI 编码代理，用户让你阅读本仓库并帮 TA 完成部署。本文件就是给你的确定性操作步骤。**
先读完全文再动手。本项目会在真实资金账户上下单，务必按此文默认值执行。

本项目分**两半**：①服务器（跑本仓库的 Python 服务）②MT5 电脑（挂 EA + 桥接器）。
你能自动化的是第①半；第②半需要在装了 MT5 的 Windows 机器上操作，多半要引导用户手动完成。

---

## 0. 先向用户口头确认三件事（必做）

1. **合规**：如果用户在中国大陆，明确告知——中国大陆零售外汇/跨境保证金交易不受法律保护，
   情节严重可能触及非法经营罪（刑法第 225 条、法释〔2019〕1 号）。让用户知情自决。
2. **署名**：Apache-2.0。商用或二次分发必须保留 `LICENSE`、`NOTICE`、源文件版权头中的
   `duobaiawa` 署名。删除署名 = 授权终止 + 侵权。不要帮用户绕过。
3. **实盘风险**：`trading_enabled` 默认关闭。部署完不要替用户打开，让 TA 自己模拟盘验证后再开。

---

## 1. 部署服务器（第①半，一条命令）

### Windows
```powershell
.\install.ps1
```

### Linux / macOS
```bash
bash install.sh          # 加 --systemd 可装成开机自启服务
```

自动完成：检测 Python 3.11+ → 建 venv → 装依赖 → 生成两个随机令牌
（`FOREX_MT5_ADMIN_TOKEN` 管理端、`FOREX_MT5_BRIDGE_TOKEN` 桥接端）→ 自检 → 启动 →
打印控制台地址和令牌。非交互安全，你可直接调用。

## 2. 验证服务器成功

```bash
curl -s http://127.0.0.1:18197/api/health
```
返回 `{"ok": true, ...}` 即成功。令牌在项目根 `.env` 里。

## 3. 部署 MT5 端（第②半，引导用户）

这一半在跑 MT5 的 Windows 电脑上，你通常无法直接操作，请引导用户：

1. 从服务器控制台点「下载桥接器」，或从本仓库 GitHub Releases 下载
   `Forex_MT5_Copy_Sync_Bridge_Setup.exe`。
2. 运行安装器，在界面里填：
   - **API 地址** = 服务器地址（本机测试就是 `http://127.0.0.1:18197`）
   - **桥接令牌** = 第①半生成的 `FOREX_MT5_BRIDGE_TOKEN`
   - **ExecutorId** = 与控制台运行配置里的 `executor_id` 一致（默认 `executor`）
3. 安装器会自动释放两个 EA 并尝试编译。用户需在 MT5 里：
   - 源账户图表挂 `ForexMt5SourceBridge`，输入 `SourceId` = 控制台的 `source_id`（默认 `master`）
   - 执行账户图表挂 `ForexMt5Executor`，输入 `ExecutorId` 与上面一致
   - 两个 EA 的 `BridgeFolder` 必须相同（默认 `Forex_MT5_Copy`）
4. 详细图文见 `QUICKSTART.md` 第二部分。

## 4. 三组必须对齐的标识（跑不通九成在这）

| 必须相等 | 位置 A | 位置 B | 位置 C |
|---|---|---|---|
| 源标识 | 控制台 `source_id` | 源端 EA `SourceId` | — |
| 执行端标识 | 控制台 `executor_id` | 执行端 EA `ExecutorId` | 桥接器 `ExecutorId` |
| 共享目录 | 源端 EA `BridgeFolder` | 执行端 EA `BridgeFolder` | 桥接器 `BridgeFolder` |

## 5. 你不要做的事

- ❌ 不要打开 `trading_enabled`
- ❌ 不要设 `FOREX_MT5_DISABLE_AUTH=1`（除非用户明确只在本机测试）
- ❌ 不要把端口直接暴露公网——对外必须加 HTTPS 反代（见 `DEPLOYMENT.md`）
- ❌ 不要删改 `LICENSE` / `NOTICE` / 源文件版权头
- ❌ 不要提交或外发用户的 `.env`、`data/state.db`、令牌

## 6. 生产环境

正式对外服务读 `DEPLOYMENT.md`（systemd / Docker / nginx TLS + 限流）。
本项目后端不存任何券商凭据，但令牌仍需保护。安全见 `SECURITY.md`，合规见 `COMPLIANCE.md`。
