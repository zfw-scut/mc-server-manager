# MC 整合包服务器搭建日志

## 2026-07-01

### 目标

- 通过远程连接进入云服务器。
- 检查服务器中已有的文件、服务和运行环境。
- 在服务器内搭建 Minecraft 整合包服务端。

### 连接信息

- 远程地址：`v.rainplay.cn:17120`
- 解析 IP：`103.40.13.59`
- 远程用户名：`root`
- 密码：未记录，避免明文保存敏感信息。

### 本地工作目录

- `E:\Work\MC服务器搭建`
- 初始检查时目录为空，暂无整合包文件或脚本。

### 已完成检查

- 本机可用 SSH 客户端：`C:\Windows\System32\OpenSSH\ssh.exe`
- 本机未安装 `sshpass`。
- 本机未安装 Python `paramiko`。
- 找到 PuTTY `plink.exe`：
  - `C:\Program Files\MWORKS\Sysplorer 2025a\Bin64\addins\MwRTSimPlugin\plink.exe`
  - 版本：`0.79`
- DNS 解析成功：
  - `v.rainplay.cn -> 103.40.13.59`
- TCP 连通性检查成功：
  - `Test-NetConnection v.rainplay.cn -Port 17120`
  - `TcpTestSucceeded: True`

### 当前问题

- OpenSSH 可以建立 TCP 连接，但在 SSH banner 阶段超时：
  - `Connection timed out during banner exchange`
  - `Connection to 103.40.13.59 port 17120 timed out`
- 这表示端口可以连通，但它可能不是 SSH 服务，或 SSH 服务响应异常/极慢，或该端口前面有代理/转发层。

### 下一步

- 继续确认 `17120` 端口到底提供的是 SSH、RDP，还是云厂商控制台代理服务。
- 如果确认是 SSH，再执行只读服务器检查：
  - 系统版本
  - CPU/内存/磁盘
  - Java 环境
  - 已有 Minecraft 服务端目录
  - 当前运行进程
  - 防火墙和开放端口

### SSH 连接结果

- 已确认 `17120` 是 SSH 服务：
  - Banner：`SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.16`
  - 主机指纹：`ssh-ed25519 255 SHA256:ivghr3WtFU5GRbhdHAiwEYuKuddWh27HMmsMdS2Jsco`
- 已成功用 `root` 登录。
- 服务器主机名：`RainYun-S203vLlP`
- 系统：`Ubuntu 24.04.1 LTS`
- 内核：`Linux 6.8.0-124-generic`

### 服务器资源

- CPU：2 核
- 内存：3.8 GiB
- Swap：1.4 GiB
- 系统盘：`/dev/sda2`，30G，总使用约 7.3G，可用约 21G
- 数据盘：`/dev/sdb1`，挂载到 `/data`，20G，基本空闲
- Java：
  - `/usr/bin/java`
  - OpenJDK `21.0.11`

### 现有 Minecraft 相关文件

- `/root/mccreate`
  - 约 317M
  - 包含 `Create+-6.0.0 Alpha E.mrpack`
  - `/root/mccreate/server` 是已展开的服务端目录
  - `modpack.json` 显示整合包名：`Create+`
  - 整合包版本：`6.0.0 Alpha E`
  - `mods/` 内有 97 个 jar
  - `eula.txt` 已是 `eula=true`
  - `server.properties` 端口是 `25565`
  - 日志显示 2026-07-01 07:07 UTC 曾成功启动，随后被正常停止
  - 世界目录约 3.9M
- `/root/mc_newpack`
  - 约 228M
  - 只有 4 个 mod jar
  - `user_jvm_args.txt` 配置了 `-Xmx6G`，高于当前服务器 3.8 GiB 物理内存
  - 最新日志显示启动失败，原因是缺少 mandatory dependency：`owo`
- `/root/mc_server`
  - 约 308M
  - `mods/` 内 0 个 jar
  - 看起来更像 NeoForge 基础服务端/旧测试目录
  - `server.jar` 和 `server_1.20.1.jar` 是空文件
  - `start.sh` 指向 `neoforge_installer.jar`，不适合作为正式启动脚本
- `/root/bmc5.zip`
  - 约 33M
  - Zip 文件，尚未进一步展开检查
- `/home/mc_server`
  - 约 26M
  - Java archive/JAR 文件

### 当前运行状态

- 没有正在运行的 Java/Minecraft 服务端进程。
- 有一个 detached screen：
  - `1616.create_server`
  - screen 内是一个 bash shell
  - 当前工作目录：`/root/mccreate/server`
- 当前监听端口中没有 `25565`。
- `ufw` 状态：inactive。

### 初步判断

- 最值得接着整理成正式服务的是：`/root/mccreate/server`
- 原因：
  - 它是完整的 `Create+ 6.0.0 Alpha E` 服务端。
  - mods 数量正常。
  - EULA 已接受。
  - 日志显示曾经成功启动并允许玩家进入。
- 暂不建议直接使用 `/root/mc_newpack` 或 `/root/mc_server`：
  - `/root/mc_newpack` 缺依赖且内存参数过大。
  - `/root/mc_server` 没有 mod，且存在空 jar/错误启动脚本。
