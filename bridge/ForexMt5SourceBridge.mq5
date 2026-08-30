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
#property description "Single-symbol MT5 source deal file bridge"
#property version "1.00"

input string SourceId = "master";
input string SymbolPrefix = "XAUUSD";
input int PollSeconds = 1;
input int LookbackMinutes = 120;
input string BridgeFolder = "Forex_MT5_Copy";  // must match the bridge agent / installer

string BridgeDir = "";
string OutboxFile = "";
string StateFile = "";
long LastTimeMsc = 0;

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
      out = "master";
   return out;
}

string UpperCopy(string value)
{
   string out = value;
   StringToUpper(out);
   return out;
}

void LoadState()
{
   int handle = FileOpen(StateFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   string text = FileReadString(handle);
   FileClose(handle);
   LastTimeMsc = (long)StringToInteger(text);
}

void SaveState()
{
   int handle = FileOpen(StateFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   FileWrite(handle, IntegerToString(LastTimeMsc));
   FileClose(handle);
}

void AppendLine(string line)
{
   int handle = FileOpen(OutboxFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, line);
   FileClose(handle);
}

string DealSide(long dealType)
{
   if(dealType == DEAL_TYPE_BUY)
      return "BUY";
   if(dealType == DEAL_TYPE_SELL)
      return "SELL";
   return "";
}

void PollDeals()
{
   string source = SourceId;
   if(StringLen(source) == 0)
   {
      Comment("Forex source bridge: fill SourceId");
      return;
   }

   datetime toTime = TimeCurrent();
   datetime fromTime = toTime - LookbackMinutes * 60;
   if(LastTimeMsc > 0)
      fromTime = (datetime)MathMax((LastTimeMsc / 1000) - 300, 0);

   if(!HistorySelect(fromTime, toTime))
   {
      Comment("Forex source bridge: HistorySelect failed");
      return;
   }

   int total = HistoryDealsTotal();
   int written = 0;
   long maxTime = LastTimeMsc;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      long timeMsc = (long)HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
      if(LastTimeMsc > 0 && timeMsc < LastTimeMsc)
         continue;
      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(StringFind(UpperCopy(symbol), UpperCopy(SymbolPrefix)) != 0)
         continue;
      string side = DealSide((long)HistoryDealGetInteger(ticket, DEAL_TYPE));
      if(side == "")
         continue;

      string line = "{"
         + "\"source_id\":\"" + JsonEscape(source) + "\","
         + "\"ticket\":\"" + IntegerToString((long)ticket) + "\","
         + "\"order\":\"" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_ORDER)) + "\","
         + "\"symbol\":\"" + JsonEscape(symbol) + "\","
         + "\"side\":\"" + side + "\","
         + "\"volume\":\"" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 2) + "\","
         + "\"price\":\"" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), 5) + "\","
         + "\"time_msc\":" + IntegerToString(timeMsc)
         + "}";
      AppendLine(line);
      written++;
      if(timeMsc > maxTime)
         maxTime = timeMsc;
   }

   if(maxTime > LastTimeMsc)
   {
      LastTimeMsc = maxTime;
      SaveState();
   }

   Comment("Forex source bridge running\nSourceId: ", source, "\nSymbol: ", SymbolPrefix, "\nwritten: ", written);
}

int OnInit()
{
   BridgeDir = SafeFilePart(BridgeFolder);
   if(StringLen(BridgeDir) == 0)
      BridgeDir = "Forex_MT5_Copy";
   FolderCreate(BridgeDir, FILE_COMMON);
   OutboxFile = BridgeDir + "\\source_outbox.jsonl";
   StateFile = BridgeDir + "\\source_state_" + SafeFilePart(SourceId) + ".txt";
   LoadState();
   EventSetTimer(MathMax(PollSeconds, 1));
   PollDeals();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   PollDeals();
}
