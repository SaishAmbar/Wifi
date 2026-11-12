// Tiny no-window launcher for the RVCE tool. Build with app\Build-Launchers.ps1.
// It starts Windows PowerShell with NO console window (so Windows Terminal never opens);
// the scripts show their own dialog boxes.
//
//   RVCE-Connect.exe          -> app\RVCE-Connect.ps1 -Gui
//   RVCE-Stop.exe             -> app\RVCE-Stop.ps1 -Gui
//   RVCE-Connect.exe /watch   -> app\RVCE-Watch.ps1   (used by the "start when I log in" shortcut)
//
// The same program is used for both; it picks the script from its own file name.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

static class RvceLauncher
{
    [STAThread]
    static int Main(string[] args)
    {
        string self = Assembly.GetEntryAssembly().Location;
        string appDir = Path.Combine(Path.GetDirectoryName(self), "app");
        string name = Path.GetFileNameWithoutExtension(self);

        string script;
        string extra = "";
        if (args.Length > 0 && string.Equals(args[0], "/watch", StringComparison.OrdinalIgnoreCase))
        {
            script = "RVCE-Watch.ps1";
        }
        else if (name.IndexOf("Stop", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            script = "RVCE-Stop.ps1"; extra = " -Gui";
        }
        else
        {
            script = "RVCE-Connect.ps1"; extra = " -Gui";
        }

        string path = Path.Combine(appDir, script);
        if (!File.Exists(path))
        {
            MessageBox.Show("Missing file:\n" + path + "\n\nKeep the 'app' folder next to this program.", "RVCE Wi-Fi",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                         @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + path + "\"" + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;      // no console window at all
        psi.WorkingDirectory = appDir;
        Process.Start(psi);
        return 0;
    }
}
