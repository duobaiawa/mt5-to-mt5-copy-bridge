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

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ForexMt5CopyBridge
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            EnableModernTls();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        private static void EnableModernTls()
        {
            try
            {
                ServicePointManager.SecurityProtocol =
                    (SecurityProtocolType)3072 |
                    SecurityProtocolType.Tls;
            }
            catch
            {
                try { ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls; } catch { }
            }
        }
    }

    internal sealed class MainForm : Form
    {
        // Placeholder only. Set your own server URL here before building, or let the
        // operator type it into the installer's "API 地址" box (it is saved per machine).
        private const string DefaultApiUrl = "http://127.0.0.1:18197";
        private const string ResourceSourceMq5 = "ForexMt5SourceBridge.mq5";
        private const string ResourceSourceEx5 = "ForexMt5SourceBridge.ex5";
        private const string ResourceExecutorMq5 = "ForexMt5Executor.mq5";
        private const string ResourceExecutorEx5 = "ForexMt5Executor.ex5";

        private readonly Label _title;
        private readonly Label _subtitle;
        private readonly Label _status;
        private readonly Label _detail;
        private readonly Label _sourceSentLabel;
        private readonly Label _commandLabel;
        private readonly Label _ackLabel;
        private readonly Label _pendingLabel;
        private readonly TextBox _apiBox;
        private readonly TextBox _executorBox;
        private readonly TextBox _tokenBox;
        private readonly Button _startButton;
        private readonly Button _pauseButton;
        private readonly Button _folderButton;
        private readonly Button _guideButton;
        private readonly TextBox _log;
        private readonly Timer _timer;
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer();

        private readonly string _appDir;
        private readonly string _commonDir;
        private readonly string _sourceOutbox;
        private readonly string _sourceSentFile;
        private readonly string _ackSentFilePrefix;
        private readonly string _logFile;
        private readonly string _configFile;

        private readonly Hashtable _sourceSent = new Hashtable();
        private readonly Hashtable _ackSent = new Hashtable();
        private bool _running;
        private bool _busy;
        private int _sourceSentCount;
        private int _commandsDelivered;
        private int _acksPosted;

        public MainForm()
        {
            Text = "MT5 Copy Sync Bridge";
            Width = 720;
            Height = 560;
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            BackColor = Color.FromArgb(246, 248, 250);
            Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Regular);

            _appDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ForexMt5CopySyncBridge");
            _commonDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MetaQuotes\\Terminal\\Common\\Files\\Forex_MT5_Copy");
            _sourceOutbox = Path.Combine(_commonDir, "source_outbox.jsonl");
            _sourceSentFile = Path.Combine(_commonDir, "source_sent_ids.txt");
            _ackSentFilePrefix = Path.Combine(_commonDir, "acks_sent_");
            _logFile = Path.Combine(_commonDir, "bridge_agent.log");
            _configFile = Path.Combine(_commonDir, "bridge_config.ini");

            _title = MakeLabel("MT5 Copy Sync 桥接器", 23, FontStyle.Bold, 24, 18, 620, 36, Color.FromArgb(15, 23, 42));
            _subtitle = MakeLabel("源端 MT5 成交 -> 控制台 -> 执行端 MT5", 10, FontStyle.Regular, 26, 54, 640, 24, Color.FromArgb(100, 116, 139));
            _status = MakeLabel("准备启动", 18, FontStyle.Bold, 28, 94, 640, 34, Color.FromArgb(181, 71, 8));
            _detail = MakeLabel("打开后会自动安装源端/执行端 EA，并启动本机桥接 Agent。", 10, FontStyle.Regular, 28, 129, 640, 24, Color.FromArgb(71, 84, 103));

            Label apiLabel = MakeLabel("控制台地址", 9, FontStyle.Regular, 28, 164, 120, 20, Color.FromArgb(100, 116, 139));
            _apiBox = MakeTextBox(28, 186, 300, 32);
            Label executorLabel = MakeLabel("执行账户 ID", 9, FontStyle.Regular, 344, 164, 120, 20, Color.FromArgb(100, 116, 139));
            _executorBox = MakeTextBox(344, 186, 126, 32);
            Label tokenLabel = MakeLabel("Bridge Token（可空）", 9, FontStyle.Regular, 486, 164, 160, 20, Color.FromArgb(100, 116, 139));
            _tokenBox = MakeTextBox(486, 186, 178, 32);
            _tokenBox.UseSystemPasswordChar = true;

            _startButton = MakeButton("一键安装并启动", 28, 234, 150, 36, true);
            _pauseButton = MakeButton("暂停", 188, 234, 84, 36, false);
            _folderButton = MakeButton("打开日志目录", 282, 234, 126, 36, false);
            _guideButton = MakeButton("安装教程", 418, 234, 100, 36, false);

            _sourceSentLabel = MakeLabel("源成交 0", 10, FontStyle.Bold, 28, 292, 150, 24, Color.FromArgb(15, 23, 42));
            _commandLabel = MakeLabel("命令下发 0", 10, FontStyle.Bold, 182, 292, 150, 24, Color.FromArgb(15, 23, 42));
            _ackLabel = MakeLabel("回执回传 0", 10, FontStyle.Bold, 340, 292, 150, 24, Color.FromArgb(15, 23, 42));
            _pendingLabel = MakeLabel("待处理 0", 10, FontStyle.Bold, 496, 292, 150, 24, Color.FromArgb(15, 23, 42));

            _log = new TextBox();
            _log.Left = 28;
            _log.Top = 326;
            _log.Width = 636;
            _log.Height = 165;
            _log.Multiline = true;
            _log.ReadOnly = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.BackColor = Color.White;
            _log.BorderStyle = BorderStyle.FixedSingle;

            Controls.Add(_title);
            Controls.Add(_subtitle);
            Controls.Add(_status);
            Controls.Add(_detail);
            Controls.Add(apiLabel);
            Controls.Add(_apiBox);
            Controls.Add(executorLabel);
            Controls.Add(_executorBox);
            Controls.Add(tokenLabel);
            Controls.Add(_tokenBox);
            Controls.Add(_startButton);
            Controls.Add(_pauseButton);
            Controls.Add(_folderButton);
            Controls.Add(_guideButton);
            Controls.Add(_sourceSentLabel);
            Controls.Add(_commandLabel);
            Controls.Add(_ackLabel);
            Controls.Add(_pendingLabel);
            Controls.Add(_log);

            _startButton.Click += delegate { InstallAndStart(); };
            _pauseButton.Click += delegate { PauseBridge(); };
            _folderButton.Click += delegate { OpenLogFolder(); };
            _guideButton.Click += delegate { OpenGuide(); };

            _timer = new Timer();
            _timer.Interval = 1000;
            _timer.Tick += delegate { TickBridge(); };

            LoadConfig();
            Shown += delegate { InstallAndStart(); };
        }

        private static Label MakeLabel(string text, float size, FontStyle style, int left, int top, int width, int height, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = new Font("Microsoft YaHei UI", size, style);
            label.Left = left;
            label.Top = top;
            label.Width = width;
            label.Height = height;
            label.ForeColor = color;
            return label;
        }

        private static TextBox MakeTextBox(int left, int top, int width, int height)
        {
            TextBox box = new TextBox();
            box.Left = left;
            box.Top = top;
            box.Width = width;
            box.Height = height;
            box.BorderStyle = BorderStyle.FixedSingle;
            return box;
        }

        private static Button MakeButton(string text, int left, int top, int width, int height, bool primary)
        {
            Button button = new Button();
            button.Text = text;
            button.Left = left;
            button.Top = top;
            button.Width = width;
            button.Height = height;
            button.FlatStyle = FlatStyle.Flat;
            button.BackColor = primary ? Color.FromArgb(23, 92, 211) : Color.White;
            button.ForeColor = primary ? Color.White : Color.FromArgb(15, 23, 42);
            button.FlatAppearance.BorderColor = primary ? Color.FromArgb(23, 92, 211) : Color.FromArgb(221, 227, 234);
            return button;
        }

        private void SetStatus(string text, Color color)
        {
            _status.Text = text;
            _status.ForeColor = color;
        }

        private void AddLog(string text)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text;
            _log.AppendText(line + Environment.NewLine);
            try
            {
                Directory.CreateDirectory(_commonDir);
                File.AppendAllText(_logFile, line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }

        private void LoadConfig()
        {
            _apiBox.Text = DefaultApiUrl;
            _executorBox.Text = "executor";
            _tokenBox.Text = "";
            try
            {
                if (!File.Exists(_configFile))
                {
                    return;
                }
                string[] lines = File.ReadAllLines(_configFile, Encoding.UTF8);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i];
                    int pos = line.IndexOf('=');
                    if (pos <= 0)
                    {
                        continue;
                    }
                    string key = line.Substring(0, pos).Trim();
                    string value = line.Substring(pos + 1).Trim();
                    if (key == "ApiUrl")
                    {
                        _apiBox.Text = value;
                    }
                    else if (key == "ExecutorId")
                    {
                        _executorBox.Text = value;
                    }
                    else if (key == "BridgeToken")
                    {
                        _tokenBox.Text = value;
                    }
                }
            }
            catch (Exception ex)
            {
                AddLog("config load skipped: " + ex.Message);
            }
        }

        private void SaveConfig()
        {
            Directory.CreateDirectory(_commonDir);
            StringBuilder text = new StringBuilder();
            text.AppendLine("ApiUrl=" + ApiBase());
            text.AppendLine("ExecutorId=" + ExecutorId());
            text.AppendLine("BridgeToken=" + _tokenBox.Text.Trim());
            File.WriteAllText(_configFile, text.ToString(), Encoding.UTF8);
        }

        private string ApiBase()
        {
            string value = _apiBox.Text.Trim();
            if (value.Length == 0)
            {
                value = DefaultApiUrl;
            }
            return value.TrimEnd('/');
        }

        private string ExecutorId()
        {
            string value = _executorBox.Text.Trim();
            return value.Length == 0 ? "executor" : value;
        }

        private string SafeExecutorId()
        {
            return SafeFilePart(ExecutorId());
        }

        private string CommandFile()
        {
            return Path.Combine(_commonDir, "commands_" + SafeExecutorId() + ".csv");
        }

        private string AckFile()
        {
            return Path.Combine(_commonDir, "acks_" + SafeExecutorId() + ".jsonl");
        }

        private string AckSentFile()
        {
            return _ackSentFilePrefix + SafeExecutorId() + ".txt";
        }

        private void InstallAndStart()
        {
            try
            {
                Directory.CreateDirectory(_appDir);
                Directory.CreateDirectory(_commonDir);
                SaveConfig();

                string sourceMq5 = WriteResource(ResourceSourceMq5);
                string sourceEx5 = WriteResource(ResourceSourceEx5);
                string executorMq5 = WriteResource(ResourceExecutorMq5);
                string executorEx5 = WriteResource(ResourceExecutorEx5);

                int installed = InstallEaToTerminals(sourceMq5, sourceEx5, executorMq5, executorEx5);
                CreateShortcuts();
                LoadSentSets();
                _running = true;
                _timer.Start();

                if (installed > 0)
                {
                    SetStatus("桥接已启动", Color.FromArgb(6, 118, 71));
                    _detail.Text = "源端挂 ForexMt5SourceBridge，执行端挂 ForexMt5Executor，ExecutorId 保持一致。";
                    AddLog("EA files installed to " + installed + " MT5 terminal folder(s).");
                }
                else
                {
                    SetStatus("未找到 MT5", Color.FromArgb(180, 35, 24));
                    _detail.Text = "请先安装并登录 MT5，然后重新打开本程序。桥接 Agent 已启动并等待文件。";
                    AddLog("No MT5 terminal data folder was found.");
                }
            }
            catch (Exception ex)
            {
                SetStatus("启动失败", Color.FromArgb(180, 35, 24));
                _detail.Text = ex.Message;
                AddLog("start error: " + ex.Message);
            }
        }

        private string WriteResource(string resourceName)
        {
            byte[] bytes = ReadResource(resourceName);
            string target = Path.Combine(_appDir, resourceName);
            File.WriteAllBytes(target, bytes);
            return target;
        }

        private static byte[] ReadResource(string resourceName)
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            Stream stream = asm.GetManifestResourceStream(resourceName);
            if (stream == null)
            {
                string[] names = asm.GetManifestResourceNames();
                for (int i = 0; i < names.Length; i++)
                {
                    if (names[i].EndsWith("." + resourceName, StringComparison.OrdinalIgnoreCase) ||
                        names[i].Equals(resourceName, StringComparison.OrdinalIgnoreCase))
                    {
                        stream = asm.GetManifestResourceStream(names[i]);
                        break;
                    }
                }
            }
            if (stream == null)
            {
                throw new FileNotFoundException("embedded resource not found: " + resourceName);
            }
            using (stream)
            using (MemoryStream ms = new MemoryStream())
            {
                stream.CopyTo(ms);
                return ms.ToArray();
            }
        }

        private int InstallEaToTerminals(string sourceMq5, string sourceEx5, string executorMq5, string executorEx5)
        {
            int count = 0;
            string baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MetaQuotes\\Terminal");
            if (!Directory.Exists(baseDir))
            {
                return 0;
            }

            string[] dirs = Directory.GetDirectories(baseDir);
            for (int i = 0; i < dirs.Length; i++)
            {
                string experts = Path.Combine(dirs[i], "MQL5\\Experts");
                if (!Directory.Exists(experts))
                {
                    continue;
                }
                string sourceMq5Target = Path.Combine(experts, ResourceSourceMq5);
                string sourceEx5Target = Path.Combine(experts, ResourceSourceEx5);
                string executorMq5Target = Path.Combine(experts, ResourceExecutorMq5);
                string executorEx5Target = Path.Combine(experts, ResourceExecutorEx5);
                File.Copy(sourceMq5, sourceMq5Target, true);
                File.Copy(sourceEx5, sourceEx5Target, true);
                File.Copy(executorMq5, executorMq5Target, true);
                File.Copy(executorEx5, executorEx5Target, true);
                count++;
                AddLog("EA copied: " + experts);
                TryCompileEa(dirs[i], sourceMq5Target);
                TryCompileEa(dirs[i], executorMq5Target);
            }
            return count;
        }

        private void TryCompileEa(string terminalDataDir, string eaPath)
        {
            try
            {
                string origin = Path.Combine(terminalDataDir, "origin.txt");
                if (!File.Exists(origin))
                {
                    return;
                }
                string installPath = File.ReadAllLines(origin)[0].Trim();
                string parent = Path.GetDirectoryName(installPath) ?? "";
                string[] candidates = new string[] {
                    Path.Combine(installPath, "metaeditor64.exe"),
                    Path.Combine(installPath, "metaeditor.exe"),
                    Path.Combine(parent, "metaeditor64.exe"),
                    Path.Combine(parent, "metaeditor.exe")
                };
                for (int i = 0; i < candidates.Length; i++)
                {
                    if (!File.Exists(candidates[i]))
                    {
                        continue;
                    }
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = candidates[i];
                    psi.Arguments = "/compile:\"" + eaPath + "\"";
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    Process p = Process.Start(psi);
                    if (p != null)
                    {
                        p.WaitForExit(12000);
                    }
                    AddLog("compile attempted: " + Path.GetFileName(eaPath));
                    return;
                }
            }
            catch (Exception ex)
            {
                AddLog("compile skipped: " + ex.Message);
            }
        }

        private void CreateShortcuts()
        {
            try
            {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                CreateShortcut(Path.Combine(desktop, "MT5 Copy Sync 桥接器.lnk"));
                CreateShortcut(Path.Combine(startup, "MT5 Copy Sync 桥接器.lnk"));
            }
            catch (Exception ex)
            {
                AddLog("shortcut skipped: " + ex.Message);
            }
        }

        private void CreateShortcut(string linkPath)
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                return;
            }
            object shell = Activator.CreateInstance(shellType);
            object shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { linkPath });
            Type shortcutType = shortcut.GetType();
            shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Application.ExecutablePath });
            shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(Application.ExecutablePath) });
            shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }

        private void LoadSentSets()
        {
            _sourceSent.Clear();
            _ackSent.Clear();
            _sourceSentCount = LoadSet(_sourceSentFile, _sourceSent);
            LoadSet(AckSentFile(), _ackSent);
            _sourceSentLabel.Text = "源成交 " + _sourceSentCount;
            _commandLabel.Text = "命令下发 " + _commandsDelivered;
            _ackLabel.Text = "回执回传 " + _acksPosted;
        }

        private static int LoadSet(string path, Hashtable target)
        {
            int count = 0;
            if (!File.Exists(path))
            {
                return 0;
            }
            string[] lines = File.ReadAllLines(path, Encoding.UTF8);
            for (int i = 0; i < lines.Length; i++)
            {
                string id = lines[i].Trim();
                if (id.Length == 0 || target.ContainsKey(id))
                {
                    continue;
                }
                target[id] = true;
                count++;
            }
            return count;
        }

        private void TickBridge()
        {
            if (!_running || _busy)
            {
                return;
            }
            _busy = true;
            try
            {
                Directory.CreateDirectory(_commonDir);
                SourceRow[] rows = ReadSourceRows();
                int sourcePosted = PostSourceRows(rows);
                int commands = PullCommands();
                int acks = PostAcks();
                int total = rows.Length + commands + acks;
                _pendingLabel.Text = "待处理 " + rows.Length;
                if (total > 0)
                {
                    SetStatus("桥接正常", Color.FromArgb(6, 118, 71));
                    _detail.Text = "本轮：源成交 " + sourcePosted + "，命令下发 " + commands + "，回执回传 " + acks + "。";
                }
                else if (File.Exists(_sourceOutbox) || File.Exists(CommandFile()) || File.Exists(AckFile()))
                {
                    SetStatus("桥接运行中", Color.FromArgb(6, 118, 71));
                    _detail.Text = "已连接本机 MT5 桥接目录，等待源端成交或控制台命令。";
                }
                else
                {
                    SetStatus("等待 MT5 EA", Color.FromArgb(181, 71, 8));
                    _detail.Text = "请在源端图表挂 SourceBridge，在执行端图表挂 Executor，并保持算法交易开启。";
                }
            }
            catch (Exception ex)
            {
                SetStatus("桥接异常", Color.FromArgb(180, 35, 24));
                _detail.Text = ex.Message;
                AddLog("bridge error: " + ex.Message);
            }
            finally
            {
                _busy = false;
            }
        }

        private SourceRow[] ReadSourceRows()
        {
            ArrayList list = new ArrayList();
            if (!File.Exists(_sourceOutbox))
            {
                return new SourceRow[0];
            }
            string[] lines = File.ReadAllLines(_sourceOutbox, Encoding.Default);
            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0)
                {
                    continue;
                }
                string sourceId = MatchJsonString(line, "source_id");
                string ticket = MatchJsonString(line, "ticket");
                if (ticket.Length == 0)
                {
                    ticket = MatchJsonString(line, "order");
                }
                if (sourceId.Length == 0 || ticket.Length == 0)
                {
                    string missingId = "bad|" + Sha1(line);
                    if (!_sourceSent.ContainsKey(missingId))
                    {
                        AddLog("skipped source row without source_id or ticket");
                        MarkSourceSent(missingId);
                    }
                    continue;
                }
                string id = sourceId + "|" + ticket;
                if (!_sourceSent.ContainsKey(id))
                {
                    list.Add(new SourceRow(sourceId, ticket, id, line));
                }
                if (list.Count >= 100)
                {
                    break;
                }
            }
            return (SourceRow[])list.ToArray(typeof(SourceRow));
        }

        private int PostSourceRows(SourceRow[] rows)
        {
            if (rows.Length == 0)
            {
                return 0;
            }
            Hashtable groups = new Hashtable();
            for (int i = 0; i < rows.Length; i++)
            {
                ArrayList group = (ArrayList)groups[rows[i].SourceId];
                if (group == null)
                {
                    group = new ArrayList();
                    groups[rows[i].SourceId] = group;
                }
                group.Add(rows[i]);
            }
            int posted = 0;
            foreach (DictionaryEntry entry in groups)
            {
                SourceRow[] groupRows = (SourceRow[])((ArrayList)entry.Value).ToArray(typeof(SourceRow));
                PostSourceGroup((string)entry.Key, groupRows);
                posted += groupRows.Length;
            }
            return posted;
        }

        private void PostSourceGroup(string sourceId, SourceRow[] rows)
        {
            StringBuilder body = new StringBuilder();
            body.Append("{\"source_id\":\"");
            body.Append(JsonEscape(sourceId));
            body.Append("\",\"deals\":[");
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0)
                {
                    body.Append(",");
                }
                body.Append(rows[i].Json);
            }
            body.Append("]}");
            string response = PostJson("/api/source-deals/ingest", body.ToString());
            for (int i = 0; i < rows.Length; i++)
            {
                MarkSourceSent(rows[i].Id);
            }
            AddLog("posted " + rows.Length + " source deal(s), SourceId=" + sourceId + ", response=" + Shorten(response, 180));
        }

        private int PullCommands()
        {
            string executorId = ExecutorId();
            string text = GetText("/api/execution/commands?executor_id=" + Uri.EscapeDataString(executorId) + "&limit=100");
            object rootObj = _json.DeserializeObject(text);
            Dictionary<string, object> root = rootObj as Dictionary<string, object>;
            if (root == null || !root.ContainsKey("commands"))
            {
                return 0;
            }
            object[] commands = root["commands"] as object[];
            if (commands == null || commands.Length == 0)
            {
                return 0;
            }

            ArrayList ids = new ArrayList();
            StringBuilder lines = new StringBuilder();
            for (int i = 0; i < commands.Length; i++)
            {
                Dictionary<string, object> cmd = commands[i] as Dictionary<string, object>;
                if (cmd == null)
                {
                    continue;
                }
                string commandId = ValueOf(cmd, "command_id");
                if (commandId.Length == 0)
                {
                    continue;
                }
                string line = JoinCommandLine(new string[] {
                    commandId,
                    ValueOf(cmd, "action"),
                    ValueOf(cmd, "symbol"),
                    ValueOf(cmd, "side"),
                    ValueOf(cmd, "position_side"),
                    ValueOf(cmd, "volume"),
                    ValueOf(cmd, "client_ref"),
                    ValueOf(cmd, "max_slippage_points")
                });
                lines.AppendLine(line);
                ids.Add(commandId);
            }
            if (ids.Count == 0)
            {
                return 0;
            }

            File.AppendAllText(CommandFile(), lines.ToString(), Encoding.ASCII);
            string deliveredBody = "{\"executor_id\":\"" + JsonEscape(executorId) + "\",\"command_ids\":" + JsonStringArray(ids) + "}";
            PostJson("/api/execution/delivered", deliveredBody);
            _commandsDelivered += ids.Count;
            _commandLabel.Text = "命令下发 " + _commandsDelivered;
            AddLog("delivered " + ids.Count + " command(s), ExecutorId=" + executorId);
            return ids.Count;
        }

        private AckRow[] ReadAcks()
        {
            ArrayList list = new ArrayList();
            string ackFile = AckFile();
            if (!File.Exists(ackFile))
            {
                return new AckRow[0];
            }
            string[] lines = File.ReadAllLines(ackFile, Encoding.Default);
            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0)
                {
                    continue;
                }
                string commandId = MatchJsonString(line, "command_id");
                string status = MatchJsonString(line, "status");
                string timeMsc = MatchJsonNumber(line, "time_msc");
                if (commandId.Length == 0)
                {
                    continue;
                }
                string key = commandId + "|" + status + "|" + timeMsc;
                if (!_ackSent.ContainsKey(key))
                {
                    list.Add(new AckRow(key, line));
                }
                if (list.Count >= 100)
                {
                    break;
                }
            }
            return (AckRow[])list.ToArray(typeof(AckRow));
        }

        private int PostAcks()
        {
            AckRow[] rows = ReadAcks();
            if (rows.Length == 0)
            {
                return 0;
            }
            StringBuilder body = new StringBuilder();
            body.Append("{\"executor_id\":\"");
            body.Append(JsonEscape(ExecutorId()));
            body.Append("\",\"acks\":[");
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0)
                {
                    body.Append(",");
                }
                body.Append(rows[i].Json);
            }
            body.Append("]}");
            PostJson("/api/execution/acks", body.ToString());
            for (int i = 0; i < rows.Length; i++)
            {
                MarkAckSent(rows[i].Id);
            }
            _acksPosted += rows.Length;
            _ackLabel.Text = "回执回传 " + _acksPosted;
            AddLog("posted " + rows.Length + " ack(s), ExecutorId=" + ExecutorId());
            return rows.Length;
        }

        private string GetText(string pathAndQuery)
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(ApiBase() + pathAndQuery);
            request.Method = "GET";
            request.Timeout = 15000;
            AddBridgeToken(request);
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                return reader.ReadToEnd();
            }
        }

        private string PostJson(string path, string body)
        {
            byte[] data = Encoding.UTF8.GetBytes(body);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(ApiBase() + path);
            request.Method = "POST";
            request.ContentType = "application/json";
            request.ContentLength = data.Length;
            request.Timeout = 15000;
            AddBridgeToken(request);
            using (Stream stream = request.GetRequestStream())
            {
                stream.Write(data, 0, data.Length);
            }
            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    string text = reader.ReadToEnd();
                    if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
                    {
                        throw new Exception("HTTP " + ((int)response.StatusCode).ToString() + " " + text);
                    }
                    return text;
                }
            }
            catch (WebException ex)
            {
                string detail = ex.Message;
                if (ex.Response != null)
                {
                    using (StreamReader reader = new StreamReader(ex.Response.GetResponseStream(), Encoding.UTF8))
                    {
                        detail += " " + reader.ReadToEnd();
                    }
                }
                throw new Exception(detail);
            }
        }

        private void AddBridgeToken(HttpWebRequest request)
        {
            string token = _tokenBox.Text.Trim();
            if (token.Length > 0)
            {
                request.Headers["X-Bridge-Token"] = token;
            }
        }

        private void MarkSourceSent(string id)
        {
            if (_sourceSent.ContainsKey(id))
            {
                return;
            }
            _sourceSent[id] = true;
            _sourceSentCount++;
            File.AppendAllText(_sourceSentFile, id + Environment.NewLine, Encoding.UTF8);
            _sourceSentLabel.Text = "源成交 " + _sourceSentCount;
        }

        private void MarkAckSent(string id)
        {
            if (_ackSent.ContainsKey(id))
            {
                return;
            }
            _ackSent[id] = true;
            File.AppendAllText(AckSentFile(), id + Environment.NewLine, Encoding.UTF8);
        }

        private void PauseBridge()
        {
            _running = false;
            _timer.Stop();
            SetStatus("已暂停", Color.FromArgb(181, 71, 8));
            _detail.Text = "点击“一键安装并启动”继续。";
        }

        private void OpenLogFolder()
        {
            Directory.CreateDirectory(_commonDir);
            Process.Start("explorer.exe", "\"" + _commonDir + "\"");
        }

        private void OpenGuide()
        {
            try
            {
                Process.Start(ApiBase() + "/static/bridge_quickstart.html");
            }
            catch (Exception ex)
            {
                AddLog("open guide failed: " + ex.Message);
            }
        }

        private static string SafeFilePart(string value)
        {
            string output = value ?? "";
            char[] bad = Path.GetInvalidFileNameChars();
            for (int i = 0; i < bad.Length; i++)
            {
                output = output.Replace(bad[i], '_');
            }
            output = output.Replace('\\', '_').Replace('/', '_').Replace(':', '_').Replace('|', '_');
            return output.Length == 0 ? "executor" : output;
        }

        private static string MatchJsonString(string line, string key)
        {
            Match match = Regex.Match(line, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"([^\"]*)\"");
            return match.Success ? match.Groups[1].Value : "";
        }

        private static string MatchJsonNumber(string line, string key)
        {
            Match match = Regex.Match(line, "\"" + Regex.Escape(key) + "\"\\s*:\\s*([0-9]+)");
            return match.Success ? match.Groups[1].Value : "";
        }

        private static string JsonEscape(string value)
        {
            if (value == null)
            {
                return "";
            }
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }

        private static string JsonStringArray(ArrayList values)
        {
            StringBuilder body = new StringBuilder();
            body.Append("[");
            for (int i = 0; i < values.Count; i++)
            {
                if (i > 0)
                {
                    body.Append(",");
                }
                body.Append("\"");
                body.Append(JsonEscape(Convert.ToString(values[i])));
                body.Append("\"");
            }
            body.Append("]");
            return body.ToString();
        }

        private static string ValueOf(Dictionary<string, object> dict, string key)
        {
            if (dict == null || !dict.ContainsKey(key) || dict[key] == null)
            {
                return "";
            }
            return Convert.ToString(dict[key]);
        }

        private static string JoinCommandLine(string[] parts)
        {
            StringBuilder line = new StringBuilder();
            for (int i = 0; i < parts.Length; i++)
            {
                if (i > 0)
                {
                    line.Append("|");
                }
                line.Append((parts[i] ?? "").Replace("|", ""));
            }
            return line.ToString();
        }

        private static string Shorten(string value, int max)
        {
            if (value == null || value.Length <= max)
            {
                return value ?? "";
            }
            return value.Substring(0, max) + "...";
        }

        private static string Sha1(string value)
        {
            using (System.Security.Cryptography.SHA1 sha1 = System.Security.Cryptography.SHA1.Create())
            {
                byte[] hash = sha1.ComputeHash(Encoding.UTF8.GetBytes(value ?? ""));
                StringBuilder text = new StringBuilder();
                for (int i = 0; i < hash.Length; i++)
                {
                    text.Append(hash[i].ToString("x2"));
                }
                return text.ToString();
            }
        }

        private sealed class SourceRow
        {
            public readonly string SourceId;
            public readonly string Ticket;
            public readonly string Id;
            public readonly string Json;

            public SourceRow(string sourceId, string ticket, string id, string json)
            {
                SourceId = sourceId;
                Ticket = ticket;
                Id = id;
                Json = json;
            }
        }

        private sealed class AckRow
        {
            public readonly string Id;
            public readonly string Json;

            public AckRow(string id, string json)
            {
                Id = id;
                Json = json;
            }
        }
    }
}
