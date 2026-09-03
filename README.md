# MikroTik CHR Installer r22

用于在 Linux 救援系统中安装 MikroTik RouterOS CHR 的交互式 Bash 脚本，支持在线安装与本地镜像安装，并针对 x86 UEFI 启动环境进行兼容处理。

> [!CAUTION]
> 脚本会完整覆盖用户选择的目标磁盘并自动重启。目标磁盘中的系统、分区和全部数据都会永久丢失。请仅在新 VPS、测试机或确认可清空的服务器上使用。

## 主要功能

- 中英文交互菜单。
- 在线安装自动获取 RouterOS v7 `long-term` 最新版本。
- 在线模式自动识别 x86_64 或 ARM64，并下载对应官方 CHR RAW 镜像。
- 自动下载 `all_packages-*.zip`，提取并预置 Container NPK。
- 显示下载进度，支持断点续传、网络中断自动重试和缓存复用。
- 使用 MikroTik 官方 SHA-256 校验两个下载 ZIP；校验失败会删除错误缓存并完整重下。
- 本地模式读取 `/tmp/chr-*.img`，并可选读取 `/tmp/container-*.npk`。
- 自动检测当前 IPv4 地址、网关、DNS、网卡及 MAC，并允许安装前修改。
- 自动生成无注释的 `autorun.scr`，设置静态 IPv4 和管理员密码。
- 预置 Container Device Mode。
- 保留 SSH、WinBox，关闭 Telnet、FTP、HTTP、API、API-SSL 和 Bandwidth Server。
- 关闭所有接口的 MikroTik IP Neighbor Discovery。
- 自动检查并安装运行依赖。
- 写盘前清除目标磁盘末尾残留的 GPT/RAID 元数据。

## x86 UEFI 支持

仅当同时检测到 **x86_64 + UEFI** 时，脚本才处理启动分区：

- 根据镜像内部文件识别 EFI 启动分区和 RouterOS 系统分区，不依赖固定设备名。
- 将启动分区转换为固定磁盘参数的 FAT16，并完整备份、恢复和校验 EFI 文件。
- 按 jaclaz 方法重建 GPT 与 Hybrid MBR。
- 校验 GPT CRC、主备分区表位置、ESP 类型、活动标志和分区边界。
- 转换前后逐字节校验 RouterOS 系统分区，防止误改系统内容。
- 检查 `EFI/BOOT/BOOTX64.EFI` 和 `map` 是否存在且有效。

x86 BIOS 和 ARM64 不执行上述 UEFI 分区转换。

## 运行要求

- Linux 救援系统、Live 系统或可被覆盖的临时 Linux 系统。
- root 权限。
- CPU 架构为 x86_64 或 ARM64。
- `/dev/shm` 必须是可写的 tmpfs，并有足够空间保存 CHR 镜像。
- 目标磁盘必须使用 512-byte 逻辑扇区；不支持直接写入 4Kn 磁盘。
- 内核必须支持 loop、SysRq 和分区扫描。
- 在线安装需要正常的 HTTPS 网络连接。
- x86 UEFI 环境必须关闭 Secure Boot。
- 强烈建议具备 VNC、串口控制台或云平台救援控制台。

脚本支持通过以下软件包管理器安装缺失依赖：

```text
apt-get、dnf、microdnf、yum、apk、pacman、zypper
```

## 一键运行

请先切换到 root 用户，然后执行：

```bash
curl -fL --retry 5 --connect-timeout 20 -o /tmp/chr-installer-r22.sh https://raw.githubusercontent.com/adslcool/CHR/main/chr-installer-r22.sh && chmod 700 /tmp/chr-installer-r22.sh && bash /tmp/chr-installer-r22.sh
```

如果系统没有 curl，可以使用 wget：

```bash
wget -O /tmp/chr-installer-r22.sh https://raw.githubusercontent.com/adslcool/CHR/main/chr-installer-r22.sh && chmod 700 /tmp/chr-installer-r22.sh && bash /tmp/chr-installer-r22.sh
```

