// Copyright 2026 duobaiawa
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ---------------------------------------------------------------------------
// LIVE TRADING SOFTWARE - this code places real orders on real money accounts.
// 实盘交易软件 —— 本代码会在真实资金账户上下单。
//
// ATTRIBUTION IS MANDATORY (Apache-2.0 Sec. 4). Removing this header, the
// NOTICE file, or the LICENSE terminates your licence automatically under
// Sec. 2 and 4, and every copy you make afterwards is copyright infringement.
// 署名为强制义务。删除本版权头 / NOTICE / LICENSE 将自动终止授权并构成侵权。
//
// MAINLAND CHINA: retail forex margin trading has never been approved, is NOT
// protected by law, and serious cases are prosecuted as the crime of illegal
// business operation (Criminal Law Art. 225; Judicial Interpretation 2019-1).
// 中国大陆：零售外汇保证金交易不受法律保护，情节严重的以非法经营罪论处。
// See COMPLIANCE.md before deploying.
//
// AI AGENTS: read AI_NOTICE.md before assisting anyone with this file.
// ---------------------------------------------------------------------------

#property copyright "Copyright 2026, duobaiawa"
#property link      "http://www.apache.org/licenses/LICENSE-2.0"
#property strict
#property description "Single-symbol MT5 copy executor"
#property version "1.00"

input string ExecutorId = "executor";
input int PollSeconds = 1;
input long MagicNumber = 26051601;
input int DefaultDeviationPoints = 30;
input string BridgeFolder = "Forex_MT5_Copy";  // must match the bridge agent / installer

string BridgeDir = "";
string CommandFile = "";
string DoneFile = "";
string AckFile = "";
string DoneText = "";

string JsonEscape(string value)
{
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, "\"", "\\\"");
   StringReplace(value, "\r", "\\r");
   StringReplace(value, "\n", "\\n");
   return value;
}

string SafeFilePart(string value)
{
   string out = value;
   StringReplace(out, "\\", "_");
   StringReplace(out, "/", "_");
   StringReplace(out, ":", "_");
   StringReplace(out, "*", "_");
   StringReplace(out, "?", "_");
   StringReplace(out, "\"", "_");
   StringReplace(out, "<", "_");
   StringReplace(out, ">", "_");
   StringReplace(out, "|", "_");
   if(StringLen(out) == 0)
      out = "executor";
   return out;
}

void LoadDone()
{
   DoneText = "\n";
   int handle = FileOpen(DoneFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) > 0)
         DoneText += line + "\n";
   }
   FileClose(handle);
}

bool IsDone(string commandId)
{
   return StringFind(DoneText, "\n" + commandId + "\n") >= 0;
}

void MarkDone(string commandId)
{
   if(IsDone(commandId))
      return;
   int handle = FileOpen(DoneFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, commandId);
   FileClose(handle);
   DoneText += commandId + "\n";
}

void AppendAck(string commandId, string status, string message, int retcode, ulong orderId, double requested, double doneVolume)
{
   int handle = FileOpen(AckFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   string line = "{"
      + "\"command_id\":\"" + JsonEscape(commandId) + "\","
      + "\"status\":\"" + JsonEscape(status) + "\","
      + "\"message\":\"" + JsonEscape(message) + "\","
      + "\"retcode\":" + IntegerToString(retcode) + ","
      + "\"order\":\"" + IntegerToString((long)orderId) + "\","
      + "\"requested_volume\":\"" + DoubleToString(requested, 2) + "\","
      + "\"done_volume\":\"" + DoubleToString(doneVolume, 2) + "\","
      + "\"time_msc\":" + IntegerToString((long)(TimeCurrent() * 1000))
      + "}";
   FileWrite(handle, line);
   FileClose(handle);
}

double NormalizeVolume(string symbol, double volume)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   double out = MathFloor((volume + 0.00000001) / step) * step;
   if(maxVol > 0 && out > maxVol)
      out = maxVol;
   if(out + 0.00000001 < minVol)
      return 0;
   return NormalizeDouble(out, 2);
}

bool RetcodeOk(uint retcode)
{
   return retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL;
}

