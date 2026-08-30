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

import hashlib
import hmac
import json
import os
import sqlite3
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from core import (
    apply_inferred_events,
    dec,
    dec_text,
    infer_netting_events,
    lot_floor,
    normalize_side,
    normalize_symbol,
    symbol_matches,
)


ROOT_DIR = Path(os.getenv("FOREX_MT5_COPY_DIR") or Path(__file__).resolve().parent)


def load_env_file(path: Path) -> None:
    """Load KEY=VALUE lines from a .env file. Real environment variables always win.

    Keeps deployment to a single step (`python app.py`) without adding a dependency.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file(ROOT_DIR / ".env")


def env_str(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    return default if value is None else value.strip()


def env_int(name: str, default: int, minimum: int = 0) -> int:
    try:
        return max(minimum, int(str(os.environ.get(name, "")).strip() or default))
    except (TypeError, ValueError):
        return default


def env_bool(name: str, default: bool = False) -> bool:
    value = env_str(name).lower()
    if not value:
        return default
    return value in {"1", "true", "yes", "on"}


# --- paths -----------------------------------------------------------------
DATA_DIR = Path(env_str("FOREX_MT5_COPY_DATA_DIR") or (ROOT_DIR / "data"))
STATIC_DIR = ROOT_DIR / "static"
DB_PATH = Path(env_str("FOREX_MT5_COPY_DB") or (DATA_DIR / "state.db"))

# --- authentication --------------------------------------------------------
BRIDGE_TOKEN = env_str("FOREX_MT5_BRIDGE_TOKEN")
ADMIN_TOKEN = env_str("FOREX_MT5_ADMIN_TOKEN")
# Auth is ON unless explicitly disabled for local development.
AUTH_DISABLED = env_bool("FOREX_MT5_DISABLE_AUTH", False)

# --- trading ---------------------------------------------------------------
DEFAULT_SYMBOL = env_str("FOREX_MT5_COPY_SYMBOL", "XAUUSD") or "XAUUSD"
# Prefix of the client_ref the executor EA writes into the order comment.
CLIENT_REF_PREFIX = env_str("FOREX_MT5_CLIENT_REF_PREFIX", "fxmt5") or "fxmt5"

# --- server ----------------------------------------------------------------
HOST = env_str("FOREX_MT5_COPY_HOST", "127.0.0.1") or "127.0.0.1"
PORT = env_int("FOREX_MT5_COPY_PORT", 18197, minimum=1)
LOG_LEVEL = env_str("FOREX_MT5_COPY_LOG_LEVEL", "info") or "info"
API_MAX_LIMIT = env_int("FOREX_MT5_API_MAX_LIMIT", 500, minimum=1)

DATA_DIR.mkdir(parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def sha1_text(value: str) -> str:
    return hashlib.sha1(value.encode("utf-8")).hexdigest()


def boolish(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on", "enabled"}


class Store:
    def __init__(self, path: Path):
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.init_db()

    def init_db(self) -> None:
        with self.lock, self.conn:
            self.conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS source_deals (
                    deal_id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    ticket TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    side TEXT NOT NULL,
                    volume TEXT NOT NULL,
                    price TEXT,
                    time_msc INTEGER NOT NULL,
                    raw_json TEXT,
                    created_at TEXT NOT NULL,
                    UNIQUE(source_id, ticket)
                );

                CREATE TABLE IF NOT EXISTS leader_positions (
                    symbol TEXT NOT NULL,
                    position_side TEXT NOT NULL,
                    volume TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(symbol, position_side)
                );

                CREATE TABLE IF NOT EXISTS copy_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT UNIQUE NOT NULL,
                    deal_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    position_side TEXT NOT NULL,
                    side TEXT NOT NULL,
                    source_volume TEXT NOT NULL,
                    copy_volume TEXT NOT NULL,
                    reduce_only INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    command_id TEXT,
                    raw_json TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS execution_commands (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    command_id TEXT UNIQUE NOT NULL,
                    event_id TEXT NOT NULL,
                    executor_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    side TEXT NOT NULL,
                    position_side TEXT NOT NULL,
                    volume TEXT NOT NULL,
                    client_ref TEXT NOT NULL,
                    status TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    delivered_at TEXT,
                    ack_json TEXT,
                    last_error TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts TEXT NOT NULL,
                    level TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    message TEXT,
                    source_id TEXT,
                    executor_id TEXT,
                    command_id TEXT,
                    symbol TEXT,
                    side TEXT,
                    position_side TEXT,
                    size TEXT,
                    raw_json TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_source_deals_created ON source_deals(created_at);
                CREATE INDEX IF NOT EXISTS idx_copy_events_created ON copy_events(created_at);
                CREATE INDEX IF NOT EXISTS idx_execution_commands_status ON execution_commands(status, updated_at);
                CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
                """
            )
            defaults = {
                "source_id": "master",
                "source_label": "MT5观摩源",
                "executor_id": "executor",
                "source_symbol": DEFAULT_SYMBOL,
                "executor_symbol": DEFAULT_SYMBOL,
                "multiplier": "1",
                "lot_step": "0.01",
                "min_lot": "0.01",
                "trading_enabled": "false",
                "max_slippage_points": "30",
                "resend_after_seconds": "30",
                "max_command_attempts": "20",
            }
            for key, value in defaults.items():
                self.conn.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)", (key, value))

    def close(self) -> None:
        with self.lock:
            self.conn.close()

    def settings(self) -> Dict[str, str]:
        with self.lock:
            rows = self.conn.execute("SELECT key,value FROM settings ORDER BY key").fetchall()
        return {str(row["key"]): str(row["value"]) for row in rows}

    def update_settings(self, payload: Dict[str, Any]) -> Dict[str, str]:
        allowed = {
            "source_id",
            "source_label",
            "executor_id",
            "source_symbol",
            "executor_symbol",
            "multiplier",
            "lot_step",
            "min_lot",
            "trading_enabled",
            "max_slippage_points",
            "resend_after_seconds",
            "max_command_attempts",
        }
        with self.lock, self.conn:
            for key in allowed:
                if key in payload:
                    value = str(payload.get(key) if payload.get(key) is not None else "").strip()
                    if key in {"source_symbol", "executor_symbol"}:
                        value = normalize_symbol(value or DEFAULT_SYMBOL)
                    if key in {"source_id", "executor_id"}:
                        value = value or ("master" if key == "source_id" else "executor")
                    if key == "trading_enabled":
                        value = "true" if boolish(payload.get(key)) else "false"
                    self.conn.execute(
                        "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (key, value),
                    )
        return self.settings()

    def event(
        self,
        level: str,
        event_type: str,
        message: str = "",
        *,
        raw: Any = None,
        source_id: str = "",
        executor_id: str = "",
        command_id: str = "",
        symbol: str = "",
        side: str = "",
        position_side: str = "",
        size: str = "",
    ) -> None:
        with self.lock, self.conn:
            self.conn.execute(
                """
                INSERT INTO events(ts,level,event_type,message,source_id,executor_id,command_id,symbol,side,position_side,size,raw_json)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    now_iso(),
                    level,
                    event_type,
                    message,
                    source_id,
                    executor_id,
                    command_id,
                    symbol,
                    side,
                    position_side,
                    size,
                    json_dumps(raw or {}),
                ),
            )

    def record_deal(self, source_id: str, payload: Dict[str, Any]) -> Optional[str]:
        ticket = str(payload.get("ticket") or payload.get("deal") or payload.get("order") or "").strip()
        if not ticket:
            ticket = sha1_text(json_dumps(payload))
        symbol = normalize_symbol(str(payload.get("symbol") or DEFAULT_SYMBOL))
        side = normalize_side(str(payload.get("side") or payload.get("type") or ""))
        volume = dec(payload.get("volume") or payload.get("lots") or payload.get("qty"), "0")
        price = str(payload.get("price") or "")
        time_msc = int(dec(payload.get("time_msc") or payload.get("time") or int(time.time() * 1000), "0"))
        deal_id = sha1_text(f"{source_id}|{ticket}")
        try:
            with self.lock, self.conn:
                self.conn.execute(
                    """
                    INSERT INTO source_deals(deal_id,source_id,ticket,symbol,side,volume,price,time_msc,raw_json,created_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """,
                    (deal_id, source_id, ticket, symbol, side, dec_text(volume), price, time_msc, json_dumps(payload), now_iso()),
                )
            return deal_id
        except sqlite3.IntegrityError:
            return None

    def leader_positions(self) -> Dict[Tuple[str, str], Decimal]:
        with self.lock:
            rows = self.conn.execute("SELECT symbol,position_side,volume FROM leader_positions").fetchall()
        return {(str(row["symbol"]), str(row["position_side"])): dec(row["volume"]) for row in rows}

    def set_leader_position(self, symbol: str, position_side: str, volume: Decimal) -> None:
        with self.lock, self.conn:
            self.conn.execute(
                """
                INSERT INTO leader_positions(symbol,position_side,volume,updated_at)
                VALUES(?,?,?,?)
                ON CONFLICT(symbol,position_side) DO UPDATE SET volume=excluded.volume, updated_at=excluded.updated_at
                """,
                (normalize_symbol(symbol), position_side, dec_text(max(volume, Decimal("0"))), now_iso()),
            )

    def position_rows(self) -> List[Dict[str, Any]]:
        with self.lock:
            rows = self.conn.execute(
                "SELECT * FROM leader_positions WHERE CAST(volume AS REAL)>0 ORDER BY symbol,position_side"
            ).fetchall()
        return [dict(row) for row in rows]

    def record_copy_event(self, event: Dict[str, Any]) -> bool:
        now = now_iso()
        try:
            with self.lock, self.conn:
                self.conn.execute(
                    """
                    INSERT INTO copy_events(
                        event_id,deal_id,action,symbol,position_side,side,source_volume,copy_volume,
                        reduce_only,status,command_id,raw_json,created_at,updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        event["event_id"],
                        event["deal_id"],
                        event["action"],
                        event["symbol"],
                        event["position_side"],
                        event["side"],
                        event["source_volume"],
                        event["copy_volume"],
                        1 if event.get("reduce_only") else 0,
                        event["status"],
                        event.get("command_id") or "",
                        json_dumps(event),
                        now,
                        now,
                    ),
                )
            return True
        except sqlite3.IntegrityError:
            return False

    def update_copy_event(self, event_id: str, status: str, command_id: str = "") -> None:
        with self.lock, self.conn:
            self.conn.execute(
                "UPDATE copy_events SET status=?, command_id=COALESCE(NULLIF(?,''),command_id), updated_at=? WHERE event_id=?",
                (status, command_id, now_iso(), event_id),
            )

    def create_command(self, command: Dict[str, Any]) -> bool:
        now = now_iso()
        try:
            with self.lock, self.conn:
                self.conn.execute(
                    """
                    INSERT INTO execution_commands(
                        command_id,event_id,executor_id,action,symbol,side,position_side,volume,
                        client_ref,status,created_at,updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        command["command_id"],
                        command["event_id"],
                        command["executor_id"],
                        command["action"],
                        command["symbol"],
                        command["side"],
                        command["position_side"],
                        command["volume"],
                        command["client_ref"],
                        command["status"],
                        now,
                        now,
                    ),
                )
            self.update_copy_event(command["event_id"], command["status"], command["command_id"])
            return True
        except sqlite3.IntegrityError:
            return False

    def pending_commands(self, executor_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        settings = self.settings()
        resend_after = max(0, int(dec(settings.get("resend_after_seconds"), "30")))
        max_attempts = max(1, int(dec(settings.get("max_command_attempts"), "20")))
        now_ts = time.time()
        out: List[Dict[str, Any]] = []
        with self.lock:
            rows = self.conn.execute(
                """
                SELECT * FROM execution_commands
                WHERE executor_id=? AND status IN ('pending','delivered')
                AND attempt_count < ?
                ORDER BY id
                LIMIT ?
                """,
                (executor_id, max_attempts, limit * 4),
            ).fetchall()
        for row in rows:
            item = dict(row)
            if item["status"] == "delivered" and item.get("delivered_at"):
                try:
                    delivered = datetime.fromisoformat(str(item["delivered_at"])).timestamp()
                except ValueError:
                    delivered = 0
                if now_ts - delivered < resend_after:
                    continue
            out.append(item)
            if len(out) >= limit:
                break
        return out

    def mark_delivered(self, executor_id: str, command_ids: List[str]) -> int:
        if not command_ids:
            return 0
        now = now_iso()
        count = 0
        with self.lock, self.conn:
            for command_id in command_ids:
                cur = self.conn.execute(
                    """
                    UPDATE execution_commands
                    SET status='delivered', delivered_at=?, attempt_count=attempt_count+1, updated_at=?
                    WHERE command_id=? AND executor_id=? AND status IN ('pending','delivered')
                    """,
                    (now, now, command_id, executor_id),
                )
                count += cur.rowcount
                self.conn.execute(
                    "UPDATE copy_events SET status='delivered', updated_at=? WHERE command_id=? AND status IN ('pending','delivered')",
                    (now, command_id),
                )
        return count

    def record_ack(self, executor_id: str, ack: Dict[str, Any]) -> Dict[str, Any]:
        command_id = str(ack.get("command_id") or "").strip()
        if not command_id:
            return {"ok": False, "reason": "missing_command_id"}
        status_in = str(ack.get("status") or "").strip().lower()
        succeeded = status_in in {"ok", "success", "succeeded", "done", "filled"}
        status = "succeeded" if succeeded else "failed"
        now = now_iso()
        with self.lock, self.conn:
            row = self.conn.execute(
                "SELECT * FROM execution_commands WHERE command_id=? AND executor_id=?",
                (command_id, executor_id),
            ).fetchone()
            if not row:
                self.event("warn", "ack_unknown_command", "ack for unknown command", raw=ack, executor_id=executor_id, command_id=command_id)
                return {"ok": False, "reason": "unknown_command"}
            current = dict(row)
            if current["status"] == "succeeded" and status != "succeeded":
                return {"ok": True, "ignored": True, "reason": "already_succeeded"}
            self.conn.execute(
                """
                UPDATE execution_commands
                SET status=?, ack_json=?, last_error=?, updated_at=?
                WHERE command_id=? AND executor_id=?
                """,
                (
                    status,
                    json_dumps(ack),
                    "" if succeeded else str(ack.get("message") or ack.get("error") or ""),
                    now,
                    command_id,
                    executor_id,
                ),
            )
            self.conn.execute(
                "UPDATE copy_events SET status=?, updated_at=? WHERE command_id=?",
                (status, now, command_id),
            )
        self.event(
            "info" if succeeded else "error",
            "executor_ack",
            str(ack.get("message") or status),
            raw=ack,
            executor_id=executor_id,
            command_id=command_id,
            symbol=str(current["symbol"]),
            side=str(current["side"]),
            position_side=str(current["position_side"]),
            size=str(current["volume"]),
        )
        return {"ok": True, "status": status}

    def rows(self, table: str, limit: int = 100) -> List[Dict[str, Any]]:
        allowed = {
            "source_deals": "created_at",
            "copy_events": "created_at",
            "execution_commands": "id",
            "events": "id",
        }
        if table not in allowed:
            raise ValueError(table)
        order = allowed[table]
        with self.lock:
            rows = self.conn.execute(f"SELECT * FROM {table} ORDER BY {order} DESC LIMIT ?", (limit,)).fetchall()
        return [dict(row) for row in rows]


class Engine:
    def __init__(self, store: Store):
        self.store = store

    def ingest_many(self, source_id: str, rows: List[Dict[str, Any]], bridge: bool = True) -> Dict[str, Any]:
        result = {"received": len(rows), "accepted": 0, "duplicates": 0, "skipped": 0, "events": 0, "commands": 0}
        for row in rows:
            one = self.ingest_deal(source_id, row, bridge=bridge)
            if one.get("duplicate"):
                result["duplicates"] += 1
            elif one.get("skipped"):
                result["skipped"] += 1
            else:
                result["accepted"] += 1
            result["events"] += int(one.get("events", 0))
            result["commands"] += int(one.get("commands", 0))
        return result

    def ingest_deal(self, source_id: str, payload: Dict[str, Any], bridge: bool = True) -> Dict[str, Any]:
        settings = self.store.settings()
        expected_source_id = str(settings.get("source_id") or "master").strip()
        source_key = str(source_id or "").strip()
        is_test = source_key.lower().startswith(("sim", "manual", "test"))
        if bridge and source_key != expected_source_id and not is_test:
            self.store.event(
                "warn",
                "source_skipped",
                "source_id does not match configured single source",
                raw={"source_id": source_key, "expected": expected_source_id, "deal": payload},
                source_id=source_key,
            )
            return {"ok": True, "skipped": 1, "reason": "source_mismatch"}

        source_symbol = normalize_symbol(settings.get("source_symbol") or DEFAULT_SYMBOL)
        raw_symbol = normalize_symbol(str(payload.get("symbol") or source_symbol))
        if not symbol_matches(raw_symbol, source_symbol):
            self.store.event(
                "warn",
                "symbol_skipped",
                "deal symbol does not match configured symbol",
                raw={"symbol": raw_symbol, "expected": source_symbol, "deal": payload},
                source_id=source_key,
                symbol=raw_symbol,
            )
            return {"ok": True, "skipped": 1, "reason": "symbol_mismatch"}

        side = normalize_side(str(payload.get("side") or payload.get("type") or ""))
        volume = dec(payload.get("volume") or payload.get("lots") or payload.get("qty"), "0")
        if side not in {"BUY", "SELL"} or volume <= 0:
            self.store.event("warn", "deal_invalid", "invalid MT5 deal side or volume", raw=payload, source_id=source_key, symbol=raw_symbol)
            return {"ok": False, "skipped": 1, "reason": "invalid_deal"}

        deal_id = self.store.record_deal(source_key, payload)
        if deal_id is None:
            return {"ok": True, "duplicate": True}

        positions = self.store.leader_positions()
        inferred = infer_netting_events(positions, source_symbol, side, volume)
        apply_inferred_events(positions, source_symbol, inferred)
        for (pos_symbol, pos_side), pos_volume in positions.items():
            if pos_symbol == source_symbol:
                self.store.set_leader_position(pos_symbol, pos_side, pos_volume)

        multiplier = dec(settings.get("multiplier"), "1")
        lot_step = dec(settings.get("lot_step"), "0.01")
        min_lot = dec(settings.get("min_lot"), "0.01")
        executor_symbol = normalize_symbol(settings.get("executor_symbol") or source_symbol)
        executor_id = str(settings.get("executor_id") or "executor").strip()
        trading_enabled = settings.get("trading_enabled", "false").lower() == "true"
        summary = {"ok": True, "events": 0, "commands": 0, "deal_id": deal_id}

        for item in inferred:
            copy_volume = lot_floor(item.volume * multiplier, lot_step)
            event_id = sha1_text(f"{source_key}|{deal_id}|{item.sequence}|{item.action}|{item.volume}|{item.before}|{item.after}")
            event_payload = {
                "event_id": event_id,
                "deal_id": deal_id,
                "source_id": source_key,
                "action": item.action,
                "symbol": executor_symbol,
                "position_side": item.position_side,
                "side": item.side,
                "source_volume": dec_text(item.volume),
                "copy_volume": dec_text(copy_volume),
                "multiplier": dec_text(multiplier),
                "reduce_only": item.reduce_only,
                "leader_position": item.as_dict(),
                "raw_deal": payload,
                "status": "pending",
            }
            summary["events"] += 1
            if copy_volume < min_lot:
                event_payload["status"] = "skipped"
                self.store.record_copy_event(event_payload)
                self.store.event(
                    "warn",
                    "copy_skipped",
                    "copy volume below minimum lot",
                    raw={"copy_volume": dec_text(copy_volume), "min_lot": dec_text(min_lot), "event": event_payload},
                    source_id=source_key,
                    symbol=executor_symbol,
                    side=item.side,
                    position_side=item.position_side,
                    size=dec_text(copy_volume),
                )
                continue
            if not trading_enabled:
                event_payload["status"] = "planned"
                self.store.record_copy_event(event_payload)
                self.store.event(
                    "info",
                    "trade_planned",
                    "trading disabled; command not queued",
                    raw=event_payload,
                    source_id=source_key,
                    executor_id=executor_id,
                    symbol=executor_symbol,
                    side=item.side,
                    position_side=item.position_side,
                    size=dec_text(copy_volume),
                )
                continue

            command_id = sha1_text(f"cmd|{event_id}|{executor_id}")
            event_payload["command_id"] = command_id
            if not self.store.record_copy_event(event_payload):
                continue
            command = {
                "command_id": command_id,
                "event_id": event_id,
                "executor_id": executor_id,
                "action": item.action,
                "symbol": executor_symbol,
                "side": "SELL" if item.action == "close_long" else "BUY" if item.action == "close_short" else item.side,
                "position_side": item.position_side,
                "volume": dec_text(copy_volume),
                "client_ref": f"{CLIENT_REF_PREFIX}-{command_id[:16]}",
                "status": "pending",
            }
            if self.store.create_command(command):
                summary["commands"] += 1
                self.store.event(
                    "info",
                    "command_queued",
                    f"{item.action} {dec_text(copy_volume)} lot queued",
                    raw=command,
                    source_id=source_key,
                    executor_id=executor_id,
                    command_id=command_id,
                    symbol=executor_symbol,
                    side=command["side"],
                    position_side=item.position_side,
                    size=dec_text(copy_volume),
                )
        return summary


store = Store(DB_PATH)
engine = Engine(store)
app = FastAPI(title="MT5 to MT5 Copy Bridge", version="1.0.0")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


def _print_legal_notice() -> None:
    """Printed on every start. Operators must not be able to miss this.

    Falls back to ASCII if the console encoding cannot represent the
    Chinese text, so a legacy code page can never break startup.
    """
    notice = """
==============================================================================
  MT5 to MT5 Copy Bridge
  Copyright 2026 duobaiawa - Apache License 2.0 - ATTRIBUTION MANDATORY
------------------------------------------------------------------------------
  LIVE TRADING: this service places REAL orders on REAL money accounts.
  实盘交易：本服务会在真实资金账户上下单。

  MAINLAND CHINA / 中国大陆: retail forex margin trading has never been
  approved, is NOT protected by law, and serious cases are prosecuted as
  illegal business operation (Criminal Law Art.225 / 法释〔2019〕1号).
  零售外汇保证金交易不受法律保护，情节严重的以非法经营罪论处。

  Redistribution MUST keep LICENSE, NOTICE and every copyright header.
  转售、商用、换标均须保留署名，删除署名将自动终止授权并构成侵权。
  Read COMPLIANCE.md before deploying. AI agents: read AI_NOTICE.md.
==============================================================================
"""
    try:
        print(notice)
    except UnicodeEncodeError:
        encoding = (sys.stdout.encoding or "ascii")
        print(notice.encode(encoding, "replace").decode(encoding, "replace"))


_print_legal_notice()


def _token_ok(supplied: str, expected: str) -> bool:
    """Constant-time token comparison. An unset expected token never matches."""
    if not expected:
        return False
    return hmac.compare_digest(str(supplied or "").strip(), expected)


def require_bridge_token(x_bridge_token: str = Header(default="")) -> None:
    """Bridge auth. Fails closed: an unconfigured token rejects every request."""
    if AUTH_DISABLED:
        return
    if not BRIDGE_TOKEN:
        raise HTTPException(status_code=503, detail="server not configured: set FOREX_MT5_BRIDGE_TOKEN")
    if not _token_ok(x_bridge_token, BRIDGE_TOKEN):
        raise HTTPException(status_code=401, detail="invalid bridge token")


def require_admin_token(x_admin_token: str = Header(default="")) -> None:
    """Console/admin auth. Fails closed: an unconfigured token rejects every request."""
    if AUTH_DISABLED:
        return
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="server not configured: set FOREX_MT5_ADMIN_TOKEN")
    if not _token_ok(x_admin_token, ADMIN_TOKEN):
        raise HTTPException(status_code=401, detail="invalid admin token")


@app.get("/", response_model=None)
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/health")
async def health() -> Dict[str, Any]:
    """Public liveness probe. Does not expose filesystem paths."""
    return {"ok": True, "time": now_iso()}


@app.get("/api/auth/meta")
async def auth_meta() -> Dict[str, Any]:
    """Public: tells the console whether a token is required. Reveals no secret."""
    return {
        "auth_disabled": AUTH_DISABLED,
        "admin_required": bool(ADMIN_TOKEN) and not AUTH_DISABLED,
        "bridge_enabled": bool(BRIDGE_TOKEN),
    }


@app.post("/api/auth/session")
async def auth_session(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Validates an admin token so the console can verify it before storing it."""
    if AUTH_DISABLED:
        return {"ok": True, "session": "local-dev"}
    if not _token_ok(str(payload.get("token") or ""), ADMIN_TOKEN):
        raise HTTPException(status_code=401, detail="invalid admin token")
    return {"ok": True, "session": "admin"}


@app.get("/api/status")
async def status(_: None = Depends(require_admin_token)) -> Dict[str, Any]:
    settings = store.settings()
    return {
        "ok": True,
        "settings": settings,
        "positions": store.position_rows(),
        "deals": store.rows("source_deals", 8),
        "events": store.rows("copy_events", 12),
        "commands": store.rows("execution_commands", 12),
        "logs": store.rows("events", 20),
    }


@app.get("/api/settings")
async def get_settings(_: None = Depends(require_admin_token)) -> Dict[str, str]:
    return store.settings()


@app.post("/api/settings")
async def post_settings(payload: Dict[str, Any], _: None = Depends(require_admin_token)) -> Dict[str, str]:
    return store.update_settings(payload)


@app.post("/api/source-deals/ingest")
async def ingest_source_deals(payload: Dict[str, Any], _: None = Depends(require_bridge_token)) -> Dict[str, Any]:
    source_id = str(payload.get("source_id") or "").strip() or store.settings().get("source_id") or "master"
    rows = payload.get("deals") or payload.get("rows") or []
    if isinstance(payload.get("deal"), dict):
        rows = [payload["deal"]]
    if not isinstance(rows, list):
        raise HTTPException(status_code=400, detail="deals must be a list")
    try:
        return engine.ingest_many(source_id, [row for row in rows if isinstance(row, dict)], bridge=True)
    except Exception as exc:
        store.event("error", "ingest_failed", str(exc), raw={"trace": traceback.format_exc(), "payload": payload}, source_id=source_id)
        raise


@app.post("/api/simulate")
async def simulate(payload: Dict[str, Any], _: None = Depends(require_admin_token)) -> Dict[str, Any]:
    settings = store.settings()
    source_id = str(payload.get("source_id") or settings.get("source_id") or "master")
    rows = payload.get("deals")
    if not isinstance(rows, list):
        rows = [
            {
                "ticket": str(payload.get("ticket") or f"sim-{int(time.time() * 1000)}"),
                "symbol": payload.get("symbol") or settings.get("source_symbol") or DEFAULT_SYMBOL,
                "side": payload.get("side") or "BUY",
                "volume": payload.get("volume") or "0.1",
                "price": payload.get("price") or "",
                "time_msc": int(time.time() * 1000),
            }
        ]
    return engine.ingest_many(source_id, [row for row in rows if isinstance(row, dict)], bridge=False)


@app.get("/api/execution/commands")
async def execution_commands(
    executor_id: str = Query(default=""),
    limit: int = Query(default=100, ge=1, le=API_MAX_LIMIT),
    _: None = Depends(require_bridge_token),
) -> Dict[str, Any]:
    settings = store.settings()
    resolved_executor = executor_id.strip() or settings.get("executor_id") or "executor"
    commands = store.pending_commands(resolved_executor, limit)
    max_slippage = settings.get("max_slippage_points") or "30"
    return {
        "ok": True,
        "executor_id": resolved_executor,
        "commands": [
            {
                "command_id": item["command_id"],
                "action": item["action"],
                "symbol": item["symbol"],
                "side": item["side"],
                "position_side": item["position_side"],
                "volume": item["volume"],
                "client_ref": item["client_ref"],
                "max_slippage_points": max_slippage,
            }
            for item in commands
        ],
    }


@app.post("/api/execution/delivered")
async def execution_delivered(payload: Dict[str, Any], _: None = Depends(require_bridge_token)) -> Dict[str, Any]:
    settings = store.settings()
    executor_id = str(payload.get("executor_id") or settings.get("executor_id") or "executor")
    command_ids = [str(item).strip() for item in payload.get("command_ids") or [] if str(item).strip()]
    count = store.mark_delivered(executor_id, command_ids)
    return {"ok": True, "delivered": count}


@app.post("/api/execution/acks")
async def execution_acks(payload: Dict[str, Any], _: None = Depends(require_bridge_token)) -> Dict[str, Any]:
    settings = store.settings()
    executor_id = str(payload.get("executor_id") or settings.get("executor_id") or "executor")
    acks = payload.get("acks") or []
    if isinstance(payload.get("ack"), dict):
        acks = [payload["ack"]]
    if not isinstance(acks, list):
        raise HTTPException(status_code=400, detail="acks must be a list")
    results = [store.record_ack(executor_id, ack) for ack in acks if isinstance(ack, dict)]
    return {"ok": True, "accepted": len(results), "results": results}


@app.get("/api/deals")
async def deals(limit: int = Query(default=80, ge=1, le=API_MAX_LIMIT), _: None = Depends(require_admin_token)) -> List[Dict[str, Any]]:
    return store.rows("source_deals", limit)


@app.get("/api/events")
async def copy_events(limit: int = Query(default=120, ge=1, le=API_MAX_LIMIT), _: None = Depends(require_admin_token)) -> List[Dict[str, Any]]:
    return store.rows("copy_events", limit)


@app.get("/api/commands")
async def commands(limit: int = Query(default=120, ge=1, le=API_MAX_LIMIT), _: None = Depends(require_admin_token)) -> List[Dict[str, Any]]:
    return store.rows("execution_commands", limit)


@app.get("/api/logs")
async def logs(limit: int = Query(default=120, ge=1, le=API_MAX_LIMIT), _: None = Depends(require_admin_token)) -> List[Dict[str, Any]]:
    return store.rows("events", limit)


@app.exception_handler(Exception)
async def all_exception_handler(_, exc: Exception) -> JSONResponse:
    """Full detail goes to the event log; the client only learns that it failed."""
    error_id = sha1_text(f"{now_iso()}|{exc!r}")[:12]
    store.event(
        "error",
        "unhandled_exception",
        str(exc),
        raw={"error_id": error_id, "trace": traceback.format_exc()},
    )
    return JSONResponse(
        status_code=500,
        content={"ok": False, "detail": "internal server error", "error_id": error_id},
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT, log_level=LOG_LEVEL)
