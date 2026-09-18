# iPhone Camera Bridge：OBS → MediaMTX → iOS 相机回调（实验版）

这个 Demo 验证一件具体的事：OBS 把画面发布到 MediaMTX，iPhone 拉流、解码，再把画面放进 `AVCaptureVideoDataOutputSampleBufferDelegate` 收到的摄像头视频帧里。**它不是系统级虚拟摄像头，也未验证抖音、淘宝等官方直播 App。**

## 为什么没有直接复制 `ios-Virtual-Camera`

[adymilk/ios-Virtual-Camera](https://github.com/adymilk/ios-Virtual-Camera) 展示了 Logos 注入和 App 内弹窗的雏形，但其 `Tweak.xm` 的摄像头替换函数仍是 TODO，甚至在启用时返回 `nil` 设备并跳过 `AVCaptureSession startRunning`。该仓库没有明确的许可文件。这里沿用“目标 App 进程内插件”的**思路**，代码独立实现，不复制原代码。

## 方案与边界

```text
OBS --RTMP/H.264--> MediaMTX --HLS/MPEG-TS--> iPhone AVPlayerItemVideoOutput
                                             --> CVPixelBuffer --> CMSampleBuffer
                                             --> AVCaptureVideoDataOutput delegate
```

- OBS 推流端是 RTMP；手机拉流端是 HLS。插件**没有**直接实现 RTMP 或 WebRTC 接收器。第一版用于验证链路，HLS 通常有数秒延迟，不适合直接当作最终低延迟方案。
- 只替换 `AVCaptureVideoDataOutput` 的 BGRA 视频回调；其他格式、`AVCaptureVideoPreviewLayer`、拍照、音频、私有相机接口不在本 Demo 范围。格式不匹配或拉流中断时自动回退真摄像头。
- 摄像头仍需要正常权限和运行中的 `AVCaptureSession`；这里替换的是 App **收到的视频帧**，不是把 iOS 系统中的摄像头设备换掉。
- OBS 声音不会进入直播 App 的麦克风回调。需要音频时，必须单独设计同步与音频输入路径。
- 插件内右侧 `OBS` 圆形按钮属于**被注入 App 自己的窗口**，不是一个独立 App 跨 App 悬浮。官方 App 的窗口、输入链、完整性保护和版本差异，均可能让注入失败或画面不生效。
- 本地 HTTP 地址仅用于同一可信局域网内的测试。测试 App 放开了 ATS；普通 App 可能禁止 HTTP，最终方案需要有效 HTTPS 证书及相应适配。不要把无认证的 MediaMTX 端口暴露到公网。

## 需要什么

1. 一台运行 OBS 和 MediaMTX 的电脑（可同一台），以及同一 Wi-Fi/LAN 的 iPhone。
2. **只测试我们自己的 App**，可以用 Windows 的 [Sideloadly](https://sideloadly.io/) 安装 IPA，无需 TrollStore。若想**免越狱注入别的 App**，才需要该 iOS 版本能安装 [TrollStore](https://github.com/opa334/TrollStore) 和 [TrollFools](https://github.com/Lessica/TrollFools)。TrollStore 官方支持范围是 iOS 14.0 beta 2～16.6.1、16.7 RC 和 17.0；17.0.1 及更新版本不在这个范围。先在“设置 → 通用 → 关于本机”确认版本。
3. 构建 iOS 程序需要 macOS/Xcode；如果手头只有 Windows，可以把此仓库推到自己的 GitHub fork，使用本仓库的手动 GitHub Actions 工作流远程构建。这里无法在 Windows 上编译或实机验收 iOS 产物。

## 1. 在 Windows 启动 MediaMTX

在本仓库根目录 `D:\mediamtx` 打开 PowerShell：

```powershell
go run . examples/ios-camera-bridge/mediamtx.demo.yml
```

首次编译会下载 Go 依赖。也可以先从 [MediaMTX Releases](https://github.com/bluenviron/mediamtx/releases) 下载 Windows 发行版，再把本目录的 `mediamtx.demo.yml` 路径作为启动参数。测试配置使用 `hlsVariant: mpegts`，优先兼容 iOS HLS 播放。让防火墙允许入站 TCP 8888；若 OBS 在另一台电脑，还要允许 TCP 1935。通过 `ipconfig` 找到这台电脑的局域网 IPv4 地址（例如 `192.168.1.20`）。

## 2. OBS 推流

OBS → 设置 → 直播：

| 项目 | 填写 |
| --- | --- |
| 服务 | 自定义 |
| 服务器 | `rtmp://127.0.0.1:1935/obs`（OBS 与 MediaMTX 同一电脑） |
| 串流密钥 | 留空 |

OBS → 设置 → 输出：视频编码先选 H.264，关键帧间隔可设为 2 秒，音频 AAC。画面里放一个会走动的时钟或挥手，以区分直播和静态图。点击“开始直播”。如果 OBS 在另一台电脑，把 `127.0.0.1` 换成 MediaMTX 电脑的局域网 IP。

在电脑浏览器检查 `http://127.0.0.1:8888/obs`；再用 iPhone Safari 访问 `http://192.168.1.20:8888/obs/index.m3u8`（替换 IP）。先确保手机浏览器能播，排除防火墙和网络问题。

## 3. 构建测试 App 和插件

### 有 Mac

安装 Xcode 和 XcodeGen（例如 `brew install xcodegen`），在 Mac 上拉取本仓库，运行：

```bash
bash examples/ios-camera-bridge/build-macos.sh
```

产物为 `examples/ios-camera-bridge/out/CameraBridgeDemo.ipa` 和 `CameraBridge.dylib`。前者是**已内置相同替换代码**的测试 App，不需要另对它注入插件；后者仅供后续 TrollFools 注入测试。脚本生成的是未使用个人证书签名的测试 IPA，按下文通过 TrollStore 安装。

如果手机没有 TrollStore，但有 Mac，可以先 `cd examples/ios-camera-bridge && xcodegen generate`，用 Xcode 打开 `CameraBridgeDemo.xcodeproj`，在 Signing & Capabilities 选自己的 Team 和唯一 Bundle Identifier，连接 iPhone 后 Run。这样**只能测试我们自己的 App**，不意味着能注入抖音/淘宝。

### 只有 Windows、没有 Mac

**现在这些文件只在本地，尚未推送到 GitHub，也没有现成 IPA 可下载。**先登录 GitHub，在 [MediaMTX 仓库](https://github.com/bluenviron/mediamtx)点 Fork，创建你自己账号下的 `mediamtx` 仓库。然后在 `D:\mediamtx` 的 PowerShell 执行（把 `你的用户名` 换成自己的 GitHub 用户名）：

```powershell
git add .github/workflows/ios-camera-bridge.yml examples/ios-camera-bridge
git commit -m "Add iOS Camera Bridge demo"
git push https://github.com/你的用户名/mediamtx.git HEAD:main
```

这只把你本地新增的 Demo 提交推到**你自己的 fork**；不要推到原作者的仓库。打开自己 fork 的 Actions（若首次进入提示启用 Actions，先按页面提示启用）→ `iOS Camera Bridge demo` → Run workflow，运行完成后下载 `ios-camera-bridge-demo` 工件并解压，得到 `CameraBridgeDemo.ipa` 和 `CameraBridge.dylib`。工作流使用 GitHub 的 macOS runner/Xcode，不需要在 Windows 本机安装 Xcode。下载的未签名 IPA 可以用 Windows 的 Sideloadly 加上你自己的 Apple ID 签名并安装测试 App；若手机兼容 TrollStore，也可以改用 TrollStore 安装。

## 4. 安装到 iPhone、验证

先在 iPhone“设置 → 通用 → 关于本机”记下 iOS 版本和机型。只测试 Demo 时，**推荐 Windows 安装路径**：电脑安装 [Sideloadly 官方版本](https://sideloadly.io/)及其要求的 Apple 官网版 iTunes/iCloud → USB 连接 iPhone 并在手机点“信任此电脑” → 将 `CameraBridgeDemo.ipa` 拖入 Sideloadly → 输入自己的 Apple ID → 选择设备并开始安装。iOS 16 及更新版本按手机提示在“设置 → 隐私与安全性”启用开发者模式；首次打开若显示“不受信任的开发者”，在“设置 → 通用 → VPN 与设备管理”信任自己的签名。免费 Apple ID 安装的测试 App 通常 7 天后需要重新签名安装，见 [Sideloadly FAQ](https://sideloadly.io/faq)。

若系统处于 TrollStore 支持范围，也可以按 [iOS Guide 的机型/版本对照教程](https://ios.cfw.guide/installing-trollstore/)安装 TrollStore（各版本入口不同，不要随意用第三方安装包）。TrollStore **不是越狱**。

1. **已安装 TrollStore 时的替代安装路径**：把 `CameraBridgeDemo.ipa` 通过“文件”、AirDrop 或本地网页传到手机，在 TrollStore 里导入/安装该 IPA。无论使用哪条安装路径，第一次打开都要允许摄像头和局域网访问。测试 App 已内置替换代码，**不用另装 TrollFools**。
2. 在测试 App 输入 `http://电脑局域网IP:8888/obs/index.m3u8`；打开“替换摄像头画面”，按键盘 Return 保存。右侧 `OBS` 按钮也可以设置和开关。
3. 看测试 App 预览是否从真摄像头变为 OBS 的时钟/动作，状态是否显示 `receiving video frames`，**相机回调**和**已替换帧**两个数字是否持续增长。关掉开关后应恢复真摄像头；停 OBS 超过约 2 秒后也应自动回退。
4. 若 Safari 能播但测试 App 一直 `connecting to HLS`，说明 AVPlayer 的视频帧输出在该机型/系统/流格式上没有工作；这时 Demo **未通过**，需针对该设备改用 VideoToolbox 解码器。不能把“浏览器能播”当作“注入成功”。

## 5. 注入到目标 App（仅在第 4 步通过后）

先从 [TrollFools 官方 Releases](https://github.com/Lessica/TrollFools/releases/latest) 下载 `.tipa`，通过 TrollStore 安装。把 `CameraBridge.dylib` 传到手机，在 TrollFools 中选目标 App → Inject/注入 → 选 dylib。先用自己开发/可控的测试 App 做验证；官方抖音、淘宝的加密安装包**不保证**被 TrollFools 列为可注入对象。[TrollFools 官方 README](https://github.com/Lessica/TrollFools/blob/main/README.md) 对加密 App Store App 的条件是“带裸动态库”。注入后完全退出并重新打开目标 App，找到右侧 `OBS` 按钮，输入 HLS 地址，启用后在目标 App 的相机预览里检查是否生效。不要直接点公开开播或用真实观众做首测；先用测试账号/私密环境，并确认符合平台规则。

若看到了 `OBS` 按钮却仍是真摄像头，可先看按钮里的状态/替换帧数；若始终为 0，通常是目标 App 没使用本 Demo 挂钩的 `AVCaptureVideoDataOutput` BGRA 回调，或预览另走一路。这是**适配工作**，不能靠修改流地址解决。若目标 App 根本不在 TrollFools 可选列表、启动崩溃、或系统不支持 TrollStore，则当前路径到此为止；不提供“所有 iPhone 免越狱通用注入”的承诺。

## 排错顺序

1. OBS 页面可见画面吗？没有先查 OBS/MediaMTX。
2. iPhone Safari 的 HLS URL 能播吗？不能先查 IP、Wi-Fi、VPN、防火墙和 H.264 编码。
3. 自己的测试 App 中“已替换帧”是否增长？不增长先查 URL/开关、HLS 解码/帧输出、相机权限。
4. 测试 App 成功，目标 App 失败？再查 TrollFools 的可注入范围、目标 App 视频格式/回调链与 HTTPS/ATS。

达到第 3 步才证明“手机内 App 可以拿到 OBS 解码帧并替换这一类摄像头回调”。达到第 4 步才证明**某个具体版本的目标 App**可用。低延迟 WebRTC、NV12 色彩格式和音频是后续独立任务。
