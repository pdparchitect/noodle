// Noodle's agent in a Windows computer. setup.ps1 compiles it with the .NET Framework's own compiler
// at the first sign-in and starts it at every sign-in. It talks to Noodle Computer over the
// virtio-serial port "org.noodle.agent"; there is no network listener.
//
// Frame: u32 length (of everything after it), u8 type, u32 channel, payload; little-endian.
// Mac -> Windows:
//   1 exec {cmd, pty, cols, rows, cwd}   2 stdin   3 resize (u16 cols, u16 rows)   4 close stdin   5 kill
//   10 list path   11 read {path, version}   12 write begin path   14 write data   15 write end   23 write cancel
//   16 delete path   17 mkdir path   18 stat path   19 rename {path, destination}   22 copy {path, version, destination}
//   20 shut down   24 restart   21 ping
// Windows -> Mac:
//   100 hello {agent, computer, user, home}   101 stdout   103 stderr   102 exit (i32)
//   110 result (JSON)   111 error (text)   112 data   113 end of data
// Paths are Windows paths in UTF-8. An empty list path lists the drives.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

namespace Noodle {
    static class Agent {
        const string PortPath = @"\\.\Global\org.noodle.agent";
        const string Version = "7";
        // Windows' serial driver refuses large single reads and writes ("Insufficient system resources"), so the
        // port is read and written a page at a time, whatever the size of a frame.
        const int PortChunk = 4096;
        static FileStream port;
        static string lastReason;
        static readonly object writeLock = new object();
        static readonly Dictionary<uint, Session> sessions = new Dictionary<uint, Session>();
        static readonly Dictionary<uint, Upload> uploads = new Dictionary<uint, Upload>();
        static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        static readonly string logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "agent.log");

        sealed class Upload { public string Path, Temporary; public FileStream Stream; }

