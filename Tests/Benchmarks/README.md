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

## 硬件实时码控候选（源码26）

`reference-hardware-realtime.json`保存第4步的有效单轮对照；普通实时硬件码控加1.5倍目标/1秒输出约束。硬件状态回读为true。帧时长实验未改善，已撤销；只切码控模式仍高延迟，增加输出约束后恢复阶段约60.1fps、P95约131ms、冻结0。

整体性能仍失败：4Mbps阶段P95约780ms、冻结0.73秒；静止后运动P95约1018ms。阶段接收帧数可含积压交付，不能把高帧数当作低延迟。此轮没有画质量化验收或真机热点回归，不替换已安装App；三次实验后停止追加参数，下一阶段处理帧节奏与发送积压。旧iOS保持原硬件低延迟路径，未实机验证。

## 第5步负向实验（保持源码26）

`pacing-experiments.json`记录三项顺序实验，均已撤销：提高pacer倍率、额外100ms编码硬限速、基于实际编码字节的输入节流。前两项对照有效但没有改善弱网/重新运动延迟；第三项严重低帧率导致条码样本不足，functional_pass/comparison_valid均false，禁止作为有效量化对照。

末次统计重传包约占发送包31%，有大量NACK。测试链路本来包含抖动/队列丢包，这只是后续定位线索，不证明全是错误重传。未修改协议条件或放宽指标；SDK未包含旧SendNackDelayMs开关，未添加它。按三次失败止损规则停止试调，下一轮先查重传与队列来源。生产源码与版本保持26，Mac Debug测试产品已恢复构建，未更换设备安装版。

## 第5步：包级诊断与2×2对照

`packet_trace.py`只读取SRTP明文RTP头及Debug信令给出的PT→编码映射，区分H.264/RTX/其他，按阶段记录收到、链路丢弃、成功sendto和同一SSRC的链路乱序。保留每流最近4096个身份、最多32流，超限使诊断无效。测试不解密媒体、不保存包内容、不修改生产传输。RTX里的原始包序号已加密，不能逐包证明RTX对应哪个原包；sendto成功也不等于对端收到/解码。

默认命令仍按原`protocol.json`运行，独立逐包±2ms抖动及验收阈值不变。另有三个诊断条件：

```sh
python3 Tests/Benchmarks/runner.py --app /tmp/touping-unified/Build/Products/Debug/MacCaster.app/Contents/MacOS/MacCaster --diagnostic-profile ordered
python3 Tests/Benchmarks/runner.py --app /tmp/touping-unified/Build/Products/Debug/MacCaster.app/Contents/MacOS/MacCaster --diagnostic-profile steady
python3 Tests/Benchmarks/runner.py --app /tmp/touping-unified/Build/Products/Debug/MacCaster.app/Contents/MacOS/MacCaster --diagnostic-profile steady-ordered
```

`ordered`把每包采样到期时间向前一包到期时间取最大值，保序但可能小幅成批交付；`steady`全程20Mbps，阶段时长/运动模式仍按原计划。它们均记录不同setup，强制comparison_valid/performance_pass=false，不替代原验收；diagnostic_valid单独检查输入/路径/观测有效性。退出2也可表示诊断有效但不是验收通过，1才表示设施/诊断无效。不同profile不得用原compare.py算性能提升。原始输出仍只留/tmp。

整理证据见`packet-diagnosis.json`。四组主实验同二进制；后续增加帧率/大帧只读日志的运行及已撤销帧率修复候选各有独立代码指纹。

| 条件 | 链路乱序视频包 | 链路丢弃视频包 | 送出RTX | 重新运动P95 |
|---|---:|---:|---:|---:|
| 原20→4→20Mbps，逐包抖动 | 15340 | 80 | 15678 | 1634ms |
| 原带宽变化，FIFO交付 | 0 | 494 | 767 | 764ms |
| 恒定20Mbps，逐包抖动 | 23919 | 0 | 26394 | 1256ms |
| 恒定20Mbps，FIFO交付 | 0 | 55 | 356 | 1556ms |

单轮结果表明独立逐包抖动在此负载下制造约45–50%视频包乱序，显著放大重传；不能直接当作典型Wi-Fi。保序后仍有带宽骤降与静止恢复的延迟，因此也不能把全部卡顿归因重传。额外只读细查在恒定20Mbps/FIFO下无链路丢包，仍有约1635ms重新运动P95；约100ms内多张170–260KB非关键帧集中输出。纠正20→60fps声明滞后的候选仍有突发，延迟未改善，已撤销。

13项定向检查通过；Mac/iOS Debug及Mac Release构建通过。生产参数和源码版本保持26，不替换设备。下一步应独立验证VT短窗口限制是否真实生效及瞬时输出控制；属性返回成功不能代替输出测量。原乱序场景保留为压力证据，第5步尚未验收，未进入复制优化。

## 编码器瞬时输出验证（未采用新参数）

