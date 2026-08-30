# 部署指南 · 零凭据跟单桥

不懂技术看 **[QUICKSTART.md](QUICKSTART.md)**（傻瓜式图文）；
让 AI 代劳看 **[AGENT_DEPLOY.md](AGENT_DEPLOY.md)**。
下面是给运维的完整方式，共五种，按场景选。
**任何一种都不要把端口直接暴露到公网**——服务默认只监听 `127.0.0.1`，对外必须走 HTTPS 反向代理。

---

## 方式零：一键安装脚本（最省事，推荐个人使用）

Windows —— 右键 `install.ps1` → 使用 PowerShell 运行，或：
```powershell
.\install.ps1
```
Linux / macOS：
```bash
bash install.sh          # 加 --systemd 直接装成开机自启服务
```

脚本自动完成：检测 Python 3.11+ → 建独立 `.venv` → 装依赖（失败自动切国内镜像）→
生成随机令牌 → 自检端口 → 启动服务 → 打印控制台地址与令牌。装完即用。

> 换端口：`.\install.ps1 -Port 18200`（Windows）。重新生成令牌：加 `-Force` / `--force`。

---

## 方式一：手动本机跑（开发 / 试用）

```bash
pip install -r requirements.txt
python scripts/init_env.py        # 生成 .env 和两个随机令牌
python app.py                     # 读取 .env 并启动
```

打开 <http://127.0.0.1:18197>，首次访问会提示输入管理令牌（脚本已打印）。

想临时免登录调试：把 `.env` 里的 `FOREX_MT5_DISABLE_AUTH` 改成 `1`。**只能在本机这么做。**

---

## 方式二：systemd（Linux 生产环境，推荐）

```bash
# 1. 建用户和目录
sudo useradd --system --home /opt/mt5-to-mt5-copy-bridge_test --shell /usr/sbin/nologin mt5-to-mt5-copy-bridge
sudo mkdir -p /opt/mt5-to-mt5-copy-bridge_test
sudo cp -r . /opt/mt5-to-mt5-copy-bridge_test/

# 2. 建虚拟环境
sudo python3 -m venv /opt/mt5-to-mt5-copy-bridge_test/.venv
sudo /opt/mt5-to-mt5-copy-bridge_test/.venv/bin/pip install -r /opt/mt5-to-mt5-copy-bridge_test/requirements.txt

# 3. 生成配置并锁权限
cd /opt/mt5-to-mt5-copy-bridge_test && sudo .venv/bin/python scripts/init_env.py
sudo chown -R mt5-to-mt5-copy-bridge:mt5-to-mt5-copy-bridge /opt/mt5-to-mt5-copy-bridge_test
sudo chmod 600 /opt/mt5-to-mt5-copy-bridge_test/.env
sudo chmod 700 /opt/mt5-to-mt5-copy-bridge_test/data

# 4. 装服务
sudo cp deploy/mt5-to-mt5-copy-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mt5-to-mt5-copy-bridge
sudo systemctl status mt5-to-mt5-copy-bridge
```

服务单元已启用 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`，
只有 `data/` 目录可写。

---

## 方式三：Docker

```bash
python scripts/init_env.py        # 先生成 .env，compose 会读它
docker compose up -d
docker compose logs -f
```

容器内监听 `0.0.0.0:18197`，但 compose 只把端口发布到宿主机的 `127.0.0.1`，
外部访问同样要经过反向代理。数据落在宿主机 `./data`。

---

## 方式四：Windows

```powershell
pip install -r requirements.txt
python scripts\init_env.py
python app.py
```

要做成开机自启的服务，用 NSSM 或计划任务包一层：

```powershell
nssm install mt5-to-mt5-copy-bridge "C:\Python311\python.exe" "C:\path	o\mt5-to-mt5-copy-bridgepp.py"
nssm set mt5-to-mt5-copy-bridge AppDirectory "C:\path	o\mt5-to-mt5-copy-bridge"
nssm start mt5-to-mt5-copy-bridge
```

---

## 对外暴露：HTTPS 反向代理

`deploy/nginx.conf.example` 是可直接改用的模板，已包含：

- 80 → 443 强制跳转、TLS 1.2/1.3
- HSTS、`X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy`
- **每 IP 10 req/s 的限流**（对应审计 R-02，防令牌爆破）

```bash
sudo cp deploy/nginx.conf.example /etc/nginx/sites-available/mt5-to-mt5-copy-bridge
sudo ln -s /etc/nginx/sites-available/mt5-to-mt5-copy-bridge /etc/nginx/sites-enabled/
sudo certbot --nginx -d copy.example.com
sudo nginx -t && sudo systemctl reload nginx
```

---

## 升级

```bash
sudo systemctl stop mt5-to-mt5-copy-bridge
sudo cp -r <新版本>/* /opt/mt5-to-mt5-copy-bridge_test/          # .env 和 data/ 不要覆盖
sudo -u mt5-to-mt5-copy-bridge /opt/mt5-to-mt5-copy-bridge_test/.venv/bin/pip install -r /opt/mt5-to-mt5-copy-bridge_test/requirements.txt
sudo systemctl start mt5-to-mt5-copy-bridge
```

数据库建表用的是 `CREATE TABLE IF NOT EXISTS`，升级不会丢数据。

## 备份

要备份的只有两样：`.env`（令牌）和 `data/state.db`（全部状态）。

```bash
sudo systemctl stop mt5-to-mt5-copy-bridge
sudo tar czf backup-$(date +%Y%m%d).tar.gz -C /opt/mt5-to-mt5-copy-bridge_test .env data/
sudo systemctl start mt5-to-mt5-copy-bridge
```

热备份用 SQLite 自带的一致性备份，不必停服务：

```bash
sqlite3 /opt/mt5-to-mt5-copy-bridge_test/data/state.db ".backup '/tmp/state-backup.db'"
```

---

## 上线前检查表

- [ ] `FOREX_MT5_DISABLE_AUTH` 是 `0`
- [ ] 两个令牌都是随机生成的，不是模板里的占位符
- [ ] `.env` 权限 600，`data/` 权限 700
- [ ] 服务监听 `127.0.0.1`，公网入口在反向代理上
- [ ] TLS 证书有效，HTTP 已跳转 HTTPS
- [ ] `trading_enabled` 先保持 `false`，用模拟盘验证链路后再打开
- [ ] 桥接器里的 `ApiUrl` 已改成你的正式地址，不是占位的 127.0.0.1
- [ ] 备份任务已配置
