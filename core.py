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

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_DOWN
from typing import Dict, Iterable, List, Mapping, Tuple


def dec(value: object, default: str = "0") -> Decimal:
    try:
        if value is None:
            return Decimal(default)
        text = str(value).strip()
        if not text:
            return Decimal(default)
        return Decimal(text)
    except (InvalidOperation, ValueError):
        return Decimal(default)


def dec_text(value: Decimal) -> str:
    normalized = value.normalize()
    text = format(normalized, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def lot_floor(value: Decimal, step: Decimal) -> Decimal:
    if value <= 0 or step <= 0:
        return Decimal("0")
    return (value / step).to_integral_value(rounding=ROUND_DOWN) * step


def normalize_symbol(symbol: str) -> str:
    return (symbol or "").strip().upper()


def symbol_matches(observed: str, expected: str) -> bool:
    observed_key = normalize_symbol(observed)
    expected_key = normalize_symbol(expected)
    if not observed_key or not expected_key:
        return False
    return observed_key == expected_key or observed_key.startswith(expected_key)


def normalize_side(side: str) -> str:
    value = (side or "").strip().upper()
    if value in {"0", "BUY", "B", "LONG"}:
        return "BUY"
    if value in {"1", "SELL", "S", "SHORT"}:
        return "SELL"
    return value


@dataclass(frozen=True)
class InferredEvent:
    action: str
    position_side: str
    side: str
    volume: Decimal
    before: Decimal
    after: Decimal
    sequence: str

    @property
    def reduce_only(self) -> bool:
        return self.action.startswith("close_")

    def as_dict(self) -> Dict[str, str | bool]:
        return {
            "action": self.action,
            "position_side": self.position_side,
            "side": self.side,
            "volume": dec_text(self.volume),
            "before": dec_text(self.before),
            "after": dec_text(self.after),
            "sequence": self.sequence,
            "reduce_only": self.reduce_only,
        }


def infer_netting_events(
    positions: Mapping[Tuple[str, str], Decimal],
    symbol: str,
    side: str,
    volume: Decimal,
) -> List[InferredEvent]:
    symbol_key = normalize_symbol(symbol)
    side_key = normalize_side(side)
    qty = dec(volume)
    if not symbol_key or qty <= 0:
        return []

    if side_key == "BUY":
        close_side = "SHORT"
        open_side = "LONG"
        close_action = "close_short"
        open_action = "open_long"
    elif side_key == "SELL":
        close_side = "LONG"
        open_side = "SHORT"
        close_action = "close_long"
        open_action = "open_short"
    else:
        return []

    current = {key: dec(value) for key, value in positions.items()}
    close_key = (symbol_key, close_side)
    open_key = (symbol_key, open_side)
    close_before = current.get(close_key, Decimal("0"))
    remaining = qty
    events: List[InferredEvent] = []

    if close_before > 0:
        close_qty = min(close_before, remaining)
        close_after = max(close_before - close_qty, Decimal("0"))
        events.append(
            InferredEvent(
                action=close_action,
                position_side=close_side,
                side=side_key,
                volume=close_qty,
                before=close_before,
                after=close_after,
                sequence="reduce",
            )
        )
        remaining -= close_qty

    if remaining > 0:
        open_before = current.get(open_key, Decimal("0"))
        open_after = open_before + remaining
        events.append(
            InferredEvent(
                action=open_action,
                position_side=open_side,
                side=side_key,
                volume=remaining,
                before=open_before,
                after=open_after,
                sequence="increase" if not events else "increase_after_flip",
            )
        )

    return events


def apply_inferred_events(
    positions: Dict[Tuple[str, str], Decimal],
    symbol: str,
    events: Iterable[InferredEvent],
) -> Dict[Tuple[str, str], Decimal]:
    symbol_key = normalize_symbol(symbol)
    for event in events:
        positions[(symbol_key, event.position_side)] = max(dec(event.after), Decimal("0"))
    return positions
