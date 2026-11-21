#!/bin/bash
# diy-part2-wr30u.sh —— feeds install 之后、make defconfig 之前执行
# 把默认值改成和现在这台网络一致，刷完不用重新配

# 1) LAN 口 IP：默认 192.168.1.1 -> 10.0.0.1
sed -i 's/192.168.1.1/10.0.0.1/g' package/base-files/files/bin/config_generate

# 2) 主机名 LEDE -> WR30U
sed -i "s/hostname='LEDE'/hostname='WR30U'/" package/base-files/files/bin/config_generate

# 3) 时区 GMT0 -> CST-8 (Asia/Shanghai)
sed -i "s/timezone='GMT0'/timezone='CST-8'/" package/base-files/files/bin/config_generate

# 4) 清掉 Lean's 默认的 root 密码（首刷完请立刻自己设一个）
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' package/lean/default-settings/files/zzz-default-settings

# 5) 校验改动是否命中（sed 没匹配到不会报错，这里显式检查一下）
echo "--- 校验 ---"
grep -n "10.0.0.1" package/base-files/files/bin/config_generate | head -3
grep -n "hostname='WR30U'\|timezone='CST-8'" package/base-files/files/bin/config_generate
grep -c "^#.*CYXluq4wUazHjmCDBCqXF" package/lean/default-settings/files/zzz-default-settings

# ---------------------------------------------------------------------------
# 6) mihomo：去掉 UPX 压缩
#
# feeds/packages/net/mihomo/Makefile 里写死了 upx --lzma --best：
#   PKG_BUILD_DEPENDS := ... upx/host
#   Build/Install:  cp 到 .upx/mihomo 后 upx --lzma --best
#   Package/install: 装的是 .upx/mihomo
#
# UPX 打包的二进制在 exec 时会把整包解到 memfd（tmpfs），表现为
# RssShmem ≈ 34MB。本机 0 swap，Shmem 永不回收 —— 这是 nikki/mihomo
# 反复被 OOM kill 的直接原因（实测 17 次）。
#
# 改成装 Go 原始产物（-s -w 已 strip，体积 ~57MB，rootfs 装得下）。
# ---------------------------------------------------------------------------
MIHOMO_MK="feeds/packages/net/mihomo/Makefile"
if [ -f "$MIHOMO_MK" ]; then
	echo "--- 去掉 mihomo 的 UPX 压缩 ---"
	# 不再需要 host 端 upx
	sed -i 's|^PKG_BUILD_DEPENDS:=golang/host upx/host$|PKG_BUILD_DEPENDS:=golang/host|' "$MIHOMO_MK"
	# Build/Install 直接放行原始二进制，不生成 .upx 副本
	python3 - "$MIHOMO_MK" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()

new_install = """define Build/Install
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/.bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/mihomo $(PKG_BUILD_DIR)/.bin/mihomo
endef
"""
s2, n = re.subn(r"define Build/Install\n.*?\nendef\n", new_install, s, count=1, flags=re.S)
if n != 1:
    sys.exit("Build/Install 块替换失败（模式未命中）")
# 安装路径从 .upx 改到 .bin
s2 = s2.replace("$(PKG_BUILD_DIR)/.upx/mihomo", "$(PKG_BUILD_DIR)/.bin/mihomo")
# 顺手改掉误导性注释
s2 = s2.replace(
    "# Compress once per build, not once per package/rootfs installation.\n"
    "# Keep Go's output intact and let the .built stamp guard the packed copy.\n",
    "# Ship the Go binary as-is (no UPX): a UPX-packed binary unpacks into a\n"
    "# memfd (tmpfs) at exec time and shows up as unreclaimable RssShmem.\n")
s2 = s2.replace(
    "# Go's -s -w flags strip the binary before UPX; do not strip it again.",
    "# Go's -s -w flags already strip the binary; do not strip it again.")
open(p, "w").write(s2)
print("Build/Install 已替换")
PYEOF
	grep -n "upx" "$MIHOMO_MK" && echo "!! 仍有 upx 残留" || echo "upx 已完全移除"
	grep -n -A4 "^define Build/Install" "$MIHOMO_MK"
else
	echo "!! 找不到 $MIHOMO_MK，UPX 未处理"
	exit 1
fi

# ---------------------------------------------------------------------------
# 7) zram：内核模块 + 用户态
#
# 这台是 231MB RAM / 0 swap，mihomo 常驻 60MB，MemAvailable 常年 8-12MB。
# 加 zram 当压缩 swap，给内核一个缓冲垫，避免流量尖峰直接触发全局 OOM。
#
# CONFIG_PACKAGE_kmod-zram 由 feeds/packages/kernel/modules/other.mk 的
# KernelPackage/zram 提供，KCONFIG 会打开 CONFIG_ZRAM / CONFIG_ZSMALLOC。
# zram-swap 依赖它，会自动带进来，这里显式写清楚便于审阅。
# ---------------------------------------------------------------------------
echo "--- 校验 zram 相关包存在 ---"
# 注意路径：这两个都在 lede 主源码树里，不在 feeds 里。
#   kmod-zram  -> package/kernel/linux/modules/other.mk   (KernelPackage/zram)
#   zram-swap  -> package/system/zram-swap/               (PKG_NAME:=zram-swap)
# 只有 mihomo / nikki 这类第三方包才在 feeds/ 下。
if grep -q "KernelPackage/zram" package/kernel/linux/modules/other.mk; then
	echo "  ok: kmod-zram (package/kernel/linux/modules/other.mk)"
