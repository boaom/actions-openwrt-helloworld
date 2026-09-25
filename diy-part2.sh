#!/bin/bash
# diy-part2.sh —— feeds install 之后、make defconfig 之前执行
# 把默认值改成和现在这台 K2P 一致，刷完不用重新配网络

# 1) LAN 口 IP：默认 192.168.1.1 -> 保持你现在的 10.0.0.1
sed -i 's/192.168.1.1/10.0.0.1/g' package/base-files/files/bin/config_generate

# 2) 主机名 LEDE -> K2P
sed -i "s/hostname='LEDE'/hostname='K2P'/" package/base-files/files/bin/config_generate

# 3) 时区 GMT0 -> CST-8 (Asia/Shanghai)
sed -i "s/timezone='GMT0'/timezone='CST-8'/" package/base-files/files/bin/config_generate

# 4) 清掉 Lean's 默认的 root 密码（首刷完请立刻自己设一个）
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' package/lean/default-settings/files/zzz-default-settings

# 5) 校验改动是否命中（sed 没匹配到不会报错，这里显式检查一下）
echo "--- 校验 ---"
grep -n "10.0.0.1" package/base-files/files/bin/config_generate | head -3
grep -n "hostname='K2P'\|timezone='CST-8'" package/base-files/files/bin/config_generate
grep -c "^#.*CYXluq4wUazHjmCDBCqXF" package/lean/default-settings/files/zzz-default-settings
echo "diy-part2.sh done"
