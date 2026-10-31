[README.md](https://github.com/user-attachments/files/34209146/README.md)
# MikroTik CHR Installer r23

用于在 Linux 救援系统中安装 MikroTik RouterOS CHR 的交互式 Bash 脚本，支持在线安装与本地镜像安装，并针对 x86 UEFI 启动环境进行兼容处理。

> [!CAUTION]
> 脚本会完整覆盖用户选择的目标磁盘并自动重启。目标磁盘中的系统、分区和全部数据都会永久丢失。请仅在新 VPS、测试机或确认可清空的服务器上使用。

## r23 主要变化

- 可选在 CHR 首次启动时申请官方 60 天试用授权，支持 P1、P10、P-Unlimited；公开脚本不内置任何 MikroTik.com 账号密码。
- 手动设置 RouterOS `admin` 密码时需要输入两次，两次一致才接受；直接回车仍生成随机密码。
- 首启授权在后台等待出口 IPv4、有效默认路由和授权服务器域名解析就绪，网络等待最多 180 秒，授权最多尝试 3 次。
- 网络配置默认使用 DHCP，自动获取 IPv4、默认网关、DNS 和 NTP。
- 用户输入 `y` 后，可改为手动指定静态 IPv4/CIDR、网关和 DNS。
- RouterOS 时区固定为 `Asia/Singapore`，并关闭自动时区检测。
- 在线与本地安装、Container 预置、下载续传、SHA-256 校验和 x86 UEFI 处理逻辑保持不变。

## 主要功能

- 中英文交互菜单。
- 在线安装自动获取 RouterOS v7 `long-term` 最新版本。
- 在线模式自动识别 x86_64 或 ARM64，并下载对应官方 CHR RAW 镜像。
- 自动下载 `all_packages-*.zip`，提取并预置 Container NPK。
- 显示下载进度，支持断点续传、网络中断自动重试和缓存复用。
- 使用 MikroTik 官方 SHA-256 校验两个下载 ZIP；校验失败会删除错误缓存并完整重下。
- 本地模式读取 `/tmp/chr-*.img`，并可选读取 `/tmp/container-*.npk`。
- 自动检测当前网卡及 MAC；网络默认使用 DHCP，也可选择填写静态 IPv4、网关和 DNS。
- 自动生成无注释、无空行的 `autorun.scr`，设置网络、管理员密码和 `Asia/Singapore` 时区。
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

使用本次交付的脚本文件可直接运行 `bash ./chr-installer-r23.sh`。下面的 GitHub 地址以仓库实际内容为准；需将新版文件更新到仓库后，一键命令才会包含本次新增功能。

请先切换到 root 用户，然后执行：

```bash
curl -fL --retry 5 --connect-timeout 20 -o /tmp/chr-installer-r23.sh https://raw.githubusercontent.com/adslcool/CHR/main/chr-installer-r23.sh && chmod 700 /tmp/chr-installer-r23.sh && bash /tmp/chr-installer-r23.sh
```

如果系统没有 curl，可以使用 wget：

```bash
wget -O /tmp/chr-installer-r23.sh https://raw.githubusercontent.com/adslcool/CHR/main/chr-installer-r23.sh && chmod 700 /tmp/chr-installer-r23.sh && bash /tmp/chr-installer-r23.sh
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
3. 选择网络配置：直接回车或输入 `n` 使用 DHCP；输入 `y` 使用静态网络。
4. 静态模式下依次确认或修改 IPv4/CIDR、IPv4 网关和 DNS；DHCP 模式跳过这些输入。
5. 输入管理员密码；输入内容会显示。手动设置需要再次输入确认，不一致则重新输入；第一次直接回车则生成随机密码。
6. 选择是否申请官方 60 天 CHR 试用授权，默认不申请。
7. 若申请：输入自己的 MikroTik.com 账号，隐藏输入两次账号密码，再选择 P1、P10 或 P-Unlimited，默认 P-Unlimited。此账号与 RouterOS 的 `admin` 账号不同。
8. 选择要覆盖的整块磁盘。
9. 输入小写或大写 `y` 确认写盘。

未输入 `y` 时，脚本不会开始最终磁盘写入。

## 首次启动配置

写入镜像的 `autorun.scr` 会在 RouterOS 首次启动时：

- 按安装时记录的 MAC 地址定位网卡，找不到时回退到 `ether1`。
- 删除现有 DHCPv4 Client，避免重复或绑定到错误网卡。
- DHCP 模式：在识别出的网卡上新建 DHCP Client，自动接收 IPv4、默认路由、DNS 和 NTP。
- 静态模式：设置用户指定的 IPv4/CIDR、默认路由和 DNS；网关不在本地子网时自动增加网关 `/32` 主机路由。
- 设置 admin 密码。
- 关闭时区自动检测，并将时区固定为 `Asia/Singapore`。
- 关闭 IP Neighbor Discovery。
- 关闭 Telnet、FTP、HTTP、API、API-SSL 和 Bandwidth Server。

`autorun.scr` 不包含注释和空行。

## 可选的首次启动试用授权

### 授权时机与重试

选择启用后，安装器会另外预置 `chr-license-firstboot.rsc`。`autorun.scr` 先完成管理员密码、网络、时区和服务配置，再在后台加载授权任务。安装器显示“已安排首次启动申请”，不表示授权已经成功。

任务仅对当前授权级别为 `free` 的 CHR 执行；已有试用或正式授权时跳过，不更换级别，也不重新生成 System ID。

后台任务每 5 秒检测一次以下条件，主任务按运行时间限定网络等待最多 180 秒，并可终止仍在等待 DNS 的检测子任务：

1. 出口以太网接口运行，且已有有效 IPv4 地址。接口识别沿用 MAC 优先、`default-name=ether1` 回退。
2. DHCP 模式额外要求该接口的 DHCP Client 为 `bound`；静态模式不要求 DHCP。
3. `main` 路由表存在 active 的 IPv4 默认路由，兼容静态 `/32` 配跨子网网关的配置。
4. 可以通过当前 RouterOS DNS 解析 `licence.mikrotik.com` 的 IPv4 地址。

网关 ping 和第三方公网 IP ping 均不作为必需条件，避免云网关屏蔽 ICMP 时误判。地址、路由和 DNS 就绪只用于判断申请时机；实际授权请求检验到 MikroTik 授权服务的通信。

网络就绪后使用 `/system/license/renew` 申请所选级别。每次请求最多等待 45 秒，最多 3 次，失败重试间隔 15 秒。服务返回明确的账号、密码或认证拒绝错误时提前结束；无法明确分类的错误按有限次数重试。每次都读取实际 `level` 与 `limited-upgrades` 确认结果，不依赖一条“命令已提交”提示。

网络超时、认证失败或最终申请失败均不撤销已经完成的网络和服务配置。此任务不创建 Scheduler，也不会在每次重启时重新提交申请。失败后可在 WinBox 的 `System > License` 中重新输入凭据手动申请。

超时日志会标明 `waiting-interface`、`waiting-address`、`waiting-dhcp`、`waiting-route` 或 `waiting-dns`。看门狗主动终止超时子任务时，RouterOS 可能同时记录 `script error: interrupted`；请结合相邻的 `[CHR license]` 日志判断原因。

### 凭据与清理

- 公开 Bash 脚本和 README 不保存固定账号密码；安装时由使用者自行输入。
- 为了实现无人值守首启申请，凭据临时存放在镜像 `rw/disk/chr-license-firstboot.rsc` 中，文件权限为 `0600`。RouterOS 中的文件名为 `chr-license-firstboot.rsc`。
- 授权任务完整加载到内存后，先删除该文件，再开始网络等待。成功、失败、跳过以及受控异常结束时均再次清理文件、子任务和用于传递状态的临时全局变量。
- 不创建含凭据的持久化 RouterOS Script 或 Scheduler；安装器完成文件预置后清空 Bash 中对应的全局变量。输出和自定义日志不打印账号密码或完整授权命令。
- 账号密码使用 RouterOS 字符串逐字节十六进制转义，支持 `$`、引号、反斜杠、`#`、空格等字符。**转义不是加密**，首启加载前的临时文件仍应视为明文凭据。
- 如果首次启动任务尚未加载就断电，或遇到文件删除错误，临时文件可能仍然存在；请检查下述文件列表并手动删除。文件删除也不等于磁盘安全擦除。

检查命令：

```routeros
/system/license/print
/log/print where message~"CHR license"
/file/print where name="chr-license-firstboot.rsc"
/system/script/job/print
```

授权成功后，`level` 应为所选级别，`limited-upgrades` 为 `no`，日志出现 `Trial activated`；任务启动后临时授权文件应消失。

如需手动重试，可使用交互命令，避免把账号密码直接粘贴到命令行：

```routeros
/system/license/renew
```

这里申请的是 MikroTik 官方 60 天试用，不是购买永久授权。同一实例不能通过重复执行 `renew` 重置试用时间，也不能直接将已有低级别试用升为更高级别试用。试用到期后按 MikroTik 官方规则处理。

## IPv6 说明

r23 只自动配置 IPv4：默认通过 DHCP 获取，或根据用户输入写入静态 IPv4。脚本不会自动写入 IPv6 地址或 IPv6 默认路由。安装完成后，请根据云服务商提供的 IPv6 地址、前缀和网关在 RouterOS 中手动配置。

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
/ip/dhcp-client/print detail
/ip/service/print
/system/clock/print
/file/print where name="rw/autorun.scr"
```

如果预置成功，`/system/device-mode/print` 应显示：

```text
container: yes
```

## 验证情况

### x86 UEFI 镜像处理

r23 沿用 r22 已验证的 x86 UEFI 镜像处理逻辑。该逻辑已使用 RouterOS `7.21.5 long-term` 官方 CHR RAW 镜像进行测试：

- 转换后的 128 MiB 镜像可通过 QEMU/OVMF 启动并进入 MikroTik 登录界面。
- 将同一镜像写入 1 GiB 虚拟磁盘后，仍可通过 QEMU/OVMF 启动。
- 转换过程会核验 GPT、Hybrid MBR、FAT16 BPB、EFI 文件和 RouterOS 系统分区内容。

以上结果用于验证脚本的镜像处理逻辑，不代表所有云厂商的 UEFI 固件、磁盘控制器或网络环境都已覆盖。首次部署仍应保留云平台控制台和救援系统。

### 首次启动配置的安全离线回归测试

在仓库根目录运行（普通用户即可，不需要 root、联网或 CHR 镜像）：

```bash
python3 -B -m unittest discover -s tests -v
```

依赖 Python 3.9+ 标准库、Bash 4+ 和 `awk`、`chmod`、`head`、`od`、`tr`。测试覆盖：

- 默认 DHCP，以及直接回车、`n`、`N` 的交互选择；确认清除旧 DHCP Client，启用默认路由、对端 DNS 和 NTP，且不写入静态配置。
- 静态 IPv4/CIDR、网关和单个或多个 DNS；无效输入重试、空 DNS 项拒绝、DNS 空格处理。
- 同子网和跨子网网关，包含 `/0`、`/1`、`/25`、`/31`、`/32` 等边界；使用 Python `ipaddress` 独立核对 Bash 子网运算，并检查 `/32` 网关主机路由先于默认路由生成、`scope=10`。
- MAC 优先匹配、使用改名后的接口、找不到 MAC 时按 `default-name=ether1` 回退，以及两个条件都不满足时中止网络配置。
- 管理员密码长度与字符边界、随机密码、`Asia/Singapore` 时区、原有服务关闭策略和文件权限 `0600`。
- `autorun.scr` 的引号、括号、变量引用和所用命令参数结构，以及 README 中 curl、wget、源码链接与现存 r23 文件是否一致。

安全边界：测试只提取白名单中的配置和输入校验函数，不加载安装脚本的顶层代码、`main`、清理 trap 或镜像/磁盘函数。网卡信息来自临时文件和模拟 `ip`；Bash 子进程使用受限 PATH，只提供上述工具。测试只写临时普通文件，不执行下载、分区、挂载、镜像安装、真实磁盘写入或重启。

`tests/routeros_subset.py` 是针对当前生成内容的有限语法检查与内存模型，未知语法或命令会报错；它不是 MikroTik 官方解释器。该套件可以发现本项目生成内容的结构与行为回归，不能证明 RouterOS 所有版本都能导入，也不验证真实 DHCP 租约、NTP 同步或实际路由转发。以下虚拟机记录单独验证了特定版本的首次启动行为；上面的 QEMU/OVMF 启动记录本身不代表网络分支已通过验证。

### 本次新增功能的离线回归测试

交付包额外提供 `tests/test_firstboot_trial.py`，在包的根目录执行：

```bash
python3 -B -m unittest discover -s tests -p 'test_firstboot_trial.py' -v
```

测试只提取白名单函数，不加载安装器入口、顶层 trap、镜像处理、下载、挂载、真实磁盘写入或重启函数。覆盖管理员密码二次确认和随机密码、授权默认跳过和全部级别、账号密码输入校验和不回显、字符串转义往返、两层命令转义、临时文件权限和清理、符号链接拒绝、DHCP/静态网络条件及重试参数。它不向 MikroTik 发送真实授权请求。

本次执行的 Bash 语法检查、ShellCheck（warning 及以上级别）和上述 15 项离线回归检查均通过。

### 本次首启授权的虚拟机验证

2026-10-31 使用通过官方 SHA-256 校验的 CHR `7.21.5 long-term` 镜像，在 QEMU `8.2.2`、TCG、SeaBIOS、256 MiB RAM、e1000 网卡环境中进行验证。每个场景均从干净镜像副本启动，由真实 `autorun.scr` 加载后台授权任务。

- 实际验证管理员密码登录、DHCP 获取地址和有效默认路由、授权临时文件加载后删除，以及任务结束后无残留子任务和临时状态变量。
- 原样执行真实 `/system/license/renew` 命令，对端为隔离网络中的模拟服务器，其 TCP 连接被拒绝；验证 3 次有限重试和最终失败清理。虚拟机无法连接 MikroTik 官方服务。
- 使用模拟授权返回及模拟授权状态，验证前两次临时失败、第三次成功；认证拒绝后仅尝试一次；请求不返回时按上限终止，最多 3 次；已有试用级别时跳过。
- 验证未获取地址和 DNS 不应答时停止等待并清理；另一次使用原样的 180 秒网络等待配置，日志时间从 `10:58:40` 到 `11:01:40`，确认等待上限实际生效。

为缩短故障分支测试，模拟场景将网络等待缩短为 8、12 或 25 秒、请求等待缩短为 3 秒、重试间隔缩短为 1 秒；上述完整 180 秒检查和真实 `renew` 连接失败检查使用原始时限。模拟授权成功只验证脚本分支，不代表已从 MikroTik 取得试用授权。没有使用真实账号密码，也没有实际申请试用；正式服务的认证、注册及成功授权仍需用户部署后验证。本次新增功能的虚拟机验证不覆盖 ARM64 和 x86 UEFI 启动转换。

### RouterOS 首次启动虚拟机验证

2026-10-31 使用官方 CHR `7.21.5 long-term` 镜像，在 QEMU `8.2.2`、TCG、SeaBIOS、1 vCPU、256 MiB RAM、e1000 网卡环境中验证以下场景，每次均从干净镜像副本启动：

- 默认 DHCP，实际接收地址、默认网关、DNS 以及 NTP 服务器选项。
- 同子网静态 IPv4，以及静态 `/32` 地址配跨子网网关。
- 双网卡时通过 MAC 命中 `ether2`，而不是默认选择 `ether1`。
- MAC 不匹配时回退到 `ether1`，以及该接口改名后的回退。

各场景均检查管理员密码登录、时区、服务配置、实际地址和路由状态，并通过模拟网关及其后方的模拟远端地址进行 ICMP 连通测试。生成内容直接写入虚拟镜像的 `rw/autorun.scr`，由 RouterOS 首次启动实际执行；没有调用 Linux 安装器主流程。

本次发现并修复：跨子网网关的 `/32` 静态主机路由使用 `scope=10` 时，默认路由需设置 `target-scope=11` 才能正确解析下一跳。修复前默认路由为 inactive，模拟远端 ping 为 `0/2`；修改后路由激活，ping 为 `2/2`。新增离线回归用例防止此问题再次出现。

虚拟机网络只连接测试进程中的 DHCP/ARP/ICMP 模拟上游，不使用真实网卡、桥接、TAP、端口转发或公网。只操作普通虚拟镜像文件及 QEMU 临时快照，不执行真实磁盘设备写入、挂载或宿主机重启。该结果不覆盖 x86 UEFI 转换、ARM64 或真实云网络；NTP 选项下发已验证，但 r23 未启用 NTP 客户端，本次不声称已验证时间同步。

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

### DHCP 启动后无法联网

请先确认云平台或上游网络提供 DHCP 服务，并通过控制台执行：

```routeros
/ip/dhcp-client/print detail
/ip/address/print
/ip/route/print
/ip/dns/print
```

如果服务商只提供固定地址，请重新安装并在网络配置提示中输入 `y`，填写服务商分配的静态 IPv4/CIDR、网关和 DNS。

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

- 执行前建议打开脚本源码进行检查：[`chr-installer-r23.sh`](https://github.com/adslcool/CHR/blob/main/chr-installer-r23.sh)。
- `main` 分支内容可以变化。正式生产环境建议创建固定的 Git Tag 或 Release，并使用固定版本链接部署。
- 不要在存有重要数据的服务器上测试。
- 不要跳过目标磁盘名称、容量和分区信息确认。
- 首次登录后建议检查 Device Mode、防火墙、服务端口和软件包状态。
- 公网 IPv6 不经过 IPv4 NAT，配置 IPv6 地址前应先准备 IPv6 Firewall。

## 参考项目与文档

- [MikroTik RouterOS CHR](https://help.mikrotik.com/docs/spaces/ROS/pages/18350234/Cloud+Hosted+Router%2C+CHR)
- [CHR 授权与试用说明](https://manual.mikrotik.com/docs/getting-started/routeros-licensing/chr/chr-licensing/)
- [RouterOS license renew 参数](https://manual.mikrotik.com/docs/cli-reference/system/license/renew/)
- [MikroTik RouterOS 下载页面](https://mikrotik.com/download)
- [alecthw/mikrotik-routeros-chr-efi](https://github.com/alecthw/mikrotik-routeros-chr-efi)
- [tikoci/fat-chr](https://github.com/tikoci/fat-chr)
- [RouterOS Device Mode](https://help.mikrotik.com/docs/spaces/ROS/pages/93749258/Device-mode)

## 免责声明

本项目按现状提供。不同云平台的磁盘控制器、UEFI 固件和网络配置可能存在差异。使用者应自行确认目标磁盘、网络参数、备份和控制台救援方式，并自行承担磁盘覆盖、网络中断或无法启动的风险。