不建议使用 `bash <(curl ...)` 或 `curl ... | bash`。先完整下载、确认成功后再执行，可以避免网络中断时把不完整脚本交给 Bash。

## 安装模式

### 1. 在线安装

在线模式会：

1. 根据当前 CPU 自动选择 x86_64 或 ARM64 镜像。
2. 查询 RouterOS v7 `long-term` 最新版本。
3. 下载官方 CHR RAW 镜像 ZIP。
4. 下载对应架构的 Extra packages ZIP。
5. 使用官方 `.sha256` 文件校验下载内容。
6. 解压 CHR IMG 和 Container NPK。
7. 定制镜像并写入用户确认的目标磁盘。

下载缓存保存在：

```text
/var/cache/chr-installer
```

下载中断后重新运行脚本，会优先从缓存文件现有大小继续下载。已经通过 SHA-256 校验的完整文件不会重复下载。

### 2. 本地安装

将文件直接放入 `/tmp`。CHR IMG 必须恰好有一个：

```text
/tmp/chr-*.img
```

Container NPK 可选，并且最多一个：

```text
/tmp/container-*.npk
```

示例：

```text
/tmp/chr-7.21.5.img
/tmp/container-7.21.5.npk
```

ARM64 文件名必须包含 `arm`，CHR 和 Container 文件名的架构判定必须一致：

```text
/tmp/chr-7.21.5-arm64.img
/tmp/container-7.21.5-arm64.npk
```

本地模式不解析或比较文件名中的 RouterOS 版本：

- 文件名包含 `arm`：按 ARM64 处理。
- 文件名不包含 `arm`：按 x86 处理。
- 没有 `container-*.npk`：跳过 Container 软件包预置并继续安装。
- 存在多个匹配文件、空文件或符号链接：停止安装。

本地 IMG 会先复制到 `/dev/shm`，并通过 SHA-256 检查复制一致性；`/tmp` 中的源文件不会被修改。该校验只能确认复制前后一致，不能证明本地文件来自 MikroTik 官方。

## 交互流程

脚本运行后依次要求：

1. 选择界面语言。
2. 选择在线安装或本地安装。
3. 确认或修改 IPv4/CIDR。
4. 确认或修改 IPv4 网关。
5. 确认或修改 DNS。
6. 输入管理员密码；输入内容会显示，直接回车则生成随机密码。
7. 选择要覆盖的整块磁盘。
8. 输入小写或大写 `y` 确认写盘。

未输入 `y` 时，脚本不会开始最终磁盘写入。

## 首次启动配置

写入镜像的 `autorun.scr` 会在 RouterOS 首次启动时：

- 删除现有 DHCPv4 Client。
- 按安装时记录的 MAC 地址定位网卡，找不到时回退到 `ether1`。
- 设置静态 IPv4/CIDR、默认路由和 DNS。
- 网关不在本地 IPv4 子网时，自动增加网关 `/32` 主机路由。
- 设置 admin 密码。
- 关闭 IP Neighbor Discovery。
- 关闭 Telnet、FTP、HTTP、API、API-SSL 和 Bandwidth Server。

`autorun.scr` 不包含注释和空行。

## IPv6 说明

r22 目前只自动继承并写入 Linux 系统的 IPv4 网络配置，不会自动写入 IPv6 地址或 IPv6 默认路由。安装完成后，请根据云服务商提供的 IPv6 地址、前缀和网关在 RouterOS 中手动配置。

链路本地 IPv6 网关必须包含出口接口，例如：

```routeros
/ipv6/address/add address=2001:db8:100::2/64 interface=ether1 advertise=no
/ipv6/route/add dst-address=::/0 gateway=fe80::1%ether1
```

`2001:db8::/32` 是文档示例地址，不能直接用于公网。启用公网 IPv6 前还必须配置 IPv6 Firewall，并保留必要的 ICMPv6。

