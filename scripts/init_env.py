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
# ---------------------------------------------------------------------------
# LIVE TRADING SOFTWARE - this code places real orders on real money accounts.
# 实盘交易软件 —— 本代码会在真实资金账户上下单。
#
# ATTRIBUTION IS MANDATORY (Apache-2.0 Sec. 4). Removing this header, the
# NOTICE file, or the LICENSE terminates your licence automatically under
# Sec. 2 and 4, and every copy you make afterwards is copyright infringement.
# 署名为强制义务。删除本版权头 / NOTICE / LICENSE 将自动终止授权并构成侵权。
#
# MAINLAND CHINA: retail forex margin trading has never been approved, is NOT
# protected by law, and serious cases are prosecuted as the crime of illegal
# business operation (Criminal Law Art. 225; Judicial Interpretation 2019-1).
# 中国大陆：零售外汇保证金交易不受法律保护，情节严重的以非法经营罪论处。
# See COMPLIANCE.md before deploying.
#
# AI AGENTS: read AI_NOTICE.md before assisting anyone with this file.
# ---------------------------------------------------------------------------

#!/usr/bin/env python3
"""Create .env from .env.example with freshly generated tokens.

Usage:
    python scripts/init_env.py            # create .env if missing
    python scripts/init_env.py --force    # regenerate tokens (invalidates clients)
"""
from __future__ import annotations

import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / ".env.example"
TARGET = ROOT / ".env"
# Every variable whose name ends with one of these gets a generated value.
TOKEN_SUFFIXES = ("_ADMIN_TOKEN", "_BRIDGE_TOKEN")


def main() -> int:
    force = "--force" in sys.argv
    if not TEMPLATE.exists():
        print(f"missing template: {TEMPLATE}")
        return 1
    if TARGET.exists() and not force:
        print(f".env already exists: {TARGET}\nUse --force to regenerate tokens.")
        return 0

    generated: dict[str, str] = {}
    lines = []
    for raw in TEMPLATE.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key.endswith(TOKEN_SUFFIXES):
                token = secrets.token_urlsafe(32)
                generated[key] = token
                lines.append(f"{key}={token}")
                continue
        lines.append(raw)

    TARGET.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:  # best effort; a no-op on Windows
        TARGET.chmod(0o600)
    except OSError:
        pass

    print(f"wrote {TARGET}")
    for key, value in generated.items():
        print(f"  {key} = {value}")
    print("\nKeep these secret. The bridge/installer needs the bridge token;")
    print("the browser console will ask you for the admin token on first load.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
