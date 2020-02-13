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

readonly COMBINED_MBR_BOOT_PARTITION_IMAGE="6FEB2020_miw_boot_part_only.img"
# miw_boot_part_only.img was created using dd command after using fdisk to delete partition 2
# sudo dd if=/dev/sdb of=6FEB2020_miw_boot_part_only.img bs=512 count=2099199

# The result is an image of the first ~1GB of the disk that contains grub, the boot partition, and
# the mbr partition table with only the boot partition included. Once this has been written to disk
# the second Linux LVM partition can be added using the fdisk command in this script, allowing the
# LVM partition to be dynamically sized to the full size of the disk.

readonly LVM_VG_NAME=centos_mcb

# Validate input argument

TARGET_BLOCK_DEV=$1
MAP_LOCATION=$(echo ${TARGET_BLOCK_DEV} | sed 's/dev\//dev\/mapper\//')

# Check for input argument
if [ -z ${TARGET_BLOCK_DEV} ]; then
    echo "A block device is required as input argument."
    exit 1
fi

# Check if target is a block device, warn and exit if not
if [ ! -b ${TARGET_BLOCK_DEV} ]; then
    echo "Target must be a block device: ${TARGET_BLOCK_DEV}"
    exit 1
fi

# Warn user that data on the target device will be destroyed.
read -r -p "WARNING: ALL DATA ON ${TARGET_BLOCK_DEV} WILL BE DESTROYED. Are you sure you want to continue? [Y/n]" input
case $input in [yY][eE][sS]|[yY])
    echo "Good luck! ;)"
    ;;
*)
    echo "Exiting."
    exit 1
    ;;
esac

echo "Unmount target disk mount points if mounted"
umount /mnt/home
umount /mnt/root
umount /mnt/mcb

lvremove ${LVM_VG_NAME} 
vgremove ${LVM_VG_NAME}
pvremove ${TARGET_BLOCK_DEV}2

echo "Removing stale dev mapping for ${MAP_LOCATION}1"
dmsetup remove ${MAP_LOCATION}1
echo "Removing stale dev mapping for ${MAP_LOCATION}2"
dmsetup remove ${MAP_LOCATION}2

kpartx -u ${TARGET_BLOCK_DEV}

# Remove /etc/lvm/backup/${LVM_VG_NAME}
if [ -f /etc/lvm/backup/${LVM_VG_NAME} ]; then
    read -r -p "/etc/lvm/backup/${LVM_VG_NAME} already exists. Remove it? [Y/n]" input
    case $input in [yY][eE][sS]|[yY])
        echo "Deleting /etc/lvm/backup/${LVM_VG_NAME}"
        rm /etc/lvm/backup/${LVM_VG_NAME} || {
            echo "Error($?) on line#: $LINENO. Failed to delete /etc/lvm/backup/${LVM_VG_NAME}. Exiting..."
            exit 1
        }
        ;;
    *)
        echo "Can not continue while lvm backup exists."
        exit 1
        ;;
    esac
fi

# sync
# partprobe
# kpartx -u ${TARGET_BLOCK_DEV}
# sync

# Clear existing partition table
echo "Zero'ing out the partition table"
dd if=/dev/zero of=${TARGET_BLOCK_DEV} bs=512 count=512 status=progress || {
    echo "Error($?) on line#: $LINENO. Failed to zero out partition table on ${TARGET_BLOCK_DEV}. Exiting..."
    exit 1
}
# sync
# partprobe
kpartx -u ${TARGET_BLOCK_DEV}
sync

# Write partition table, grub, and boot partition from image
# Partition table at this point only includes a 1GB boot partition
# LVM Partition will be added to fill the remaining disk space using fdisk
echo "Write MBR and boot partition"
dd if=${COMBINED_MBR_BOOT_PARTITION_IMAGE} of=${TARGET_BLOCK_DEV} status=progress || {
    echo "Error($?) on line#: $LINENO. Failed during dd of MBR and BOOT partition. Exiting..."
    exit 1
}
sync
partprobe
kpartx -u ${TARGET_BLOCK_DEV}
sync