独立工具`encoder_burst_probe.swift`只运行本机硬件H.264：3秒运动、4秒静止、4秒重新运动，1920×1440、固定15Mbps，共500帧。输入为本套生成的document.png，不采集用户屏幕。它不包含WebRTC、网络、应用的两/三帧在途上限，也不作画质验收；不能代替App性能基线。示例（先将TP_PROBE_IMAGE设为一次本机测试生成的PNG绝对路径）：

```sh
swiftc -O Shared/StreamFormat.swift Tests/Benchmarks/encoder_burst_probe.swift -o /tmp/touping-encoder-burst-probe
/tmp/touping-encoder-burst-probe 1 invalid "$TP_PROBE_IMAGE"
/tmp/touping-encoder-burst-probe 0.1 valid "$TP_PROBE_IMAGE" long-first
/tmp/touping-encoder-burst-probe 0.1 valid "$TP_PROBE_IMAGE" vbr
```

`valid/invalid`控制是否提供明确帧时长；可选`long-first/short-first`设置两个窗口的顺序；`vbr`需要macOS26+，使用原生VBR、等于目标的VBVMaxBitRate和100ms缓冲，不与AverageBitRate/DataRateLimits混用。输出仅聚合数据：设置/回读状态、硬件状态、恢复第一秒的帧大小及任意100ms累计、在途峰值和末尾排空时间，不保存媒体字节。

整理结果在`encoder-burst-investigation.json`。早期探针版本逐步增加选项，未冻结首六次二进制，结果仅作探索；最终工具的源码、二进制、素材指纹单独保存。属性接受并回读100ms限制，不等于逐个100ms都严格符合额度。独立探针长窗口恢复突发约0.92–1.20MB；短窗口配合明确帧时长约0.32–0.40MB，但不能外推到动态网络。

三项完整App诊断（恒定20Mbps、FIFO交付）：短长窗口+明确帧时长导致恢复约1.7fps；VBR+两帧在途恢复P95约176ms、稳定34.2fps；VBR+三帧在途恢复P95约94ms、稳定36.2fps。三者均未达到原目标，全部撤销，没有把低延迟与帧率回退交换后发布。VBR确实启用、硬件状态为true，但回调耗时约20–56ms，包含内部排队，不能直接视为纯硬件计算时间。

按项目三次试调止损暂停追加参数。最终只读固定码率VBR探针500帧全部完成，最多三帧在途、末尾无积压，不能据App回调时长就认定硬件跑不了60fps。下一轮优先验证动态码率/FPS更新是否频繁重配置，再评估速度与解码画质；不能无限加在途帧。保持源码26、现有协议和设备安装版；Mac Debug已恢复构建，独立工具编译及500帧参考检查通过。第5步仍未通过。

## 帧级QP反馈（27版交付）

最终采用公开BaseFrameQP硬件接口，逐帧用实际输出字节对比WebRTC当前预算调整QP；单次上调最多6、下调1，QP限制10–51，静止小包不继续降低QP，避免静止后突然积累大帧。每帧都带QP，按Apple接口约定不再依赖该模式下被忽略的AverageBitRate/DataRateLimits。保持原尺寸、无B帧、最多两帧在途；不支持接口或约束High的情况重新创建旧模式编码器。四个入口仍共用原生H.264轨道，服务端不变。

`reference-frame-qp.json`保留最终三个场景与画质采样。恒定20Mbps/FIFO诊断的各计分阶段指标均达到原阈值：约57–59fps、恢复运动P95约98ms、冻结0；该诊断仍不算原协议整体通过。原高乱序压力场景恢复运动约58.4fps/P95约37ms、恢复阶段无冻结，但稳定/骤降阶段仍未通过；FIFO带宽骤降期间P95约1933ms、冻结1.495秒，恢复后约60fps/P95约34ms。

独立15Mbps同素材17帧解码亮度采样：旧平均码控约26.82dB，新控制约35.05dB；顶端256行约26.18→35.27dB。输出字节约20.74→17.19MB。仅是采样亮度/顶部条带，不能外推为全色彩、文字可读性或真机跨网画质验收。新增`manual --quality`工具模式，编码结束后离线解码测量，不干扰编码计时。

```sh
/tmp/touping-encoder-burst-probe 1 invalid "$TP_PROBE_IMAGE" --quality
/tmp/touping-encoder-burst-probe 1 invalid "$TP_PROBE_IMAGE" manual --quality
```

14项定向检查、Mac/iOS Debug与Mac Release构建通过；Mac四路功能及旋转回归通过。13英寸已更新，设备自测须保持前台，后台暂停会使VT会话无效；不把受后台影响的运行当通过。11英寸当前不可调试，旧接收协议仍兼容。真实ReplayKit跨网广播仍需系统确认后复测。该交付解决主要静止恢复问题，第5步的弱网骤降/高乱序仍未全面验收，不宣称全部性能目标已完成。


27版补充验证：3840×2160功能回归使用30fps合成注入、配置60fps上限，不等于4K60性能验收。单独追加ExpectedFrameRate提示曾造成帧率回退，已撤销，最终编码器源码指纹与已验证的原压力场景版本完全一致。13英寸完整设备自测遇VTInvalidSession(-12903)及系统暂停，未计为通过；已退出测试恢复普通界面，真实广播等待用户确认。
