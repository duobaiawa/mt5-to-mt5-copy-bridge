# 配置参考 · 零凭据跟单桥

本项目所有可调参数分四层。**没有任何一层需要改源码。**

| 层 | 配置方式 | 何时生效 | 改动频率 |
|---|---|---|---|
| 1. 环境变量 | `.env` 或系统环境变量 | 重启服务 | 部署时一次 |
| 2. 运行配置 | 控制台页面 / `POST /api/settings` | 立即 | 随时 |
| 3. EA 输入 | MT5 里挂载 EA 时填写 | 重新挂载 | 装机时 |
| 4. 桥接器参数 | 安装器界面 / PowerShell 参数 | 重启桥接器 | 装机时 |

---

## 1. 环境变量（`.env`）

`app.py` 启动时自动读取同目录的 `.env`；**系统环境变量优先级更高**，方便容器和 systemd 覆盖。

### 鉴权（必填）

| 变量 | 默认 | 说明 |
|---|---|---|
| `FOREX_MT5_ADMIN_TOKEN` | 空 | 控制台令牌。为空时所有管理接口返回 503 |
| `FOREX_MT5_BRIDGE_TOKEN` | 空 | 桥接器令牌。为空时所有桥接接口返回 503 |
| `FOREX_MT5_DISABLE_AUTH` | `0` | 设 1 关闭全部鉴权。**仅限本机 127.0.0.1 开发** |

用 `python scripts/init_env.py` 自动生成两个随机令牌。

### 服务

| 变量 | 默认 | 说明 |
|---|---|---|
| `FOREX_MT5_COPY_HOST` | `127.0.0.1` | 监听地址。容器内才设 `0.0.0.0` |
| `FOREX_MT5_COPY_PORT` | `18197` | 监听端口 |
| `FOREX_MT5_COPY_LOG_LEVEL` | `info` | uvicorn 日志级别 |
| `FOREX_MT5_API_MAX_LIMIT` | `500` | 列表接口单次最多返回多少行 |

### 交易

| 变量 | 默认 | 说明 |
|---|---|---|
| `FOREX_MT5_COPY_SYMBOL` | `XAUUSD` | 数据库首次初始化时的默认品种 |
| `FOREX_MT5_CLIENT_REF_PREFIX` | `fxmt5` | 写进 MT5 订单注释的引用前缀，用于对账 |

### 路径

| 变量 | 默认 | 说明 |
|---|---|---|
| `FOREX_MT5_COPY_DIR` | 程序所在目录 | 项目根 |
| `FOREX_MT5_COPY_DATA_DIR` | `<root>/data` | 数据目录 |
| `FOREX_MT5_COPY_DB` | `<data>/state.db` | SQLite 路径 |

---

## 2. 运行配置（控制台可改，立即生效）

存在 SQLite 的 `settings` 表，走 `POST /api/settings` 白名单校验，非白名单字段直接忽略。

| 键 | 默认 | 说明 |
|---|---|---|
| `source_id` | `master` | 认可的源标识。与此不符的推送会被拒绝并记录 |
| `source_label` | `MT5观摩源` | 显示名 |
| `executor_id` | `executor` | 执行端标识，决定命令文件名 `commands_<id>.csv` |
| `source_symbol` | `XAUUSD` | 源端品种 |
| `executor_symbol` | `XAUUSD` | 执行端品种。**两边券商符号不同时在这里映射** |
| `multiplier` | `1` | 手数倍率 |
| `lot_step` | `0.01` | 手数步长，向下取整 |
| `min_lot` | `0.01` | 低于此手数的跟单直接跳过 |
| `trading_enabled` | `false` | 总开关。false 时只生成计划事件，不下发命令 |
| `max_slippage_points` | `30` | 随命令下发给 EA 的最大滑点 |
| `resend_after_seconds` | `30` | 已投递但未收到 ack 多久后重发 |
| `max_command_attempts` | `20` | 单条命令最多投递次数，超过则停投 |

---

## 3. EA 输入参数

### `ForexMt5SourceBridge.mq5`（源端）

| 输入 | 默认 | 说明 |
|---|---|---|
| `SourceId` | `master` | 必须与运行配置的 `source_id` 一致 |
| `SymbolPrefix` | `XAUUSD` | 前缀匹配，可覆盖 `XAUUSD.m`、`XAUUSDmicro` 之类的券商后缀 |
| `PollSeconds` | `1` | 扫描间隔 |
| `LookbackMinutes` | `120` | 首次启动回溯多久的历史成交 |
| `BridgeFolder` | `Forex_MT5_Copy` | 共享文件夹名，**必须与桥接器一致** |

### `ForexMt5Executor.mq5`（执行端）

| 输入 | 默认 | 说明 |
|---|---|---|
| `ExecutorId` | `executor` | 必须与运行配置的 `executor_id` 一致 |
| `PollSeconds` | `1` | 扫描命令文件间隔 |
| `MagicNumber` | `26051601` | 订单魔术号。一个终端跑多套时必须区分 |
| `DefaultDeviationPoints` | `30` | 服务端未下发滑点时的兜底值 |
| `BridgeFolder` | `Forex_MT5_Copy` | 共享文件夹名，**必须与桥接器一致** |

---

## 4. 桥接器参数

### Windows 安装器（`ForexMt5BridgeSetup.cs` 编译产物）

界面填写，存到 `%APPDATA%\MetaQuotes\Terminal\Common\Files\<BridgeFolder>ridge_config.txt`：

- `ApiUrl` —— 服务端地址。源码里的 `DefaultApiUrl` 只是占位默认值，**编译前改成你自己的地址**
- `ExecutorId` —— 执行端标识
- `BridgeToken` —— 桥接令牌

### PowerShell 代理（`Start-ForexMt5-BridgeAgent.ps1`）

```powershell
.\Start-ForexMt5-BridgeAgent.ps1 `
    -ApiUrl "https://copy.example.com" `
    -ExecutorId "executor" `
    -BridgeToken "<bridge token>" `
    -IntervalSeconds 1 `
    -BridgeFolder "Forex_MT5_Copy"
```

---

## 一致性检查表

跑不通时按这三组对照，九成问题出在这里：

| 必须相等 | 位置 A | 位置 B | 位置 C |
|---|---|---|---|
| 源标识 | 运行配置 `source_id` | 源端 EA `SourceId` | — |
| 执行端标识 | 运行配置 `executor_id` | 执行端 EA `ExecutorId` | 桥接器 `ExecutorId` |
| 共享目录 | 源端 EA `BridgeFolder` | 执行端 EA `BridgeFolder` | 桥接器 `BridgeFolder` |
