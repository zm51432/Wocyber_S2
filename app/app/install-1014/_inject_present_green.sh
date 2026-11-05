#!/bin/bash
# 注入：硬盘灯改为「无盘全灭、有盘绿灯常亮」（在 v5 基础上）
set -x
D=/data/fnOS-s2
BASE=fnos_Mainland-PE_arm_1.2.0701_nanopi-r5s_2882
IMG_GZ=$D/${BASE}_modified.img.gz
BAK_OFF=$D/${BASE}_v5-hddled-off.img.gz      # 冻结当前 v5（有盘也灭灯）版本
WORK=$D/work_present_green.img
MNT=/mnt/r5s_root
SRC=$D/install-1014

cd "$D" || exit 1

# 0) 冻结当前 v5（有盘灭灯版）作为备份（real copy，不破坏已有 hardlink）
cp -f "$IMG_GZ" "$BAK_OFF" && echo BACKUP_V5_OFF_OK

# 1) 解包
rm -f "$WORK"
pigz -d -c "$IMG_GZ" > "$WORK" && echo DECOMP_OK
ls -l "$WORK"

# 2) 挂载 rootfs（p2 = btrfs）
mkdir -p "$MNT"
LOOP=$(losetup -P -f --show "$WORK")
echo "LOOP=$LOOP"
mount "${LOOP}p2" "$MNT" && echo MOUNT_OK
ls "$MNT" | head -5

# 3) 注入到三处：运行位 / guard 安装源 / 自愈备份源
for T in /usr/local/sbin /home/anna/install-1014 /usr/local/share/install-1014; do
    mkdir -p "$MNT$T"
    install -m 755 "$SRC/sata-led-manager.sh" "$MNT$T/sata-led-manager.sh" || echo "FAIL copy $T"
done
install -m 644 "$SRC/sata-led.conf" "$MNT/etc/sata-led.conf" || echo "FAIL conf etc"
install -m 644 "$SRC/sata-led.conf" "$MNT/home/anna/install-1014/sata-led.conf"
install -m 644 "$SRC/sata-led.conf" "$MNT/usr/local/share/install-1014/sata-led.conf"

# 4) 校验
echo "--- md5 校验（应全部一致）---"
md5sum "$MNT/usr/local/sbin/sata-led-manager.sh" \
       "$MNT/home/anna/install-1014/sata-led-manager.sh" \
       "$MNT/usr/local/share/install-1014/sata-led-manager.sh" \
       "$MNT/etc/sata-led.conf"
echo "--- 关键行（应为 PRESENT_GREEN=1 / KEEP_OFF_WHEN_PRESENT=1）---"
grep -n "KEEP_OFF_WHEN_PRESENT\|PRESENT_GREEN\|PRESENT_RED" "$MNT/etc/sata-led.conf"
echo "smartctl 出现次数（应为 0）: $(grep -c smartctl "$MNT/usr/local/sbin/sata-led-manager.sh")"
echo "--- 服务启用状态 ---"
ls "$MNT/etc/systemd/system/multi-user.target.wants/" | grep -E "sata-led" || echo "NO sata-led wants"

# 5) 卸载
sync
umount "$MNT" && echo UMOUNT_OK
losetup -d "$LOOP" && echo LOOP_FREED

# 6) 重新打包
pigz -c "$WORK" > "$IMG_GZ.new" && echo PACK_OK
mv -f "$IMG_GZ.new" "$IMG_GZ"
rm -f "$WORK"
ls -l "$IMG_GZ"
gzip -t "$IMG_GZ" && echo GZIP_TEST_OK
md5sum "$IMG_GZ" "$BAK_OFF"
echo ALL_DONE
