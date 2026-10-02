using System.Diagnostics;
using System.IO;

namespace Boleme.TrollDeploy.Services;

public sealed record RunnerResult(bool Success, int ExitCode, string Summary);

public sealed class TrollRestoreRunner
{
    public event Action<string>? OutputReceived;
    public event Action<string>? StageChanged;

    public async Task<RunnerResult> RunAsync(string executablePath, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executablePath,
            WorkingDirectory = Path.GetDirectoryName(executablePath) ?? AppContext.BaseDirectory,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, args) => HandleLine(args.Data);
        process.ErrorDataReceived += (_, args) => HandleLine(args.Data);

        StageChanged?.Invoke("正在启动手机部署组件…");
        if (!process.Start())
        {
            return new RunnerResult(false, -1, "无法启动 TrollRestore");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        // TrollRestore asks for the target system app. Writing early is safe: stdin buffers
        // the answer until the tool reaches its prompt.
        await process.StandardInput.WriteLineAsync("Tips");
        await process.StandardInput.FlushAsync(cancellationToken);
        StageChanged?.Invoke("正在配置 Tips，请保持数据线连接…");

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            throw;
        }

        if (process.ExitCode == 0)
        {
            StageChanged?.Invoke("电脑端部署已完成");
            return new RunnerResult(true, 0, "TrollRestore 已正常结束");
        }

        return new RunnerResult(false, process.ExitCode, $"部署组件退出，错误码 {process.ExitCode}");
    }

    private void HandleLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        OutputReceived?.Invoke(line.Trim());
        string normalized = line.ToLowerInvariant();

        if (normalized.Contains("backup"))
        {
            StageChanged?.Invoke("正在准备设备数据…");
        }
        else if (normalized.Contains("restore"))
        {
            StageChanged?.Invoke("正在写入手机环境…");
        }
        else if (normalized.Contains("reboot") || normalized.Contains("restart"))
        {
            StageChanged?.Invoke("手机正在重新启动…");
        }
    }
}
