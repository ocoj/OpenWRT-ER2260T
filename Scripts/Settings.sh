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

	# 2) GE 口：QSGMII -> PSGMII（与 U-Boot / 原厂 / 旧版固件一致）
	ER_DTS="$DTS_PATH/ipq8070-tl-er2260t.dts"
	if grep -q "MAC_MODE_QSGMII" "$ER_DTS"; then
		sed -i 's/switch_mac_mode = <MAC_MODE_QSGMII>;/switch_mac_mode = <MAC_MODE_PSGMII>;/' "$ER_DTS"
		echo "ER2260T PSGMII applied"
	else
		echo "ER2260T switch_mac_mode already PSGMII or missing"
	fi

	# 2b) SFP：主线 sfp.c 方案（DTS 重构 + nss-dp SFP bus 支持）
	#     内核配置：PHYLINK / SFP / MARVELL_10G_PHY / AQUANTIA_PHY（MDIO_I2C 由 SFP 自动选中）
	ER_KCFG="target/linux/qualcommax/config-6.18"
	grep -q "CONFIG_PHYLINK=y" "$ER_KCFG" || echo "CONFIG_PHYLINK=y" >> "$ER_KCFG"
	grep -q "CONFIG_SFP=y" "$ER_KCFG" || echo "CONFIG_SFP=y" >> "$ER_KCFG"
	grep -q "CONFIG_MARVELL_10G_PHY=y" "$ER_KCFG" || echo "CONFIG_MARVELL_10G_PHY=y" >> "$ER_KCFG"
	grep -q "CONFIG_AQUANTIA_PHY=y" "$ER_KCFG" || echo "CONFIG_AQUANTIA_PHY=y" >> "$ER_KCFG"
	echo "ER2260T SFP kernel config applied"

	#     设备树：blsp1_i2c3（GPIO46/47）挂 sff,sfp 节点；dp5_syn/dp6_syn 改 sfp 引用；
	#     qcom,port_phyinfo 移除 SSDK SFP 属性（media-type/phy-i2c-mode）
	if [ -f "$GITHUB_WORKSPACE/Patches/er2260t-sfp-mainline-dts.patch" ]; then
		patch -p1 < "$GITHUB_WORKSPACE/Patches/er2260t-sfp-mainline-dts.patch"
		echo "ER2260T SFP DTS patch applied"
	else
		echo "ER2260T SFP DTS patch missing"
	fi

	#     nss-dp：注册 SFP bus upstream（connect_phy -> phy_connect_direct）
	mkdir -p ./package/qca-nss/qca-nss-dp/patches
	if [ -f "$GITHUB_WORKSPACE/Patches/013-nss-dp-sfp-bus-support.patch" ]; then
		cp "$GITHUB_WORKSPACE/Patches/013-nss-dp-sfp-bus-support.patch" \
			./package/qca-nss/qca-nss-dp/patches/
		echo "ER2260T nss-dp SFP patch copied"
	else
		echo "ER2260T nss-dp SFP patch missing"
	fi


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
