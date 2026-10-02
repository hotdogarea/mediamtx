using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using Boleme.TrollDeploy.Models;

namespace Boleme.TrollDeploy.Services;

public sealed class DeviceProbe
{
    private const string AppleVendorId = "VID_05AC";
    private const string ExpectedTrollRestoreSha256 = "78F032B448B544C23FFECE9E9EB08DCFC7CF3535EEADEE59D44C12BA2FB5F387";
    private readonly AppleMobileDeviceClient appleClient = new();
    private readonly CompatibilityService compatibilityService = new();
    private long cachedToolLength = -1;
    private DateTime cachedToolWriteTimeUtc;
    private bool cachedToolHashValid;

    public async Task<PreflightResult> RunAsync(CancellationToken cancellationToken = default)
    {
        string toolPath = Path.Combine(AppContext.BaseDirectory, "TrollRestore.exe");
        bool toolExists = File.Exists(toolPath);
        bool toolHashValid = toolExists && await ValidateToolHashAsync(toolPath, cancellationToken);

        string deviceOutput = await QueryConnectedDevicesAsync(cancellationToken);
        bool appleUsbPresent = deviceOutput.Contains(AppleVendorId, StringComparison.OrdinalIgnoreCase);
        bool phonePresent = appleUsbPresent &&
            (deviceOutput.Contains("iPhone", StringComparison.OrdinalIgnoreCase) ||
             deviceOutput.Contains("iPad", StringComparison.OrdinalIgnoreCase) ||
             deviceOutput.Contains("iPod", StringComparison.OrdinalIgnoreCase) ||
             deviceOutput.Contains("Apple Mobile Device", StringComparison.OrdinalIgnoreCase));

        DeviceInfo? deviceInfo = null;
        string deviceDetail;
        CompatibilityResult compatibility;

        if (!phonePresent)
        {
            deviceDetail = "请连接、解锁设备并点击“信任”";
            compatibility = CompatibilityResult.Unsupported("等待读取设备信息");
        }
        else
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(6));
                deviceInfo = await appleClient.ReadDeviceInfoAsync(timeout.Token);
                if (deviceInfo is null || string.IsNullOrWhiteSpace(deviceInfo.ProductVersion))
                {
                    deviceDetail = "已连接，但尚未取得设备授权";
                    compatibility = CompatibilityResult.Unsupported("请解锁设备并点击“信任”后重新检测");
                }
                else
                {
                    deviceDetail = $"{deviceInfo.DisplayName} · {deviceInfo.ProductVersion}";
                    compatibility = await compatibilityService.MatchAsync(deviceInfo, cancellationToken);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                deviceDetail = "已连接，但无法读取详细信息";
                compatibility = CompatibilityResult.Unsupported(ex.Message);
            }
        }

        return new PreflightResult(
            new CheckItem(
                "部署组件",
                toolHashValid,
                !toolExists
                    ? "未找到 TrollRestore.exe"
                    : toolHashValid
                        ? "TrollRestore 已就绪 · 校验通过"
                        : "文件校验失败，请重新解压原始发布包"),
            new CheckItem(
                "Apple 设备",
                deviceInfo is not null,
                deviceDetail),
            new CheckItem(
                "苹果 USB 驱动",
                appleUsbPresent,
                appleUsbPresent ? "驱动工作正常" : "未发现苹果 USB 设备，请检查 iTunes 驱动"),
            deviceInfo,
            compatibility,
            toolPath);
    }

    private async Task<bool> ValidateToolHashAsync(string toolPath, CancellationToken cancellationToken)
    {
        var info = new FileInfo(toolPath);
        if (info.Length == cachedToolLength && info.LastWriteTimeUtc == cachedToolWriteTimeUtc)
        {
            return cachedToolHashValid;
        }

        await using FileStream stream = File.OpenRead(toolPath);
        byte[] hash = await SHA256.HashDataAsync(stream, cancellationToken);
        cachedToolLength = info.Length;
        cachedToolWriteTimeUtc = info.LastWriteTimeUtc;
        cachedToolHashValid = Convert.ToHexString(hash).Equals(ExpectedTrollRestoreSha256, StringComparison.OrdinalIgnoreCase);
        return cachedToolHashValid;
    }

    private static async Task<string> QueryConnectedDevicesAsync(CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "pnputil.exe",
            Arguments = "/enum-devices /connected",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return string.Empty;
            }

            string output = await process.StandardOutput.ReadToEndAsync(cancellationToken);
            string error = await process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            return output + Environment.NewLine + error;
        }
        catch
        {
            return string.Empty;
        }
    }
}
