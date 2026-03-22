#!/bin/bash
# =============================================================================
#  Arch Linux - Otomatik Kurulum Scripti
#  LUKS2 + Btrfs + i3wm + NVIDIA Optimus + Pipewire
# =============================================================================
set -euo pipefail

# --- Renkler ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n"; }

# =============================================================================
# 1. ÖN KONTROLLER
# =============================================================================
section "Ön Kontroller"

[[ $EUID -ne 0 ]] && error "Bu script root olarak çalıştırılmalıdır."
ping -c1 -W3 archlinux.org &>/dev/null || error "İnternet bağlantısı yok!"
info "Root ve internet erişimi doğrulandı."

# =============================================================================
# 2. BİLGİ TOPLAMA
# =============================================================================
section "Disk ve Kullanıcı Bilgileri"

echo -e "${BOLD}Mevcut diskler:${NC}"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|rom"
echo ""

while true; do
    read -rp "Kurulum yapılacak disk (Örn: nvme0n1 veya sda): " DISK_NAME
    [[ -b "/dev/$DISK_NAME" ]] && break
    warn "/dev/$DISK_NAME geçerli bir blok aygıtı değil, tekrar deneyin."
done
DISK="/dev/$DISK_NAME"

while true; do
    read -rp "Kullanıcı adı: " USER_NAME
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    warn "Geçersiz kullanıcı adı. Küçük harf, rakam, _ veya - kullanın."
done

while true; do
    read -rp "Host adı: " HOST_NAME
    [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && break
    warn "Geçersiz host adı. Harf, rakam ve - kullanın."
done

# GPU seçimi
echo ""
echo -e "${BOLD}GPU yapılandırması:${NC}"
echo "  1) Intel iGPU only (entegre)"
echo "  2) NVIDIA only (masaüstü)"
echo "  3) Intel + NVIDIA Optimus (laptop - önerilen)"
while true; do
    read -rp "Seçim [1-3]: " GPU_CHOICE
    [[ "$GPU_CHOICE" =~ ^[123]$ ]] && break
done

# Swap büyüklüğü
read -rp "ZRAM boyutu (MB, önerilen: 4096): " ZRAM_SIZE
ZRAM_SIZE=${ZRAM_SIZE:-4096}

echo ""
warn "DİKKAT: ${DISK} üzerindeki TÜM VERİ SİLİNECEK!"
read -rp "Devam etmek için 'EVET' yazın: " CONFIRM
[[ "$CONFIRM" == "EVET" ]] || error "Kurulum iptal edildi."

# =============================================================================
# 3. DİSK YAPILAN DİRMASI
# =============================================================================
section "Disk Bölümlendirme"

timedatectl set-ntp true
info "NTP senkronizasyonu başlatıldı."

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:"EFI"       "$DISK"
sgdisk -n 2:0:0      -t 2:8309 -c 2:"LUKS_ROOT" "$DISK"
partprobe "$DISK"
sleep 1

# nvme/mmcblk → p1/p2, diğerleri → 1/2
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

info "Bölümler oluşturuldu: EFI=${EFI_PART}, ROOT=${ROOT_PART}"

# =============================================================================
# 4. LUKS2 ŞİFRELEME
# =============================================================================
section "LUKS2 Şifreleme"

cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot
info "LUKS2 konteyneri açıldı."

REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# =============================================================================
# 5. BTRFS YAPILAN DİRMASI
# =============================================================================
section "Btrfs Subvolume Yapılandırması"

mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

SUBVOLS=(@ @home @log @pkg @snapshots @tmp)
for sub in "${SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/$sub"
    info "Subvolume oluşturuldu: $sub"
done
umount /mnt

MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2,discard=async"

mount -o "${MOUNT_OPTS},subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}

mount -o "${MOUNT_OPTS},subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev" /dev/mapper/cryptroot /mnt/tmp

mkfs.fat -F32 -n "EFI" "$EFI_PART"
mount "$EFI_PART" /mnt/boot
info "Tüm dosya sistemleri mount edildi."

# =============================================================================
# 6. PAKET KURULUMU
# =============================================================================
section "Temel Paketlerin Kurulumu"

# GPU paketlerini belirle
GPU_PKGS=""
case "$GPU_CHOICE" in
    1) GPU_PKGS="mesa intel-media-driver vulkan-intel" ;;
    2) GPU_PKGS="nvidia-open nvidia-utils nvidia-settings" ;;
    3) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia-open nvidia-utils nvidia-prime nvidia-settings" ;;
