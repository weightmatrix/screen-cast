# 投屏受控性能对照

当前工作只建立基线和复现工具，不修改生产码率、编码参数或帧率策略。测试入口只存在于 Debug Mac App。

## 冻结的历史版本

| 版本 | 来源 | 可用程度 |
|---|---|---|
| 18 | `c79d691`、`stable/build18` | 可恢复精确源码；旧字节视频协议，不能直接运行本套原生轨道驱动 |
| 21 | 当时未单独提交 | 仅保留已有实测日志，没有精确源码/可执行文件，不作为同条件定量基线 |
| 24 | `af42b34`、`baseline/build24` | 精确源码及本机原有 Mac App 已冻结；后续测试另记录只读观测代码的指纹 |

`baselines.json` 固定来源；`freeze.py` 在 `~/Library/Application Support/ToupingBenchmarks/baselines/` 保存源码归档、安装包、原始证据及 SHA-256 索引。可重复运行，已有内容变化会报错。Debug App 同时指纹 loader 和 debug dylib，不能只看版本号或 loader 的散列。

历史热点记录不是同条件自动测试，不能据此计算18→24的性能提升百分比。21版缺失源码的事实不通过“仿制21版”补齐。

## 固定实验

完整定义和通过条件在 `protocol.json`；默认种子20261029，图文素材由标准库生成，不采集用户屏幕。

- 输入1920×1440，运动阶段60fps，静止阶段20fps重复同一画面；用户码率上限100Mbps。
- 一次66秒：预热6秒、稳定12秒、降速12秒、恢复16秒、静止8秒、再次运动12秒。
- 链路20→4→20Mbps，只改变网络带宽；每方向延迟10ms、抖动±2ms、随机丢包0，队列上限150ms。
- 通过两端本机UDP端口转发真实STUN/DTLS/SRTP/SCTP包。所有远端ICE候选被限定到测试端口；转发仅接受指定的两个源端点，队列满会实际丢包。
- 视频仍走实际NativeVideoPeer和Apple编码/解码、Metal显示。测试转发器不部署到服务器、不进入产品连接流程，不是TURN功能。配对信令在进程内交换；SDK可能照常做少量STUN地址探测。
- 生产控制及诊断循环保持2秒；每秒的测量单独读取RTC统计，不运行控制循环。屏幕分辨率、码率上限等固定设置不匹配驱动版本时拒绝运行。

## 运行

在仓库根目录执行，先构建 Debug Mac App：

```sh
python3 Tests/Benchmarks/freeze.py
python3 -m unittest Tests/Benchmarks/test_link.py
xcodebuild -project Touping.xcodeproj -scheme Touping-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/touping-unified build -quiet > /tmp/touping-benchmark-build.log 2>&1
python3 Tests/Benchmarks/runner.py --app /tmp/touping-unified/Build/Products/Debug/MacCaster.app/Contents/MacOS/MacCaster
```

Mac需有en0 IPv4地址。测试窗口会显示合成图文；不要同时构建或运行其他重负载测试。无需重装平板、确认ReplayKit广播或修改系统全局网络配置。脚本结束时回收自己启动的测试进程及UDP端口，不替换`/Applications`中的App。

输出默认在 `/tmp/touping-benchmark-*/`：

- `report.json`：帧到达时间、条码延迟、RTC累计统计、各阶段及性能窗口事件。
- `summary.json`：分阶段帧率、冻结、延迟P95、最大间隔、编码/解码/发送队列/抖动缓冲耗时及Metal、采集窗口统计。
- `control.json`、`console.log`、`document.png`：本机测试材料，不上传公开仓库。

退出码0表示全部预设性能条件通过；2表示测试有效但性能未达标；1表示测试设施或输入无效。`functional_pass`、`comparison_valid`、`performance_pass`分开报告：正常出画面不等于性能通过。

## 预设判断

- 正常运动平均至少50fps，采集提交到解码P95不超过200ms；降速阶段至少12fps、P95不超过300ms。
- 计分阶段最大帧间隔不超过500ms、冻结累计不超过0.2秒。
- 恢复阶段8秒内、静止后再次运动2秒内，连续两个2秒窗口达到至少45fps。
- 运动输入必须实际达到57fps以上；条码测量至少20个有效样本；必须有本机转发流量并确实在降速阶段形成排队丢包，否则不能作性能对照。
- 以上是开发验收目标，不能为了让现有版本通过而在测试后放宽。

固定条码识别合成帧序号，每10个解码帧抽样；所有时间取同进程单调时钟。该延迟是“提交原始帧→解码帧”，不含物理屏幕扫描。静止时保留旧条码，其画面年龄不计入运动延迟；新阶段只计该阶段提交的新帧。RTC累计统计每秒读取，阶段边界误差可到1秒；性能窗口事件按刷出时间归类，边界误差可到2秒。

它不覆盖真实ReplayKit/ScreenCaptureKit采集、异机时钟、跨NAT及蜂窝网络波动。固定本机实验用于定位与回归，性能改善仍需同设置的真机热点复核。

## 比较结果

```sh
python3 Tests/Benchmarks/compare.py before/summary.json after/summary.json
```

只有实验设置、协议指纹、素材、种子、硬件、OS和工具链一致且测试有效，才输出阶段指标差值。未通过性能目标的24版也可以作为有效对照；测试设施失败的记录不能用于对照。报告记录源码提交、未提交差异指纹、实际源文件指纹和加载代码文件散列，避免把同版本号的不同二进制混在一起。

公开仓库只保存去除路径和原始追踪的整理结果，原始日志、素材、安装包及源码归档均留在本机。

## 已记录的24版对照

整理结果在 `reference-build24.json`，来源为一次有效的受控运行，不是性能验收通过记录。

| 阶段 | 实际输入fps | 接收fps | 冻结累计秒 | 性能目标 |
|---|---:|---:|---:|---|
| 稳定20Mbps | 60.0 | 42.2 | 0.0 | 未通过 |
| 降至4Mbps | 60.0 | 10.4 | 5.7 | 未通过 |
| 恢复20Mbps | 60.0 | 0.5 | 12.3 | 未通过 |
| 静止后再运动 | 60.0 | 15.8 | 0.0 | 未通过 |

测试链路和输入有效，带宽下降确实形成了队列丢包；恢复阶段16秒内未达到持续45fps。后续第3步优先修复恢复链路。P95须连同样本数阅读，低帧率阶段样本稀少，不把单个样本外推为普遍延迟。

## 预算恢复候选（源码25）

`reference-budget-recovery.json`保存第3步的有效单轮对照。移除排队清零的恢复前置条件，并在独立BWE安全余量内加快有界恢复；硬件编码与帧率参数不变。恢复阶段由约0.5升至2.4fps，末段编码预算回到约15.9Mbps，但仍未达到预设恢复目标。

周期ALR探测的中间实验未改善恢复帧率，已撤销。三次实验后按项目止损规则停止继续试调；后续单独检查硬件编码器丢帧。不能用一次指标改善替代整体性能通过。
