## 2026-11-05 当前运维要求

境外复制已停止（腾讯timer禁用，service inactive/dead），不新增第二台。保留已有快照待依法核对，不擅自删除。audit_snapshot.py未升级200段格式，且destination_region不是CN时拒绝发送；禁止重启旧境外复制任务。

当前源日志最多200个5MiB段，固定184天，满后拒绝新配对；不要通过删除未到期日志恢复容量，应扩容并调整有界实现。新的cleanup_audit.py和touping-audit-cleanup.service/timer只在境内运行，主日志及admin-audit使用共享.lock；锁文件归各数据目录所有者，避免root清理造成nobody写入失败。标准systemd入口只链接ops，脚本/上传均留在投屏沙盒。后台日志读挂载及管理操作写目录见排课仓库docker-compose.touping-audit.yml；不得向HTTP暴露data目录。

下方为旧复制运维档案，不代表仍在启用。

# 投屏审计运维沙盒

应用目录统一为`/srv/apps/<app>/`。目录隔离还须配合账户、权限、容器/服务资源限制；仅创建文件夹不等于OS级安全沙盒。下列配置只涉及投屏，不迁移或停止其他应用。

## 当前布局

腾讯：`/srv/apps/touping/{app,data/audit,data/replication,ops,secrets,backups}`。
搬瓦工：`/srv/apps/touping/{data/replica,ops,secrets,backups,.ssh}`。
旧腾讯home部署入口已归档；`app/audit`仍在沙盒内链接到`../data/audit`，使旧备份Compose可挂载同一日志。禁止把任何data/secrets目录映射到HTTP或提交仓库。

所有上传在`ops/staging/`，不要使用服务器/tmp或home；部署账户持有该目录0700，发布后原子移动到对应app/Web或ops。旧散落日志、暂存、旧路由脚本和候选配置统一在`backups/cleanup-20261104/`私有归档。路由脚本现在位于ops，sudo运行，所有临时配置也写ops/staging。

腾讯app目录保持原部署账户，沙盒root:ubuntu 0750；data/audit保持65534:65534 0700，日志0600。secrets和backups仅root可读。搬瓦工沙盒root:touping-audit 0710，ops为root持有且组可读执行；replica为touping-audit 0700，文件0600。该账户home为沙盒、无sudo，只有受限专用密钥，不复用管理员密钥。

## 初次配置的必要项

- 腾讯源码放app，运维文件放ops；创建65534持有的data/audit和root持有的data/replication；Compose默认挂载`../data/audit`。旧目录迁移时保留原审计，不删除或截断。
- 在腾讯secrets内生成专用ed25519密钥`replica_ed25519`，私钥0600；复制管理员已核验的搬瓦工主机公钥到secrets/known_hosts（不能关闭主机校验）。secrets/replication.json仅包含`{"destination":"touping-audit@备份主机"}`。
- 搬瓦工安装Python脚本和receive-audit wrapper；账户home下`.ssh/authorized_keys`由root持有，单行前缀为`from="腾讯实际出口IP",restrict,command="/srv/apps/touping/ops/receive-audit"`，后接专用公钥。root持有文件夹，接收账户不能修改运维脚本。不得给该密钥普通shell、sudo或其他路径权限。
- 腾讯将两个systemd unit从ops符号链接到`/etc/systemd/system/`，daemon-reload；先手动start service验证，再enable --now timer。不需要打开新公网端口、重启SSH、nginx或搬瓦工代理。

## 检查

```sh
# 腾讯
sudo systemctl start touping-audit-replica.service
sudo systemctl show touping-audit-replica.service -p Result -p ExecMainStatus
sudo systemctl list-timers touping-audit-replica.timer
sudo cat /srv/apps/touping/data/replication/last-success.json
sudo journalctl -u touping-audit-replica.service -n 10 --no-pager

# 搬瓦工，仅看元数据及容量；不要向公开输出导出原始日志
sudo ls -ld /srv/apps/touping/data/replica/snapshot-*
sudo du -sh /srv/apps/touping/data/replica
```

接收端验证文件摘要后才返回AUDIT_SNAPSHOT_OK。回执是最近成功任务，不代表下次任务或当前状态成功。每小时加0–2分钟抖动；失败不立即无限重试，排查固定主机公钥、专用密钥权限、磁盘空间和服务journal。ssh并发接收被锁拒绝，坏摘要/路径/超量内容不发布快照。异地保留两份成功快照（最多约400MiB；接收时约600MiB），额外留1GiB空间；不能代替完整历史归档。源日志并发轮转时也可能产生快照窗口，不能声称零丢失。

两台机器上的root依然可修改日志；未实现独立签名时间戳或不可变存储。备份链路加密，磁盘文件为受权限保护的明文，并非静态加密。

## 回滚

先`systemctl disable --now touping-audit-replica.timer`；源端服务文件和镜像在`backups/before50`、`touping-signaling:before-build50`，恢复文件后在app目录只重建`touping` project。保留沙盒和data/audit；app/audit兼容链接确保旧Compose继续使用原日志。不撤销其他应用路由、不操作业务数据库、不删除异地现存快照。需撤销复制访问时仅删除专用authorized_keys条目，不动管理员密钥或代理服务。
