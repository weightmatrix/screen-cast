# Mac / iPad 原生投屏

Mac 使用 ScreenCaptureKit 采集屏幕、应用或单个窗口，通过统一的 WebRTC 原生 H.264 视频轨道传输。iPad 使用 VideoToolbox 解码、Metal 显示；Mac 也支持接收。

## 项目文档与协作

- [开发手册](投屏·开发手册.MD)、[开发记录](投屏·开发记录.MD)、[说明书](投屏·说明书.MD)以顶部当前基线为准。
- 每次改动完成更新三份文档、提交并推送；规则见[AGENTS.md](AGENTS.md)。
- 原始运行诊断只保存在本机，不纳入公开仓库。

## 使用

1. Mac 与接收设备连接同一局域网，允许 App 的本地网络访问。Mac 还需允许屏幕录制；授权后重新打开 App。
2. Mac 点击“添加投屏流”，选择显示器、应用或窗口，点击“开始投屏”。每个流显示自己的端口和6–36 位数字匹配码。
3. iPad 打开 App 后直接显示连接设置；选择“匹配码”，输入发送端显示的6–36 位数字码即可自动发现并连接。IP 直连需要同时填写 IP、端口和匹配码。
4. 连接设置关闭后，从屏幕左边缘向右滑动重新打开。

首个流使用端口 **8318**，后续流依次分配端口；发现广播使用 UDP **8321**。建议先用 8 Mbps、30 fps，确认稳定后再提高码率。

## 构建与安装

- 统一入口：打开根目录 `Touping.xcodeproj`。
- 原生 Mac：选择 `Touping-macOS` scheme，运行设备选择 My Mac。使用 macOS SDK、AppKit、SwiftUI 和 ScreenCaptureKit，不使用 Mac Catalyst 或 iPad App 兼容运行。
- iPhone / iPad：选择 `Touping-iOS` scheme，再选择真机或 iOS 模拟器。已禁用 Mac Catalyst 和 Designed for iPad on Mac，避免误选为 Mac 运行。
- 两个原生 target 共用 `Shared/AppIdentity.xcconfig` 中的 Bundle ID 和版本号，开发团队不变。统一使用原 iOS 标识，iPhone/iPad 安装身份不变；Mac 标识由 `com.witten.touping.maccaster` 改为统一标识，系统可能要求重新授权屏幕录制，旧 Mac 的偏好设置和日志不会自动迁移。
- 目录：`Shared/` 为两端共用的原生视频引擎、格式与诊断工具；`MacCaster/MacCaster/` 为 macOS 代码；`iPadReceiver/iPadReceiver/` 为 iOS 代码。
- 命令行构建：`xcodebuild -project Touping.xcodeproj -scheme Touping-macOS -destination 'platform=macOS' build`；iOS 使用 `-scheme Touping-iOS -destination 'generic/platform=iOS'`。
- 当前源码为 1.3（build 25），建议两端均安装当前版本。连接建立后必须通过匹配码校验，旧接收端无法连接新版发送端。
- 当前仅传视频，不含音频。被关闭的窗口无法继续采集；请重新选择有效窗口或显示器。

## 故障定位

- 应用列表读取失败、采集启动失败，会直接显示错误；请先查看该提示。
- 无法连接：检查本地网络权限、IP/端口/匹配码，以及路由器客户端隔离和防火墙。
- 长期停在连接中：新版连接和认证超过 10 秒会报超时，断开后可再次连接。
- Mac 日志：~/Library/Application Support/com.witten.touping.ipadreceiver.f4l9p953mq/diagnostic.log。
- iPad：连接设置内的“诊断·连接”，以及 App Documents/ConnectionDiag.md。

## 受控性能对照

当前25版仅修复预算恢复策略，整体性能仍未验收；不增加码率上限或降低采集分辨率。

固定基线及66秒自动网络场景见 [Tests/Benchmarks/README.md](Tests/Benchmarks/README.md)。测试有效与性能通过分开判断，原始材料仅留本机。18、24版有精确源码，21版仅有历史日志，不能伪称同条件对照。

## 运行回归检查

Debug 版 Mac App 使用 `--verify-native-capture` 检查真实屏幕采集及 GPU 显示，`--verify-native-routes` 检查四入口的媒体与旋转；结果写入本机诊断。单独的认证测试见 Tests/CastingServerLatencyCheck.swift。

Debug 版 iPad 支持 --verify-code，通过正常广播发现和匹配码路径连接测试流。--verify-host 后跟 Mac IP，可检查 IP 直连。GPU 完成显示会记录 display rendered 日志。

## 触控与 Apple Pencil

触控功能暂时挂起：不显示触控开关，iPad 不采集或回传触控/Pencil 事件，Mac 拒绝远程触控输入。现有实现保留，供后续恢复；屏幕采集、视频传输和原有批注功能继续使用。

## 低延迟投屏

