#!/usr/bin/env bash
# Copyright 2026 duobaiawa
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# MT5 -> MT5 同平台跟单桥 - Linux / macOS 一键安装
#   bash install.sh              安装并启动
#   bash install.sh --no-start   只安装
#   bash install.sh --force      重新生成令牌
#   bash install.sh --systemd    额外安装为开机自启服务（需要 sudo）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

NO_START=0; FORCE=0; SYSTEMD=0
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    --force)    FORCE=1 ;;
    --systemd)  SYSTEMD=1 ;;
    -h|--help)  sed -n '17,22p' "$0"; exit 0 ;;
  esac
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; D='\033[0;90m'; N='\033[0m'
step() { echo; echo -e "${C}[$1/6] $2${N}"; }
ok()   { echo -e "      ${G}OK${N}  $1"; }
bad()  { echo -e "      ${R}!!${N}  $1"; }

echo
echo -e "${Y}  ==================================================${N}"
echo -e "${Y}   MT5 -> MT5 同平台跟单桥${N}"
echo -e "${Y}   Linux / macOS 一键安装${N}"
echo -e "${Y}  ==================================================${N}"
echo
echo -e "${R}  这套程序会在真实资金账户上自动下单。${N}"
echo -e "${R}  安装完成后交易开关默认关闭，请先用模拟账户验证。${N}"
echo -e "${R}  中国大陆用户请务必先读 COMPLIANCE.md。${N}"

# ---------------------------------------------------------------- 1. python
step 1 "检查 Python 运行环境"
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    ver="$("$candidate" -c 'import sys;print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    if [ -n "$ver" ] && [ "$(printf '%s\n3.11\n' "$ver" | sort -V | head -1)" = "3.11" ]; then
      PYTHON="$candidate"; ok "找到 Python $ver ($candidate)"; break
    fi
  fi
done
if [ -z "$PYTHON" ]; then
  bad "没有找到 Python 3.11 或更高版本（低版本会导致命令重发计时失效）。"
  echo -e "${Y}  Debian/Ubuntu:  sudo apt install python3.11 python3.11-venv${N}"
  echo -e "${Y}  RHEL/CentOS:    sudo dnf install python3.11${N}"
  echo -e "${Y}  macOS:          brew install python@3.11${N}"
  exit 1
fi

# ---------------------------------------------------------------- 2. venv
step 2 "创建独立运行环境 (.venv)"
if [ -x ".venv/bin/python" ]; then
  ok "运行环境已存在，跳过"
else
  "$PYTHON" -m venv .venv || { bad "创建失败；Debian/Ubuntu 需要先装 python3-venv"; exit 1; }
  ok "已创建 .venv"
fi
VENV_PY="$ROOT/.venv/bin/python"

# ---------------------------------------------------------------- 3. deps
step 3 "安装依赖包"
"$VENV_PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
if ! "$VENV_PY" -m pip install --quiet -r requirements.txt; then
  bad "依赖安装失败，尝试国内镜像重试..."
  "$VENV_PY" -m pip install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt \
    || { bad "仍然失败，请检查网络"; exit 1; }
fi
ok "依赖就绪"

# ---------------------------------------------------------------- 4. config
step 4 "生成配置与访问令牌"
if [ "$FORCE" = "1" ] && [ -f .env ]; then
  "$VENV_PY" scripts/init_env.py --force >/dev/null
  ok "令牌已重新生成（旧令牌立即失效）"
elif [ -f .env ]; then
  ok "配置已存在，保留现有令牌"
else
  "$VENV_PY" scripts/init_env.py >/dev/null
  ok "已生成 .env 和随机令牌"
fi
chmod 600 .env 2>/dev/null || true
mkdir -p data && chmod 700 data 2>/dev/null || true

get_env() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
ADMIN_TOKEN="$(get_env FOREX_MT5_ADMIN_TOKEN)"
BRIDGE_TOKEN="$(get_env FOREX_MT5_BRIDGE_TOKEN)"
PORT="$(get_env FOREX_MT5_COPY_PORT)"; PORT="${PORT:-18197}"

