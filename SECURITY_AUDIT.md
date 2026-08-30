# 安全审计报告

审计对象：`mt5-to-gateio-copy-bridge`（MT5 → Gate.io）与 `mt5-to-mt5-copy-bridge`（MT5 → MT5）
审计日期：2026-08-31
审计范围：Python 后端、前端控制台、MQL5 EA、C# 桥接安装器、PowerShell 代理、SQLite 数据库、打包产物

---

## 一、已修复（本次改动）

### F-01 [严重] xauusd 全站无鉴权
`AUTH_DISABLED = True` 写死在源码里，`require_session()` 无条件返回 `"public"`。
15 个接口全部对任何人开放，包括：

- `POST /api/gate-accounts` —— 写入/覆盖 Gate API key + secret
- `POST /api/mt5-sources` —— 写入 MT5 账号密码
- `POST /api/settings` —— 把 `trading_enabled` 打开
- `POST /api/deals/ingest` —— 注入伪造成交，直接触发真实下单
- `POST /api/probe/gate` —— 用已存密钥查询账户资产
- `DELETE /api/{mt5-sources,gate-accounts}/{id}` —— 删除配置

**影响**：只要服务端口可达，攻击者无需任何凭据即可让你的 Gate 账户按他的指令开平仓。
**修复**：改为环境变量驱动的令牌鉴权（`X-Admin-Token`），默认开启、未配置令牌时拒绝服务（fail-closed）；
`XAUUSD_COPY_DISABLE_AUTH=1` 仅供本机开发使用。

### F-02 [严重] xauusd 桥接令牌是死代码
`XAUUSD_COPY_BRIDGE_TOKEN` 被读入，但全文件没有任何一处校验它，只在 `/api/auth/meta` 里回显
`bridge_enabled: true`——看起来有鉴权，实际没有。
**修复**：`/api/deals/ingest` 现在强制校验 `X-Bridge-Token`（管理员令牌亦可，供控制台手动注入）。

### F-03 [高] forex 令牌校验 fail-open
```python
if BRIDGE_TOKEN and x_bridge_token != BRIDGE_TOKEN:   # 旧代码
```
环境变量没配 → `BRIDGE_TOKEN` 为空 → 条件永远为假 → **鉴权被静默跳过**。
忘记设 env 的部署 = 完全裸奔，且没有任何告警。
**修复**：未配置令牌时返回 503 明确拒绝，不再放行。

### F-04 [高] forex 读接口无鉴权
`/api/status`、`/api/settings`、`/api/deals`、`/api/events`、`/api/commands`、`/api/logs` 全部匿名可读，
泄露实时持仓、手数、倍率、source_id/executor_id 和完整事件日志。
**修复**：全部纳入 `X-Admin-Token` 保护。

### F-05 [中] 令牌比较非常量时间
两代都用 `!=` 直接比字符串，存在时序侧信道。
**修复**：统一改用 `hmac.compare_digest()`。

### F-06 [中] forex 异常处理器回显内部错误
`return {"detail": str(exc)}` 把内部异常原文返回给客户端。
**修复**：客户端只收到 `internal server error` + 一个 `error_id`；完整堆栈写入事件日志，按 id 可追溯。

### F-07 [中] forex `/api/health` 泄露服务器路径
返回 `{"db": "/opt/forex_mt5_copy_sync/data/state.db"}`。
**修复**：健康检查不再返回文件系统路径。

### F-08 [高] 备份包内的真实密钥与身份信息
| 位置 | 内容 | 处理 |
|---|---|---|
| `xauusd_copy_sync/.env` | 2 个生产令牌 | 移出仓库 → `.env.example` |
| `forex_mt5_copy_sync_test/.env` | 2 个生产令牌 | 移出仓库 → `.env.example` |
| `xauusd .../state.db` | 真实 MT5 账号 + 明文密码、452 条真实成交 | 移出仓库 |
| `ForexMt5BridgeSetup.cs:44` | 生产域名 `test.mt5-copy-sync.<已脱敏>` | 替换为 `http://127.0.0.1:18197` |
| `Forex_..._Setup_20260516.exe` | 编译产物内嵌同一域名（UTF-16） | 移出仓库，改由 Releases 分发 |

原始文件完整保留在工作区外的 `_private_original_data/`，两个 tar.gz 备份未做任何改动。

### F-09 [低] 其它
- xauusd 使用已废弃的 `@app.on_event("startup")` → 迁移到 `lifespan`，顺带修复了退出时轮询线程不停止的问题。
- xauusd 控制台的"下载桥接器"指向一个不存在的 exe（死链）→ 改为指向桥接教程页。
- 两代均补上 `.gitignore`，禁止 `.env`、`data/`、`*.db`、`*.exe` 再次入库。
- `Build-ForexMt5-BridgeSetup.ps1` 引用了备份里根本不存在的图标路径
  （`artifacts/xauusd_winforms_installer_.../xauusd_bridge.ico`），**开箱即构建失败**
  → 图标改为可选参数 `-Icon`，无图标也能正常编译；输出文件名去掉硬编码日期。

---

## 二、遗留风险（未改，需你决策）

