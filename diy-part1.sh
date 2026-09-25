#!/bin/bash
# diy-part1.sh —— feeds update 之前执行
# 只启用 helloworld（ssr-plus）这一个第三方 feed，缩短编译时间、避免体积膨胀

# 打开 Lean's lede 自带的 helloworld feed（默认被注释）
sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# 不要 passwall / openclash，K2P 的 16MB flash 装不下
sed -i '/passwall/d' feeds.conf.default
sed -i '/openclash/d' feeds.conf.default

echo "feeds.conf.default 当前内容："
grep -v '^#' feeds.conf.default | grep -v '^$'
