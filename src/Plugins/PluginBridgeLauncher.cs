using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace LiteMonitor.src.Plugins
{
    internal static class PluginBridgeLauncher
    {
        private static readonly SemaphoreSlim StartLock = new(1, 1);
        private static DateTime _lastStartAttempt = DateTime.MinValue;

        public static void EnsureStartedIfNeeded(Settings settings)
        {
            if (settings?.PluginInstances == null) return;

            bool needsBridge = settings.PluginInstances.Any(x =>
                x.Enabled &&
                (string.Equals(x.TemplateId, "LocalSubTraffic", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(x.TemplateId, "LocalVpsTraffic", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(x.Id, "LocalSubTraffic", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(x.Id, "LocalVpsTraffic", StringComparison.OrdinalIgnoreCase)));

            if (!needsBridge) return;

            _ = Task.Run(EnsureStartedAsync);
        }

        private static async Task EnsureStartedAsync()
        {
            if (!await StartLock.WaitAsync(0)) return;
            try
            {
                if ((DateTime.Now - _lastStartAttempt).TotalSeconds < 10) return;
                _lastStartAttempt = DateTime.Now;

                var bridgeDir = Path.Combine(AppContext.BaseDirectory, "resources", "plugins", "LiteMonitorBridge");
                var scriptPath = Path.Combine(bridgeDir, "Start-LiteMonitorBridge.ps1");
                var configPath = Path.Combine(bridgeDir, "config.json");

                if (!File.Exists(scriptPath))
                {
                    Debug.WriteLine("LiteMonitor bridge script not found.");
                    return;
                }

                if (!File.Exists(configPath))
                {
                    Debug.WriteLine("LiteMonitor bridge config.json not found.");
                    return;
                }

                if (await IsTcpOpenAsync("127.0.0.1", 18786, 500)) return;

                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    WorkingDirectory = bridgeDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                startInfo.ArgumentList.Add("-NoProfile");
                startInfo.ArgumentList.Add("-ExecutionPolicy");
                startInfo.ArgumentList.Add("Bypass");
                startInfo.ArgumentList.Add("-File");
                startInfo.ArgumentList.Add(scriptPath);

                Process.Start(startInfo);
                Debug.WriteLine("LiteMonitor bridge auto-start requested.");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"LiteMonitor bridge auto-start failed: {ex.Message}");
            }
            finally
            {
                StartLock.Release();
            }
        }

        private static async Task<bool> IsTcpOpenAsync(string host, int port, int timeoutMs)
        {
            try
            {
                using var client = new TcpClient();
                var connectTask = client.ConnectAsync(host, port);
                var timeoutTask = Task.Delay(timeoutMs);
                var completed = await Task.WhenAny(connectTask, timeoutTask);
                return completed == connectTask && client.Connected;
            }
            catch
            {
                return false;
            }
        }
    }
}
