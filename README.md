# actions-openwrt-helloworld

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/Lancenas/actions-openwrt-helloworld/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/Lancenas/actions-openwrt-helloworld.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/Lancenas/actions-openwrt-helloworld.svg?style=flat-square&label=Forks&logo=github)

## 本 fork 的用途：一台路由器 / 一台盒子的自用固件

基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) master，一台设备一个 workflow，
点 Actions → 对应 workflow → Run workflow 就行。三个目标互不影响，可以同时跑。

| 设备 | Workflow | 配置 | 平台 | 内核 |
|---|---|---|---|---|
| Phicomm K2P (A1/A2) | `build-openwrt.yml` | `.config` | ramips/mt7621 (mipsel) | 5.10 |
| Phicomm N1 盒子 | `build-n1.yml` | `.config.n1` | amlogic/mesongx (aarch64) | 6.18 |
| Xiaomi WR30U | `build-wr30u.yml` | `.config.wr30u` | mediatek/filogic (aarch64) | 6.12 |

三个 workflow 都会在 `make defconfig` 之后断言目标设备确实被选进了 `.config`
（`DEVICE_ASSERT`），选不中就立刻失败，不会白跑两小时才发现编错设备。

---

## 代理能力对比（为什么三台的配置差这么多）

K2P 的 `firmware` 分区只有 **15.69 MiB**（kernel 1.70 + rootfs 12.3 + overlay 1.875），
mipsel_24kc 上现代代理内核装不下；N1 是 eMMC、WR30U 是 128M NAND，宽裕得多。

| 内核 | mipsel 安装后 | K2P | N1 / WR30U |
|---|---|---|---|
| xray-core | 29.07 MB | ✘ | ✔ |
| v2ray-core | 34.60 MB | ✘ | ✘（被 xray 取代） |
| sing-box | 44.07 MB | ✘ | ✘ |
| hysteria (v2) | 19.09 MB | ✘ | ✔ |
| shadowsocks-rust | 9.52 MB | ✘ | ✔ |
| trojan (C++) | 0.63 MB | ✔ | ✔ |
| shadowsocks-libev / ssr-libev (C) | ~0.2 MB | ✔ | ✔ |

落到实际节点上是这样（订阅里共 59 个节点）：

| 节点类型 | 数量 | K2P | N1 / WR30U |
|---|---|---|---|
| vmess (WS+TLS) | 30 | ✔ xray | ✔ xray |
| vless + REALITY + Vision | 8 | ✘ | ✔ xray |
| trojan | 8 | ✔ | ✔ |
| shadowsocks **2022-blake3** | 10 | ✘ | ✔ **必须 shadowsocks-rust** |
| hysteria2 | 3 | ✘ | ✔ hysteria v2 |

两个容易踩的点：

- **ss 的 2022-blake3 只有 shadowsocks-rust 支持**，`shadowsocks-libev 3.3.5` 不支持。
  所以 aarch64 这两台用的是 rust 版客户端，别改成 libev。
- **ssr-plus 支持 hysteria2 客户端**（`hy2_type_list`，可走 `hysteria` 二进制或 `Xray`），
  所以 `INCLUDE_Hysteria` 要带上，否则那 3 个 hysteria2 节点是灰的。

### 透明代理后端

Lean's LEDE 的 `DEFAULT_PACKAGES.router` 里是 `dnsmasq-full firewall iptables`，
也就是**默认还是 firewall3 / iptables**，不是 nftables。所以三台都显式选
`Iptables_Transparent_Proxy=y`，配 `ipset`。K2P 的 manifest 已经验证过这一点
（里面有 `firewall 2022-02-17`、`ipset`、`iptables-mod-tproxy`，没有 `firewall4`/`nftables`）。

---

## Phicomm K2P (A1/A2)

| 文件 | 改动 |
|---|---|
| `.config` | 锁定 `phicomm_k2p`，只带 ssr-plus + trojan + ss/ssr 的 C 版内核，**显式关掉 xray** |
| `diy-part2.sh` | LAN `10.0.0.1`、主机名 `K2P`、时区 `CST-8`、清默认 root 密码 |

- 已确认是 `ramips/mt7621`，即 **K2P A1/A2**；B1 是博通芯片，固件不通用。
- 刷前务必在原固件里备份 `mtd1`(Config) 和 `mtd2`(Factory)——无线校准数据，丢了 5G 会废。
- 从 2019 年的 LEDE 17.01 跨版本升级，分区布局有变，建议走 Breed 刷而不是直接 sysupgrade。
- 刷完 LAN 仍是 `10.0.0.1`，但 root 密码为空，**先设密码再接网**。

> 如果一定要在 K2P 上保留 vmess：把旧设备上那个 3.8MB 的 `xray 1.2.4` 二进制放进
> 仓库的 `files/usr/bin/xray`，再把 `INCLUDE_NONE_V2RAY=y` 换成 `INCLUDE_Xray=y`。
> 代价是沿用 2019 年的 xray（有已知漏洞，且不支持 REALITY）。

---

## Phicomm N1 盒子

`amlogic/mesongx` + `phicomm_n1`，DTS 来自内核主线
（`arch/arm64/boot/dts/amlogic/meson-gxl-s905d-phicomm-n1.dts`）。

| 文件 | 改动 |
|---|---|
| `.config.n1` | 锁定 `phicomm_n1`，rootfs 用 **ext4**、`PARTSIZE=256`，代理内核全带 |
| `diy-part2-n1.sh` | LAN `10.0.0.2`、主机名 `N1`、时区 `CST-8`、清默认 root 密码 |