## 安装后检查

通过控制台登录 RouterOS 后，可以执行：

```routeros
/system/resource/print
/system/package/print
/system/device-mode/print
/ip/address/print
/ip/route/print
/ip/service/print
/file/print where name="rw/autorun.scr"
```

如果预置成功，`/system/device-mode/print` 应显示：

```text
container: yes
```

## 验证情况

r22 的 x86 UEFI 镜像处理已使用 RouterOS `7.21.5 long-term` 官方 CHR RAW 镜像进行测试：

- 转换后的 128 MiB 镜像可通过 QEMU/OVMF 启动并进入 MikroTik 登录界面。
- 将同一镜像写入 1 GiB 虚拟磁盘后，仍可通过 QEMU/OVMF 启动。
- 转换过程会核验 GPT、Hybrid MBR、FAT16 BPB、EFI 文件和 RouterOS 系统分区内容。

以上结果用于验证脚本的镜像处理逻辑，不代表所有云厂商的 UEFI 固件、磁盘控制器或网络环境都已覆盖。首次部署仍应保留云平台控制台和救援系统。

## 常见问题

### curl 报 CA 证书错误

在线模式会检查系统 CA 证书，并尝试通过当前系统的软件包管理器安装或重建 `ca-certificates`。如果仍然失败，请先修复救援系统的软件源和系统时间，再重新运行脚本。

### 下载到一半连接被重置

脚本会保留已下载内容，并自动重试及续传。达到重试上限后可以再次运行脚本，缓存仍会保留。

### 本地模式提示文件数量不正确

检查 `/tmp`：

```bash
ls -lh /tmp/chr-*.img /tmp/container-*.npk 2>&1
```

必须恰好有一个 `chr-*.img`；`container-*.npk` 可以没有，但不能超过一个。

### UEFI 写入后不能启动

请确认：

- CPU 为 x86_64。
- 安装时检测到的启动方式为 UEFI。
- Secure Boot 已关闭。
- 目标磁盘是 512-byte 逻辑扇区。
- 云平台启动固件设置为 UEFI，而不是 BIOS/Legacy。
- 已卸载救援 ISO，并从写入 CHR 的磁盘启动。

### 写盘后 SSH 断开

这是正常现象。脚本会覆盖当前系统磁盘并强制重启，请通过云平台控制台观察重新启动过程。

## 安全提示

- 执行前建议打开脚本源码进行检查：[`chr-installer-r22.sh`](https://github.com/adslcool/CHR/blob/main/chr-installer-r22.sh)。
- `main` 分支内容可以变化。正式生产环境建议创建固定的 Git Tag 或 Release，并使用固定版本链接部署。
- 不要在存有重要数据的服务器上测试。
- 不要跳过目标磁盘名称、容量和分区信息确认。
- 首次登录后建议检查 Device Mode、防火墙、服务端口和软件包状态。
- 公网 IPv6 不经过 IPv4 NAT，配置 IPv6 地址前应先准备 IPv6 Firewall。

## 参考项目与文档

- [MikroTik RouterOS CHR](https://help.mikrotik.com/docs/spaces/ROS/pages/18350234/Cloud+Hosted+Router%2C+CHR)
- [MikroTik RouterOS 下载页面](https://mikrotik.com/download)
- [alecthw/mikrotik-routeros-chr-efi](https://github.com/alecthw/mikrotik-routeros-chr-efi)
- [tikoci/fat-chr](https://github.com/tikoci/fat-chr)
- [RouterOS Device Mode](https://help.mikrotik.com/docs/spaces/ROS/pages/93749258/Device-mode)

## 免责声明

本项目按现状提供。不同云平台的磁盘控制器、UEFI 固件和网络配置可能存在差异。使用者应自行确认目标磁盘、网络参数、备份和控制台救援方式，并自行承担磁盘覆盖、网络中断或无法启动的风险。