else
	echo "!! 主树里找不到 kmod-zram"
	exit 1
fi
if grep -q "PKG_NAME:=zram-swap" package/system/zram-swap/Makefile; then
	echo "  ok: zram-swap (package/system/zram-swap)"
else
	echo "!! 主树里找不到 zram-swap"
	exit 1
fi

# ⚠️ 关键修正：zram 压缩后端的版本门槛
#
# other.mk 里 KernelPackage/zram/config 的选择块是这样写的：
#     if LINUX_6_12
#         config KERNEL_ZRAM_BACKEND_LZO / LZ4 / LZ4HC / ZSTD ...
#     choice "ZRAM Default compressor"
#     ...
# 本目标是 mediatek/filogic，KERNEL_PATCHVER=6.18 —— `if LINUX_6_12` 不成立，
# 整个选择块被跳过，KERNEL_ZRAM_BACKEND_* 一个都不会声明。
#
# 后果链（不改就会中招）：
#   内核 .config 里 ZRAM_BACKEND_* 全 not set
#   → generic/config-6.18 又显式写着 CONFIG_ZRAM_DEF_COMP="unset-value"
#   → zram.ko 编出来没有任何压缩后端，初始化即失败，swap 起不来
#
# 放宽门槛到 6.18 / 7.3（lede 现有的内核版本档位），让选择块正常生效。
# 改的是主源码树的 package/kernel/linux/modules/other.mk（不是 feeds 副本）。
OTHER_MK="package/kernel/linux/modules/other.mk"
if [ -f "$OTHER_MK" ]; then
	echo "--- 放宽 zram 后端的内核版本门槛 ---"
	before=$(grep -c "if LINUX_6_12$" "$OTHER_MK")
	sed -i 's#^\([[:space:]]*\)if LINUX_6_12$#\1if LINUX_6_12 || LINUX_6_18 || LINUX_7_3#' "$OTHER_MK"
	after=$(grep -c "if LINUX_6_12 || LINUX_6_18 || LINUX_7_3$" "$OTHER_MK")
	echo "  命中 $before 处，改后 $after 处"
	if [ "$before" -gt 0 ] && [ "$after" -eq 0 ]; then
		echo "!! sed 未生效，zram 后端会缺失"
		exit 1
	fi
	grep -n -A6 "if LINUX_6_12" "$OTHER_MK" | head -12
else
	echo "!! 找不到 $OTHER_MK"
	exit 1
fi

# ---------------------------------------------------------------------------
# 8) 首启默认值（uci-defaults）
#
# 两个脚本随固件带进 /etc/uci-defaults/，首次启动时执行一次：
#   98-nikki-tuning      test_profile=0（关掉启动前的全量 mihomo -t 预检）
#                        + GOMEMLIMIT=96MiB
#   99-zram-settings     zram 尺寸 / 算法 / 优先级
#
# ⚠️ 不能直接改 /etc/config/system 或 /etc/config/nikki：这两份都是
# 首启动态生成 / conffile，源码树里没有可靠副本可 sed。
# 工作流的 `[ -e files ] && mv files openwrt/files` 会把 files/ 带进固件。
# ---------------------------------------------------------------------------
for d in files/etc/uci-defaults/97-carbon-theme files/etc/uci-defaults/98-nikki-tuning files/etc/uci-defaults/99-zram-settings; do
	if [ -f "$d" ]; then
		chmod 755 "$d"
		sh -n "$d" && echo "  ok: $d"
	else
		echo "!! 缺少 $d"
		exit 1
	fi
done

# Carbon 主题离线包（不在 lede feeds 里，只能离线装）
CARBON_IPK="files/opt/pkgs/luci-theme-carbon.ipk"
if [ -f "$CARBON_IPK" ]; then
	sha=$(sha256sum "$CARBON_IPK" | cut -d' ' -f1)
	if [ "$sha" = "99cfad5d365a39911c411aa2025670868480cfe61534c906c64ec7eebf4ab310" ]; then
		echo "  ok: carbon ipk (v1.1.8, sha256 匹配)"
	else
		echo "!! carbon ipk sha256 不匹配: $sha"
		exit 1
	fi
else
	echo "!! 缺少 $CARBON_IPK"
	exit 1
fi

# ---------------------------------------------------------------------------
# 9) 空间自检：去掉 UPX 后 mihomo 原始体积 ~57MB
#
# squashfs 压缩后实测 ~16.5MB（UPX 版 12.8MB），净增约 3.7MB。
# 这里只做提示，真正的容量判断交给 make 阶段的 image 大小检查。
# ---------------------------------------------------------------------------
echo "--- 预期体积 ---"
echo "  mihomo（未压缩，squashfs 后）: ~16.5MB（UPX 版 12.8MB，净增 ~3.7MB）"
echo "  已移除：xray-core / hysteria / sslocal / ssr-* / v2ray-geoip(19MB) ≈ 60MB"

echo "diy-part2-wr30u.sh done"
