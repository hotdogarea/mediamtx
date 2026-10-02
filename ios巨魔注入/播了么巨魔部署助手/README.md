# 播了么巨魔一键部署助手

独立于 MediaMTX 和播了么推流插件的 Windows 部署工具。程序连接 Apple Mobile
Device 服务读取设备信息，根据 `compatibility-rules.json` 自动选择已验证路线。

## v0.2.0 功能

- 自动读取 `DeviceClass`、`ProductType`、系统版本和 BuildVersion；
- 使用外部 JSON 兼容规则匹配安装方案，不在界面中写死机型和版本；
- 根据匹配路线动态生成备份、Tips、“查找”等确认项；
- 不支持的设备组合会被阻止，不会启动 TrollRestore；
- 校验固定版本 `TrollRestore.exe` 的 SHA-256；
- 后台运行 TrollRestore 并自动输入 `Tips`；
- 展示实时状态、脱敏日志、取消和 25 分钟超时；
- 引导用户在 Tips 中完成 TrollStore 安装并恢复“查找”；
- 发布版自带 .NET 8 桌面运行库。

## 当前兼容规则

规则以本项目随附的 TrollRestore 实际校验逻辑为依据：

- iPhone、iPad、iPod；
- iOS/iPadOS 15.0 至低于 16.7；
- 16.7 RC，BuildVersion 必须为 `20H18`；
- iOS/iPadOS 17.0。

新增路线时应修改 `compatibility-rules.json` 并完成真机验证，不能只扩大版本范围。

## 开发与发布

出于安全与授权考虑，Git 只保存部署助手源代码，不提交 `TrollRestore.exe`。
本地构建前需要把经过校验的 `TrollRestore.exe` 放在项目目录的上一级；项目文件会在
构建和发布时将它复制到输出目录。

```powershell
dotnet build .\Boleme.TrollDeploy.csproj --configuration Release
.\build.ps1
```

输出位于 `发布包-v0.2.0`。发布目录中的部署助手、`TrollRestore.exe`、
`compatibility-rules.json` 和 `使用说明.txt` 必须一起交付。

## 安全边界

- 不关闭 Windows Defender，不添加排除项；
- 不保存 Apple ID、密码或验证码；
- 不自动操作 Windows 安全设置；
- 不允许未匹配兼容规则的设备继续；
- 正式发布前需做 Windows 代码签名和真机全流程测试。
