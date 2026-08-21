#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#无WIFI配置标志
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# ER2260T 专用修复
if [[ "$WRT_CONFIG" == "IPQ807X-ER2260T" ]]; then
	echo "=== ER2260T patches ==="

	# 1) 有线机型去除 wifi dtsi（沿用 wifi-no 构建行为）
	find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
	echo "ER2260T nowifi dtsi applied"

	# 2) SFP：复刻 VIKINGYFY/immortalwrt PR#196 的社区验证方案
	#    （QCA SSDK SFP 路径 + 6.18 兼容补丁 + ER2260T DTS + 网络/LED 配置）
	#    设备树：直接用 PR196 的完整 DTS 补丁（含 PSGMII、SFP 端口、
	#    link-poll、mdio-bus、sfp_rx_los_pin、blsp1_i2c3 等）
	if [ -f "$GITHUB_WORKSPACE/Patches/er2260t-sfp-pr196-dts.patch" ]; then
		patch -p1 < "$GITHUB_WORKSPACE/Patches/er2260t-sfp-pr196-dts.patch"
		echo "ER2260T SFP PR196 DTS patch applied"
	else
		echo "ER2260T SFP PR196 DTS patch missing"
	fi

	#     base-files：接口名已改为 lan1~lan6，必须同步替换 board.d 配置
	#     （否则 LAN 桥引用不存在的旧接口名，设备起来后无 IP 可达）
	ER_BF="target/linux/qualcommax/ipq807x/base-files/etc"
	if [ -f "$GITHUB_WORKSPACE/Patches/er2260t-02_network" ]; then
		cp "$GITHUB_WORKSPACE/Patches/er2260t-02_network" "$ER_BF/board.d/02_network"
		echo "ER2260T 02_network replaced"
	fi
	if [ -f "$GITHUB_WORKSPACE/Patches/er2260t-01_leds" ]; then
		cp "$GITHUB_WORKSPACE/Patches/er2260t-01_leds" "$ER_BF/board.d/01_leds"
		echo "ER2260T 01_leds replaced"
	fi
	if [ -f "$GITHUB_WORKSPACE/Patches/er2260t-sfp_link_speed" ]; then
		cp "$GITHUB_WORKSPACE/Patches/er2260t-sfp_link_speed" "$ER_BF/init.d/sfp_link_speed"
		chmod +x "$ER_BF/init.d/sfp_link_speed"
		echo "ER2260T sfp_link_speed installed"
	fi

	#     QCA SSDK：开启 SFP 相关编译开关
	SSDK_MK="./package/qca-nss/qca-ssdk/Makefile"
	if grep -q "IN_SFP_PHY=TRUE" "$SSDK_MK"; then
		echo "ER2260T SSDK SFP flags already present"
	else
		sed -i 's/CHIP_TYPE=HPPE/CHIP_TYPE=HPPE \\\n\tIN_SFP_PHY=TRUE \\\n\tIN_SFP=TRUE \\\n\tIN_PHY_I2C_MODE=TRUE/' "$SSDK_MK"
		echo "ER2260T SSDK SFP flags applied"
	fi

	#     QCA SSDK：拷贝 PR196 的 SFP 6.18 兼容补丁（012-016）
	mkdir -p ./package/qca-nss/qca-ssdk/patches
	for n in 012-compat-sfp-phy-driver-linux-6.18 \
		013-fix-sfp-link-status-cache-loop \
		014-fix-sfp-link-without-rx-los-gpio \
		015-fix-10g-r-without-hardware-rx-los \
		016-keep-sfp-driver-bound-on-later-ports; do
		if [ -f "$GITHUB_WORKSPACE/Patches/$n.patch" ]; then
			cp "$GITHUB_WORKSPACE/Patches/$n.patch" ./package/qca-nss/qca-ssdk/patches/
		else
			echo "ER2260T SSDK patch $n missing"
		fi
	done
	echo "ER2260T SSDK SFP patches copied"


	# 4) 精简冗余包：AC 管理 + 音频（纯有线路由用不上）
	sed -i '/CONFIG_PACKAGE_luci-app-gecoosac/d' .config
	sed -i '/CONFIG_PACKAGE_kmod-sound-core/d' .config
	sed -i '/CONFIG_PACKAGE_kmod-usb-audio/d' .config
	echo "ER2260T redundant packages removed"

	# 5) 网络监控/管理工具（阶段2：ER2260T_MINIMAL=0 时启用）
	ER2260T_MINIMAL=1
	if [ "$ER2260T_MINIMAL" != "1" ]; then
		echo "CONFIG_PACKAGE_snmpd-ssl=y" >> .config
		echo "CONFIG_PACKAGE_snmp-utils-ssl=y" >> .config
		echo "CONFIG_PACKAGE_netdata=y" >> .config
		echo "CONFIG_PACKAGE_prometheus-node-exporter-lua=y" >> .config
		echo "CONFIG_PACKAGE_zabbix-agentd=y" >> .config
		echo "CONFIG_PACKAGE_luci-app-netdata=y" >> .config
		echo "ER2260T monitoring tools added"
	fi


	# 7) 禁用 WiFi 认证（纯有线路由无 WiFi；规避 hostapd 补丁失败）
	echo "CONFIG_PACKAGE_wpad-openssl=n" >> .config
	echo "CONFIG_PACKAGE_wpad-full-openssl=n" >> .config
	echo "CONFIG_PACKAGE_wpad-basic-openssl=n" >> .config
	echo "CONFIG_PACKAGE_hostapd=n" >> .config
	echo "CONFIG_PACKAGE_hostapd-utils=n" >> .config
	echo "ER2260T wpad/hostapd disabled"

	echo "=== ER2260T patches done ==="
fi