- 发送端最多排队 3 个视频帧；发现待发视频超过 100 毫秒或队列已满时，清理待发视频并请求关键帧恢复，不把缺失参考帧的后续 P 帧继续发送。该阈值不是端到端延迟保证。
- 采集队列使用 3 帧，编码同时最多处理 2 帧；iPad 每次显示读取最新解码画面，最多允许 2 个 GPU 显示任务在途，静止画面不重复提交 GPU 渲染。
- iPad 解码积压时回传关键帧请求，发送端限制请求频率；帧数统计每 30 帧更新，减少界面刷新。
- 添加投屏流后可选“画质预设”：均衡 12 Mbps / 30 fps、文字清晰 24 Mbps / 30 fps、动态流畅 20 Mbps / 60 fps。仍可手动调整码率和帧率；输出按接收端和源画面尺寸适配，不放大小窗口。预设不是自动网络测速或自适应码率。
- 定向协议验证：`swiftc MacCaster/MacCaster/CastingServer.swift Tests/CastingServerLatencyCheck.swift -o /tmp/casting-latency-check && /tmp/casting-latency-check`。

## 界面

Mac 工作台与接收设置统一使用深色背景、蓝色强调和较大的文字及操作区域。投屏卡片突出匹配码，刷新、换源、停止使用带文字的按钮；iPad 接收面板加宽，放大连接输入与按钮，连接诊断默认折叠。界面调整不改变采集、传输与触控挂起状态。

## App Store 统一身份

- 统一 Bundle ID：`com.witten.touping.ipadreceiver.f4l9p953mq`。两端的 Debug/Release 都引用同一份 `Shared/AppIdentity.xcconfig`。
- App Store Connect 应使用同一条 App 记录并添加 iOS 与 macOS 平台，分别上传两个原生平台的构建；一个 Xcode 项目不会自动创建或合并后台记录。
- 如果已有上传过构建的商店记录，必须沿用该记录的 Bundle ID；已经独立发布的两个记录不能仅靠本地改标识合并。
- 原 Mac 标识下的历史日志仍位于 `~/Library/Application Support/com.witten.touping.maccaster/`；新版日志位于 `~/Library/Application Support/com.witten.touping.ipadreceiver.f4l9p953mq/`。

## 权限与运行中画质

- Mac 读取可投屏内容时自动请求屏幕录制权限，不再提供“申请权限”按钮。系统拒绝后仍需用户在系统设置中手动授权，软件不能自动授予权限。
- Mac 底部不再显示新建流的默认码率/FPS 控件。每个运行中投屏卡片都有独立的码率与帧率；码率更新当前编码器，帧率变更会重建本流采集和编码，TCP 连接保持，其他流的参数不变。调整采用短暂防抖。
- 码率是编码目标而不是恒定网络流量；静态画面的实际流量通常低于设置值。FPS 是上限，实际帧数由画面更新、设备和网络共同决定。

## iPhone / iPad 发送屏幕

- 在连接设置中选择“切换到投屏”，或首次启动选择“投屏”。设置 6–36 位数字匹配码、码率（8–100 Mbps，步进 2 Mbps）和帧率后，点击系统录屏按钮，在 iOS 系统界面确认开始广播。
- 使用 ReplayKit Broadcast Upload Extension 采集整屏，允许切到其他应用继续发送；不能按 Mac 的方式选择任意应用窗口。仅传视频，不传声音，受保护内容可能不可采集。
- Mac 或另一台 iPad 选择接收模式，使用同一匹配码连接；UDP 发现端口 8321，认证/协商 TCP 端口 8318，视频使用 WebRTC 协商出的 UDP 端口。发送设备需允许本地网络访问。
- 停止广播使用系统录屏入口。界面会显示广播状态；设置在开始前调整。广播扩展使用受限缓冲和最长边 1600 像素，避免扩展内存积压；旋转时重新配置视频尺寸。
- 广播扩展与主应用使用限定到本应用的 Keychain Access Group，共享匹配码、画质及心跳。它是 iOS 包内的扩展，不是另一个商店 App；Mac 仍为原生 macOS。
- Debug 版 iPad 的 `--verify-broadcast-encoder` 参数测试真实编码、共享格式解析、解码、横竖屏切换及共享钥匙串，不会静默开始整屏录制。实际系统广播需用户确认。

- iPad 广播码率与 Mac 同为 8–100 Mbps；选择值通过共享配置传入编码器，不再固定为 8/12 Mbps。广播期间的设置保持锁定，新码率在下次开始广播时生效。分辨率可选最长边 1600、1920 或原生（系统提供的采集尺寸），默认 1600；提高码率不会自动切换分辨率。

- Mac 接收通过 Metal 直接渲染解码画面，新帧到达触发合并绘制，解码使用独立队列；保留最新帧，最多两次 GPU 渲染在途，避免逐帧转换为 NSImage。

