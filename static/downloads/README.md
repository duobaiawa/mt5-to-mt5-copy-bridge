# 桥接器分发文件

本目录存放**已审核、无生产域名**的桥接器可再分发文件，控制台的「下载桥接器」按钮从这里取：

| 文件 | 说明 |
|---|---|
| `Forex_MT5_Copy_Sync_Bridge_Setup.exe` | Windows 一键安装器：释放并编译两个 EA、内置桥接 Agent |
| `forex-mt5-bridge-bundle.zip` | 手动安装包：两个 EA（源码 + 编译产物）、桥接 Agent、说明 |

这两个文件同时发布在 **GitHub Releases** 上，并附 SHA256 校验和。

## 自己重新编译

不信任预编译产物？用 .NET Framework 自行编译（产物应与 Release 一致）：

```powershell
.ridge\Build-ForexMt5-BridgeSetup.ps1
```

> 编译前可修改 `bridge/ForexMt5BridgeSetup.cs` 里的 `DefaultApiUrl` 为你自己的服务地址；
> 默认是占位的 `http://127.0.0.1:18197`。
