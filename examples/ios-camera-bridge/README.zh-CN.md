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

- OBS 推流端是 RTMP；手机拉流端是 HLS。插件**没有**直接实现 RTMP 或 WebRTC 接收器。这是功能验证版，HLS 通常有数秒延迟，不适合直接当作最终低延迟方案。
- 只挂接 `AVCaptureVideoDataOutput` 的视频回调；支持 BGRA 和常见 NV12 全/视频范围像素格式，但 NV12 尚待目标 App 实机验证。`AVCaptureVideoPreviewLayer`、拍照、音频、私有相机接口不在本 Demo 范围。
- **启用替换后不再回退真摄像头**：短暂断流保留最后一帧，超过 5 秒显示黑画面；不支持的相机像素格式会停止向目标 App 传真实视频帧并在面板提示。这是避免直播中意外泄露真实镜头的保护，但某些目标 App 可能因此停止预览。
- 摄像头仍需要正常权限和运行中的 `AVCaptureSession`；这里替换的是 App **收到的视频帧**，不是把 iOS 系统中的摄像头设备换掉。
- OBS 声音不会直接进入直播 App 的麦克风回调。面板可检测 HLS 音轨和音频码率，并提供“静音 / 本机播放 / 外接回录”三种输出策略，但这三种都**不是软件麦克风注入**。真正的软件注入仍需单独实现音频解码、同步，并针对目标 App 的录音采集链适配。
- 可拖动的 `OBS` 浮动按钮及可按住标题上下移动的设置弹窗属于**被注入 App 自己的窗口**，不是一个独立 App 跨 App 悬浮。官方 App 的窗口、输入链、完整性保护和版本差异，均可能让注入失败或画面不生效。
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

