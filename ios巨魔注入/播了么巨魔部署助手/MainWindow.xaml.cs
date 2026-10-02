using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Boleme.TrollDeploy.Models;
using Boleme.TrollDeploy.Services;

namespace Boleme.TrollDeploy;

public partial class MainWindow : Window
{
    private readonly DeviceProbe deviceProbe = new();
    private readonly TrollRestoreRunner runner = new();
    private readonly AppLog appLog = new();
    private readonly DispatcherTimer refreshTimer;
    private readonly Dictionary<string, CheckBox> prerequisiteChecks = [];
    private CancellationTokenSource? deploymentCancellation;
    private PreflightResult? preflight;
    private bool deploymentRunning;
    private string renderedRouteKey = string.Empty;

    public MainWindow()
    {
        InitializeComponent();

        runner.OutputReceived += line => Dispatcher.Invoke(() => AppendLog(line));
        runner.StageChanged += stage => Dispatcher.Invoke(() => RunningStatusText.Text = stage);

        refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        refreshTimer.Tick += async (_, _) => await RefreshPreflightAsync();

        Loaded += async (_, _) =>
        {
            await RefreshPreflightAsync();
            refreshTimer.Start();
        };

        Closing += (_, args) =>
        {
            if (deploymentRunning)
            {
                var answer = MessageBox.Show(
                    "部署仍在进行。现在退出会中断操作，确定退出吗？",
                    "确认退出",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);
                if (answer != MessageBoxResult.Yes)
                {
                    args.Cancel = true;
                    return;
                }
                deploymentCancellation?.Cancel();
            }
            appLog.Dispose();
        };
    }

    private async Task RefreshPreflightAsync()
    {
        if (deploymentRunning)
        {
            return;
        }

        HeaderStatusText.Text = "正在检测";
        preflight = await deviceProbe.RunAsync();
        RenderCheck(preflight.Tool, ToolIcon, ToolDetail);
        RenderCheck(preflight.Device, DeviceIcon, DeviceDetail);
        RenderCheck(preflight.Driver, DriverIcon, DriverDetail);
        RenderDeviceAndRoute(preflight);
        HeaderStatusText.Text = preflight.CanContinue
            ? "设备受支持"
            : preflight.DeviceInfo is not null
                ? "版本不支持"
                : "等待设备";
        UpdateStartAvailability();
    }

    private void RenderDeviceAndRoute(PreflightResult result)
    {
        if (result.DeviceInfo is null)
        {
            DetectedDeviceText.Text = "尚未读取到设备信息";
            DetectedVersionText.Text = "请连接、解锁设备并点击“信任”";
            DetectedRouteText.Text = $"安装方案：{result.Compatibility.Message}";
        }
        else
        {
            DeviceInfo device = result.DeviceInfo;
            DetectedDeviceText.Text = device.DisplayName;
            DetectedVersionText.Text = $"系统：{device.ProductVersion} · 构建 {device.BuildVersion}";
            DetectedRouteText.Text = result.Compatibility.Supported
                ? $"安装方案：{result.Compatibility.RouteName}"
                : $"暂不支持：{result.Compatibility.Message}";
        }

        string routeKey = result.Compatibility.Supported
            ? result.Compatibility.RouteId
            : $"unsupported:{result.Compatibility.Message}";
        if (routeKey == renderedRouteKey)
        {
            return;
        }

        renderedRouteKey = routeKey;
        prerequisiteChecks.Clear();
        DynamicChecksPanel.Children.Clear();

        if (!result.Compatibility.Supported)
        {
            var message = new TextBlock
            {
                Text = "当前没有可执行的安装确认项",
                Foreground = (Brush)FindResource("MutedBrush"),
                FontSize = 12,
                Margin = new Thickness(0, 7, 0, 7)
            };
            DynamicChecksPanel.Children.Add(message);
            RouteNoticeText.Text = "不支持的设备不会启动底层部署工具。";
            return;
        }

        foreach (PrerequisiteDefinition prerequisite in result.Compatibility.Prerequisites)
        {
            var checkBox = new CheckBox
            {
                Content = prerequisite.Label,
                Tag = prerequisite.Id
            };
            checkBox.Checked += ManualCheck_Changed;
            checkBox.Unchecked += ManualCheck_Changed;
            prerequisiteChecks.Add(prerequisite.Id, checkBox);
            DynamicChecksPanel.Children.Add(checkBox);
        }

        RouteNoticeText.Text = result.Compatibility.Prerequisites.Any(item => item.Id == "find-my")
            ? "安装完成后，助手会提醒重新开启“查找我的 iPhone/iPad”。"
            : "请只确认当前安装方案显示的必要操作。";
    }

