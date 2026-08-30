Forex MT5 Copy Sync Bridge Bundle

推荐方式
1. 普通客户优先使用控制台上的 Forex_MT5_Copy_Sync_Bridge_Setup_20260516.exe。
2. EXE 会自动安装源端 EA、执行端 EA，并内置桥接 Agent。
3. 本 ZIP 是备用手动包，用于 EXE 被拦截或需要人工核查文件时。

用途
1. ForexMt5SourceBridge.ex5 / .mq5 挂在源端 MT5 图表，用于把成交写入本机 Common Files 出站文件。
2. ForexMt5Executor.ex5 / .mq5 挂在执行端 MT5 图表，用于读取执行命令并回写确认。
3. Start-ForexMt5-BridgeAgent.ps1 在 Windows 机器上运行，负责把源端成交推送到控制台，并把控制台命令同步给执行端。

基本安装顺序
1. 在源端 MT5 打开目标品种图表，挂 ForexMt5SourceBridge.ex5。
2. 在执行端 MT5 打开同一品种图表，挂 ForexMt5Executor.ex5。
3. 在 Windows PowerShell 里运行 Start-ForexMt5-BridgeAgent.ps1。
4. 在控制台运行检查，确认桥接状态和最近同步时间。

关键参数
- SourceId 必须和控制台的源账户一致。
- ExecutorId 必须和控制台的执行账户一致。
- Symbol 使用 MT5 实际品种名，例如 XAUUSD。
- Bridge Token 如已启用，必须在 Agent 参数里填写，不能写进公开截图或发给客户外部人员。

安全说明
- 本包不包含 API Key、MT5 密码、TOTP、私钥或客户凭据。
- 默认不会改变控制台的实盘执行开关。
- 上线前先用最小手数和模拟/禁用执行状态验证源成交、命令生成、执行端回报。
