#!/bin/bash
set -e

# ==========================================
# 1. BİLGİ TOPLAMA
# ==========================================
echo "=> Mevcut diskler listeleniyor:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|rom"
echo "------------------------------------------"

while true; do
    read -p "Kurulum yapılacak disk (Örn: nvme0n1): " DISK_NAME
    if [ -b "/dev/$DISK_NAME" ]; then
        DISK="/dev/$DISK_NAME"
        break
    else
        echo "Hata: /dev/$DISK_NAME geçerli bir disk değil."
    fi
done

while true; do
    read -p "Kullanıcı adı: " USER_NAME
    [[ -z "$USER_NAME" ]] && echo "Boş bırakılamaz!" || break
done

while true; do
    read -p "Host adı: " HOST_NAME
    [[ -z "$HOST_NAME" ]] && echo "Boş bırakılamaz!" || break
done

# ==========================================
# 2. DİSK VE BTRFS YAPILANDIRMASI
# ==========================================
timedatectl set-ntp true
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS_ROOT" "$DISK"

# Disk isimlendirme kontrolü (p1/p2 vs 1/2)
if [[ $DISK == *"nvme"* || $DISK == *"mmcblk"* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

echo "=> Disk şifreleniyor (LUKS)..."
cryptsetup -q -y -v luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot

echo "=> Btrfs subvolume'lar oluşturuluyor..."
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sub in @ @home @log @pkg @snapshots; do btrfs subvolume create /mnt/$sub; done
umount /mnt

MOUNT_OPTS="rw,noatime,compress=zstd,space_cache=v2,discard=async"
mount -o "$MOUNT_OPTS",subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
mount -o "$MOUNT_OPTS",subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o "$MOUNT_OPTS",subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o "$MOUNT_OPTS",subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "$MOUNT_OPTS",subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

mkfs.fat -F32 "$EFI_PART"
mount "$EFI_PART" /mnt/boot
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# ==========================================
# 3. PAKET KURULUMU
# ==========================================
echo "=> Paketler kuruluyor..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
    btrfs-progs nano nano-syntax-highlighting networkmanager git \
    xorg-server xorg-xauth xorg-xinit i3-wm i3status dmenu gnome-terminal \
    lxsession polkit \
    nvidia-open nvidia-utils pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
    bluez bluez-utils ufw zram-generator timeshift wget

genfstab -U /mnt >> /mnt/etc/fstab

# ==========================================
# 4. CHROOT İŞLEMLERİ
# ==========================================
cat <<EOF > /mnt/chroot.sh
#!/bin/bash
set -e

# Dil ve Klavye
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "tr_TR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=trq" > /etc/vconsole.conf

# X11 Klavye (TR)
mkdir -p /etc/X11/xorg.conf.d/
cat <<XKB > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "tr"
EndSection
XKB

echo "$HOST_NAME" > /etc/hostname

# mkinitcpio (microcode kaldırıldı, doğru yer bootloader)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot)
bootctl install
echo -e "default arch.conf\ntimeout 3\neditor no" > /boot/loader/loader.conf
cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=$REAL_LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw nvidia_drm.modeset=1
ENTRY

# ZRAM Yapılandırması (Otomatik)
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

# Kullanıcı İşlemleri
useradd -m -G wheel,video,audio,storage,optical -s /bin/bash $USER_NAME
echo "=> $USER_NAME kullanıcısı için şifre:"
passwd $USER_NAME
echo "=> Root kullanıcısı için şifre:"
passwd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Servisler
systemctl enable NetworkManager bluetooth ufw

# .xinitrc (LXPolkit ve Pipewire düzeltildi)
cat <<XINIT > /home/$USER_NAME/.xinitrc
export GKSU_TYPE=gksu
exec_always --no-startup-id setxkbmap tr
lxsession &
exec i3
XINIT

# .bash_profile
cat <<BASH_P > /home/$USER_NAME/.bash_profile
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z \$DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
    exec startx
fi
BASH_P

chown $USER_NAME:$USER_NAME /home/$USER_NAME/.xinitrc /home/$USER_NAME/.bash_profile
mkdir -p /home/$USER_NAME/.config/i3
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config

# Yay Kurulumu (AUR)
su - $USER_NAME -c 'git clone https://aur.archlinux.org/yay.git ~/yay && cd ~/yay && makepkg -si --noconfirm && rm -rf ~/yay'
EOF

chmod +x /mnt/chroot.sh
arch-chroot /mnt /chroot.sh
rm /mnt/chroot.sh

echo "=========================================="
echo "KURULUM TAMAMLANDI!"
echo "Sistemi 'reboot' yaparak başlatabilirsin."
echo "ZRAM aktif, LUKS şifreleme hazır, i3 kurulu."
echo "=========================================="
