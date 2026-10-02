using System.IO;
using System.Text.Json;
using Boleme.TrollDeploy.Models;

namespace Boleme.TrollDeploy.Services;

public sealed class CompatibilityService
{
    private CompatibilityRulesFile? cachedRules;

    public async Task<CompatibilityResult> MatchAsync(DeviceInfo device, CancellationToken cancellationToken)
    {
        CompatibilityRulesFile rules = cachedRules ??= await LoadRulesAsync(cancellationToken);
        Version deviceVersion = ParseVersion(device.ProductVersion);

        foreach (CompatibilityRouteRule route in rules.Routes)
        {
            if (!route.DeviceClasses.Contains(device.DeviceClass, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            if (route.ExactVersion is not null && deviceVersion != ParseVersion(route.ExactVersion))
            {
                continue;
            }

            if (route.MinVersionInclusive is not null && deviceVersion < ParseVersion(route.MinVersionInclusive))
            {
                continue;
            }

            if (route.MaxVersionExclusive is not null && deviceVersion >= ParseVersion(route.MaxVersionExclusive))
            {
                continue;
            }

            if (route.RequiredBuild is not null &&
                !route.RequiredBuild.Equals(device.BuildVersion, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            return new CompatibilityResult(
                true,
                route.Id,
                route.Name,
                $"已匹配 {route.Name}",
                route.Prerequisites);
        }

        return CompatibilityResult.Unsupported(
            $"{device.DeviceClass} {device.ProductVersion}（{device.BuildVersion}）不在当前已验证范围内");
    }

    private static async Task<CompatibilityRulesFile> LoadRulesAsync(CancellationToken cancellationToken)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "compatibility-rules.json");
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("缺少兼容规则文件 compatibility-rules.json", path);
        }

        await using FileStream stream = File.OpenRead(path);
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        return await JsonSerializer.DeserializeAsync<CompatibilityRulesFile>(stream, options, cancellationToken)
            ?? throw new InvalidDataException("兼容规则文件内容无效");
    }

    private static Version ParseVersion(string value)
    {
        if (!Version.TryParse(value.Trim(), out Version? version))
        {
            throw new InvalidDataException($"无法解析系统版本：{value}");
        }
        return version;
    }
}