esac

pacstrap /mnt \
    base base-devel linux linux-headers linux-firmware intel-ucode \
    btrfs-progs nano nano-syntax-highlighting \
    networkmanager network-manager-applet \
    git wget curl \
    xorg-server xorg-xauth xorg-xinit xorg-xrandr xorg-xinput \
    i3-wm i3status i3lock dmenu \
    alacritty \
    lxsession polkit \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    bluez bluez-utils \
    ufw \
    zram-generator \
    snapper snap-pac \
    feh picom dunst \
    ttf-dejavu ttf-liberation noto-fonts \
    man-db man-pages \
    $GPU_PKGS

info "Paketler kuruldu."
genfstab -U /mnt >> /mnt/etc/fstab
info "fstab oluşturuldu."

# =============================================================================
# 7. CHROOT HAZIRLIĞI
# =============================================================================
section "Chroot Ortamı Hazırlanıyor"

# Değişkenleri chroot script'e güvenli şekilde aktar
cat > /mnt/chroot_vars.sh <<VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
REAL_LUKS_UUID="${REAL_LUKS_UUID}"
ZRAM_SIZE="${ZRAM_SIZE}"
GPU_CHOICE="${GPU_CHOICE}"
VARS

# chroot.sh — tüm iç heredoc'lar 'TIRMAKLI' delimiter ile yazılıyor
#              böylece dış değişkenler bu bloklarda expand edilmez.
cat > /mnt/chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n"; }

# ── Saat Dilimi & Locale ─────────────────────────────────────────────────────
section "Yerelleştirme"

ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#tr_TR.UTF-8/tr_TR.UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=trq"        > /etc/vconsole.conf

# X11 Türkçe klavye
mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'XKB'
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "tr"
        Option "XkbOptions" "caps:escape"
EndSection
XKB
info "Yerelleştirme tamamlandı."

# ── Hostname & Hosts ─────────────────────────────────────────────────────────
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS
info "Hostname: $HOST_NAME"

# ── mkinitcpio ───────────────────────────────────────────────────────────────
section "initramfs Yapılandırması"

# NVIDIA için gerekli modüller (GPU_CHOICE=2 veya 3)
if [[ "$GPU_CHOICE" == "2" || "$GPU_CHOICE" == "3" ]]; then
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
fi

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
info "initramfs oluşturuldu."

# ── systemd-boot ─────────────────────────────────────────────────────────────
section "Bootloader"

bootctl install

cat > /boot/loader/loader.conf <<'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

# nvidia_drm.modeset sadece NVIDIA varsa
NV_OPT=""
[[ "$GPU_CHOICE" == "2" || "$GPU_CHOICE" == "3" ]] && NV_OPT=" nvidia_drm.modeset=1"

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot:allow-discards root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3${NV_OPT}
ENTRY

# Fallback entry
cat > /boot/loader/entries/arch-fallback.conf <<ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY_FB

info "systemd-boot yapılandırıldı."

# ── ZRAM ─────────────────────────────────────────────────────────────────────
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram / 2, ${ZRAM_SIZE})
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
info "ZRAM yapılandırıldı."

# ── UFW Güvenlik Duvarı ──────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw enable
info "UFW güvenlik duvarı etkinleştirildi."

# ── Snapper (Btrfs Snapshot) ─────────────────────────────────────────────────
section "Snapper Yapılandırması"
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
snapper -c root create-config /
# Snapper kendi .snapshots dizinini oluşturur, btrfs subvol ile çakışmamak için:
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a  # fstab'dan @snapshots tekrar mount edilir
chmod 750 /.snapshots
info "Snapper yapılandırıldı."

# ── Kullanıcı ────────────────────────────────────────────────────────────────
section "Kullanıcı Oluşturuluyor: $USER_NAME"

useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
echo "=> $USER_NAME için şifre:"
passwd "$USER_NAME"
echo "=> root için şifre:"
passwd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
info "Kullanıcı $USER_NAME oluşturuldu."

# ── .xinitrc ─────────────────────────────────────────────────────────────────
cat > "/home/${USER_NAME}/.xinitrc" <<'XINIT'
#!/bin/sh

# Pipewire başlat
pipewire &
pipewire-pulse &
wireplumber &

# Türkçe klavye
setxkbmap tr &

# Compositor (şeffaflık/gölge)
picom --daemon

# Polkit
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &

# Arka plan (varsa ~/Pictures/wallpaper.jpg)
[ -f "$HOME/Pictures/wallpaper.jpg" ] && feh --bg-scale "$HOME/Pictures/wallpaper.jpg" &

exec i3
XINIT

# ── .bash_profile (TTY1'de otomatik startx) ──────────────────────────────────
cat > "/home/${USER_NAME}/.bash_profile" <<'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P

# ── Temel i3 config ──────────────────────────────────────────────────────────
mkdir -p "/home/${USER_NAME}/.config/i3"
cat > "/home/${USER_NAME}/.config/i3/config" <<'I3CONF'
# i3 config — temel başlangıç yapılandırması
set $mod Mod4

font pango:DejaVu Sans Mono 10

# Floating modifier
floating_modifier $mod

# Terminal
bindsym $mod+Return exec alacritty

# Uygulama başlatıcı
bindsym $mod+d exec dmenu_run

# Pencere kapat
bindsym $mod+Shift+q kill

# Focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Workspaces
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5

bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3

# Layout
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen toggle

# Reload / Restart / Exit
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning -m 'Çıkmak istiyor musun?' -B 'Evet' 'i3-msg exit'

# Ses (PipeWire/PulseAudio)
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute @DEFAULT_SINK@ toggle

# Ekran parlaklığı (brightnessctl gerekir)
# bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
# bindsym XF86MonBrightnessDown exec brightnessctl set 10%-

# Ekran kilidi
bindsym $mod+ctrl+l exec i3lock -c 000000

bar {
    status_command i3status
    position bottom
}
I3CONF

chown -R "${USER_NAME}:${USER_NAME}" \
    "/home/${USER_NAME}/.xinitrc" \
    "/home/${USER_NAME}/.bash_profile" \
    "/home/${USER_NAME}/.config"

# ── Servisler ────────────────────────────────────────────────────────────────
section "Sistem Servisleri"
systemctl enable NetworkManager bluetooth snapper-timeline.timer snapper-cleanup.timer
info "Servisler etkinleştirildi."

# ── Yay (AUR Helper) ─────────────────────────────────────────────────────────
section "Yay (AUR) Kurulumu"
su - "$USER_NAME" -c '
    git clone https://aur.archlinux.org/yay.git ~/yay
    cd ~/yay
    makepkg -si --noconfirm
    rm -rf ~/yay
    yay --version
'
info "Yay kuruldu."

# ── Özet ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[0;32m╔══════════════════════════════════════════╗"
echo -e "║     Chroot kurulumu tamamlandı! ✓       ║"
echo -e "╚══════════════════════════════════════════╝\033[0m"
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# 8. CHROOT ÇALIŞTIR
# =============================================================================
section "Chroot Başlatılıyor"
arch-chroot /mnt /chroot.sh

# Temizlik
rm -f /mnt/chroot.sh /mnt/chroot_vars.sh

# =============================================================================
# 9. BİTİŞ
# =============================================================================
section "Kurulum Tamamlandı"

echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║          ARCH LINUX KURULUMU TAMAMLANDI ✓            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  • LUKS2 (Argon2id) şifreleme aktif                 ║"
echo "║  • Btrfs subvolume yapısı kuruldu                    ║"
echo "║  • Snapper otomatik snapshot etkin                   ║"
echo "║  • ZRAM swap yapılandırıldı                          ║"
echo "║  • Pipewire ses sistemi kuruldu                      ║"
echo "║  • i3wm + temel config hazır                         ║"
echo "║  • UFW güvenlik duvarı aktif                         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  'umount -R /mnt && reboot' ile yeniden başlatın     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
