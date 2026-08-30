# 傻瓜式安装 — MT5 → MT5 跟单桥

面向完全不懂命令行的用户。本项目分**两半**：
**① 服务器**（跑本程序的电脑）和 **② MT5 电脑**（挂 EA 的地方）。
两半可以是同一台电脑，也可以分开。

---

# 第一部分：装服务器

## 第一步：装 Python（只需一次）

1. 打开 <https://www.python.org/downloads/>，下载并安装。
2. **务必勾选 `Add Python to PATH`。**

> 已有 Python 3.11+ 跳过。

## 第二步：下载本项目

本仓库页面点绿色 `Code` → `Download ZIP`，解压到桌面。

## 第三步：一键安装

1. 打开文件夹，右键 `install.ps1` → **使用 PowerShell 运行**。
2. 跑完后记下两串令牌：
   - **管理令牌** —— 打开控制台时用
   - **桥接令牌** —— 第二部分装桥接器时用
3. 浏览器自动打开控制台，粘入管理令牌。
4. 在「运行配置」里设好源标识、执行端标识、倍率等，保存。**先别开「启用执行」。**

---

# 第二部分：装 MT5 端

## 第四步：装桥接器

1. 在控制台点「下载桥接器」，或从本仓库 GitHub Releases 下载
   `Forex_MT5_Copy_Sync_Bridge_Setup.exe`。
2. 运行它，填三样：
   - **API 地址** = 服务器地址（同一台电脑就是 `http://127.0.0.1:18197`）
   - **桥接令牌** = 第一部分记下的那串
   - **ExecutorId** = 与控制台里的执行端标识一致（默认 `executor`）
3. 点安装，它会自动释放并编译两个 EA。

## 第五步：在 MT5 里挂 EA

1. **源账户**（你要跟的信号账户）的图表上，挂 `ForexMt5SourceBridge`，
   `SourceId` 填控制台里的源标识（默认 `master`）。
2. **执行账户**（实际下单的账户）的图表上，挂 `ForexMt5Executor`，
   `ExecutorId` 与第四步一致。
3. 两个 EA 的 `BridgeFolder` 保持默认 `Forex_MT5_Copy` 即可（要改就两边一起改）。
4. MT5 里允许「算法交易」。

## 第六步：验证

回到控制台，点「测试 / 手动验证」注入一笔模拟成交，看命令是否从
`待执行 → 已投递 → 成功` 走完。通了以后再打开「启用执行」跑实盘。

---

## ⭐ 三组必须对齐的标识（跑不通九成在这）

| 必须相等 | 服务器控制台 | MT5 端 |
|---|---|---|
| 源标识 | `source_id`（默认 master） | 源端 EA 的 `SourceId` |
| 执行端标识 | `executor_id`（默认 executor） | 执行端 EA + 桥接器的 `ExecutorId` |
| 共享目录 | — | 两个 EA + 桥接器的 `BridgeFolder`（默认 Forex_MT5_Copy） |

---

## 交给 AI 帮你装

把下面这句发给你的 AI 助手（Claude / ChatGPT / Cursor 等）：

> 请阅读这个仓库 https://github.com/duobaiawa/mt5-to-mt5-copy-bridge
> 的 AGENT_DEPLOY.md，按里面的步骤帮我完成部署和配置。

它能帮你自动装好服务器那一半，并引导你完成 MT5 端。

---

## Linux / macOS（仅服务器半）

```bash
bash install.sh          # 加 --systemd 装成开机自启
```
MT5 端仍需在 Windows 上完成（MT5 是 Windows 程序）。

## 停止 / 重启

- **停止服务器**：关掉黑窗口。**重启**：双击 `start.ps1`。

> ⚠️ 对外服务前读 `DEPLOYMENT.md` 反向代理章节。
> ⚠️ 交易有风险，AS IS 提供。中国大陆用户先读 `COMPLIANCE.md`。
