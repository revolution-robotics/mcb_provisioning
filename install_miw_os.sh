#!/bin/bash
# Dependencies: 

##### Creating xfs dump images #####
# You have to mount the partition first, can't xfsdump from dev/device, can't from mount point, has to be post mounted /dev/mapper/
# 1. Mount the logical volume, example:
#   sudo mount /dev/centos_mcb/root /mnt/root/
# 2. Create dumpfile, example:
#   sudo xfsdump -l 0 -f /home/root_lvm.image.v2 /dev/mapper/centos_mcb-root

# When making a new image will need to adjust the following files to boot properly:
# /etc/fstab - change centos_unassigned to centos_mcb (or other lvm vg name)
# /etc/default/grub - change centos_unassigned to centos_mcb (or other lvm vg name)
# /boot/grub2/grub.cfg - change centos_unassigned to centos_mcb (or other lvm vg name)

readonly TARGET_BLOCK_DEV="/dev/sdb"

readonly COMBINED_MBR_BOOT_PARTITION_IMAGE="6FEB2020_miw_boot_part_only.img"
# miw_boot_part_only.img was created using dd command after using fdisk to delete partition 2
# sudo dd if=/dev/sdb of=6FEB2020_miw_boot_part_only.img bs=512 count=2099199

# The result is an image of the first ~1GB of the disk that contains grub, the boot partition, and
# the mbr partition table with only the boot partition included. Once this has been written to disk
# the second Linux LVM partition can be added using the fdisk command in this script, allowing the
# LVM partition to be dynamically sized to the full size of the disk.

# Validate input argument
# TODO

# Clear existing partition table
dd if=/dev/zero of=${TARGET_BLOCK_DEV} bs=512 count=512

# Write partition table, grub, and boot partition from image
# Partition table at this point only includes a 1GB boot partition
# LVM Partition will be added to fill the remaining disk space using fdisk
sudo dd if=${COMBINED_MBR_BOOT_PARTITION_IMAGE} of=${TARGET_BLOCK_DEV}

# Partition drive
fdisk ${TARGET_BLOCK_DEV} << EOF
n
p
2
2099200

t
2
8e
p
w
EOF

# If this disk has been used before on this machine there may be cached versions of the lvm volumes
# that will prevent the creation of new pv vg and lv commands. These can be removed in the
# /etc/lvm/backup and /etc/lvm/archive directories

##### Configure LVM volumes #####
# Create physical volume
pvcreate ${TARGET_BLOCK_DEV}2

# Create volume group
vgcreate centos_mcb ${TARGET_BLOCK_DEV}2

# Create logical volumes
lvcreate -L 16G -n swap centos_mcb
lvcreate -L 20G -n home centos_mcb
lvcreate -L 50G -n root centos_mcb
lvcreate -L 840G -n mcb centos_mcb

mkswap /dev/centos_mcb/swap
mkfs.xfs /dev/centos_mcb/home
mkfs.xfs /dev/centos_mcb/root
mkfs.xfs /dev/centos_mcb/mcb

mkdir /mnt/home
mkdir /mnt/root
mkdir /mnt/mcb

mount /dev/centos_mcb/home /mnt/home/
mount /dev/centos_mcb/root /mnt/root/
mount /dev/centos_mcb/mcb /mnt/mcb

xfsrestore -f home_lvm.image /mnt/home/
xfsrestore -f root_lvm.image.v2 /mnt/root/
xfsrestore -f mcb_lvm.image /mnt/mcb/

