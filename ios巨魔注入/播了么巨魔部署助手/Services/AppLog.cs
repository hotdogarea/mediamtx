using System.Text;
using System.Text.RegularExpressions;
using System.IO;

namespace Boleme.TrollDeploy.Services;

public sealed partial class AppLog : IDisposable
{
    private readonly StreamWriter writer;
    private readonly object sync = new();

    public AppLog()
    {
        string logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Boleme",
            "TrollDeploy",
            "Logs");
        Directory.CreateDirectory(logDirectory);
        FilePath = Path.Combine(logDirectory, $"deploy-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        writer = new StreamWriter(FilePath, append: false, new UTF8Encoding(false)) { AutoFlush = true };
    }

    public string FilePath { get; }

    public string Write(string message)
    {
        string safeMessage = Sanitize(message);
        string line = $"[{DateTime.Now:HH:mm:ss}] {safeMessage}";
        lock (sync)
        {
            writer.WriteLine(line);
        }
        return line;
    }

    private static string Sanitize(string value) =>
        LongHexIdentifier().Replace(value, match => $"{match.Value[..6]}…{match.Value[^4..]}");

    [GeneratedRegex(@"\b[0-9A-Fa-f]{24,40}\b")]
    private static partial Regex LongHexIdentifier();

    public void Dispose() => writer.Dispose();
}