### R-01 [高] 密钥明文落盘
`gate_accounts.api_secret`、`mt5_sources.password` 以明文存在 SQLite 里。
拿到 `state.db` 文件 = 拿到 Gate 交易权限。
**建议**：三选一 —— ① 用 env 里的主密钥做信封加密（需要迁移脚本 + 密钥管理方案）；
② 依赖磁盘加密 + `chmod 600`；③ 改为只存密钥引用，实际密钥交给系统密钥库。
未直接改是因为它会改变存储格式，需要你先定密钥管理方式。

### R-02 [中] 无频率限制
令牌接口可无限次爆破。建议前置 nginx 限流，或引入 slowapi。

### R-03 [中] 应用层无 TLS
令牌走 HTTP 头明文传输，必须部署在 HTTPS 反代之后。桥接器已启用 TLS 1.2，但默认地址是 http。

### R-04 [中] SQLite 单连接 + 全局锁
`check_same_thread=False` 配一把 RLock：正确但完全串行化。
xauusd 的 1 秒轮询叠加 Web 流量时会互相阻塞，慢查询会卡住下单路径。建议改为每线程独立连接。

### R-05 [中] xauusd MT5 轮询过重且无退避
`poll_mt5_sources` 每秒对每个源执行 `shutdown() → initialize() → login()`；
登录失败也是每秒重试，没有指数退避，容易触发券商风控。

### R-06 [低] 前端依赖第三方 CDN
xauusd 控制台从 `cdn.jsdelivr.net` 加载字体样式表——交易控制台引入外部资源，
既是可用性风险也会把访问行为暴露给第三方。建议自托管或删除。

### R-07 [低] `ensure_column()` 用 f-string 拼表名/列名
目前只以硬编码字面量调用，不可利用；但后续若传入外部输入即成注入点。

### R-08 [信息] CSRF
鉴权走自定义请求头而非 Cookie，跨站表单无法伪造该头，当前设计已天然免疫。
**若未来改成 Cookie 会话，必须同时加 CSRF 令牌。**

---

## 三、未发现的问题（已核查）

- SQL 注入：所有数据操作均使用参数化查询；`rows()` 的表名走白名单校验。
- XSS：两个控制台的所有动态插值都经过 `esc()` HTML 转义。
- 路径穿越：静态资源由 `StaticFiles` 托管，未接受用户输入路径。
- 幂等性：成交按 `UNIQUE(source_id, ticket)` 去重，命令按 `command_id` 去重，重复投递不会重复下单。
- 净仓算法：20 万次随机状态转移压测，0 偏差（见"四、可用性验证"）。

---

## 四、可用性验证（2026-08-31 实测）

环境：Python 3.11.9 / FastAPI 0.136.1 / uvicorn 0.47.0，两个服务分别跑在 18196、18197 端口。

**39 项端到端测试全部通过**，覆盖：

| 类别 | 验证内容 |
|---|---|
| 鉴权 | 无令牌 401、错令牌 401、正确令牌 200、桥接接口拒绝管理员令牌、`/api/auth/meta` 不泄露令牌 |
| xauusd 链路 | 桥接注入成交 → 推断净仓 → 记录事件；重复 ticket 去重；反手拆成"平 1.0 + 开 0.5"两个事件，持仓由 LONG 1 正确翻为 SHORT 0.5 |
| forex 链路 | 注入成交 → 2 倍缩放（0.5 → 1.0 手）→ 命令入队 → 执行端拉取 → 标记已投递 → 回写 ack → 状态转 succeeded → 已成功命令不再重发 |
| 控制台 | 两个页面均正常返回并带上令牌头 |

**自带压测**（`tests/forex_mt5_copy_stress.py`）：
核心算法 200,000 次状态转移、463 次反手，**0 处不一致**；
端到端 5,000 笔成交生成 1,000 条命令，**0 处不一致**，误判率 0.0。

**C# 桥接安装器**：用 .NET Framework 4.0 `csc.exe` 实测编译通过（80,384 字节），
反查编译产物内嵌 URL 仅剩占位的 `http://127.0.0.1:18197`，生产域名已彻底清除。
修复后的构建脚本可直接运行，无需任何额外素材。

服务日志无告警、无异常。

### 未能验证的部分（需你自己在实盘/模拟盘上确认）

- **Gate.io TradFi 真实下单**：没有 API 凭据，且真实调用会产生实际交易，本次只验证了签名构造与本地链路。
- **MT5 直连轮询**：本机无 `MetaTrader5` 包与 MT5 终端，该分支代码未执行（默认关闭）。
- **EA 在 MT5 里的实际运行**：`.mq5` 未经 MetaEditor 重新编译验证，仓库内 `.ex5` 为你当初编译的产物。

### 现在怎么跑起来

```bash
# 1. 装依赖
pip install -r requirements.txt

# 2. 生成配置
cp .env.example .env
python -c "import secrets;print(secrets.token_urlsafe(32))"   # 分别填入 ADMIN / BRIDGE 令牌

# 3. 启动（xauusd 用 18196，forex 用 18197）
uvicorn app:app --host 127.0.0.1 --port 18197
```

浏览器打开 `http://127.0.0.1:18197`，首次访问会提示输入管理令牌，验证通过后存在浏览器本地。

> 对外提供服务时务必绑 `127.0.0.1` 并前置 HTTPS 反向代理，不要直接把端口暴露到公网（见 R-02、R-03）。
