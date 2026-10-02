namespace Boleme.TrollDeploy.Models;

public sealed record CheckItem(string Label, bool Passed, string Detail);

public sealed record DeviceInfo(
    string DeviceClass,
    string ProductType,
    string ProductVersion,
    string BuildVersion,
    string DeviceName,
    string UniqueDeviceId)
{
    public string DisplayName => $"{DeviceClass} · {ProductType}";
}

public sealed record PrerequisiteDefinition(string Id, string Label);

public sealed record CompatibilityResult(
    bool Supported,
    string RouteId,
    string RouteName,
    string Message,
    IReadOnlyList<PrerequisiteDefinition> Prerequisites)
{
    public static CompatibilityResult Unsupported(string message) =>
        new(false, string.Empty, "未找到可用方案", message, []);
}

public sealed record PreflightResult(
    CheckItem Tool,
    CheckItem Device,
    CheckItem Driver,
    DeviceInfo? DeviceInfo,
    CompatibilityResult Compatibility,
    string TrollRestorePath)
{
    public bool CanContinue => Tool.Passed && Device.Passed && Driver.Passed &&
        DeviceInfo is not null && Compatibility.Supported;
}
