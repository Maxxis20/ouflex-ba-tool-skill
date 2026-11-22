// AgentHost: runs Ouflex BA Tool (ProjectManager.exe) in-process and executes PowerShell
// scripts dropped into <work>\host-<instance>\in\*.ps1 on the tool's UI thread.
// Output of script X.ps1 is written to <work>\host-<instance>\out\X.txt (then X.done).
// Must sit in the tool's own folder (it loads the tool's exe and DLLs from beside itself). Compiled by `setup`.
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

public static class AgentHost
{
    static Runspace rs;
    static Timer timer;
    static bool busy;
    static string Root = @"C:\agentwork\host";
    public static Assembly ToolAssembly;

    [STAThread]
    public static int Main(string[] args)
    {
        // usage: AgentHost.exe [--work <folder>] [--name <instance>] [--exe <target.exe>] [target args...]
        string target = "ProjectManager.exe"; string work = @"C:\agentwork"; string inst = null;
        var rest = new System.Collections.Generic.List<string>();
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--work" && i + 1 < args.Length) { work = args[++i].TrimEnd('\\'); }
            else if (args[i] == "--name" && i + 1 < args.Length) { inst = args[++i]; }
            else if (args[i] == "--exe" && i + 1 < args.Length) { target = args[++i]; }
            else rest.Add(args[i]);
        }
        args = rest.ToArray();
        Root = work + (inst == null ? @"\host" : @"\host-" + inst);
        Directory.CreateDirectory(Root + @"\in");
        Directory.CreateDirectory(Root + @"\out");
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        Environment.CurrentDirectory = dir;
        try {
            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;
            rs = RunspaceFactory.CreateRunspace(iss);
            rs.ApartmentState = System.Threading.ApartmentState.STA;
            rs.Open();
            // No controls may exist before the tool's Main runs; create the timer lazily on first idle.
            Application.Idle += OnFirstIdle;
            ToolAssembly = Assembly.LoadFrom(Path.Combine(dir, target));
            File.WriteAllText(Root + @"\host.log", "started " + DateTime.Now.ToString("o") + "\r\n");
            MethodInfo ep = ToolAssembly.EntryPoint;
            object[] p = ep.GetParameters().Length == 0 ? null : new object[] { args };
            ep.Invoke(null, p);
        } catch (Exception e) {
            File.AppendAllText(Root + @"\host.log", "FATAL " + e.ToString() + "\r\n");
            return 1;
        }
        File.AppendAllText(Root + @"\host.log", "exited " + DateTime.Now.ToString("o") + "\r\n");
        return 0;
    }

    static void OnFirstIdle(object sender, EventArgs e)
    {
        Application.Idle -= OnFirstIdle;
        timer = new Timer();
        timer.Interval = 300;
        timer.Tick += Tick;
        timer.Start();
        File.AppendAllText(Root + @"\host.log", "timer armed " + DateTime.Now.ToString("o") + "\r\n");
    }

    static void Tick(object sender, EventArgs e)
    {
        if (busy) return;
        busy = true;
        try {
            foreach (string f in Directory.GetFiles(Root + @"\in", "*.ps1").OrderBy(x => x)) {
                string name = Path.GetFileNameWithoutExtension(f);
                string script = File.ReadAllText(f, Encoding.UTF8);
                File.Delete(f);
                var sb = new StringBuilder();
                try {
                    using (PowerShell ps = PowerShell.Create()) {
                        ps.Runspace = rs;
                        ps.AddScript(script, false).AddCommand("Out-String").AddParameter("Width", 400);
                        foreach (PSObject o in ps.Invoke()) sb.Append(o == null ? "" : o.ToString());
                        foreach (ErrorRecord er in ps.Streams.Error) {
                            sb.AppendLine("ERR: " + er.ToString());
                            if (er.Exception != null && er.Exception.InnerException != null) sb.AppendLine("  inner: " + er.Exception.InnerException.ToString());
                            sb.AppendLine("  at " + er.ScriptStackTrace);
                        }
                    }
                } catch (Exception ex) {
                    sb.AppendLine("EXC: " + ex.ToString());
                }
                File.WriteAllText(Root + @"\out\" + name + ".txt", sb.ToString(), Encoding.UTF8);
                File.WriteAllText(Root + @"\out\" + name + ".done", "");
            }
        } finally { busy = false; }
    }
}
