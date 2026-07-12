# 正式服务器技术上下文

本文件保存可提交的非秘密信息。实际凭据位于 `.local/servers.yaml`。

## 主机

- SSH 主机：`wzk.rainplay.cn`
- SSH 公网端口：`56902`
- SSH 用户：`root`
- SSH 主机指纹：`ssh-ed25519 255 SHA256:Cnv7QmX5pg/NMTsLyClUTvPOaUAj23EX3wUtcHMNJH0`
- 操作系统：Ubuntu 24.04.1 LTS

## Minecraft

- 整合包：你好新蒸程 1.5.9
- Minecraft：1.21.1
- NeoForge：21.1.233
- 服务：`hello-new-generation.service`
- 工作目录：`/data/minecraft/hello-new-generation`
- 内网端口：`25565`
- 公网地址：`wzk.rainplay.cn:56903`

## 管理面板 Demo

- 服务：`mc-panel-demo.service`
- 工作目录：`/data/minecraft/panel-demo`
- 内网端口：`18080`
- 公网地址：`http://wzk.rainplay.cn:56904/`
- 当前认证：HTTP Basic Auth，密码位于本地凭据文件。
- 安全提示：当前公网 HTTP 不提供传输加密，正式管理功能上线前应增加 HTTPS 或限制访问范围。

以上状态来自现有运维记录。执行写操作前必须通过只读检查确认仍然有效。