echo "Adding LVM partition to ${TARGET_BLOCK_DEV}"
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

retVal=$?
echo "Return code of fdisk command: ($retVal)"
if [ $retVal -ne 0 ]; then
    echo "Error($retVal) during fdisk command. Exiting..."
    exit 1
fi
# echo "Sleeping for 2s"
# sleep 2
# sync
# echo "Sleeping for 10s"
# sleep 10
echo "Removing stale dev mapping for ${MAP_LOCATION}1"
dmsetup remove ${MAP_LOCATION}1
echo "Removing stale dev mapping for ${MAP_LOCATION}2"
dmsetup remove ${MAP_LOCATION}2

# If this disk has been used before on this machine there may be cached versions of the lvm volumes
# that will prevent the creation of new pv vg and lv commands. These can be removed in the
# /etc/lvm/backup and /etc/lvm/archive directories

##### Configure LVM volumes #####
# Create physical volume
pvcreate ${TARGET_BLOCK_DEV}2 || {
    echo "Error($?) on line#: $LINENO while creating physical volume. Exiting..."
    exit 1
}

# Create volume group
vgcreate ${LVM_VG_NAME} ${TARGET_BLOCK_DEV}2 || {
    echo "Error($?) on line#: $LINENO while creating volume group. Exiting..."
    exit 1
}

# Create logical volumes
lvcreate -L 16G -n swap ${LVM_VG_NAME} || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

lvcreate -L 20G -n home ${LVM_VG_NAME} || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

lvcreate -L 50G -n root ${LVM_VG_NAME} || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

lvcreate -l +99%FREE -n mcb ${LVM_VG_NAME} || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

mkswap /dev/${LVM_VG_NAME}/swap || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}
mkfs.xfs /dev/${LVM_VG_NAME}/home || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}
mkfs.xfs /dev/${LVM_VG_NAME}/root || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}
mkfs.xfs /dev/${LVM_VG_NAME}/mcb || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Creating mount points if they do not already exist:"
echo "Creating /mnt/home"
mkdir -p /mnt/home
echo "Creating /mnt/root"
mkdir -p /mnt/root
echo "Creating /mnt/mcb"
mkdir -p /mnt/mcb

echo "Mounting /dev/${LVM_VG_NAME}/home to /mnt/home"
mount /dev/${LVM_VG_NAME}/home /mnt/home/ || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Mounting /dev/${LVM_VG_NAME}/root to /mnt/root"
mount /dev/${LVM_VG_NAME}/root /mnt/root/ || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Mounting /dev/${LVM_VG_NAME}/mcb to /mnt/mcb"
mount /dev/${LVM_VG_NAME}/mcb /mnt/mcb || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Restoring xfsdump home_lvm.image to /mnt/home"
xfsrestore -p 5 -f home_lvm.image /mnt/home/ || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Restoring xfsdump root_lvm.image to /mnt/root"
xfsrestore -p 5 -f root_lvm.image /mnt/root/ || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Restoring xfsdump mcb_lvm.image to /mnt/mcb"
xfsrestore -p 5 -f mcb_lvm.image /mnt/mcb/ || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

NEW_UUID1=$(uuidgen)
echo "Updating eno2 ethernet interface UUID: ${NEW_UUID1}"
sed -i -e "s/e3930085-af04-4a52-9328-9e4565166dbb/${NEW_UUID1}/" /mnt/root/etc/sysconfig/network-scripts/ifcfg-eno1 || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

NEW_UUID2=$(uuidgen)
echo "Updating eno2 ethernet interface UUID: ${NEW_UUID2}"
sed -i -e "s/0f8926bd-cbd7-412d-8855-abe33e1f8177/${NEW_UUID2}/" /mnt/root/etc/sysconfig/network-scripts/ifcfg-eno2 || {
    echo "Error($?) on line#: $LINENO. Exiting..."
    exit 1
}

echo "Unmounting target disk mount points"
umount /mnt/home
umount /mnt/root
umount /mnt/mcb