        static void Main() {
            AppDomain.CurrentDomain.UnhandledException += (sender, e) => Log("crashed: " + e.ExceptionObject);
            // Windows PowerShell's first start after boot takes about a minute; doing it now makes the first
            // Terminal quick.
            ThreadPool.QueueUserWorkItem(_ => {
                try {
                    var warm = Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -Command exit") {
                        UseShellExecute = false, CreateNoWindow = true });
                    warm.WaitForExit();
                } catch (Exception e) { Log("warming PowerShell: " + e.Message); }
            });
            while (true) {
                try {
                    var h = Native.CreateFile(PortPath, 0xC0000000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
                    if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "open " + PortPath);
                    port = new FileStream(h, FileAccess.ReadWrite, 1, true);
                    Log("connected");
                    Hello();
                    ReadLoop();
                } catch (Exception e) {
                    Log(e.ToString());
                    lastReason = e.Message;
                }
                try { if (port != null) port.Dispose(); } catch { }
                Thread.Sleep(2000);
            }
        }

        public static void Log(string s) {
            try {
                if (File.Exists(logPath) && new FileInfo(logPath).Length > (1 << 20)) File.Delete(logPath);
                File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + s + "\r\n");
            } catch { }
        }

        static void Hello() {
            Send(100, 0, Encoding.UTF8.GetBytes(json.Serialize(new Dictionary<string, object> {
                { "agent", Version }, { "computer", Environment.MachineName }, { "user", Environment.UserName },
                { "home", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
                { "reason", lastReason }
            })));
        }

        public static void Send(byte type, uint channel, byte[] payload, int count = -1) {
            if (count < 0) count = payload == null ? 0 : payload.Length;
            var frame = new byte[9 + count];
            BitConverter.GetBytes((uint)(5 + count)).CopyTo(frame, 0);
            frame[4] = type;
            BitConverter.GetBytes(channel).CopyTo(frame, 5);
            if (count > 0) Buffer.BlockCopy(payload, 0, frame, 9, count);
            lock (writeLock) {
                for (int o = 0; o < frame.Length; o += PortChunk) {
                    // When the Mac is slow to take what Windows sends, the driver runs out of buffers and says so
                    // ("Insufficient system resources") rather than waiting; it clears once the Mac catches up.
                    for (int attempt = 0; ; attempt++) {
                        try { port.Write(frame, o, Math.Min(PortChunk, frame.Length - o)); break; }
                        catch (IOException e) {
                            if ((e.HResult & 0xFFFF) != 1450 || attempt >= 3000) throw;
                            Thread.Sleep(10);
                        }
                    }
                }
                port.Flush();
            }
        }

        static void SendError(uint ch, Exception e) { Send(111, ch, Encoding.UTF8.GetBytes(e.Message)); }
        static void SendResult(uint ch, object o) { Send(110, ch, Encoding.UTF8.GetBytes(json.Serialize(o))); }

        static void ReadExact(byte[] b, int n) {
            int o = 0;
            while (o < n) {
                int r;
                try { r = port.Read(b, o, Math.Min(PortChunk, n - o)); }
                catch (IOException e) {
                    if ((e.HResult & 0xFFFF) != 1450) throw;
                    Thread.Sleep(10);
                    continue;
                }
                if (r <= 0) throw new EndOfStreamException("port closed");
                o += r;
            }
        }

        static void ReadLoop() {
            var head = new byte[4];
            while (true) {
                ReadExact(head, 4);
                int len = (int)BitConverter.ToUInt32(head, 0);
                if (len < 5 || len > (64 << 20)) throw new InvalidDataException("bad frame length " + len);
                var frame = new byte[len];
                ReadExact(frame, len);
                byte type = frame[0];
                uint ch = BitConverter.ToUInt32(frame, 1);
                var payload = new byte[len - 5];
                Buffer.BlockCopy(frame, 5, payload, 0, payload.Length);
                // Listings and reads must not hold up terminal input; an upload's frames stay in order.
                if (type == 10 || type == 11 || (type >= 16 && type <= 19) || type == 22) {
                    ThreadPool.QueueUserWorkItem(_ => { try { Handle(type, ch, payload); } catch (Exception e) { SendError(ch, e); } });
                } else {
                    try { Handle(type, ch, payload); } catch (Exception e) { SendError(ch, e); }
                }
            }
        }

        static string Text(byte[] p) { return Encoding.UTF8.GetString(p); }
        static Dictionary<string, object> Object(byte[] p) { return json.Deserialize<Dictionary<string, object>>(Text(p)); }

        static void Handle(byte type, uint ch, byte[] p) {
            Session s;
            switch (type) {
                case 1: {
                    var req = Object(p);
                    s = new Session(ch, (string)req["cmd"], req.ContainsKey("pty") && (bool)req["pty"],
                        req.ContainsKey("cols") ? Convert.ToInt16(req["cols"]) : (short)120,
                        req.ContainsKey("rows") ? Convert.ToInt16(req["rows"]) : (short)30,
                        req.ContainsKey("cwd") ? (string)req["cwd"] : null);
                    lock (sessions) sessions[ch] = s;
                    try { s.Start(() => { lock (sessions) sessions.Remove(ch); }); }
                    catch (Exception e) { lock (sessions) sessions.Remove(ch); Log("start " + ch + " failed: " + e.Message); throw; }
                    break;
                }
                case 2: if (Find(ch, out s)) s.Input(p); break;
                case 3: if (Find(ch, out s)) s.Resize(BitConverter.ToInt16(p, 0), BitConverter.ToInt16(p, 2)); break;
                case 4: if (Find(ch, out s)) s.CloseInput(); break;
                case 5: if (Find(ch, out s)) s.Kill(); break;
                case 10: SendResult(ch, List(Text(p))); break;
                case 18: SendResult(ch, Describe(Info(Text(p)))); break;
                case 11: {
                    var req = Object(p);
                    var path = (string)req["path"];
                    using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                        if (req.ContainsKey("version") && (string)req["version"] != FileVersion(new FileInfo(path)))
                            throw new IOException("The file changed. Refresh and try again.");
                        var buf = new byte[256 * 1024];
                        int n;
                        while ((n = f.Read(buf, 0, buf.Length)) > 0) Send(112, ch, buf, n);
                    }
                    Send(113, ch, null);
                    break;
                }
                case 12: {
                    var path = Text(p);
                    var temporary = Path.Combine(Path.GetDirectoryName(path), "." + Path.GetFileName(path) + ".noodle-" + ch);
                    var upload = new Upload { Path = path, Temporary = temporary, Stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write) };
                    lock (uploads) uploads[ch] = upload;
                    break;
                }
                case 14: { Upload u; lock (uploads) u = uploads[ch]; u.Stream.Write(p, 0, p.Length); break; }
                case 15: {
                    Upload u;
                    lock (uploads) { u = uploads[ch]; uploads.Remove(ch); }
                    long size = u.Stream.Length;
                    u.Stream.Dispose();
                    if (File.Exists(u.Path)) File.Delete(u.Path);
                    File.Move(u.Temporary, u.Path);
                    SendResult(ch, new Dictionary<string, object> { { "size", size } });
                    break;
                }
                case 23: {
                    Upload u = null;
                    lock (uploads) { if (uploads.TryGetValue(ch, out u)) uploads.Remove(ch); }
                    if (u != null) { u.Stream.Dispose(); try { File.Delete(u.Temporary); } catch { } }
                    break;
                }
                case 16: {
                    var path = Text(p);
                    if (Directory.Exists(path)) Directory.Delete(path, true); else File.Delete(path);
                    SendResult(ch, true);
                    break;
                }
                case 17: Directory.CreateDirectory(Text(p)); SendResult(ch, true); break;
                case 19: {
                    var req = Object(p);
                    string from = (string)req["path"], to = (string)req["destination"];
                    if (File.Exists(to) || Directory.Exists(to)) throw new IOException("An item with that name already exists.");
                    if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
                    SendResult(ch, true);
                    break;
                }
                case 22: {
                    var req = Object(p);
                    string from = (string)req["path"], to = (string)req["destination"];
                    if ((string)req["version"] != FileVersion(new FileInfo(from))) throw new IOException("The file changed. Refresh and try again.");
                    File.Copy(from, to, false);
                    SendResult(ch, true);
                    break;
                }
                case 20: Process.Start("shutdown.exe", "/s /t 0"); SendResult(ch, true); break;
                case 24: Process.Start("shutdown.exe", "/r /t 0"); SendResult(ch, true); break;
                case 21: Hello(); break;
                default: throw new InvalidDataException("unknown frame type " + type);
            }
        }

        static bool Find(uint ch, out Session s) { lock (sessions) return sessions.TryGetValue(ch, out s); }

        static string FileVersion(FileInfo f) { return f.LastWriteTimeUtc.Ticks + "-" + f.Length; }

        static FileSystemInfo Info(string path) {
            if (Directory.Exists(path)) return new DirectoryInfo(path);
            if (File.Exists(path)) return new FileInfo(path);
            throw new FileNotFoundException("No such file or folder.", path);
        }

        static Dictionary<string, object> Describe(FileSystemInfo i) {
            bool dir = (i.Attributes & FileAttributes.Directory) != 0;
            bool link = (i.Attributes & FileAttributes.ReparsePoint) != 0;
            var file = i as FileInfo;
            return new Dictionary<string, object> {
                { "name", i.Name }, { "kind", link ? "symlink" : dir ? "directory" : "file" },
                { "size", file == null ? 0 : file.Length },
                { "modified", (long)(i.LastWriteTimeUtc - new DateTime(1970, 1, 1)).TotalSeconds },
                { "version", file == null ? i.LastWriteTimeUtc.Ticks.ToString() : FileVersion(file) },
                { "hidden", (i.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0 }
            };
        }

        static object List(string path) {
            var items = new List<object>();
            if (string.IsNullOrEmpty(path)) {
                foreach (var d in DriveInfo.GetDrives()) {
                    if (!d.IsReady) continue;
                    items.Add(new Dictionary<string, object> {
                        { "name", d.Name }, { "kind", "directory" }, { "size", 0 }, { "modified", 0 }, { "version", "" }, { "hidden", false } });
                }
                return items;
            }
            foreach (var i in new DirectoryInfo(path).EnumerateFileSystemInfos()) {
                try { items.Add(Describe(i)); } catch { }
                if (items.Count >= 5000) break;
            }
            return items;
        }
    }

    // One exec: a ConPTY session when pty is set, otherwise plain pipes with separate stdout and stderr.
    sealed class Session {
        readonly uint ch;
        readonly string cmd, cwd;
        readonly bool pty;
        short cols, rows;
        IntPtr hpc = IntPtr.Zero;
        Stream input;
        Process process;
        IntPtr hProcess;

        public Session(uint ch, string cmd, bool pty, short cols, short rows, string cwd) {
            this.ch = ch; this.cmd = cmd; this.pty = pty;
            // A console needs a size; a terminal not laid out yet can report none.
            this.cols = Math.Max(cols, (short)20); this.rows = Math.Max(rows, (short)5);
            this.cwd = string.IsNullOrEmpty(cwd) || !Directory.Exists(cwd) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : cwd;
        }

        public void Start(Action done) {
            if (pty) StartPty(done); else StartPipes(done);
        }

        void StartPipes(Action done) {
            var psi = new ProcessStartInfo("cmd.exe", "/d /s /c \"" + cmd + "\"") {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = cwd,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
            process = Process.Start(psi);
            input = process.StandardInput.BaseStream;
            var outT = Pump(process.StandardOutput.BaseStream, 101);
            var errT = Pump(process.StandardError.BaseStream, 103);
            new Thread(() => {
                try {
                    process.WaitForExit();
                    outT.Join(); errT.Join();
                    Agent.Send(102, ch, BitConverter.GetBytes(process.ExitCode));
                } catch (Exception e) { Agent.Log("command " + ch + ": " + e); }
                done();
            }) { IsBackground = true }.Start();
        }

        void StartPty(Action done) {
            SafeFileHandle inRead, inWrite, outRead, outWrite;
            if (!Native.CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !Native.CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe");
            int hr = Native.CreatePseudoConsole(new Native.COORD { X = cols, Y = rows }, inRead, outWrite, 0, out hpc);
            if (hr != 0) throw new Win32Exception(hr, "CreatePseudoConsole");

            var si = new Native.STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(Native.STARTUPINFOEX));
            var size = IntPtr.Zero;
            Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            si.lpAttributeList = Marshal.AllocHGlobal(size);
            if (!Native.InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref size) ||
                !Native.UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)0x00020016, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ProcThreadAttribute");
            Native.PROCESS_INFORMATION pi;
            if (!Native.CreateProcessW(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0x00080000 | 0x00000400,
                                       IntPtr.Zero, cwd, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess " + cmd);
            Native.CloseHandle(pi.hThread);
            hProcess = pi.hProcess;
            Agent.Log("console " + ch + " started " + cmd + " as " + pi.dwProcessId);
            inRead.Dispose(); outWrite.Dispose();
            input = new FileStream(inWrite, FileAccess.Write, 1);
            var outT = Pump(new FileStream(outRead, FileAccess.Read, 1), 101);
            new Thread(() => {
                try {
                    Native.WaitForSingleObject(hProcess, 0xFFFFFFFF);
                    int code;
                    Native.GetExitCodeProcess(hProcess, out code);
                    Native.ClosePseudoConsole(hpc);
                    outT.Join(5000);
                    Native.CloseHandle(hProcess);
                    Marshal.FreeHGlobal(si.lpAttributeList);
                    Agent.Send(102, ch, BitConverter.GetBytes(code));
                    Agent.Log("console " + ch + " exited " + code);
                } catch (Exception e) { Agent.Log("console " + ch + ": " + e); }
                done();
            }) { IsBackground = true }.Start();
        }

        Thread Pump(Stream s, byte type) {
            var t = new Thread(() => {
                var buf = new byte[64 * 1024];
                var started = DateTime.Now;
                bool first = true;
                try {
                    int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0) {
                        if (first) { first = false; Agent.Log("output " + ch + " after " + (int)(DateTime.Now - started).TotalMilliseconds + " ms"); }
                        Agent.Send(type, ch, buf, n);
                    }
                } catch (Exception e) { Agent.Log("output " + ch + ": " + e.Message); }
            }) { IsBackground = true };
            t.Start();
            return t;
        }

        public void Input(byte[] data) { input.Write(data, 0, data.Length); input.Flush(); }
        public void CloseInput() { input.Dispose(); }
        public void Resize(short c, short r) { if (hpc != IntPtr.Zero) Native.ResizePseudoConsole(hpc, new Native.COORD { X = c, Y = r }); }
        public void Kill() {
            if (process != null) { try { process.Kill(); } catch { } }
            else if (hProcess != IntPtr.Zero) Native.TerminateProcess(hProcess, 1);
        }
    }

    static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)] public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
        [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
        [DllImport("kernel32.dll")] public static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr hpc);
        [DllImport("kernel32.dll")] public static extern int ResizePseudoConsole(IntPtr hpc, COORD size);
        [DllImport("kernel32.dll")] public static extern void ClosePseudoConsole(IntPtr hpc);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd,
                                                 ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out int code);
        [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint code);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    }
}
