# MikroTik CHR 一键安装脚本 r22

用于在 Linux 救援系统中自动安装 MikroTik RouterOS CHR，支持在线安装和本地镜像安装。

## 主要功能

* 中英文交互菜单。
* 在线安装自动获取 RouterOS v7 `long-term` 最新版。
* 自动识别 x86_64、ARM64 架构。
* 显示下载进度，支持断点续传和失败自动重试。
* 使用 MikroTik 官方 SHA-256 校验下载文件。
* 自动从 `all_packages-*.zip` 提取并预置 Container 软件包。
* 本地模式读取：

  * `/tmp/chr-*.img`
  * 可选 `/tmp/container-*.npk`
* 本地文件名包含 `arm` 时按 ARM64 处理，否则按 x86 处理。
* 仅对 x86 UEFI 镜像执行 FAT16、GPT 和 Hybrid MBR 启动兼容处理。
* 自动生成网络、管理员密码和首启配置。
* 关闭 IP Neighbor Discovery 及不必要的 RouterOS 服务。
* 自动检查并安装运行依赖。

## 使用方法

```bash
chmod +x chr-installer-r22.sh
sudo ./chr-installer-r22.sh
```

本地安装前，将镜像文件放入 `/tmp`：

```text
/tmp/chr-*.img
/tmp/container-*.npk
```

Container 软件包可以省略。

## 注意事项

* 脚本会完整覆盖所选目标磁盘，磁盘中的所有数据都会丢失。
* 必须使用 root 权限运行。
* x86 UEFI 环境需要关闭 Secure Boot。
* 目标磁盘必须使用 512-byte 逻辑扇区。
* 请通过服务器控制台或救援系统运行，避免写盘后 SSH 中断导致无法处理异常。