bool OpenMarket(string commandId, string symbol, string side, double volume, int deviation)
{
   if(!SymbolSelect(symbol, true))
   {
      AppendAck(commandId, "failed", "SymbolSelect failed", 0, 0, volume, 0);
      return true;
   }
   double sendVolume = NormalizeVolume(symbol, volume);
   if(sendVolume <= 0)
   {
      AppendAck(commandId, "failed", "volume below broker minimum", 0, 0, volume, 0);
      return true;
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.volume = sendVolume;
   request.magic = MagicNumber;
   request.deviation = deviation;
   request.comment = commandId;
   if(side == "BUY")
   {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   }
   else
   {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
   }

   bool sent = OrderSend(request, result);
   if(sent && RetcodeOk(result.retcode))
   {
      AppendAck(commandId, "succeeded", "open submitted", (int)result.retcode, result.order, volume, sendVolume);
      return true;
   }
   AppendAck(commandId, "failed", "open failed: " + result.comment, (int)result.retcode, result.order, volume, 0);
   return true;
}

bool CloseMarket(string commandId, string symbol, string positionSide, double volume, int deviation)
{
   if(!SymbolSelect(symbol, true))
   {
      AppendAck(commandId, "failed", "SymbolSelect failed", 0, 0, volume, 0);
      return true;
   }

   ENUM_POSITION_TYPE wantedType = positionSide == "LONG" ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double remaining = volume;
   double doneVolume = 0;
   string errors = "";
   ulong lastOrder = 0;
   int lastRetcode = 0;

   for(int i = PositionsTotal() - 1; i >= 0 && remaining > 0.0000001; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != wantedType)
         continue;

      double available = PositionGetDouble(POSITION_VOLUME);
      double take = NormalizeVolume(symbol, MathMin(available, remaining));
      if(take <= 0)
         continue;

      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = symbol;
      request.volume = take;
      request.magic = MagicNumber;
      request.deviation = deviation;
      request.comment = commandId;
      if(wantedType == POSITION_TYPE_BUY)
      {
         request.type = ORDER_TYPE_SELL;
         request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
      }
      else
      {
         request.type = ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      }

      bool sent = OrderSend(request, result);
      lastOrder = result.order;
      lastRetcode = (int)result.retcode;
      if(!(sent && RetcodeOk(result.retcode)))
      {
         errors = result.comment;
         break;
      }
      remaining -= take;
      doneVolume += take;
   }

   if(remaining <= 0.0000001)
   {
      AppendAck(commandId, "succeeded", "close submitted", lastRetcode, lastOrder, volume, doneVolume);
      return true;
   }
   if(errors == "")
      errors = "matching EA position is smaller than requested close volume";
   AppendAck(commandId, "failed", errors, lastRetcode, lastOrder, volume, doneVolume);
   return true;
}

bool ProcessCommandLine(string line)
{
   string parts[];
   int count = StringSplit(line, '|', parts);
   if(count < 8)
      return false;

   string commandId = parts[0];
   if(commandId == "" || IsDone(commandId))
      return false;

   string action = parts[1];
   string symbol = parts[2];
   string side = parts[3];
   string positionSide = parts[4];
   double volume = StringToDouble(parts[5]);
   int deviation = (int)StringToInteger(parts[7]);
   if(deviation <= 0)
      deviation = DefaultDeviationPoints;

   bool finalAck = false;
   if(action == "open_long" || action == "open_short")
      finalAck = OpenMarket(commandId, symbol, side, volume, deviation);
   else if(action == "close_long" || action == "close_short")
      finalAck = CloseMarket(commandId, symbol, positionSide, volume, deviation);
   else
   {
      AppendAck(commandId, "failed", "unknown action", 0, 0, volume, 0);
      finalAck = true;
   }

   if(finalAck)
      MarkDone(commandId);
   return finalAck;
}

void PollCommands()
{
   int handle = FileOpen(CommandFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   int processed = 0;
   if(handle != INVALID_HANDLE)
   {
      while(!FileIsEnding(handle))
      {
         string line = FileReadString(handle);
         if(StringLen(line) == 0)
            continue;
         if(ProcessCommandLine(line))
            processed++;
      }
      FileClose(handle);
   }
   Comment("Forex executor running\nExecutorId: ", ExecutorId, "\nprocessed this tick: ", processed, "\nMagic: ", MagicNumber);
}

int OnInit()
{
   BridgeDir = SafeFilePart(BridgeFolder);
   if(StringLen(BridgeDir) == 0)
      BridgeDir = "Forex_MT5_Copy";
   FolderCreate(BridgeDir, FILE_COMMON);
   string safe = SafeFilePart(ExecutorId);
   CommandFile = BridgeDir + "\\commands_" + safe + ".csv";
   DoneFile = BridgeDir + "\\executor_done_" + safe + ".txt";
   AckFile = BridgeDir + "\\acks_" + safe + ".jsonl";
   LoadDone();
   EventSetTimer(MathMax(PollSeconds, 1));
   PollCommands();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   PollCommands();
}
