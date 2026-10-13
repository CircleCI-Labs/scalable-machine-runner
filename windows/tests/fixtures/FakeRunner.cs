// Stand-in for circleci-runner.exe in tests\Test-StopHandling.ps1 and tests\Test-Persistent.ps1. Compile with
// csc.exe (it ships with .NET Framework on every Windows host). "FakeRunner.exe machine" pretends to be running
// a job for FAKE_JOB_SECONDS. Like the real runner (a Go program, which turns a console shutdown event into
// SIGTERM and drains), it keeps working when it is told to stop, and exits 0 when the job is done.
//
// It prints what a job could see, never the token itself:
//   FAKERUNNER identity computer=<COMPUTERNAME> instance=<SMR_INSTANCE_ID> mode=<..> idle_timeout=<..> token_in_env=<True|False>
//   FAKERUNNER config=<path of --config> config_has_token=<True|False>   (whether the file can be read and has an auth_token)
// and, when FAKE_MARKER_DIR is set, lists the marker files left there by earlier containers and adds one:
//   FAKERUNNER markers=<names, comma separated>
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class FakeRunner
{
    private delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    private static HandlerRoutine keepAlive;
    private static volatile int firstEvent = -1;

    private static bool OnEvent(uint ctrlType)
    {
        if (firstEvent < 0)
        {
            firstEvent = (int)ctrlType;
            Console.Out.WriteLine("FAKERUNNER event=" + ctrlType + " draining: the job keeps running");
            Console.Out.Flush();
        }
        if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            // Windows ends the process when this handler returns; the Go runtime blocks here forever.
            Thread.Sleep(Timeout.Infinite);
        }
        return true;
    }

    public static int Main(string[] args)
    {
        int seconds = 40;
        string configured = Environment.GetEnvironmentVariable("FAKE_JOB_SECONDS");
        if (!string.IsNullOrEmpty(configured)) { seconds = int.Parse(configured); }
        keepAlive = new HandlerRoutine(OnEvent);
        SetConsoleCtrlHandler(keepAlive, true);
        Console.Out.WriteLine("FAKERUNNER started args=" + string.Join(" ", args) + " job_seconds=" + seconds);
        Console.Out.WriteLine("FAKERUNNER identity computer=" + Environment.GetEnvironmentVariable("COMPUTERNAME")
            + " instance=" + Environment.GetEnvironmentVariable("SMR_INSTANCE_ID")
            + " mode=" + Environment.GetEnvironmentVariable("CIRCLECI_RUNNER_MODE")
            + " idle_timeout=" + Environment.GetEnvironmentVariable("CIRCLECI_RUNNER_IDLE_TIMEOUT")
            + " token_in_env=" + !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CIRCLECI_RUNNER_API_AUTH_TOKEN")));
        string configPath = "";
        for (int i = 0; i + 1 < args.Length; i++) { if (args[i] == "--config" || args[i] == "-c") { configPath = args[i + 1]; } }
        bool hasToken = false;
        if (configPath != "")
        {
            try { hasToken = File.ReadAllText(configPath).Contains("auth_token:"); } catch (Exception) { hasToken = false; }
        }
        Console.Out.WriteLine("FAKERUNNER config=" + configPath + " config_has_token=" + hasToken);
        string markerDir = Environment.GetEnvironmentVariable("FAKE_MARKER_DIR");
        if (!string.IsNullOrEmpty(markerDir))
        {
            string[] files = Directory.GetFiles(markerDir, "*.marker");
            for (int i = 0; i < files.Length; i++) { files[i] = Path.GetFileName(files[i]); }
            Console.Out.WriteLine("FAKERUNNER markers=" + string.Join(",", files));
            File.WriteAllText(Path.Combine(markerDir, Guid.NewGuid().ToString("N") + ".marker"), "x");
        }
        Console.Out.Flush();
        for (int i = 0; i < seconds; i++) { Thread.Sleep(1000); }
        Console.Out.WriteLine("FAKERUNNER job-finished event=" + firstEvent);
        Console.Out.Flush();
        return 0;
    }
}
