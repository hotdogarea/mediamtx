namespace Boleme.TrollDeploy.Models;

public sealed class CompatibilityRulesFile
{
    public List<CompatibilityRouteRule> Routes { get; init; } = [];
}

public sealed class CompatibilityRouteRule
{
    public string Id { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public List<string> DeviceClasses { get; init; } = [];
    public string? MinVersionInclusive { get; init; }
    public string? MaxVersionExclusive { get; init; }
    public string? ExactVersion { get; init; }
    public string? RequiredBuild { get; init; }
    public List<PrerequisiteDefinition> Prerequisites { get; init; } = [];
}
