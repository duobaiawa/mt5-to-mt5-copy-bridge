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

from __future__ import annotations

import importlib
import random
import os
import tempfile
from decimal import Decimal
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from core import apply_inferred_events, dec_text, infer_netting_events  # noqa: E402


def snapshot(positions):
    return {k: v for k, v in positions.items() if v > 0}


def model_transition(model, side, volume):
    symbol = "XAUUSD"
    out = dict(model)
    if side == "BUY":
        close_key = (symbol, "SHORT")
        open_key = (symbol, "LONG")
    else:
        close_key = (symbol, "LONG")
        open_key = (symbol, "SHORT")
    close_before = out.get(close_key, Decimal("0"))
    close_qty = min(close_before, volume)
    if close_qty > 0:
        out[close_key] = max(close_before - close_qty, Decimal("0"))
    remainder = volume - close_qty
    if remainder > 0:
        out[open_key] = out.get(open_key, Decimal("0")) + remainder
    return snapshot(out)


def main() -> int:
    rng = random.Random(20260516)
    with tempfile.TemporaryDirectory() as td:
        db = Path(td) / "state.db"
        os.environ["FOREX_MT5_COPY_DB"] = str(db)
        mod = importlib.import_module("app")
        store = mod.store
        engine = mod.engine
        store.update_settings(
            {
                "source_id": "master",
                "executor_id": "executor",
                "source_symbol": "XAUUSD",
                "executor_symbol": "XAUUSD",
                "trading_enabled": True,
                "multiplier": "0.37",
                "lot_step": "0.01",
                "min_lot": "0.01",
            }
        )
        core_positions = {}
        core_model = {}
        core_mismatches = 0
        core_flips = 0
        core_total = 200000
        for i in range(core_total):
            side = "BUY" if rng.random() < 0.5 else "SELL"
            volume = Decimal(rng.randint(1, 1000)) / Decimal("100")
            expected = model_transition(core_model, side, volume)
            events = infer_netting_events(core_positions, "XAUUSD", side, volume)
            if len(events) == 2:
                core_flips += 1
            apply_inferred_events(core_positions, "XAUUSD", events)
            core_model = expected
            if snapshot(core_positions) != expected:
                core_mismatches += 1
                print("core mismatch", i, side, dec_text(volume), events, snapshot(core_positions), expected)
                return 1

        positions = {}
        model = {}
        mismatches = 0
        flips = 0
        duplicates = 0
        total = 5000

        seed_deal = {
            "ticket": "seed",
            "symbol": "XAUUSD",
            "side": "BUY",
            "volume": "0.01",
            "time_msc": 1,
        }
        engine.ingest_deal("master", seed_deal, bridge=True)
        engine.ingest_deal("master", seed_deal, bridge=True)
        if len(store.rows("source_deals", 10)) != 1:
            print("duplicate dedupe failed")
            return 1
        duplicates += 1
        seed_events = infer_netting_events(positions, "XAUUSD", "BUY", Decimal("0.01"))
        apply_inferred_events(positions, "XAUUSD", seed_events)
        model = model_transition(model, "BUY", Decimal("0.01"))

        fixed = [
            ("BUY", Decimal("1.00")),
            ("BUY", Decimal("0.50")),
            ("SELL", Decimal("0.40")),
            ("SELL", Decimal("2.00")),
            ("BUY", Decimal("0.35")),
            ("SELL", Decimal("0.10")),
        ]
        for i, (side, volume) in enumerate(fixed):
            expected = model_transition(model, side, volume)
            events = infer_netting_events(positions, "XAUUSD", side, volume)
            apply_inferred_events(positions, "XAUUSD", events)
            model = expected
            engine.ingest_deal(
                "master",
                {"ticket": f"fixed{i}", "symbol": "XAUUSD", "side": side, "volume": dec_text(volume), "time_msc": i + 2},
                bridge=True,
            )
            db_positions = snapshot(store.leader_positions())
            if db_positions != expected:
                print("fixed DB mismatch", i, side, dec_text(volume), db_positions, expected)
                return 1

        for i in range(total):
            side = "BUY" if rng.random() < 0.5 else "SELL"
            volume = Decimal(rng.randint(1, 1000)) / Decimal("100")
            expected = model_transition(model, side, volume)
            events = infer_netting_events(positions, "XAUUSD", side, volume)
            if len(events) == 2:
                flips += 1
            apply_inferred_events(positions, "XAUUSD", events)
            model = expected
            ticket = f"t{i}"
            result = engine.ingest_deal(
                "master",
                {"ticket": ticket, "symbol": "XAUUSD", "side": side, "volume": dec_text(volume), "time_msc": i + 100},
                bridge=True,
            )
            db_positions = snapshot(store.leader_positions())
            if snapshot(positions) != expected or db_positions != expected:
                mismatches += 1
                print("mismatch", i, side, dec_text(volume), events, snapshot(positions), db_positions, expected, result)
                break

        commands = store.rows("execution_commands", 1000)
        if not commands:
            print("no commands generated")
            return 1
        pending = store.pending_commands("executor", 10)
        pending_ids = [item["command_id"] for item in pending]
        delivered = store.mark_delivered("executor", pending_ids)
        if delivered != len(pending_ids):
            print("delivery mark mismatch", delivered, len(pending_ids))
            return 1
        first_ack = store.record_ack("executor", {"command_id": pending_ids[0], "status": "succeeded", "message": "stress ok"})
        second_ack = store.record_ack("executor", {"command_id": pending_ids[0], "status": "failed", "message": "late duplicate"})
        if not first_ack.get("ok") or not second_ack.get("ignored"):
            print("ack idempotency failed", first_ack, second_ack)
            return 1
        print(
            {
                "core_total": core_total,
                "core_flips": core_flips,
                "core_mismatches": core_mismatches,
                "total": total,
                "flips": flips,
                "duplicates": duplicates,
                "commands": len(commands),
                "delivered_checked": delivered,
                "mismatches": mismatches,
                "misclassification_rate": mismatches / total,
            }
        )
        store.close()
        return 1 if mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
