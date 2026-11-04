# 投屏轻量配对服务

公网入口：https://zhibenwang.com/touping/health
WebSocket：wss://zhibenwang.com/touping/signal
独立应用沙盒：`/srv/apps/touping/`；源码部署目录：`/srv/apps/touping/app/`。
旧`/home/ubuntu/touping-signal`只保留兼容符号链接，不保存第二份数据。
容器：touping-signaling，独立 Compose project `touping`。

服务只处理SDP/ICE配对和有界连接元数据，不接收屏幕、音频或任意二进制消息，不提供TURN、视频转发或下载。每端配对帧累计最多64KiB、96帧；每对连接描述总计最多64KiB；单帧16KiB、SDP12KiB；最多64个连接、32个等待房间；等待最多10分钟。配对握手每IP每分钟20次，直连审计入口另限60次。配对时发送匹配码SHA-256，不发送原始匹配码。

双方P2P建立后同时发送done，服务关闭配对连接并删除房间，不持续承载视频。等待期间只有每60秒一个WebSocket ping/pong；长时间无人连接时客户端有退避重连。以上应用数据限额不包含TLS/TCP/IP协议开销；不承诺把所有公网流量硬限制为64 KiB。

STUN仅响应IPv4 Binding请求（20–256字节请求，32字节响应），每IP每分钟60次；不支持TURN Allocate。自有UDP3478在本次外网探测超时，容器内/服务器本机探测通过；客户端配置Cloudflare公开STUN备用，仅探测地址，不申请TURN。若希望只使用自有地址探测，可在云防火墙放行UDP3478并在真实跨网测试通过后移除备用。不要把UDP3478配置成视频代理。

## 部署

### 52版：受限自有STUN与失败诊断

腾讯旧STUN从本次客户端网络外部探测超时，未修改云安全组；新增搬瓦工`/srv/apps/touping/ops/stun_server.py`和`touping-stun.service`，UDP3478只做IPv4 Binding，32字节响应，无TURN Allocate/媒体转发。拒绝坏长度/属性边界，100包/秒总量、每IP60包/分钟、2048个IP条目。DynamicUser辅以touping-audit组遍历ops，仅能读脚本；systemd明确禁读data/secrets/backups/.ssh，无能力、只读、CPU5%/32MiB/Tasks8。不重启代理。旧腾讯入口保留；客户端首选搬瓦工、Cloudflare备用。两台自有机器没有配置公网IPv6，不声称已提供IPv6 STUN。运维检查`systemctl status touping-stun.service`及外部Binding事务，停用只disable --now该unit，不动代理。

Web目录只读挂载到/app/Web，原子替换HTML/JS即可发布静态修正；首次新增挂载需要在app目录只重建touping容器。52前compose和Web备份在backups/before52，镜像touping-signaling:before-build52，回滚这些项保留审计。客户端与网页新增无IP的ICE阶段、数量和超时诊断；公网候选交换完整仍可能不能直连，本次手机蜂窝复测即失败，不能把STUN响应当作跨网验收。

### 51版：网页接收入口

`https://zhibenwang.com/touping/`提供无外部依赖的WebRTC接收页，发送端生成`#code=<匹配码>`片段链接预填代码；不把代码放HTTP查询或referrer。公网须开启发送端广域及匹配码，复用原生配对、H.264/Opus轨道及最多4个公网接收槽，无媒体中继或TURN。浏览器握手接受platform=browser，使用随机localStorage实例ID、通用Browser机型和OS版本0（未知），不抓原始UA/硬件标识；沿用私有审计及异地快照。

部署还需上传`Web/receiver.html`、`Web/receiver.js`至app/Web；Docker复制Web目录。现有nginx/touping路由即可，不改业务路由或端口。静态资源no-store/no-referrer/nosniff/CSP，单份最多64KiB；不把媒体写入HTTP或WebSocket。配对成功关闭信令后，浏览器保持媒体连接。更换静态资源也需重建本投屏镜像，不运行其他应用发布脚本。

