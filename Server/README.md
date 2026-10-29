# 投屏轻量配对服务

公网入口：https://zhibenwang.com/touping/health
WebSocket：wss://zhibenwang.com/touping/signal
独立部署目录：/home/ubuntu/touping-signal
容器：touping-signaling，独立 Compose project `touping`。

服务只转发 SDP/ICE 连接描述，不接收屏幕、音频或任意二进制消息，不提供 TURN、视频转发或下载。每端配对帧累计最多 64 KiB、96 帧；每对连接描述总计最多64 KiB；单帧16 KiB、SDP12 KiB；最多64个连接、32个等待房间；等待最多10分钟。握手每IP每分钟20次。配对时发送匹配码的SHA-256值，不发送原始匹配码。

双方P2P建立后同时发送done，服务关闭配对连接并删除房间，不持续承载视频。等待期间只有每60秒一个WebSocket ping/pong；长时间无人连接时客户端有退避重连。以上应用数据限额不包含TLS/TCP/IP协议开销；不承诺把所有公网流量硬限制为64 KiB。

STUN仅响应IPv4 Binding请求（20–256字节请求，32字节响应），每IP每分钟60次；不支持TURN Allocate。自有UDP3478在本次外网探测超时，容器内/服务器本机探测通过；客户端配置Cloudflare公开STUN备用，仅探测地址，不申请TURN。若希望只使用自有地址探测，可在云防火墙放行UDP3478并在真实跨网测试通过后移除备用。不要把UDP3478配置成视频代理。

## 部署

服务器已缓存排课后端Python运行时镜像，因此Compose复用该镜像以免额外下载Python镜像；新容器清除了业务入口点，不执行排课迁移或启动业务，且无数据库环境变量。CPU上限0.3核、内存96MiB、只读文件系统、非root、日志轮换。独立机器可设置TOUPING_RUNTIME_IMAGE=python:3.12-slim。

上传signaling.py、Dockerfile、compose.yml，然后：

```sh
docker compose -p touping -f compose.yml up -d --build
```

首次路由接入由deploy_route.py完成：备份nginx运行配置与模板，增加/touping/位置块，通过nginx -t后仅reload，不重启业务容器；失败恢复原配置。动态解析Docker内部DNS，信令容器重建后仍能解析。

同时同步了排课项目的nginx.https.conf.template中的独立位置块，防止其以后发布时丢失该路由。没有改动排课后端、数据库或账号。

## 验证与回滚

```sh
python3 -m unittest discover -s Server -p 'test_signaling.py'
curl --fail https://zhibenwang.com/touping/health
```

回滚：先撤销nginx模板和运行配置中的/touping/块，通过nginx -t后reload，再在独立目录docker compose -p touping -f compose.yml down。配置备份在部署目录backups/。不运行排课项目的整套发布脚本。
