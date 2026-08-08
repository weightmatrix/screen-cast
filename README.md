# Mac 投屏到 iPad

局域网投屏方案：Mac 端通过 ScreenCaptureKit 采集屏幕并按 H.264 编码，走 TCP 推流；iPad 端接收数据流并解码显示。支持像 AirPlay 一样选择**任意应用或单个窗口**投屏。

## 项目结构

```
投屏/
├── MacCaster/       macOS 发送端（ScreenCaptureKit 采集 + VideoToolbox 编码 + TCP 服务端）
│   └── MacCaster.xcodeproj
└── iPadReceiver/     iPadOS 接收端（TCP 客户端 + AVSampleBufferDisplayLayer 解码）
    └── iPadReceiver.xcodeproj
```

## 使用前提
- Mac：macOS 14.0+，Xcode 已安装
- iPad：iPadOS 15.0+
- Mac 与 iPad 连在**同一 WiFi** 下，路由器不要开启“AP 隔离/客户端隔离”

## 构建
1. 用 Xcode 打开 `MacCaster/MacCaster.xcodeproj`，点 Run 运行（无需开发者账号，本地运行即可）。
2. 用 Xcode 打开 `iPadReceiver/iPadReceiver.xcodeproj`：开发团队已预先配置好（13911851897@163.com 的免费开发者账号，Team F4L9P953MQ），选好目标设备直接点 Run 即可装到 iPad。若换账号/换设备，在 Signing & Capabilities 里重新选择 Team 即可。

## 使用步骤
1. **Mac 端**：
   - 第一次运行会弹出**屏幕录制**权限提示，点击允许；如果已拒绝，请到 系统设置 → 隐私与安全性 → 屏幕录制 中勾选后**重启 App**。
   - 等窗口列出应用列表后，点某个窗口（或“投屏整个应用”）的「投屏」。
   - 窗口底部会显示投屏服务地址（IP 和端口 8317）。监听端口时若 macOS 防火墙询问，点“允许”。
2. **iPad 端**：
   - 输入 Mac 显示的 IP 地址（端口一般保持 8317），点「连接」。
   - 第一次连接会弹「本地网络」权限提示，点“允许”。
   - 连接成功后画面即开始显示。

## 说明
- 视频编码：H.264（Main Profile），可在投屏中切换 4M / 8M / 16M 码率，即改即生效。
- 传输协议：TCP，端口固定 `8317`；帧格式为 `[4字节大端长度][1字节类型][负载]`（类型 0=SPS/PPS 配置，1=视频帧）。
- 支持多台设备（iPad / iPhone）同时连接和接收。
- 当前为纯视频，未包含音频。
- 限制：只要窗口在屏幕上可见即可采集；被移到其他桌面空间的窗口不会出现在列表。

## 常见问题
| 现象 | 解决 |
| --- | --- |
| Mac 列表为空 | 先打开一个应用窗口再刷新；若为权限问题，允许“屏幕录制”后重启 App |
| iPad 连不上 | 确认同一 WiFi、端口一致、Mac 防火墙未拦截；用 Mac 的 IP 而不是电脑名 |
| 画面卡顿 | 降低码率档位，或关闭其它占用带宽的应用 |