局域页面由Mac/iPad发送端自己提供，默认10318（原信令端口+2000），不依赖云服务器；仅接受私网来源及本机Host、同源JSON POST和匹配码，4个局域网页会话上限，其他数据/数量/超时保护见开发手册。只在可信局域网使用HTTP；公网使用HTTPS入口，不将局域HTTP端口映射为公网服务。页面默认静音，手动开声/全屏；后台、锁屏、穿透失败及旧Safari兼容须真机验证。

51前服务文件备份`/srv/apps/touping/backups/before51/`，镜像`touping-signaling:before-build51`。回滚只恢复这四个服务文件并重建touping容器，保留data/audit及异地副本；旧服务不读取Web目录。客户端50备份仅本机保留，不提交构建产物。

### 50版：设备元数据与双机隔离备份

腾讯云和搬瓦工各有独立`/srv/apps/touping/`，不混入其他应用目录。腾讯云`app/`为服务源码，`data/audit/`为原始审计，`data/replication/`为最近成功回执，`ops/`为运维脚本和timer，`secrets/`为专用SSH密钥及固定主机公钥，`backups/`为部署回滚材料。搬瓦工只运行SSH受限接收脚本，快照放`data/replica/`；不部署第二套配对服务，不接收音视频。其他应用可沿用`/srv/apps/<app>/`约定，本任务没有迁移其既有服务。

50版匹配码握手增加可选设备信息：随机应用实例标识、系统类型/版本、硬件机型、应用版本/构建号；老客户端缺少这些字段时明确记为空。字段须通过固定白名单、格式和长度校验；不会转发给对端。新`/touping/audit` WebSocket入口仅接受公网IP直连的attempt/connected/ended元数据报告，写入后才返回`audit_recorded`，不创建配对房间；拒绝媒体、SDP及额外字段。与匹配入口隔离每IP限流（审计60次/分钟，配对20次/分钟），仍共用64个连接及原帧/字节限额。每个直连对端最多3个一次性报告、单次8秒、应用全局最多16个在途报告，无轮询或无限重试。新接收端经原鉴权信令把随机会话标识交给发送端，双端报告可关联；旧对端不保证关联。

来源IP是服务器观察到的上报/配对连接地址，可能属于NAT或代理，不是实名身份。硬件MAC地址不随互联网路由传递，应用不获取MAC、序列号、设备名称、账号或屏幕内容。随机ID区分应用实例，主App与广播扩展可有不同ID，重装/清除应用数据可变，不是永久硬件ID。设备字段和直连事件均标为`client_report_only`，不可当作真实性认证或实际媒体时长证明。直连上报尽力发送，不阻塞投屏；断网、限流、应用被杀等可漏报/乱序，不承诺全连接完整审计。局域连接仍不主动上报。

`ops/audit_snapshot.py`将源日志的完整行压缩，经专用SSH密钥交给搬瓦工。接收账户`touping-audit`的密钥仅允许腾讯来源IP和固定接收命令，禁止shell/PTY/转发；账户无sudo，脚本root持有。固定主机公钥校验、文件名白名单、SHA256/大小校验、写入fsync、目录原子发布，失败不发布半份备份。接收端单进程锁、20分钟超时和内存/CPU/文件限制；腾讯timer低优先级、10%CPU、384MiB内存，每小时执行，未变则跳过，成功后记录回执，失败保留旧副本并由systemd记失败。同步是异步快照，不是双机同步写入或不可篡改存证；源日志轮转期间/两次任务间存在窗口，不能保证零丢失。

源日志上限约200MiB；异地保留最近2份（至多约400MiB，临时接收时约600MiB），写入前额外保留1GiB空闲空间；没有视频备份。源端90天过期规则继续生效，异地仅保留最近两次成功快照，不另作90天保证。运维步骤、失败检查及回滚见[ops/README.md](ops/README.md)。密钥、主机配置、回执和原始日志均不提交公开仓库。

### 连接审计（47版）

广域匹配信令连接以JSONL持久保存在部署目录`audit/connections.jsonl`，容器重建不丢失；文件权限0600，目录由容器UID65534持有，不能映射为公开下载地址。记录UTC时间、随机连接ID/配对ID、代理确认的来源IP、角色、等待/加入、双方各自声明直连成功、拒绝原因、信令关闭及信令字节/时长；不记录原始匹配码、房间摘要、SDP/ICE载荷或音视频。nginx覆盖X-Real-IP，服务只接受内部代理的合法单个IP，拒绝伪造/换行内容。写入异常时拒绝新配对，不静默丢弃审计。