- iPad“原生采集”保留 ReplayKit 交付的画面尺寸，不保证等于屏幕物理像素；界面显示采集与输出尺寸。13 英寸 M2 iPad Air 本机日志已确认系统交付 1920×1440、输出 1920×1440，原生选择值为 0。
- 无旋转/缩放且像素格式兼容时，iPad 广播直接将源缓冲送入 VideoToolbox；其余情况使用转换路径，直接输入被拒绝时自动回退。

- 两端使用公开WebRTC编码器接口接入VideoToolbox低延迟码控，创建失败会让原生视频连接报错；不回退字节隧道。100 Mbps 是用户上限，不承诺瞬时硬上限。

- Mac 与 Mac、iPad 与 iPad，以及跨平台均使用相同发现、认证和视频协议；发送端选投屏，接收端选接收。匹配码为6–36位ASCII数字，默认生成8位，保留前导0，不转整数或截断。旧4位发送码首次打开自动换成新8位码，两端需要更新。
- iPad 匹配码使用普通系统输入框与默认系统输入法，不在输入过程中删改文字；数字格式在连接/保存时验证。抽屉拖动限制到边缘，避免干扰文字编辑。

### 局域网与广域网

接收端提供四种模式：局域 IP 直连、局域匹配码、广域网 IP 直连、广域网匹配码。局域模式仍使用原TCP/UDP发现，不访问配对服务。

发送端默认关闭广域网。开启“允许广域网直连”后，可单独关闭“允许广域网匹配码”：这样只监听公网IP加密直连端口，完全不用配对服务。Mac各投屏流的公网IP端口为局域端口+1000（第一路9318）；iPad为9318。公网IP模式需要用户提供可达地址及端口映射/IPv6防火墙配置，不能凭公网IP自动穿透路由器。该入口用匹配码派生密钥进行TLS 1.2 PSK/AES-GCM加密，不回退明文。

四种入口现已统一为 WebRTC 原生 H.264 RTP/SRTP 视频轨道。局域网不访问配对服务器；广域网匹配码通过自有HTTPS/WebSocket交换SDP/ICE，连接成功关闭信令。TCP/TLS不承载视频，不再使用SCTP视频字节桥。每个接收端独立编码/拥塞控制，共用原始采集源；有界DataChannel仅回传诊断。不提供TURN、视频中继或SFU，无法穿透时明确失败。

1.3（22–24）：Apple VideoToolbox低延迟码控、Level5.2协商、最多2帧在途；Mac普通采集NV12、标注时BGRA；iPad新帧触发Metal绘制。24版将WAN编码预算与BWE探测上限分离：RTP预算逐步增加，但探测上限始终为用户设置；根据独立可用BWE及丢包调整，避免22版自锁和23版快速突发。每个编码器根据真实丢帧适应60/30/20/15fps，保持分辨率。新视频协议两端需19版及以上，推荐更新当前版。

公网配对服务部署和流量限制见[Server/README.md](Server/README.md)。自有STUN外网端口暂不可达，另配置免费公开STUN作地址探测备用；它不转发视频。依赖固定为stasel/WebRTC 156.0.0（原生macOS和iOS切片，仍不使用Catalyst），校验和由SwiftPM验证。

Debug验证：Mac `--verify-native-capture`验证真实屏幕4K采集与显示，`--verify-native-routes`验证四种入口，附加`--verify-native-4k`执行4K局域媒体检查；iPad `--verify-native-routes`执行真机编码与四入口检查。同机回环不等同跨NAT实测。`Tests/NativeVideoBudgetCheck.swift`覆盖拥塞后恢复、用户边界及无数据情形；`--verify-native-motion`通过原生WAN匹配入口发送20秒1920×1440移动棋盘，检查动态内容帧率；常量画面通过不能替代运动负载验证。

以下16–18版记录为历史行为，已由原生视频替代：

1.3（16）：广域网匹配码P2P发送采用自适应码率（8Mbps起步、2–100Mbps控制范围，同时受用户码率上限约束）。每2秒根据交付确认、信用等待和发送背压调整，拥塞快速降低，有持续负载且稳定6秒后缓慢增加；静止画面不主动升码率。连接结束恢复原设置。原生采集分辨率和帧率不变。P2P本地发送队列收紧为2帧/60ms，关键帧请求间隔至少0.5秒。已经进入TCP/SCTP的字节仍无法撤回，这次没有改成原生WebRTC视频轨道。
注意：同一路投屏共用编码器，同时向局域网和P2P观众发送时，自适应码率影响该路所有观众；广域网IP/TLS入口暂不参与自适应。

1.3（18）：P2P缓冲变化事件优先恢复发送，250ms兜底；根据持续编码器主动丢帧在60/30/20/15fps之间调整（受用户帧率上限约束），编码前节流与ExpectedFrameRate同步，分辨率不变。静止画面不触发升档，断开恢复用户设置。同一路共享编码器时影响全部观众。