**镜像分区是写死的**（`target/linux/amlogic/image/Makefile` 给 `gen_amlogic_image.sh`
传的 `64 / 256 / 2048`）：

```
p1  boot   64 MiB   FAT（kernel.img + amlogic.dtb + u-boot.emmc + 三个 autoscript）
p2  rootfs 256 MiB  ← 所以 CONFIG_TARGET_ROOTFS_PARTSIZE 不能超过 256
p3  overlay 2 GiB   首扇区写 "RESET000"
```

产物是 `openwrt-amlogic-mesongx-phicomm_n1-ext4-sysupgrade.img.gz`，
**这其实是个 U 盘启动镜像**，不是给 sysupgrade 用的：

1. `balenaEtcher` 或 `dd` 写到 U 盘；
2. U 盘插到 N1 上开机。N1 的原厂 U-Boot 会跑 `aml_autoscript`
   → `s905_autoscript` → 载入镜像里的 `u-boot.emmc` 并 `go`
   → 新的 U-Boot 接管后执行 `emmc_autoscript`，自动装进 eMMC；
3. 装完拔掉 U 盘重启即可。

也可以先只从 U 盘跑起来，再手动 `install-to-emmc.sh`（脚本在 `/root/`，
按 68MiB/132MiB/764MiB 三个偏移重新分区并 dd 过去，目标 rootfs 分区正好 256MiB
—— 这就是 `PARTSIZE=256` 的由来）。

- LAN 默认 `10.0.0.2`（不是 `.1`，因为 K2P 已经占了 `10.0.0.1`，避免同网撞 IP）。
  想让 N1 当主路由就把 `diy-part2-n1.sh` 里的 `10.0.0.2` 改成 `10.0.0.1`。
- N1 只有 **1 个千兆口**，常见用法是单臂旁路由或小服务器。
- 刷完 root 密码为空，**先设密码再接网**。

---

## Xiaomi / Redmi WR30U

`mediatek/filogic` + `xiaomi_mi-router-wr30u`（MT7981B，aarch64）。

| 文件 | 改动 |
|---|---|
| `.config.wr30u` | 锁定 `xiaomi_mi-router-wr30u`，rootfs 走 ubi 里的 squashfs，代理内核全带 |
| `diy-part2-wr30u.sh` | LAN `10.0.0.1`、主机名 `WR30U`、时区 `CST-8`、清默认 root 密码 |

**⚠️ 这份固件是 U-Boot mod（ubootmod）布局，不是原厂引导。**

树里的 DTS 是 `mt7981b-xiaomi-wr30u.dts` → `mt7981b-xiaomi_mi-router.dtsi`，分区表是：

```
BL2 / Nvram / Bdata / Factory / FIP / crash / crash_log / ubi(0x600000, 112MiB) / KF
```

`crash` + `crash_log` + `ubi` + `KF` 这一套是 **ubootmod** 的布局（原厂布局是
`kernel` + `rootfs` + `rootfs_data`）。所以：

- 只能刷在**已经改过 U-Boot** 的机器上（hanwckf U-Boot / OpenWrt 官方 ubootmod）；
- 产物是 `openwrt-mediatek-filogic-xiaomi_mi-router-wr30u-squashfs-sysupgrade.bin`，
  走 LuCI 的「不保留配置」升级，或 `sysupgrade` 刷入；
- 原厂 U-Boot 的机器**不要**直接刷，先按社区流程刷好 U-Boot。

ubi 分区 112MiB，squashfs 压缩后放得下 xray-core + hysteria + shadowsocks-rust，
剩余空间给 `rootfs_data` 覆盖层。

- LAN 默认 `10.0.0.1`。
- 刷完 root 密码为空，**先设密码再接网**。

---

## 常用改动

**换默认 LAN IP / 主机名**：改对应的 `diy-part2-*.sh`，注意脚本末尾的 `grep` 校验会打印命中情况。

**加 BBR**：在对应 `.config*` 里加 `CONFIG_PACKAGE_kmod-tcp-bbr=y`。

**要 openclash / passwall**：改 `diy-part1.sh`，别删那两行 `sed`，
然后在 `.config*` 里加上对应包（aarch64 两台空间够，K2P 不够）。

**N1 想要 squashfs + failsafe**：把 `.config.n1` 里的
`CONFIG_TARGET_ROOTFS_EXT4FS=y` 换成 `CONFIG_TARGET_ROOTFS_SQUASHFS=y`，
同时把 `PARTSIZE` 从 256 降到 160（squashfs 会按 PARTSIZE 补齐，补满 256 就没有
覆盖层空间了）。

---

- **感谢** [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) 和 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- 通过创建流程文件，在线编译 helloworld 服务固件；
- 修改 `REPO_URL` / `REPO_BRANCH` 可换源码库（默认 lean 的 `coolsnowwolf/lede` master，
  也可以换 Lienol 的 `Lienol/openwrt`，分支 `dev-master` 激进、`dev-19.07` 平稳、`dev-lean-lede` 跟 lean）；
- `diy-part1.sh` 在 `feeds update` 前改 `feeds.conf.default`，`diy-part2.sh` 在 `feeds install` 后改默认值；
- 在 Actions 页面选对应 workflow，点 Run workflow 即可开始编译。