首次编译会下载 Go 依赖。如果提示缺少 `VERSION` 或 `hls.min.js`，先运行 `go generate ./internal/core ./internal/servers/hls`，再重试。也可以先从 [MediaMTX Releases](https://github.com/bluenviron/mediamtx/releases) 下载 Windows 发行版，再把本目录的 `mediamtx.demo.yml` 路径作为启动参数。测试配置使用 MPEG-TS HLS 和 2 秒片段，优先兼容 iOS HLS 播放。让防火墙允许局域网入站 TCP 8888；若 OBS 在另一台电脑，还要允许 TCP 1935。通过 `ipconfig` 找到这台电脑的局域网 IPv4 地址（例如 `192.168.1.20`）。

## 2. OBS 推流

OBS → 设置 → 直播：

| 项目 | 填写 |
| --- | --- |
| 服务 | 自定义 |
| 服务器 | `rtmp://127.0.0.1:1935/obs`（OBS 与 MediaMTX 同一电脑） |
| 串流密钥 | 留空 |

OBS → 设置 → 输出：视频编码选 H.264，**关键帧间隔明确设为 2 秒**，音频 AAC。OBS → 设置 → 视频：测试时先设 720×1280 输出、30 帧/秒，码率从约 2500–3500 kb/s 开始。画面里放一个会走动的时钟或挥手，以区分直播和静态图。点击“开始直播”。如果 OBS 在另一台电脑，把 `127.0.0.1` 换成 MediaMTX 电脑的局域网 IP。关键帧隔 8 秒以上时，HLS 分片会显著变慢，App 会误以为接收中断。

在电脑浏览器检查 `http://127.0.0.1:8888/obs`；再用 iPhone Safari 访问 `http://192.168.1.20:8888/obs/index.m3u8`（替换 IP）。先确保手机浏览器能播，排除防火墙和网络问题。

## 3. 构建测试 App 和插件

### 有 Mac

安装 Xcode 和 XcodeGen（例如 `brew install xcodegen`），在 Mac 上拉取本仓库，运行：

```bash
bash examples/ios-camera-bridge/build-macos.sh
```

产物为 `CameraBridgeDemo.ipa`、`CameraBridgeCleanHost.ipa` 和 `CameraBridge.dylib`。Demo 是**已内置相同替换代码**的测试 App；CleanHost 是**没有内置插件**的普通摄像头 App，用于先验证 TrollFools 注入；dylib 才是真正注入的插件。脚本生成的是未使用个人证书签名的测试 IPA，按下文通过 TrollStore 安装。

如果手机没有 TrollStore，但有 Mac，可以先 `cd examples/ios-camera-bridge && xcodegen generate`，用 Xcode 打开 `CameraBridgeDemo.xcodeproj`，在 Signing & Capabilities 选自己的 Team 和唯一 Bundle Identifier，连接 iPhone 后 Run。这样**只能测试我们自己的 App**，不意味着能注入抖音/淘宝。

### 只有 Windows、没有 Mac

本 Demo 已推送到 [hotdogarea/mediamtx](https://github.com/hotdogarea/mediamtx)。其他使用者可 Fork 后，在自己仓库的 Actions 中运行 `iOS Camera Bridge demo`；如果在本地修改了源码，再把改动推送到自己的 fork。不要把实验代码误推到原作者仓库。

打开 fork 的 Actions → `iOS Camera Bridge demo` → Run workflow，成功后下载 `ios-camera-bridge-demo` 工件并解压，得到两个 IPA 和一个 dylib。工作流使用 GitHub 的 macOS runner/Xcode，不需要在 Windows 本机安装 Xcode。若手机兼容 TrollStore，可以直接用它安装测试 IPA；否则可使用 Windows 上的 Sideloadly 和自己的 Apple ID 签名测试 App。

## 4. 安装到 iPhone、验证

先在 iPhone“设置 → 通用 → 关于本机”记下 iOS 版本和机型。对已安装 TrollStore 的 iPhone 7/iOS 14.3，直接使用下述 TrollStore 路径。没有 TrollStore、只测试自己的 Demo 时，可在 Windows 安装 [Sideloadly 官方版本](https://sideloadly.io/)及其要求的 Apple 官网版 iTunes/iCloud → USB 连接 iPhone 并信任电脑 → 将 `CameraBridgeDemo.ipa` 拖入 Sideloadly → 输入自己的 Apple ID 签名并安装。免费 Apple ID 安装的测试 App 通常 7 天后需要重新签名，见 [Sideloadly FAQ](https://sideloadly.io/faq)。

若系统处于 TrollStore 支持范围，也可以按 [iOS Guide 的机型/版本对照教程](https://ios.cfw.guide/installing-trollstore/)安装 TrollStore（各版本入口不同，不要随意用第三方安装包）。TrollStore **不是越狱**。

1. **已安装 TrollStore**：把 `CameraBridgeDemo.ipa` 传到手机“文件”App，在 TrollStore 里导入/安装。第一次打开允许摄像头、麦克风和局域网访问。麦克风仅用于模拟直播 App 的采集状态、识别外接输入路线；Demo 不保存或上传录音。Demo 已内置替换代码，**不用再注入它**。
2. 点可拖动的 `OBS` 按钮，地址栏可以**只填电脑 IP**，例如 `192.168.1.20`；插件自动补齐 `http://…:8888/obs/index.m3u8`。也可以先在 Safari 打开播放地址，复制后点面板的“粘贴”。地址会保存，下次只需打开开关。
3. 面板分为“画面 / 音频”两个 Tab。画面页显示“画面稳定 / 正在缓冲 / 重连”，以及**解码帧/秒、替换帧/秒、视频码率、分片下载吞吐、HLS 直播边缘落后量及本次峰值、重连次数、累计接收/替换帧、累计黑帧**。按住弹窗顶部标题可上下移动它。接收帧是从 HLS 实际取到的帧；替换帧是目标 App 实际收到的替换回调；它们不必严格相等。码率来自 AVPlayer 日志，无法读取时显示“暂无数据”。分片下载吞吐可能远高于视频码率，它不是 OBS 编码码率。HLS 落后量用播放位置与可跳转范围末端估算，**不是 OBS 采集到观众看到画面的端到端延迟**。这不是严格意义的 RTF。
4. 预览应变成 OBS 的时钟/动作；关闭开关后应恢复真摄像头。停 OBS 后，**开关仍开着时**应先保留最后画面再变黑，不能露出真摄像头。若方向不对，可在面板试 90°/180°/270°；Demo 自身的真实相机预览已设置竖屏方向。
5. 若 Safari 能播但 Demo 一直缓冲，先检查 OBS 关键帧是否为 2 秒、分辨率/码率是否过高；若这些都正确而解码帧率仍为 0，再针对该机型考虑 VideoToolbox 解码器。不能把“浏览器能播”当作“注入成功”。

建议连续测试 20–30 分钟，分别在开始、10 分钟、结束时记录面板截图；重点看 HLS 落后量是否持续上升，以及重连、卡顿、黑帧是否增加。30 帧/秒的短时截图只能说明当时帧率正常，不能证明长时间无积累延迟。

音频页有三种模式：

- **静音（默认）**：不播放 OBS 音轨；直播 App 继续使用真实的手机或外接麦克风。这也是不插硬件时的安全默认值。
- **本机播放**：OBS 音轨按 iOS 当前路线播放，可能去扬声器、听筒或耳机。若由扬声器播放，真实麦克风可能从空气中再次收音，会带入环境声、回声和延迟；它不是“内录”。
- **外接回录**：用于照片中那类带音频回录/环回能力的有线或 USB 转接设备。插件只有同时检测到外接音频输入和外接音频输出时才取消静音；拔掉设备或路线不完整时强制静音，避免意外改走扬声器。端口检测只能证明 iOS 看到了输入和输出，不能证明硬件内部确实完成环回，必须再用“语音备忘录”或直播 App 的私密预览录一段确认。

因此，在不插任何硬件时，本版插件**不能**把 OBS 声音直接交给抖音的麦克风。若 OBS 音轨显示“有音轨”但静音模式听不到声音是正常的；可先选“本机播放”或用 Safari 播放同一 HLS 地址验证源音轨。

音频页还分别显示喇叭和麦克风通道：

- **喇叭 / OBS 输出**显示音轨是否正在发送、当前输出端口和音频码率。进度条表示音轨数据流量，不冒充真实响度；AVPlayer 的 HLS 音轨没有向本插件暴露可直接计量的输出 PCM。
- **麦克风输入**显示直播 App 实际使用的输入端口，并从 `AVCaptureAudioDataOutput` 收到的 PCM 采样计算实时 dB/RMS 电平。插入回录设备后，若这里显示 `USBAudio2.0` 且绿色电平随声音跳动，才说明声音已经回到这一条麦克风采集链。
- 若目标 App 不使用 `AVCaptureAudioDataOutput`（例如改走 AudioUnit、AVAudioEngine 或私有音频链），界面会明确显示“未捕获到 App 的麦克风采样回调”；这时不能据此判断没有声音，需要针对该 App 的采集路径另做适配。

## 5. 先验证插件注入，再考虑目标直播 App

先通过 TrollStore 安装 `CameraBridgeCleanHost.ipa`，确认它**只有真实摄像头预览，没有 OBS 按钮**。把 `CameraBridge.dylib` 传到手机，在 TrollFools 中选 `CameraBridgeCleanHost` → Inject/注入 → 选 dylib；完全退出并重新打开 CleanHost，若出现 OBS 按钮且能替换画面，才证明 dylib 注入路径跑通。若注入后 App 崩溃，先在 TrollFools 中撤销该 App 的注入。

之后再考虑官方直播 App。[TrollFools 官方 README](https://github.com/Lessica/TrollFools/blob/main/README.md) 对加密 App Store App 的条件是“带裸动态库”，所以**不保证**抖音/淘宝可注入或能捕获相机回调。即使插件在目标 App 内运行，也只先检查开播前预览，不要直接对真实观众开播；还需确认符合平台规则。

若看到 `OBS` 按钮却仍是真摄像头，先看“解码帧/秒”和“替换帧/秒”；解码有值但替换为 0，通常是目标 App 没走本插件挂钩的 `AVCaptureVideoDataOutput` 回调，或格式/预览另走一路。这是**针对 App 版本的适配工作**，不能靠修改流地址解决。若目标 App 根本不在 TrollFools 可选列表或注入后启动崩溃，当前路径到此为止；不提供“所有 iPhone 免越狱通用注入”的承诺。

## 排错顺序

1. OBS 页面可见画面吗？没有先查 OBS/MediaMTX。
2. iPhone Safari 的 HLS URL 能播吗？不能先查 IP、Wi-Fi、VPN、防火墙和 H.264 编码。
3. 自己的测试 App 中“已替换帧”是否增长？不增长先查 URL/开关、HLS 解码/帧输出、相机权限。
4. 测试 App 成功，目标 App 失败？再查 TrollFools 的可注入范围、目标 App 视频格式/回调链与 HTTPS/ATS。

Demo 测通只证明“我们的 App 可以拿到 OBS 解码帧并替换这一类摄像头回调”；CleanHost 测通才证明**插件注入链路**；某个具体版本的目标直播 App 还需单独验证。低延迟 WebRTC、音频注入和长期稳定性是后续独立任务。
