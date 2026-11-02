# 投屏轻量配对服务

公网入口：https://zhibenwang.com/touping/health
WebSocket：wss://zhibenwang.com/touping/signal
独立部署目录：/home/ubuntu/touping-signal
容器：touping-signaling，独立 Compose project `touping`。

服务只转发 SDP/ICE 连接描述，不接收屏幕、音频或任意二进制消息，不提供 TURN、视频转发或下载。每端配对帧累计最多 64 KiB、96 帧；每对连接描述总计最多64 KiB；单帧16 KiB、SDP12 KiB；最多64个连接、32个等待房间；等待最多10分钟。握手每IP每分钟20次。配对时发送匹配码的SHA-256值，不发送原始匹配码。

双方P2P建立后同时发送done，服务关闭配对连接并删除房间，不持续承载视频。等待期间只有每60秒一个WebSocket ping/pong；长时间无人连接时客户端有退避重连。以上应用数据限额不包含TLS/TCP/IP协议开销；不承诺把所有公网流量硬限制为64 KiB。

STUN仅响应IPv4 Binding请求（20–256字节请求，32字节响应），每IP每分钟60次；不支持TURN Allocate。自有UDP3478在本次外网探测超时，容器内/服务器本机探测通过；客户端配置Cloudflare公开STUN备用，仅探测地址，不申请TURN。若希望只使用自有地址探测，可在云防火墙放行UDP3478并在真实跨网测试通过后移除备用。不要把UDP3478配置成视频代理。

## 部署

### 连接审计（47版）

广域匹配信令连接以JSONL持久保存在部署目录`audit/connections.jsonl`，容器重建不丢失；文件权限0600，目录由容器UID65534持有，不能映射为公开下载地址。记录UTC时间、随机连接ID/配对ID、代理确认的来源IP、角色、等待/加入、双方各自声明直连成功、拒绝原因、信令关闭及信令字节/时长；不记录原始匹配码、房间摘要、SDP/ICE载荷或音视频。nginx覆盖X-Real-IP，服务只接受内部代理的合法单个IP，拒绝伪造/换行内容。写入异常时拒绝新配对，不静默丢弃审计。

默认5MiB一卷、最多40卷（约200MiB），90天为过期阈值；先触及容量上限会提前淘汰旧记录，不保证90天完整覆盖。`TOUPING_AUDIT_RETENTION_DAYS`可配置1–3650天，有审计写入时至多每小时执行一次过期清理，空闲时不单独唤醒。运维人员需按自己的保存需求定期安全归档；原始记录不得提交公开Git仓库。

运维查看：`sudo tail -n 50 /home/ubuntu/touping-signal/audit/connections.jsonl`。`transport_peer_port`是服务实际接受的TCP对端端口（反向代理存在时通常属于代理），不是声称已观测到用户公网源端口。日志是本机运维记录，没有防篡改或独立时间戳存证保证。

这些记录证明的是服务器观察到的配对事件及客户端声明，不是实名身份验证或画面内容证明；服务器在配对成功后退出，无法观测实际投屏结束，`signaling_duration_ms`不是投屏时长。局域匹配/局域IP/公网IP不经本服务，当前不在服务端审计覆盖内。不读取或审核画面，不能用连接日志代替内容治理。

部署前先创建受限的持久化目录：

```sh
sudo install -d -m 700 -o 65534 -g 65534 /home/ubuntu/touping-signal/audit
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