# ---------------------------------------------------------------- 5. self-test
step 5 "自检"
"$VENV_PY" -c "import fastapi, uvicorn, core" || { bad "自检失败"; exit 1; }
ok "模块加载正常"
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$PORT "; then
  bad "端口 $PORT 已被占用（可能服务已在运行）"
  PORT_BUSY=1
else
  ok "端口 $PORT 可用"
  PORT_BUSY=0
fi

# ---------------------------------------------------------------- 6. start
step 6 "启动服务"
if [ "$SYSTEMD" = "1" ]; then
  UNIT="deploy/mt5-to-mt5-copy-bridge.service"
  sudo cp "$UNIT" /etc/systemd/system/
  sudo sed -i "s#^WorkingDirectory=.*#WorkingDirectory=$ROOT#" /etc/systemd/system/mt5-to-mt5-copy-bridge.service
  sudo sed -i "s#^EnvironmentFile=.*#EnvironmentFile=$ROOT/.env#" /etc/systemd/system/mt5-to-mt5-copy-bridge.service
  sudo sed -i "s#^ExecStart=.*#ExecStart=$VENV_PY $ROOT/app.py#" /etc/systemd/system/mt5-to-mt5-copy-bridge.service
  sudo sed -i "s#^ReadWritePaths=.*#ReadWritePaths=$ROOT/data#" /etc/systemd/system/mt5-to-mt5-copy-bridge.service
  sudo sed -i "s#^User=.*#User=$(id -un)#; s#^Group=.*#Group=$(id -gn)#" /etc/systemd/system/mt5-to-mt5-copy-bridge.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now mt5-to-mt5-copy-bridge
  ok "已安装为开机自启服务：systemctl status mt5-to-mt5-copy-bridge"
elif [ "$NO_START" = "1" ]; then
  ok "已跳过启动 (--no-start)"
elif [ "$PORT_BUSY" = "1" ]; then
  ok "服务似乎已在运行，跳过启动"
else
  nohup "$VENV_PY" app.py > "$ROOT/service.log" 2>&1 &
  echo $! > "$ROOT/service.pid"
  for _ in $(seq 1 30); do
    sleep 0.7
    if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then READY=1; break; fi
  done
  if [ "${READY:-0}" = "1" ]; then ok "服务已就绪 (PID $(cat "$ROOT/service.pid"))"
  else bad "启动超时，请看 service.log"; fi
fi

echo
echo -e "${G}  ==================================================${N}"
echo -e "${G}   安装完成${N}"
echo -e "${G}  ==================================================${N}"
echo
echo "   控制台地址   http://127.0.0.1:$PORT"
echo
echo "   管理令牌（首次打开控制台时粘贴进去）:"
echo -e "${Y}   $ADMIN_TOKEN${N}"
echo
echo "   桥接令牌（装在 MT5 电脑上的桥接器要填这个）:"
echo -e "${Y}   $BRIDGE_TOKEN${N}"
echo
echo -e "${D}   两个令牌也保存在本目录的 .env 里，不要发给任何人。${N}"
echo
echo "   下一步："
echo -e "${D}     1. 打开控制台，把上面的管理令牌粘进去${N}"
echo -e "${D}     2. 填好参数，先用模拟账户验证整条链路${N}"
echo -e "${D}     3. 确认无误后再打开交易开关${N}"
echo
if [ "$SYSTEMD" = "1" ]; then
  echo -e "${D}   停止服务：sudo systemctl stop mt5-to-mt5-copy-bridge${N}"
else
  echo -e "${D}   停止服务：kill \$(cat service.pid)${N}"
  echo -e "${D}   重新启动：bash install.sh${N}"
fi
echo -e "${D}   对外提供服务前务必读 DEPLOYMENT.md 的反向代理章节。${N}"
echo
