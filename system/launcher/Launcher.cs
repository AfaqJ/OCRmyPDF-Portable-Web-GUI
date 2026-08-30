// Document OCR launcher.
//
// This is the thing a user double-clicks. It does one job: find
// system\native_gui.ps1 next to itself, start Windows PowerShell on it with no
// window, and exit. Nothing is packed inside this .exe -- app\ and system\ sit
// beside it in the folder, exactly as they always have.
//
// Why an .exe when START OCR.bat already works: a .bat is run by cmd.exe, and
// cmd.exe always gets a console window, however briefly. Built with
// /target:winexe there is no console at any point.
//
// It adds no requirement to the target machine. It targets .NET Framework 4.x,
// which is already there -- native_gui.ps1 draws its window with WinForms under
// PowerShell 5.1, and that IS .NET Framework.
//
// Built by "Build Launcher.bat" with the C# compiler that ships inside Windows.
// Nothing is installed to build it or to run it. Keep this C# 5 compatible:
// that compiler is from 2012 and has no string interpolation.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static int Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string gui = Path.Combine(dir, "system\\native_gui.ps1");
        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");

        // A hidden process cannot report anything, so the two things that can be
        // wrong before it starts are checked here and shown in a dialog. Past
        // that point native_gui.ps1 has its own trap and writes to system\logs.
        if (!File.Exists(gui))
        {
            return Fail("The download is incomplete - this file is missing:\n\n" + gui +
                        "\n\nExtract the ZIP again, whole.");
        }
        if (!File.Exists(powershell))
        {
            return Fail("Windows PowerShell was not found where it should be:\n\n" + powershell);
        }

        // The script path is quoted because it is pasted into a command line.
        // An unquoted path is what killed the .bat launcher twice: once on its
        // own folder being called "...-dotnet-ocr (1)", once in Get-PageCount.
        ProcessStartInfo psi = new ProcessStartInfo(powershell,
            "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + gui + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;

        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            return Fail("Document OCR could not start.\n\n" + ex.Message);
        }
        return 0;
    }

    private static int Fail(string message)
    {
        MessageBox.Show(message, "Document OCR",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
        return 1;
    }
}
