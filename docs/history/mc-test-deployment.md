# MC 测试整合包部署记录

## 2026-07-01

### 本次目标

- 清空现有测试整合包服务端。
- 下载一个轻量级新版本整合包。
- 完成服务端部署、配置和启动验证。
- 生成/取回客户端整合包压缩包。

### 选用整合包

- 来源：Modrinth
- 项目：`Gierem Vanilla Plus: Client & Server Edition`
- 项目 ID：`fBLSVOCX`
- 版本 ID：`K9gdsMNS`
- 版本：`Gierem Vanilla Plus 1.0.0`
- Minecraft：`1.21.1`
- Loader：`Fabric`
- 客户端：required
- 服务端：required
- 下载文件：`Gierem Vanilla Plus 1.0.0.mrpack`
- 下载地址：`https://cdn.modrinth.com/data/fBLSVOCX/versions/K9gdsMNS/Gierem%20Vanilla%20Plus%201.0.0.mrpack`

### 远程清理

- 已关闭旧的 `screen` 会话：`create_server`
- 已清空旧目录：`/root/mccreate/server`
- 清空后目录大小：约 `4.0K`

### 服务端安装

- 远程下载位置：`/root/mccreate/downloads/gierem-vanilla-plus-1.21.1-1.0.0.mrpack`
- 初始安装命令使用现有工具：`/root/mrpack-install-linux`
- 初始安装目录：`/root/mccreate/server`
- 后续正式运行目录迁移到：`/data/mc-test-server`
- 兼容旧路径的符号链接：
  - `/root/mccreate/server -> /data/mc-test-server`
- 运行用户：`minecraft`
- 服务端大小：约 `140M`
- mods 数量：`104`
- disabled mod 文件数量：`2`

### 服务端配置

- EULA：`eula=true`
- 启动脚本：`/data/mc-test-server/start.sh`
- JVM 参数：`/data/mc-test-server/user_jvm_args.txt`
  - `-Xms512M`
  - `-Xmx2G`
  - G1GC
- `server.properties` 关键配置：
  - `server-port=25565`
  - `motd=Codex Test Modpack Server - Gierem Vanilla Plus 1.21.1`
  - `max-players=8`
  - `online-mode=true`
  - `view-distance=6`
  - `simulation-distance=4`
  - `allow-flight=true`
  - `sync-chunk-writes=false`

### 启动验证

- 手动验证启动成功：
  - 日志出现：`Done (36.454s)! For help, type "help"`
  - 已发送 `stop` 正常停服并保存世界。
- systemd 服务：
  - 文件：`/etc/systemd/system/mc-test.service`
  - 服务名：`mc-test.service`
  - 已 `enable`
  - 已启动
  - 状态：`active (running)`
  - 主进程：`java @user_jvm_args.txt -jar server.jar nogui`
- 服务端监听：
  - `*:25565`

### 公网连通性

- 服务器内部已经监听 `25565`。
- 本机到 `v.rainplay.cn:25565` 的 TCP 测试失败：
  - `TcpTestSucceeded: False`
- 服务器内 `ufw` 为 inactive，因此当前公网不通大概率是云厂商外层安全组/端口映射未开放。
- 需要在云厂商控制台开放或映射 Minecraft 端口 `25565`，或提供已映射的游戏端口后将 `server-port` 改成对应端口。

### 客户端整合包

- 已保存原生 Modrinth 客户端包：
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client.mrpack`
- 已额外复制为 zip 扩展名：
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client.zip`
- 两个文件内容相同，大小均为 `140983` bytes。
- 建议优先用 `.mrpack` 导入 Prism Launcher / Modrinth App。

### 完整客户端 zip 补充

- 已额外导出完整客户端文件包：
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client-full.zip`
  - 大小：`121236654` bytes
  - 内容包括：`mods/`、`config/`、`resourcepacks/`、`shaderpacks/`、`datapacks/`、`modpack.json`
  - 不包含服务端运行文件，例如 `server.jar`、`world/`、`logs/`。
- 完整 zip 是从远程已安装目录打包后，经 SSH 本地隧道取回。

### 最终状态

- 远程服务仍在运行：
  - `systemctl is-active mc-test.service -> active`
  - Java 进程：`java @user_jvm_args.txt -jar server.jar nogui`
  - 监听：`*:25565`
- 本地已交付文件：
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client.mrpack`
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client.zip`
  - `client-packs/gierem-vanilla-plus-1.21.1-1.0.0-client-full.zip`

## 2026-07-02 实时状态检查

- 检查时间：
  - 服务器 UTC：`2026-07-01T16:38:38+00:00`
  - 本地 Asia/Shanghai：`2026-07-02 00:38:38`
- `mc-test.service` 状态：`active`
- 运行时长：约 `33min`
- 主进程：`8324`
- 内存占用：约 `1.0G`
- 服务端监听：`*:25565`
- 服务器日志仍停留在成功启动状态：
  - `Done (2.762s)! For help, type "help"`
- 服务器资源：
  - 内存：3.8 GiB，总体可用约 2.4 GiB
  - Swap：1.4 GiB，未使用
  - `/data`：20G，可用约 19G
- 本机公网端口测试：
  - `Test-NetConnection v.rainplay.cn -Port 25565`
  - `TcpTestSucceeded: False`
- 结论：
  - Minecraft 服务端在服务器内部运行正常。
  - 公网 `v.rainplay.cn:25565` 暂不可达，仍需要在云厂商控制台开放或映射 Minecraft 端口。

## 2026-07-02 OP 与创造模式设置

- 当前玩家：`ye_fan_233`
- UUID：`07713d91-9a24-4266-a021-1644777bcc9d`
- 已短暂停止 `mc-test.service`，备份并修改玩家权限/数据后重启。
- 备份目录：`/data/mc-test-server/backups/op-creative-20260701-170753`
- 已写入 `/data/mc-test-server/ops.json`：
  - `level: 4`
  - `bypassesPlayerLimit: false`
- 已修改玩家数据：
  - `playerGameType = 1`
  - `previousPlayerGameType = 1`
  - abilities 中开启 `mayfly`、`instabuild`、`mayBuild`、`invulnerable`
- 重启后服务状态：`active`
- 最新启动日志：`Done (2.121s)! For help, type "help"`
- 服务端内部监听：`*:25565`
- 当前外部连接端口：`v.rainplay.cn:48390`
