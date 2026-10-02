using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;
using Boleme.TrollDeploy.Models;

namespace Boleme.TrollDeploy.Services;

public sealed class AppleMobileDeviceClient
{
    private const int UsbMuxPort = 27015;
    private const int LockdownPort = 62078;
    private int nextTag = 1;

    public async Task<DeviceInfo?> ReadDeviceInfoAsync(CancellationToken cancellationToken)
    {
        UsbMuxDevice? device = await FindFirstUsbDeviceAsync(cancellationToken);
        if (device is null)
        {
            return null;
        }

        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, UsbMuxPort, cancellationToken);
        NetworkStream stream = client.GetStream();

        ushort networkPort = unchecked((ushort)IPAddress.HostToNetworkOrder(unchecked((short)LockdownPort)));
        string connectRequest = CreatePlist(
            "<key>MessageType</key><string>Connect</string>" +
            $"<key>DeviceID</key><integer>{device.DeviceId}</integer>" +
            $"<key>PortNumber</key><integer>{networkPort}</integer>");
        XDocument connectResponse = await SendUsbMuxRequestAsync(stream, connectRequest, cancellationToken);
        int result = ReadInteger(connectResponse.Root?.Element("dict"), "Number");
        if (result != 0)
        {
            throw new IOException($"Apple Mobile Device 连接失败，代码 {result}");
        }

        string getValueRequest = CreatePlist(
            "<key>Label</key><string>com.boleme.deploy</string>" +
            "<key>Request</key><string>GetValue</string>");
        await SendLockdownPlistAsync(stream, getValueRequest, cancellationToken);
        XDocument response = await ReadLockdownPlistAsync(stream, cancellationToken);
        XElement? responseDict = response.Root?.Element("dict");
        XElement? valueDict = FindValueElement(responseDict, "Value");
        if (valueDict is null || valueDict.Name.LocalName != "dict")
        {
            string error = ReadString(responseDict, "Error");
            throw new IOException(string.IsNullOrWhiteSpace(error)
                ? "手机尚未授权读取设备信息，请解锁并点击“信任”"
                : $"无法读取设备信息：{error}");
        }

        return new DeviceInfo(
            ReadString(valueDict, "DeviceClass"),
            ReadString(valueDict, "ProductType"),
            ReadString(valueDict, "ProductVersion"),
            ReadString(valueDict, "BuildVersion"),
            ReadString(valueDict, "DeviceName"),
            ReadString(valueDict, "UniqueDeviceID", device.SerialNumber));
    }

    private async Task<UsbMuxDevice?> FindFirstUsbDeviceAsync(CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, UsbMuxPort, cancellationToken);
        NetworkStream stream = client.GetStream();
        XDocument response = await SendUsbMuxRequestAsync(
            stream,
            CreatePlist("<key>MessageType</key><string>ListDevices</string>"),
            cancellationToken);

        XElement? deviceArray = FindValueElement(response.Root?.Element("dict"), "DeviceList");
        if (deviceArray is null || deviceArray.Name.LocalName != "array")
        {
            return null;
        }

        foreach (XElement entry in deviceArray.Elements("dict"))
        {
            XElement? properties = FindValueElement(entry, "Properties");
            if (properties is null || properties.Name.LocalName != "dict")
            {
                continue;
            }

            string connectionType = ReadString(properties, "ConnectionType");
            if (!connectionType.Equals("USB", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            return new UsbMuxDevice(
                ReadInteger(entry, "DeviceID"),
                ReadString(properties, "SerialNumber"));
        }

        return null;
    }

    private async Task<XDocument> SendUsbMuxRequestAsync(NetworkStream stream, string plist, CancellationToken cancellationToken)
    {
        byte[] payload = Encoding.UTF8.GetBytes(plist);
        byte[] header = new byte[16];
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(0, 4), header.Length + payload.Length);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4, 4), 1);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(8, 4), 8);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(12, 4), nextTag++);
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);

        byte[] responseHeader = await ReadExactlyAsync(stream, 16, cancellationToken);
        int totalLength = BinaryPrimitives.ReadInt32LittleEndian(responseHeader.AsSpan(0, 4));
        if (totalLength < 16 || totalLength > 4 * 1024 * 1024)
        {
            throw new InvalidDataException("Apple Mobile Device 返回了无效数据");
        }

        byte[] responsePayload = await ReadExactlyAsync(stream, totalLength - 16, cancellationToken);
        return XDocument.Parse(Encoding.UTF8.GetString(responsePayload));
    }

    private static async Task SendLockdownPlistAsync(NetworkStream stream, string plist, CancellationToken cancellationToken)
    {
        byte[] payload = Encoding.UTF8.GetBytes(plist);
        byte[] length = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(length, payload.Length);
        await stream.WriteAsync(length, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static async Task<XDocument> ReadLockdownPlistAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        byte[] lengthBytes = await ReadExactlyAsync(stream, 4, cancellationToken);
        int length = BinaryPrimitives.ReadInt32BigEndian(lengthBytes);
        if (length <= 0 || length > 4 * 1024 * 1024)
        {
            throw new InvalidDataException("手机返回了无效的设备信息");
        }

        byte[] payload = await ReadExactlyAsync(stream, length, cancellationToken);
        return XDocument.Parse(Encoding.UTF8.GetString(payload));
    }

    private static async Task<byte[]> ReadExactlyAsync(Stream stream, int length, CancellationToken cancellationToken)
    {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(offset, length - offset), cancellationToken);
            if (read == 0)
            {
                throw new EndOfStreamException("Apple Mobile Device 连接意外关闭");
            }
            offset += read;
        }
        return buffer;
    }

    private static string CreatePlist(string dictContents) =>
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
        "<plist version=\"1.0\"><dict>" +
        "<key>BundleID</key><string>com.boleme.deploy</string>" +
        "<key>ClientVersionString</key><string>boleme-troll-deploy 0.2.0</string>" +
        "<key>ProgName</key><string>boleme-troll-deploy</string>" +
        $"{dictContents}</dict></plist>";

    private static XElement? FindValueElement(XElement? dict, string key)
    {
        if (dict is null)
        {
            return null;
        }

        List<XElement> children = dict.Elements().ToList();
        for (int index = 0; index + 1 < children.Count; index += 2)
        {
            if (children[index].Name.LocalName == "key" && children[index].Value == key)
            {
                return children[index + 1];
            }
        }
        return null;
    }

    private static string ReadString(XElement? dict, string key, string fallback = "") =>
        FindValueElement(dict, key)?.Value ?? fallback;

    private static int ReadInteger(XElement? dict, string key)
    {
        string value = FindValueElement(dict, key)?.Value ?? "-1";
        return int.TryParse(value, out int result) ? result : -1;
    }

    private sealed record UsbMuxDevice(int DeviceId, string SerialNumber);
}