默认5MiB一卷、最多40卷（约200MiB），90天为过期阈值；先触及容量上限会提前淘汰旧记录，不保证90天完整覆盖。`TOUPING_AUDIT_RETENTION_DAYS`可配置1–3650天，有审计写入时至多每小时执行一次过期清理，空闲时不单独唤醒。运维人员需按自己的保存需求定期安全归档；原始记录不得提交公开Git仓库。

运维查看：`sudo tail -n 50 /home/ubuntu/touping-signal/audit/connections.jsonl`。`transport_peer_port`是服务实际接受的TCP对端端口（反向代理存在时通常属于代理），不是声称已观测到用户公网源端口。日志是本机运维记录，没有防篡改或独立时间戳存证保证。

这些记录证明服务器观察到的配对事件及客户端声明，不是实名身份验证或画面内容证明；服务器在配对成功后退出，无法观测实际投屏结束，`signaling_duration_ms`不是投屏时长。局域匹配/局域IP不在服务端审计覆盖内；公网IP直连自50版补充客户端生命周期报告，限制见上文。不读取或审核画面，不能用连接日志代替内容治理。

部署前先创建受限的持久化目录：

```sh
sudo install -d -m 700 -o 65534 -g 65534 /srv/apps/touping/data/audit
```

服务器已缓存排课后端Python运行时镜像，因此Compose复用该镜像以免额外下载Python镜像；新容器清除了业务入口点，不执行排课迁移或启动业务，且无数据库环境变量。CPU上限0.3核、内存96MiB、只读文件系统、非root、日志轮换。独立机器可设置TOUPING_RUNTIME_IMAGE=python:3.12-slim。

上传signaling.py、audit.py、Dockerfile、compose.yml，然后：

```sh
docker compose -p touping -f compose.yml up -d --build
```

首次路由接入由deploy_route.py完成：备份nginx运行配置与模板，增加/touping/位置块，通过nginx -t后仅reload，不重启业务容器；失败恢复原配置。动态解析Docker内部DNS，信令容器重建后仍能解析。

同时同步了排课项目的nginx.https.conf.template中的独立位置块，防止其以后发布时丢失该路由。没有改动排课后端、数据库或账号。

## 验证与回滚

### 49版建议匹配码

同一WebSocket入口新增一次性`{"role":"suggest","exclude":["已有码的SHA256", "..."]}`，排除列表最多32项。服务器用安全随机数生成8位数字，跳过当前配对注册表及排除列表，最多128次，返回`{"type":"suggestion","code":"建议码"}`后结束查询，不注册发送房间、不预留该码、不轮询、不传视频。原限流/数据限额继续适用；审计只增加`code_suggested`元数据事件，不记录建议码或排除摘要。

建议只表示检查当时未在服务器配对注册表中占用，不代表离线局域设备或未登记会话的全局独占。正式发送注册仍原子检查占用；若确认前被抢占，会再次提示冲突并可重新取建议。占码返回`code_in_use`，房间容量满返回`server_busy`，不再用同一句话混淆。老客户端继续兼容。

49升级前文件位于`backups/build49-before-suggestions/`，镜像`touping-signaling:before-build49`；恢复signaling.py并重建独立服务即可回滚，保留审计目录。

47版服务升级前的三个文件在`backups/build47-before-audit/`，旧镜像保留为`touping-signaling:before-build47`。仅回滚本次服务升级时，恢复备份的signaling.py、Dockerfile、compose.yml并重建独立signaling容器；保留audit目录，不删除已产生的连接记录，也不需要撤销nginx路由。

```sh
python3 -m unittest discover -s Server -p 'test_signaling.py'
curl --fail https://zhibenwang.com/touping/health
```

回滚：先撤销nginx模板和运行配置中的/touping/块，通过nginx -t后reload，再在独立目录docker compose -p touping -f compose.yml down。配置备份在部署目录backups/。不运行排课项目的整套发布脚本。