    private static void RenderCheck(CheckItem item, TextBlock icon, TextBlock detail)
    {
        icon.Text = item.Passed ? "✓" : "!";
        icon.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString(item.Passed ? "#167D62" : "#C2413B"));
        detail.Text = item.Detail;
    }

    private void UpdateStartAvailability()
    {
        bool confirmationsComplete = prerequisiteChecks.Count > 0 &&
            prerequisiteChecks.Values.All(checkBox => checkBox.IsChecked == true);
        bool checksComplete = preflight?.CanContinue == true;

        StartButton.IsEnabled = confirmationsComplete && checksComplete;
        ReadyHint.Text = checksComplete
            ? confirmationsComplete ? "准备就绪，可以开始部署" : "请完成右侧安装前确认"
            : preflight?.DeviceInfo is not null && preflight.Compatibility.Supported == false
                ? preflight.Compatibility.Message
                : "请先解决自动检查中标记的问题";
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) => await RefreshPreflightAsync();

    private void ManualCheck_Changed(object sender, RoutedEventArgs e) => UpdateStartAvailability();

    private async void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (preflight?.CanContinue != true || !File.Exists(preflight.TrollRestorePath))
        {
            await RefreshPreflightAsync();
            return;
        }

        refreshTimer.Stop();
        ErrorBanner.Visibility = Visibility.Collapsed;
        PreparationPanel.Visibility = Visibility.Collapsed;
        RunningPanel.Visibility = Visibility.Visible;
        SetActiveStep(2);
        HeaderStatusText.Text = "正在部署";
        deploymentRunning = true;
        deploymentCancellation = new CancellationTokenSource(TimeSpan.FromMinutes(25));

        AppendLog($"开始部署；设备：{preflight.DeviceInfo?.DisplayName}；系统：{preflight.DeviceInfo?.ProductVersion}（{preflight.DeviceInfo?.BuildVersion}）；方案：{preflight.Compatibility.RouteName}；目标系统应用：Tips");

        try
        {
            RunnerResult result = await runner.RunAsync(preflight.TrollRestorePath, deploymentCancellation.Token);
            AppendLog(result.Summary);

            if (!result.Success)
            {
                ShowDeploymentError(result.Summary);
                return;
            }

            RunningPanel.Visibility = Visibility.Collapsed;
            PhoneActionPanel.Visibility = Visibility.Visible;
            HeaderStatusText.Text = "等待手机确认";
            SetActiveStep(3);
        }
        catch (OperationCanceledException)
        {
            string reason = deploymentCancellation.IsCancellationRequested
                ? "部署已取消或等待超时。请确认手机连接后重试。"
                : "部署已取消。";
            AppendLog(reason);
            ShowDeploymentError(reason);
        }
        catch (Exception ex)
        {
            AppendLog($"发生错误：{ex.Message}");
            ShowDeploymentError("无法完成部署。请查看日志后重试。\n" + ex.Message);
        }
        finally
        {
            deploymentRunning = false;
            deploymentCancellation?.Dispose();
            deploymentCancellation = null;
        }
    }

    private void ShowDeploymentError(string message)
    {
        RunningPanel.Visibility = Visibility.Collapsed;
        PreparationPanel.Visibility = Visibility.Visible;
        ErrorText.Text = message;
        ErrorBanner.Visibility = Visibility.Visible;
        HeaderStatusText.Text = "需要处理";
        SetActiveStep(1);
        refreshTimer.Start();
        _ = RefreshPreflightAsync();
    }

    private void AppendLog(string message)
    {
        string line = appLog.Write(message);
        LogTextBox.AppendText(line + Environment.NewLine);
        LogTextBox.ScrollToEnd();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        var answer = MessageBox.Show(
            "确定取消当前部署吗？请不要在手机正在重启时拔掉数据线。",
            "取消部署",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (answer == MessageBoxResult.Yes)
        {
            deploymentCancellation?.Cancel();
            CancelButton.IsEnabled = false;
            RunningStatusText.Text = "正在安全停止…";
        }
    }

    private void TrollStoreCheck_Changed(object sender, RoutedEventArgs e) =>
        FinishButton.IsEnabled = TrollStoreCheck.IsChecked == true;

    private void FinishButton_Click(object sender, RoutedEventArgs e)
    {
        AppendLog("用户确认 TrollStore 已安装并可以打开");
        PhoneActionPanel.Visibility = Visibility.Collapsed;
        CompletePanel.Visibility = Visibility.Visible;
        HeaderStatusText.Text = "安装完成";
        SetActiveStep(4);
    }

    private void OpenLogButton_Click(object sender, RoutedEventArgs e)
    {
        string? directory = Path.GetDirectoryName(appLog.FilePath);
        if (directory is null || !Directory.Exists(directory))
        {
            return;
        }

        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{appLog.FilePath}\"") { UseShellExecute = true });
    }

    private void ExitButton_Click(object sender, RoutedEventArgs e) => Close();

    private void SetActiveStep(int activeStep)
    {
        StackPanel[] steps = [Step1, Step2, Step3, Step4];
        Border[] dots = [Step1Dot, Step2Dot, Step3Dot, Step4Dot];

        for (int index = 0; index < steps.Length; index++)
        {
            bool active = index + 1 == activeStep;
            bool complete = index + 1 < activeStep;
            steps[index].Opacity = active || complete ? 1 : 0.55;
            dots[index].Background = active
                ? new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E76F51"))
                : complete
                    ? new SolidColorBrush((Color)ColorConverter.ConvertFromString("#167D62"))
                    : Brushes.Transparent;
            dots[index].BorderBrush = active || complete
                ? Brushes.Transparent
                : new SolidColorBrush((Color)ColorConverter.ConvertFromString("#9FB3C8"));
        }
    }
}
