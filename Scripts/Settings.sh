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
	echo "LS0tIGEvc3JjL2hzbC9waHkvc2ZwX3BoeS5jCisrKyBiL3NyYy9oc2wvcGh5L3NmcF9waHkuYwpAQCAtMzgsNiArMzgsNyBAQAogI2luY2x1ZGUgPGxpbnV4L2kyYy5oPgogI2luY2x1ZGUgPGxpbnV4L3BoeWxpbmsuaD4KICNpbmNsdWRlIDxsaW51eC9zZnAuaD4KKyNpbmNsdWRlIDxsaW51eC9vZi5oPgogCiBzdGF0aWMgYV9ib29sX3Qgc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9IEFfRkFMU0U7CiAKQEAgLTE1NywxMSArMTU4LDcgQEAKIAlwZGV2LT5wb3J0ID0gUE9SVF9GSUJSRTsKIAogCXBvcnQgPSBxY2Ffc3Nka19waHlkZXZfdG9fcG9ydChwcml2LT5kZXZpY2VfaWQsIHBkZXYpOwotCWlmIChBX1RSVUUgPT0gaHNsX3BvcnRfZmVhdHVyZV9nZXQocHJpdi0+ZGV2aWNlX2lkLCBwb3J0LCBQSFlfRl9TRlBfU0dNSUkpKSB7Ci0JCXBkZXYtPmF1dG9uZWcgPSBBVVRPTkVHX0VOQUJMRTsKLQl9IGVsc2UgewotCQlwZGV2LT5hdXRvbmVnID0gQVVUT05FR19ESVNBQkxFOwotCX0KKwlwZGV2LT5hdXRvbmVnID0gQVVUT05FR19FTkFCTEU7CiAJcmV0dXJuIDA7CiB9CiAKQEAgLTYzNCwxMSArNjMxLDMwIEBACiAJYV9ib29sX3QgaXNfYzQ1OwogCXN0cnVjdCBkZXZpY2VfZHJpdmVyICpkZXZfZHJ2OwogCXN0cnVjdCBwaHlfZHJpdmVyICpuc3NfcGh5X2RydjsKKwlzdHJ1Y3QgZGV2aWNlX25vZGUgKnN3aXRjaF9ub2RlLCAqcGh5X2luZm9fbm9kZSwgKnBvcnRfbm9kZTsKKwlzdHJ1Y3QgZGV2aWNlX25vZGUgKnBvcnRfb2Zfbm9kZSA9IE5VTEw7CisJYV91aW50MzJfdCBkdHNfcG9ydF9pZCA9IDA7CiAKIAlpZiAoQV9UUlVFID09IGhzbF9wb3J0X3BoeV9jb21ib19jYXBhYmlsaXR5X2dldChkZXZfaWQsIHBvcnQpKQogCXsKIAkJcmV0dXJuIDA7CiAJfQorCS8qIGZpbmQgZXNzLXN3aXRjaCBub2RlLCB0aGVuIG1hdGNoaW5nIHBvcnRATiB1bmRlciBxY29tLHBvcnRfcGh5aW5mbyAqLworCXN3aXRjaF9ub2RlID0gb2ZfZmluZF9jb21wYXRpYmxlX25vZGUoTlVMTCwgTlVMTCwgInFjb20sZXNzLXN3aXRjaC1pcHE4MDd4Iik7CisJaWYgKHN3aXRjaF9ub2RlKSB7CisJCXBoeV9pbmZvX25vZGUgPSBvZl9nZXRfY2hpbGRfYnlfbmFtZShzd2l0Y2hfbm9kZSwgInFjb20scG9ydF9waHlpbmZvIik7CisJCWlmIChwaHlfaW5mb19ub2RlKSB7CisJCQlmb3JfZWFjaF9hdmFpbGFibGVfY2hpbGRfb2Zfbm9kZShwaHlfaW5mb19ub2RlLCBwb3J0X25vZGUpIHsKKwkJCQlpZiAoIW9mX3Byb3BlcnR5X3JlYWRfdTMyKHBvcnRfbm9kZSwgInBvcnRfaWQiLCAmZHRzX3BvcnRfaWQpICYmCisJCQkJICAgIGR0c19wb3J0X2lkID09IHBvcnQpIHsKKwkJCQkJcG9ydF9vZl9ub2RlID0gb2Zfbm9kZV9nZXQocG9ydF9ub2RlKTsKKwkJCQkJYnJlYWs7CisJCQkJfQorCQkJfQorCQkJb2Zfbm9kZV9wdXQocGh5X2luZm9fbm9kZSk7CisJCX0KKwkJb2Zfbm9kZV9wdXQoc3dpdGNoX25vZGUpOworCX0KIAkvKmNyZWF0ZSBwaHkgZGV2aWNlKi8KICNpZiBkZWZpbmVkKElOX1BIWV9JMkNfTU9ERSkKIAlpZiAoaHNsX3BvcnRfcGh5X2FjY2Vzc190eXBlX2dldChkZXZfaWQsIHBvcnQpID09IFBIWV9JMkNfQUNDRVNTKSB7CkBAIC02NjIsNiArNjc4LDcgQEAKIAkJU1NES19FUlJPUigiRmFpbGVkIHRvIGNyZWF0ZSBwaHkgZGV2aWNlIVxuIik7CiAJCXJldHVybiBTV19OT1RfU1VQUE9SVEVEOwogCX0KKwlwaHlkZXYtPm1kaW8uZGV2Lm9mX25vZGUgPSBwb3J0X29mX25vZGU7CiAJcGh5ZGV2LT5wcml2ID0gcHJpdjsKIAkvKnJlZ2lzdGVyIHBoeSBkZXZpY2UqLwogCXBoeV9kZXZpY2VfcmVnaXN0ZXIocGh5ZGV2KTsKQEAgLTY4MCw3ICs2OTcsNyBAQAogI2lmIGRlZmluZWQoSU5fUEhZX0kyQ19NT0RFKQogCWlmIChoc2xfcG9ydF9waHlfYWNjZXNzX3R5cGVfZ2V0KGRldl9pZCwgcG9ydCkgPT0gUEhZX0kyQ19BQ0NFU1MpIHsKIAkJaWYocGh5ZGV2LT5kcnYpCi0JCQlwaHlfZHJpdmVyX3VucmVnaXN0ZXIocGh5ZGV2LT5kcnYpOworCQkJcGh5X2RyaXZlcnNfdW5yZWdpc3Rlcigoc3RydWN0IHBoeV9kcml2ZXIgKilwaHlkZXYtPmRydiwgMSk7CiAJfQogI2VuZGlmCiAJcmV0dXJuIDA7CkBAIC03MjEsNyArNzM4LDcgQEAKIAlpbnQgcmV0ID0gMDsKIAlpZihzZnBfcGh5X2Rydl9yZWdpc3RlcmVkID09IEFfRkFMU0UpCiAJewotCQlyZXQgPSBwaHlfZHJpdmVyX3JlZ2lzdGVyKCZzZnBfcGh5X2RyaXZlciwgVEhJU19NT0RVTEUpOworCQlyZXQgPSBwaHlfZHJpdmVyc19yZWdpc3Rlcigmc2ZwX3BoeV9kcml2ZXIsIDEsIFRISVNfTU9EVUxFKTsKIAkJc2ZwX3BoeV9kcnZfcmVnaXN0ZXJlZCA9IEFfVFJVRTsKIAl9CiAJcmV0dXJuIHJldDsKQEAgLTczMSw3ICs3NDgsNyBAQAogewogCWlmIChzZnBfcGh5X2Rydl9yZWdpc3RlcmVkID09IEFfVFJVRSkKIAl7Ci0JCXBoeV9kcml2ZXJfdW5yZWdpc3Rlcigmc2ZwX3BoeV9kcml2ZXIpOworCQlwaHlfZHJpdmVyc191bnJlZ2lzdGVyKCZzZnBfcGh5X2RyaXZlciwgMSk7CiAJCXNmcF9waHlfZHJ2X3JlZ2lzdGVyZWQgPSBBX0ZBTFNFOwogCX0KIH0KQEAgLTczOSwyNiArNzU2LDE3IEBACiBzdGF0aWMgYV91aW50MzJfdAogc2ZwX3BoeV9pZF9nZXQoYV91aW50MzJfdCBkZXZfaWQsIGFfdWludDMyX3QgcG9ydF9pZCkKIHsKLQlhX3VpbnQxNl90IG9yZ19pZCwgcmV2X2lkLCByZWdfZGF0YTsKKwlhX3VpbnQxNl90IG9yZ19pZCwgcmV2X2lkOwogCWFfdWludDMyX3QgcGh5X2lkOwogCXN0cnVjdCBtaWlfYnVzICptZGlvX2kyYyA9IHNzZGtfcG9ydF9taWlidXNfZ2V0KGRldl9pZCwgcG9ydF9pZCk7CiAKIAlpZiAoIW1kaW9faTJjKQogCQlyZXR1cm4gSU5WQUxJRF9QSFlfSUQ7CiAKLQkvKiBpZiBlMnByb20gc3BlZWQgdmFsdWUgaXMgdmFsaWQsIHRoZW4gdGhlIG1vZHVsZSBpcyBTRlAuICovCi0JLyogaWYgdGhlIHZhbHVlIGlzIDB4ZmZmZiwgbWF5IGJlIHFjb20gcGh5IG1vZHVsZSBvciBubyBtb2R1bGUgKi8KLQkvKiBpbiBTRlAgY2FnZSwgbmVlZCB0byBjaGVjayBQSFkgaWQgKi8KLQlyZWdfZGF0YSA9IG1kaW9faTJjLT5yZWFkKG1kaW9faTJjLCBUT19NRElPX0kyQ19BRERSKFNGUF9FMlBST01fQUREUiksCi0JCVNGUF9TUEVFRF9BRERSKTsKLQlTU0RLX0lORk8oImUycHJvbSBzcGVlZCB2YWx1ZToweCV4XG4iLCByZWdfZGF0YSk7Ci0JaWYgKHJlZ19kYXRhICE9IDB4ZmZmZikKLQkJcmV0dXJuIElOVkFMSURfUEhZX0lEOwotCiAJb3JnX2lkID0gbWRpb19pMmMtPnJlYWRfYzQ1KG1kaW9faTJjLCBGQUxfU0ZQX1BIWV9BRERSLAotCQlNRElPX01NRF9BTiwgTURJT19ERVZJRDEpOworCQlNRElPX01NRF9QTUFQTUQsIE1ESU9fREVWSUQxKTsKIAlyZXZfaWQgPSBtZGlvX2kyYy0+cmVhZF9jNDUobWRpb19pMmMsIEZBTF9TRlBfUEhZX0FERFIsCi0JCU1ESU9fTU1EX0FOLCBNRElPX0RFVklEMik7CisJCU1ESU9fTU1EX1BNQVBNRCwgTURJT19ERVZJRDIpOwogCXBoeV9pZCA9ICgob3JnX2lkIDw8IDE2KSB8IHJldl9pZCk7CiAJaWYgKHBoeV9pZCAhPSBJTlZBTElEX1BIWV9JRCAmJiBwaHlfaWQgIT0gMCkgewogCQloc2xfcG9ydF9mZWF0dXJlX2NsZWFyKGRldl9pZCwgcG9ydF9pZCwgUEhZX0ZfU0ZQKTsKQEAgLTc3MSwxOCArNzc5LDE3IEBACiAKIGludCBzZnBfcGh5X2luaXQoYV91aW50MzJfdCBkZXZfaWQsIGFfdWludDMyX3QgcG9ydF9pZCwgYV91aW50MzJfdCBidXNfaW5kZXgpCiB7Ci0JYV91aW50MzJfdCBwaHlfaWQ7CisJYV91aW50MzJfdCBwaHlfaWQsIHRtcF9waHlfaWQ7CiAJc3RydWN0IHFjYV9waHlfcHJpdiAqcHJpdiA9IHNzZGtfcGh5X3ByaXZfZGF0YV9nZXQoZGV2X2lkKTsKIAogCVNTREtfSU5GTygicWNhIHByb2JlIHNmcCBwaHkgZHJpdmVyIHN1Y2NlZWRlZCBvbiBwb3J0JWRcbiIscG9ydF9pZCk7CiAKIAlwaHlfaWQgPSBTRlBfUEhZOwotCWlmIChidXNfaW5kZXggIT0gU1NES19NSUlfREVGQVVMVF9CVVNfSUQpIHsKLQkJaHNsX3BoeV9hZGRyZXNzX2luaXQoZGV2X2lkLCBwb3J0X2lkLAotCQkJVE9fUEhZX0FERFJfRShGQUxfU0ZQX1BIWV9BRERSLCBidXNfaW5kZXgpKTsKLQkJaWYoc2ZwX3BoeV9pZF9nZXQoZGV2X2lkLCBwb3J0X2lkKSA9PSBRQ0E4MTExX1BIWSkKLQkJCXBoeV9pZCA9IFFDQTgxMTFfUEhZOwotCX0KKwloc2xfcGh5X2FkZHJlc3NfaW5pdChkZXZfaWQsIHBvcnRfaWQsCisJCVRPX1BIWV9BRERSX0UoRkFMX1NGUF9QSFlfQUREUiwgMCkpOworCXRtcF9waHlfaWQgPSBzZnBfcGh5X2lkX2dldChkZXZfaWQsIHBvcnRfaWQpOworCWlmICh0bXBfcGh5X2lkICE9IElOVkFMSURfUEhZX0lEICYmIHRtcF9waHlfaWQgIT0gMCkKKwkJcGh5X2lkID0gdG1wX3BoeV9pZDsKIAogCVNTREtfSU5GTygiU0ZQIHBoeSBpZCBpcyAweCV4XG4iLCBwaHlfaWQpOwogCXNmcF9waHlfZGV2aWNlX3NldHVwKGRldl9pZCwgcG9ydF9pZCwgcGh5X2lkLCBwcml2KTsK" | base64 -d > "$SFPPHY_PATCH"
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
