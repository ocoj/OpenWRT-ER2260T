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

	# 3) SFP：打开 qca-ssdk 的 SFP 编译开关（ipq807x/HPPE 默认关闭）
	ER_SSDK="./package/qca-nss/qca-ssdk/Makefile"
	if grep -q "SSDK_MAKE_FLAGS += CHIP_TYPE=HPPE" "$ER_SSDK"; then
		sed -i 's/SSDK_MAKE_FLAGS += CHIP_TYPE=HPPE/SSDK_MAKE_FLAGS += CHIP_TYPE=HPPE IN_SFP=TRUE IN_SFP_PHY=TRUE IN_PHY_I2C_MODE=TRUE/' "$ER_SSDK"
		echo "ER2260T SSDK SFP flags applied"
	else
		echo "ER2260T SSDK CHIP_TYPE=HPPE line not found"
	fi
	# 4) 精简冗余包：AC 管理 + 音频（纯有线路由用不上）
	sed -i '/CONFIG_PACKAGE_luci-app-gecoosac/d' .config
	sed -i '/CONFIG_PACKAGE_kmod-sound-core/d' .config
	sed -i '/CONFIG_PACKAGE_kmod-usb-audio/d' .config
	echo "ER2260T redundant packages removed"

	# 5) 网络监控/管理工具
	echo "CONFIG_PACKAGE_snmpd-ssl=y" >> .config
	echo "CONFIG_PACKAGE_snmp-utils-ssl=y" >> .config
	echo "CONFIG_PACKAGE_netdata=y" >> .config
	echo "CONFIG_PACKAGE_prometheus-node-exporter-lua=y" >> .config
	echo "CONFIG_PACKAGE_zabbix-agentd=y" >> .config
	echo "CONFIG_PACKAGE_luci-app-netdata=y" >> .config
	echo "ER2260T monitoring tools added"

	# 6) 修复 qca-ssdk sfp_phy.c PHY API (Linux 6.18)
	SFPPHY_PATCH="./package/qca-nss/qca-ssdk/patches/012-compat-sfp-phy-driver-register-linux-6.18.patch"
	echo "LS0tIGEvc3JjL2hzbC9waHkvc2ZwX3BoeS5jCisrKyBiL3NyYy9oc2wvcGh5L3NmcF9waHkuYwpAQCAtNjgxLDcgKzY4MSw3IEBACiAJaWYgKGhzbF9wb3J0X3BoeV9hY2Nlc3NfdHlwZV9nZXQoZGV2X2lkLCBwb3J0KSA9PSBQSFlfSTJDX0FDQ0VTUykgewogCQlpZihwaHlkZXYtPmRydikKLQkJCXBoeV9kcml2ZXJfdW5yZWdpc3RlcihwaHlkZXYtPmRydik7CisJCQlwaHlfZHJpdmVyc191bnJlZ2lzdGVyKChzdHJ1Y3QgcGh5X2RyaXZlciAqKXBoeWRldi0+ZHJ2LCAxKTsKIAl9CiAjZW5kaWYKIAlyZXR1cm4gMDsKIH0KQEAgLTcyMiw3ICs3MjIsNyBAQAogCWlmKHNmcF9waHlfZHJ2X3JlZ2lzdGVyZWQgPT0gQV9GQUxTRSkKIAl7Ci0JCXJldCA9IHBoeV9kcml2ZXJfcmVnaXN0ZXIoJnNmcF9waHlfZHJpdmVyLCBUSElTX01PRFVMRSk7CisJCXJldCA9IHBoeV9kcml2ZXJzX3JlZ2lzdGVyKCZzZnBfcGh5X2RyaXZlciwgMSwgVEhJU19NT0RVTEUpOwogCQlzZnBfcGh5X2Rydl9yZWdpc3RlcmVkID0gQV9UUlVFOwogCX0KIAlyZXR1cm4gcmV0OwogfQpAQCAtNzMyLDYgKzczMiw2IEBACiAJaWYgKHNmcF9waHlfZHJ2X3JlZ2lzdGVyZWQgPT0gQV9UUlVFKQogCXsKLQkJcGh5X2RyaXZlcl91bnJlZ2lzdGVyKCZzZnBfcGh5X2RyaXZlcik7CisJCXBoeV9kcml2ZXJzX3VucmVnaXN0ZXIoJnNmcF9waHlfZHJpdmVyLCAxKTsKIAkJc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9IEFfRkFMU0U7CiAJfQogfQpAQCAtNzc5LDcgKzc3OSw1IEBACiAJcGh5X2lkID0gU0ZQX1BIWTsKLQlpZiAoYnVzX2luZGV4ICE9IFNTREtfTUlJX0RFRkFVTFRfQlVTX0lEKSB7Ci0JCWhzbF9waHlfYWRkcmVzc19pbml0KGRldl9pZCwgcG9ydF9pZCwKLQkJCVRPX1BIWV9BRERSX0UoRkFMX1NGUF9QSFlfQUREUiwgYnVzX2luZGV4KSk7Ci0JCWlmKHNmcF9waHlfaWRfZ2V0KGRldl9pZCwgcG9ydF9pZCkgPT0gUUNBODExMV9QSFkpCi0JCQlwaHlfaWQgPSBRQ0E4MTExX1BIWTsKLQl9CisJaHNsX3BoeV9hZGRyZXNzX2luaXQoZGV2X2lkLCBwb3J0X2lkLAorCQlUT19QSFlfQUREUl9FKEZBTF9TRlBfUEhZX0FERFIsIDApKTsKKwlpZihzZnBfcGh5X2lkX2dldChkZXZfaWQsIHBvcnRfaWQpID09IFFDQTgxMTFfUEhZKQorCQlwaHlfaWQgPSBRQ0E4MTExX1BIWTsK" | base64 -d > "$SFPPHY_PATCH"
	echo "ER2260T sfp_phy.c PHY API patch added"

	# 7) 禁用 WiFi 认证（纯有线路由无 WiFi；规避 hostapd 补丁失败）
	echo "CONFIG_PACKAGE_wpad-openssl=n" >> .config
	echo "CONFIG_PACKAGE_wpad-full-openssl=n" >> .config
	echo "CONFIG_PACKAGE_wpad-basic-openssl=n" >> .config
	echo "CONFIG_PACKAGE_hostapd=n" >> .config
	echo "CONFIG_PACKAGE_hostapd-utils=n" >> .config
	echo "ER2260T wpad/hostapd disabled"

	echo "=== ER2260T patches done ==="
fi
