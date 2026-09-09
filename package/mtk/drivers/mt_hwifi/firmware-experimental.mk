# Laboratory pairing only; no claim of vendor MCU ABI compatibility.
# The two executables and their redistribution license are kept unmodified.
C2000MAX_FW_COMMIT:=be5ce7910521492d4a2e4ce7ee3843680a46c047
C2000MAX_FW_URL:=https://raw.githubusercontent.com/openwrt/mt76/$(C2000MAX_FW_COMMIT)/firmware
C2000MAX_FW_WM:=c2000max-mt7993-mt76-20260310-wm.bin
C2000MAX_FW_ROM:=c2000max-mt7993-mt76-20260310-rom.bin
C2000MAX_FW_LICENSE:=c2000max-mt7993-mt76-20260310-LICENSE

define Download/c2000max-experimental-wm
  FILE:=$(C2000MAX_FW_WM)
  URL:=$(C2000MAX_FW_URL)/mt7996
  URL_FILE:=mt7990_wm.bin
  HASH:=b35b8c0737b55bd176a7e0142ec902c6edcfee1731b9ae6b2b7ecb557c2637c3
endef

define Download/c2000max-experimental-rom
  FILE:=$(C2000MAX_FW_ROM)
  URL:=$(C2000MAX_FW_URL)/mt7996
  URL_FILE:=mt7990_rom_patch.bin
  HASH:=e3ca02567e703a224719dd80c8f1d0c47642d4bede0c4501249ccf7b7602d973
endef

define Download/c2000max-experimental-license
  FILE:=$(C2000MAX_FW_LICENSE)
  URL:=$(C2000MAX_FW_URL)
  URL_FILE:=LICENSE
  HASH:=77c0eb6b7915fdb17b328c1eff3d2074bff2025e88603ac59e01ffc07ba0b541
endef

$(eval $(call Download,c2000max-experimental-wm))
$(eval $(call Download,c2000max-experimental-rom))
$(eval $(call Download,c2000max-experimental-license))

define Install/C2000MAXExperimentalFirmware
	# Check again at packaging: never silently mix a different cached WM/ROM.
	$(MKHASH) sha256 $(DL_DIR)/$(C2000MAX_FW_WM) | grep -Fxq b35b8c0737b55bd176a7e0142ec902c6edcfee1731b9ae6b2b7ecb557c2637c3
	$(MKHASH) sha256 $(DL_DIR)/$(C2000MAX_FW_ROM) | grep -Fxq e3ca02567e703a224719dd80c8f1d0c47642d4bede0c4501249ccf7b7602d973
	$(MKHASH) sha256 $(DL_DIR)/$(C2000MAX_FW_LICENSE) | grep -Fxq 77c0eb6b7915fdb17b328c1eff3d2074bff2025e88603ac59e01ffc07ba0b541
	$(INSTALL_DIR) $(1)/lib/firmware $(1)/usr/share/c2000max-wifi-experimental
	$(INSTALL_DATA) $(DL_DIR)/$(C2000MAX_FW_WM) $(1)/lib/firmware/WIFI_RAM_CODE_MT7993_1_1.bin
	$(INSTALL_DATA) $(DL_DIR)/$(C2000MAX_FW_ROM) $(1)/lib/firmware/WIFI_MT7993_PATCH_MCU_1_1_hdr.bin
	$(INSTALL_DATA) $(DL_DIR)/$(C2000MAX_FW_LICENSE) $(1)/usr/share/c2000max-wifi-experimental/LICENSE
	$(INSTALL_DATA) ./files/experimental-firmware.txt $(1)/usr/share/c2000max-wifi-experimental/README.txt
endef
