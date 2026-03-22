#!/bin/bash
set -e

# ==========================================
# 1. DİSK SEÇİMİ VE DEĞİŞKENLER
# ==========================================
echo "=> Mevcut diskler listeleniyor:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|rom"
echo "------------------------------------------"
read -p "Lütfen kurulum yapmak istediğiniz diski girin (Örn: nvme0n1 veya sda): " DISK_NAME
DISK="/dev/$DISK_NAME"
USER_NAME="kerem"
HOST_NAME="archlinux"

# ==========================================
# 2. ZAMAN AYARI VE DİSK BÖLÜMLEME
# ==========================================
echo "=> Zaman güncelleniyor..."
timedatectl set-ntp true

echo "=> Disk formatlanıyor ve bölümleniyor ($DISK)..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS_ROOT" "$DISK"

if [[ $DISK == *"nvme"* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# ==========================================
# 3. LUKS ŞİFRELEME VE BTRFS
# ==========================================
echo "=> LUKS şifreleme ayarlanıyor..."
cryptsetup -q -y -v luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot

echo "=> Btrfs dosya sistemi oluşturuluyor..."
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
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

# KRİTİK: Chroot içine aktarmak için UUID'yi ana sistemde alıyoruz
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# ==========================================
# 4. TEMEL SİSTEM VE PAKET KURULUMu
# ==========================================
echo "=> Paketler kuruluyor..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
    btrfs-progs nano nano-syntax-highlighting networkmanager git \
    xorg-server i3-wm i3status dmenu ly gnome-terminal polkit-gnome \
    nvidia-open nvidia-utils \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    bluez bluez-utils ufw zram-generator timeshift wget

genfstab -U /mnt >> /mnt/etc/fstab

# ==========================================
# 5. CHROOT AŞAMASI
# ==========================================
cat <<EOF > /mnt/chroot.sh
#!/bin/bash
set -e

# Saat ve Dil Ayarları
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "tr_TR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=trq" > /etc/vconsole.conf

# Nano Syntax Highlighting
echo 'include "/usr/share/nano/*.nanorc"' >> /etc/nanorc

# Hostname
echo "$HOST_NAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
HOSTS

# mkinitcpio (Hook sıralaması düzeltildi: keyboard ve keymap encrypt'ten önce!)
sed -i 's/MODULES=()/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/g' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot)
bootctl install

cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
LOADER

# Dışarıdan gelen REAL_LUKS_UUID buraya enjekte ediliyor
cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=$REAL_LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw nvidia_drm.modeset=1
ENTRY

# Kullanıcı ve Yetkiler
useradd -m -G wheel,video,audio,storage,optical -s /bin/bash $USER_NAME
echo "=> $USER_NAME kullanıcısı için şifre belirleyin:"
passwd $USER_NAME
echo "=> Root kullanıcısı için şifre belirleyin:"
passwd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Servisler
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable ufw
systemctl enable ly.service

# Zram Konfigürasyonu
echo -e "[zram0]\nzram-size = min(ram / 2, 4096)" > /etc/systemd/zram-generator.conf

# Yay kurulumu
su - $USER_NAME -c 'git clone https://aur.archlinux.org/yay.git ~/yay && cd ~/yay && makepkg -si --noconfirm && rm -rf ~/yay'
EOF

chmod +x /mnt/chroot.sh
arch-chroot /mnt /chroot.sh
rm /mnt/chroot.sh

echo "=========================================="
echo "KURULUM TAMAMLANDI!"
echo "Şimdi 'reboot' yazarak sistemi yeniden başlatabilirsin."
echo "Not: i3 config dosyana 'exec --no-startup-id /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' eklemeyi unutma."
echo "=========================================="
