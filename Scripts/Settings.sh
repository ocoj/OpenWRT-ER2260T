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

	# 6) 修复 qca-ssdk sfp_phy.c PHY API (Linux 6.18)
	SFPPHY_PATCH="./package/qca-nss/qca-ssdk/patches/012-compat-sfp-phy-driver-register-linux-6.18.patch"
	echo "LS0tIGEvc3JjL2hzbC9waHkvc2ZwX3BoeS5jCisrKyBiL3NyYy9oc2wvcGh5L3NmcF9waHkuYwpAQCAtMzksNCArMzksNSBAQAogI2luY2x1ZGUgPGxpbnV4L3BoeWxpbmsuaD4KICNpbmNsdWRlIDxsaW51eC9zZnAuaD4KKyNpbmNsdWRlIDxsaW51eC9vZi5oPgogCiBzdGF0aWMgYV9ib29sX3Qgc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9IEFfRkFMU0U7CkBAIC02MzYsMyArNjM2LDYgQEAKIAlzdHJ1Y3QgcGh5X2RyaXZlciAqbnNzX3BoeV9kcnY7CisJc3RydWN0IGRldmljZV9ub2RlICpzd2l0Y2hfbm9kZSwgKnBoeV9pbmZvX25vZGUsICpwb3J0X25vZGU7CisJc3RydWN0IGRldmljZV9ub2RlICpwb3J0X29mX25vZGUgPSBOVUxMOworCWFfdWludDMyX3QgZHRzX3BvcnRfaWQgPSAwOwogCiAJaWYgKEFfVFJVRSA9PSBoc2xfcG9ydF9waHlfY29tYm9fY2FwYWJpbGl0eV9nZXQoZGV2X2lkLCBwb3J0KSkKQEAgLTY0MSwzICs2NDUsMTkgQEAKIAkJcmV0dXJuIDA7CiAJfQorCS8qIGZpbmQgZXNzLXN3aXRjaCBub2RlLCB0aGVuIG1hdGNoaW5nIHBvcnRATiB1bmRlciBxY29tLHBvcnRfcGh5aW5mbyAqLworCXN3aXRjaF9ub2RlID0gb2ZfZmluZF9jb21wYXRpYmxlX25vZGUoTlVMTCwgTlVMTCwgInFjb20sZXNzLXN3aXRjaC1pcHE4MDd4Iik7CisJaWYgKHN3aXRjaF9ub2RlKSB7CisJCXBoeV9pbmZvX25vZGUgPSBvZl9nZXRfY2hpbGRfYnlfbmFtZShzd2l0Y2hfbm9kZSwgInFjb20scG9ydF9waHlpbmZvIik7CisJCWlmIChwaHlfaW5mb19ub2RlKSB7CisJCQlmb3JfZWFjaF9hdmFpbGFibGVfY2hpbGRfb2Zfbm9kZShwaHlfaW5mb19ub2RlLCBwb3J0X25vZGUpIHsKKwkJCQlpZiAoIW9mX3Byb3BlcnR5X3JlYWRfdTMyKHBvcnRfbm9kZSwgInBvcnRfaWQiLCAmZHRzX3BvcnRfaWQpICYmCisJCQkJICAgIGR0c19wb3J0X2lkID09IHBvcnQpIHsKKwkJCQkJcG9ydF9vZl9ub2RlID0gb2Zfbm9kZV9nZXQocG9ydF9ub2RlKTsKKwkJCQkJYnJlYWs7CisJCQkJfQorCQkJfQorCQkJb2Zfbm9kZV9wdXQocGh5X2luZm9fbm9kZSk7CisJCX0KKwkJb2Zfbm9kZV9wdXQoc3dpdGNoX25vZGUpOworCX0KIAkvKmNyZWF0ZSBwaHkgZGV2aWNlKi8KQEAgLTY1OCwzICs2NTgsNCBAQAogCX0gZWxzZSB7CiAJCXBoeWRldiA9IHBoeV9kZXZpY2VfY3JlYXRlKGJ1cywgYWRkciwgcGh5X2lkLCBmYWxzZSwgTlVMTCk7CisJCXBoeWRldi0+bWRpby5kZXYub2Zfbm9kZSA9IHBvcnRfb2Zfbm9kZTsKIAl9CkBAIC02ODEsNyArNjgxLDcgQEAKIAlpZiAoaHNsX3BvcnRfcGh5X2FjY2Vzc190eXBlX2dldChkZXZfaWQsIHBvcnQpID09IFBIWV9JMkNfQUNDRVNTKSB7CiAJCWlmKHBoeWRldi0+ZHJ2KQotCQkJcGh5X2RyaXZlcl91bnJlZ2lzdGVyKHBoeWRldi0+ZHJ2KTsKKwkJCXBoeV9kcml2ZXJzX3VucmVnaXN0ZXIoKHN0cnVjdCBwaHlfZHJpdmVyICopcGh5ZGV2LT5kcnYsIDEpOwogCX0KICNlbmRpZgogCXJldHVybiAwOwogfQpAQCAtNzIyLDcgKzcyMiw3IEBACiAJaWYoc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9PSBBX0ZBTFNFKQogCXsKLQkJcmV0ID0gcGh5X2RyaXZlcl9yZWdpc3Rlcigmc2ZwX3BoeV9kcml2ZXIsIFRISVNfTU9EVUxFKTsKKwkJcmV0ID0gcGh5X2RyaXZlcnNfcmVnaXN0ZXIoJnNmcF9waHlfZHJpdmVyLCAxLCBUSElTX01PRFVMRSk7CiAJCXNmcF9waHlfZHJ2X3JlZ2lzdGVyZWQgPSBBX1RSVUU7CiAJfQogCXJldHVybiByZXQ7CiB9CkBAIC03MzIsNiArNzMyLDYgQEAKIAlpZiAoc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9PSBBX1RSVUUpCiAJewotCQlwaHlfZHJpdmVyX3VucmVnaXN0ZXIoJnNmcF9waHlfZHJpdmVyKTsKKwkJcGh5X2RyaXZlcnNfdW5yZWdpc3Rlcigmc2ZwX3BoeV9kcml2ZXIsIDEpOwogCQlzZnBfcGh5X2Rydl9yZWdpc3RlcmVkID0gQV9GQUxTRTsKIAl9CiB9CkBAIC03NDIsMSArNzQyLDEgQEAKLQlhX3VpbnQxNl90IG9yZ19pZCwgcmV2X2lkLCByZWdfZGF0YTsKKwlhX3VpbnQxNl90IG9yZ19pZCwgcmV2X2lkOwpAQCAtNzQ2LDE3ICs3NDYsOCBAQAogCWlmICghbWRpb19pMmMpCiAJCXJldHVybiBJTlZBTElEX1BIWV9JRDsKIAotCS8qIGlmIGUycHJvbSBzcGVlZCB2YWx1ZSBpcyB2YWxpZCwgdGhlbiB0aGUgbW9kdWxlIGlzIFNGUC4gKi8KLQkvKiBpZiB0aGUgdmFsdWUgaXMgMHhmZmZmLCBtYXkgYmUgcWNvbSBwaHkgbW9kdWxlIG9yIG5vIG1vZHVsZSAqLwotCS8qIGluIFNGUCBjYWdlLCBuZWVkIHRvIGNoZWNrIFBIWSBpZCAqLwotCXJlZ19kYXRhID0gbWRpb19pMmMtPnJlYWQobWRpb19pMmMsIFRPX01ESU9fSTJDX0FERFIoU0ZQX0UyUFJPTV9BRERSKSwKLQkJU0ZQX1NQRUVEX0FERFIpOwotCVNTREtfSU5GTygiZTJwcm9tIHNwZWVkIHZhbHVlOjB4JXhcbiIsIHJlZ19kYXRhKTsKLQlpZiAocmVnX2RhdGEgIT0gMHhmZmZmKQotCQlyZXR1cm4gSU5WQUxJRF9QSFlfSUQ7Ci0KIAlvcmdfaWQgPSBtZGlvX2kyYy0+cmVhZF9jNDUobWRpb19pMmMsIEZBTF9TRlBfUEhZX0FERFIsCi0JCU1ESU9fTU1EX0FOLCBNRElPX0RFVklEMSk7CisJCU1ESU9fTU1EX1BNQVBNRCwgTURJT19ERVZJRDEpOwogCXJldl9pZCA9IG1kaW9faTJjLT5yZWFkX2M0NShtZGlvX2kyYywgRkFMX1NGUF9QSFlfQUREUiwKLQkJTURJT19NTURfQU4sIE1ESU9fREVWSUQyKTsKKwkJTURJT19NTURfUE1BUE1ELCBNRElPX0RFVklEMik7CiAJcGh5X2lkID0gKChvcmdfaWQgPDwgMTYpIHwgcmV2X2lkKTsKQEAgLTc3OSw3ICs3NzksNSBAQAogCXBoeV9pZCA9IFNGUF9QSFk7Ci0JaWYgKGJ1c19pbmRleCAhPSBTU0RLX01JSV9ERUZBVUxUX0JVU19JRCkgewotCQloc2xfcGh5X2FkZHJlc3NfaW5pdChkZXZfaWQsIHBvcnRfaWQsCi0JCQlUT19QSFlfQUREUl9FKEZBTF9TRlBfUEhZX0FERFIsIGJ1c19pbmRleCkpOwotCQlpZihzZnBfcGh5X2lkX2dldChkZXZfaWQsIHBvcnRfaWQpID09IFFDQTgxMTFfUEhZKQotCQkJcGh5X2lkID0gUUNBODExMV9QSFk7Ci0JfQorCWhzbF9waHlfYWRkcmVzc19pbml0KGRldl9pZCwgcG9ydF9pZCwKKwkJVE9fUEhZX0FERFJfRShGQUxfU0ZQX1BIWV9BRERSLCAwKSk7CisJaWYoc2ZwX3BoeV9pZF9nZXQoZGV2X2lkLCBwb3J0X2lkKSA9PSBRQ0E4MTExX1BIWSkKKwkJcGh5X2lkID0gUUNBODExMV9QSFk7Cg==" | base64 -d > "$SFPPHY_PATCH"
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
