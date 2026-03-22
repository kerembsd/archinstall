#!/bin/bash
# =============================================================================
#   █████╗ ██████╗  ██████╗██╗  ██╗    ████████╗██╗   ██╗██╗
#  ██╔══██╗██╔══██╗██╔════╝██║  ██║    ╚══██╔══╝██║   ██║██║
#  ███████║██████╔╝██║     ███████║       ██║   ██║   ██║██║
#  ██╔══██║██╔══██╗██║     ██╔══██║       ██║   ██║   ██║██║
#  ██║  ██║██║  ██║╚██████╗██║  ██║       ██║   ╚██████╔╝██║
#  ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝ ╚═╝
#
#  TUI Installer v2.0 — LUKS2 + Btrfs + i3wm + Pipewire
#  whiptail tabanlı, TR/EN dil desteği
# =============================================================================
set -euo pipefail

# =============================================================================
# SABITLER
# =============================================================================
readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly SCRIPT_VERSION="2.0"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== ArchInstall v${SCRIPT_VERSION} — $(date) ===" >> "$LOG_FILE"

# =============================================================================
# RENK & YARDIMCI FONKSİYONLAR
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[✗]${NC} $*"   | tee -a "$LOG_FILE"; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }

# Dil desteği
LANG_CHOICE="tr"
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

# whiptail kısayolları
WT_TITLE="ArchInstall v${SCRIPT_VERSION}"
wt_msg()  { whiptail --title "$WT_TITLE" --msgbox  "$1" "${2:-12}" "${3:-65}"; }
wt_info() { whiptail --title "$WT_TITLE" --infobox "$1" "${2:-6}"  "${3:-55}"; sleep "${4:-1}"; }

# Hata yakalayıcı — retry / iptal
on_error() {
    local code=$? line=$1
    err "Satır ${line} — hata kodu: ${code}"
    err "Log: $LOG_FILE"
    if whiptail --title "$(T "⚠ HATA" "⚠ ERROR")" \
        --yesno "$(T \
            "Satır ${line}'de hata oluştu (kod: ${code}).\n\nLog: $LOG_FILE\n\nYine de devam etmek istiyor musun?" \
            "Error at line ${line} (code: ${code}).\n\nLog: $LOG_FILE\n\nDo you want to continue anyway?")" \
        12 65; then
        warn "$(T "Kullanıcı devam etmeyi seçti." "User chose to continue.")"
    else
        wt_msg "$(T "Kurulum iptal edildi.\n\nLog: $LOG_FILE" \
                    "Installation cancelled.\n\nLog: $LOG_FILE")" 10 55
        exit 1
    fi
}
trap 'on_error $LINENO' ERR

# =============================================================================
# 0. DİL SEÇİMİ
# =============================================================================
LANG_CHOICE=$(whiptail --title "ArchInstall — Language / Dil" \
    --menu "Lütfen dil seçin / Please select language:" 12 50 2 \
    "tr" "Turkce" \
    "en" "English" \
    3>&1 1>&2 2>&3) || exit 0

# =============================================================================
# 1. SPLASH EKRANI
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << 'SPLASH'

         .88888888:.
        88888888.88888.
      .8888888888888888.
      888888888888888888
      88' _`88'_  `88888
      88 88 88 88  88888
      88_88_::_88_:88888
      88:::,::,:::::8888
      88`::::::::::'8888
     .88  `::::'    8:88.
    8888            `8:888.
  .8888'             `888888.
 .8888:..  .::.  ...:'8888888:.
.8888.'     :'     `'::`88:88888
.8888        '         `.888:8888.
888:8         .           888:88888
.888:80        .           888:88888

SPLASH
echo -e "${NC}"
echo -e "${BOLD}${CYAN}       ArchInstall TUI v2.0${NC}"
echo -e "  LUKS2  Btrfs  i3wm  Pipewire"
sleep 1

whiptail --title "$WT_TITLE" --msgbox "$(T \
"Arch Linux Kurulum Sihirbazina Hos Geldin!

Bu script otomatik olarak sunu kurar:
  * LUKS2 (Argon2id) tam disk sifreleme
  * Btrfs subvolume + Snapper snapshot
  * i3wm + gaps masaustu ortami
  * Pipewire ses sistemi
  * ZRAM swap
  * UFW guvenlik duvari
  * Yay (AUR helper)

Log dosyasi: $LOG_FILE

Devam etmek icin OK tusuna basin." \
"Welcome to the Arch Linux Installation Wizard!

This script will automatically install:
  * LUKS2 (Argon2id) full disk encryption
  * Btrfs subvolumes + Snapper snapshots
  * i3wm + gaps desktop environment
  * Pipewire audio system
  * ZRAM swap
  * UFW firewall
  * Yay (AUR helper)

Log file: $LOG_FILE

Press OK to continue.")" 24 62

# =============================================================================
# 2. ON KONTROLLER
# =============================================================================
section "$(T "On Kontroller" "Pre-checks")"

[[ $EUID -ne 0 ]] && {
    wt_msg "$(T "Bu script ROOT olarak calistirilmalidir!" \
                "This script must be run as ROOT!")" 8 52
    exit 1
}

wt_info "$(T "Internet baglantisi kontrol ediliyor..." \
             "Checking internet connection...")"

ping -c1 -W3 archlinux.org &>/dev/null || {
    wt_msg "$(T "Internet baglantisi yok!\nLutfen baglantinizi kontrol edin." \
               "No internet connection!\nPlease check your connection.")" 9 55
    exit 1
}
log "$(T "Internet: OK" "Internet: OK")"

# CPU tespiti
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    CPU_UCODE="amd-ucode"
else
    CPU_UCODE="intel-ucode"
fi
log "CPU: $CPU_VENDOR -> $CPU_UCODE"

# =============================================================================
# 3. DiSK SECiMi
# =============================================================================
section "$(T "Disk Secimi" "Disk Selection")"

DISK_LIST=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    model=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf $i" "; print ""}' | xargs)
    [[ -z "$name" ]] && continue
    [[ -z "$model" ]] && model="$(T "Bilinmiyor" "Unknown")"
    DISK_LIST+=("$name" "${size} - ${model}")
done < <(lsblk -dno NAME,SIZE,MODEL 2>/dev/null | grep -v "loop\|rom\|sr" || true)

if [[ ${#DISK_LIST[@]} -eq 0 ]]; then
    wt_msg "$(T "Kurulabilir disk bulunamadi!\nlsblk ciktisini kontrol edin." \
               "No installable disk found!\nCheck lsblk output.")" 9 55
    exit 1
fi

DISK_NAME=$(whiptail --title "$(T "Disk Secimi" "Disk Selection")" \
    --menu "$(T \
        "Kurulum yapilacak diski secin:\n!! SECILEN DISKTEKI TUM VERi SiLiNECEK !!" \
        "Select the installation disk:\n!! ALL DATA ON SELECTED DISK WILL BE ERASED !!")" \
    18 72 8 "${DISK_LIST[@]}" \
    3>&1 1>&2 2>&3) || exit 0

DISK="/dev/$DISK_NAME"
log "$(T "Secilen disk: $DISK" "Selected disk: $DISK")"

# =============================================================================
# 4. KULLANICI BiLGiLERi
# =============================================================================
section "$(T "Kullanici Bilgileri" "User Information")"

while true; do
    USER_NAME=$(whiptail --title "$(T "Kullanici Adi" "Username")" \
        --inputbox "$(T \
            "Kullanici adinizi girin:\n(kucuk harf, rakam, _ veya - kullanin)" \
            "Enter your username:\n(use lowercase, numbers, _ or -)")" \
        10 55 3>&1 1>&2 2>&3) || exit 0
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    wt_msg "$(T "Gecersiz kullanici adi!\nKucuk harf, rakam, _ veya - kullanin." \
               "Invalid username!\nUse lowercase, numbers, _ or -.")" 9 55
done
log "$(T "Kullanici: $USER_NAME" "User: $USER_NAME")"

while true; do
    HOST_NAME=$(whiptail --title "$(T "Bilgisayar Adi" "Hostname")" \
        --inputbox "$(T \
            "Bilgisayar adini (hostname) girin:" \
            "Enter the computer hostname:")" \
        9 55 3>&1 1>&2 2>&3) || exit 0
    [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && break
    wt_msg "$(T "Gecersiz hostname!\nHarf, rakam ve - kullanin." \
               "Invalid hostname!\nUse letters, numbers and -.")" 9 50
done
log "Hostname: $HOST_NAME"

# =============================================================================
# 5. LUKS SiFRESi + GUC KONTROLU
# =============================================================================
section "$(T "Disk Sifreleme" "Disk Encryption")"

check_pass_strength() {
    local pass="$1"
    local score=0
    local warnings=""

    [[ ${#pass} -ge 12 ]] && ((score++)) || true
    [[ ${#pass} -ge 16 ]] && ((score++)) || true
    [[ "$pass" =~ [A-Z] ]] && ((score++)) || true
    [[ "$pass" =~ [0-9] ]] && ((score++)) || true
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && ((score++)) || true

    [[ ${#pass} -lt 12 ]] && warnings+="$(T "- Kisa sifre (12+ onerilen)\n" "- Short password (12+ recommended)\n")"
    [[ ! "$pass" =~ [A-Z] ]] && warnings+="$(T "- Buyuk harf yok\n" "- No uppercase letter\n")"
    [[ ! "$pass" =~ [0-9] ]] && warnings+="$(T "- Rakam yok\n" "- No digit\n")"
    [[ ! "$pass" =~ [^a-zA-Z0-9] ]] && warnings+="$(T "- Ozel karakter yok\n" "- No special character\n")"

    echo "${score}|${warnings}"
}

while true; do
    LUKS_PASS=$(whiptail --title "$(T "LUKS Sifresi" "LUKS Passphrase")" \
        --passwordbox "$(T \
            "Disk sifreleme parolasini girin:\n(Bu parola olmadan sisteme giremezsiniz!)" \
            "Enter disk encryption passphrase:\n(You cannot access the system without this!)")" \
        10 65 3>&1 1>&2 2>&3) || exit 0

    LUKS_PASS2=$(whiptail --title "$(T "LUKS Sifresi - Dogrula" "LUKS Passphrase - Confirm")" \
        --passwordbox "$(T "Parolayi tekrar girin:" "Re-enter passphrase:")" \
        9 55 3>&1 1>&2 2>&3) || exit 0

    if [[ "$LUKS_PASS" != "$LUKS_PASS2" ]]; then
        wt_msg "$(T "Parolalar eslesmiyor! Tekrar deneyin." \
                   "Passphrases do not match! Try again.")" 8 50
        continue
    fi

    if [[ ${#LUKS_PASS} -lt 8 ]]; then
        wt_msg "$(T "Parola cok kisa! En az 8 karakter gerekli." \
                   "Passphrase too short! Minimum 8 characters.")" 8 55
        continue
    fi

    result=$(check_pass_strength "$LUKS_PASS")
    score=$(cut -d'|' -f1 <<< "$result")
    warns=$(cut -d'|' -f2- <<< "$result")

    if [[ $score -ge 4 ]]; then
        strength="$(T "Guclu" "Strong")"
    elif [[ $score -ge 2 ]]; then
        strength="$(T "Orta" "Moderate")"
    else
        strength="$(T "Zayif" "Weak")"
    fi

    if [[ -n "$warns" ]]; then
        if ! whiptail --title "$(T "Sifre Gucu: $strength" "Passphrase Strength: $strength")" \
            --yesno "$(T \
                "Uyarilar:\n${warns}\nYine de devam etmek istiyor musun?" \
                "Warnings:\n${warns}\nDo you want to continue anyway?")" \
            14 60; then
            continue
        fi
    else
        wt_info "$(T "Sifre gucu: $strength" "Passphrase strength: $strength")" 6 45 1
    fi
    break
done
log "$(T "LUKS sifresi ayarlandi." "LUKS passphrase configured.")"

# =============================================================================
# 6. GPU / TIMEZONE / LOCALE / ZRAM
# =============================================================================
section "$(T "Sistem Ayarlari" "System Settings")"

GPU_CHOICE=$(whiptail --title "$(T "GPU Surucusu" "GPU Driver")" \
    --menu "$(T "GPU yapilandirmasini secin:" "Select GPU configuration:")" \
    20 72 7 \
    "1" "$(T "Intel iGPU (entegre grafik)"          "Intel iGPU (integrated graphics)")" \
    "2" "$(T "AMD GPU (radeon/amdgpu)"               "AMD GPU (radeon/amdgpu)")" \
    "3" "$(T "NVIDIA - Proprietary (Maxwell+)"       "NVIDIA - Proprietary (Maxwell+)")" \
    "4" "$(T "NVIDIA - Open (Turing+/RTX serisi)"    "NVIDIA - Open (Turing+/RTX only)")" \
    "5" "$(T "Intel + NVIDIA Optimus - Proprietary"  "Intel + NVIDIA Optimus - Proprietary")" \
    "6" "$(T "Intel + NVIDIA Optimus - Open (RTX)"   "Intel + NVIDIA Optimus - Open (RTX)")" \
    "7" "$(T "Sanal Makine (VirtualBox/VMware/QEMU)" "Virtual Machine (VirtualBox/VMware/QEMU)")" \
    3>&1 1>&2 2>&3) || exit 0
log "$(T "GPU: $GPU_CHOICE" "GPU: $GPU_CHOICE")"

# Timezone: bölge
TZ_REGION=$(whiptail --title "$(T "Zaman Dilimi - Bolge" "Timezone - Region")" \
    --menu "$(T "Bolge secin:" "Select region:")" 18 55 8 \
    "Europe"   "Europe / Avrupa" \
    "America"  "America / Amerika" \
    "Asia"     "Asia / Asya" \
    "Africa"   "Africa / Afrika" \
    "Pacific"  "Pacific / Pasifik" \
    "Atlantic" "Atlantic / Atlantik" \
    "Indian"   "Indian Ocean / Hint Okyanusu" \
    "Arctic"   "Arctic / Arktik" \
    3>&1 1>&2 2>&3) || exit 0

# Timezone: şehir
TZ_CITIES=()
while IFS= read -r city; do
    TZ_CITIES+=("$city" "")
done < <(timedatectl list-timezones 2>/dev/null | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

TIMEZONE_CITY=$(whiptail --title "$(T "Zaman Dilimi - Sehir" "Timezone - City")" \
    --menu "$(T "Sehir secin:" "Select city:")" 22 55 14 \
    "${TZ_CITIES[@]}" \
    3>&1 1>&2 2>&3) || exit 0

TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
LOCALE=$(whiptail --title "$(T "Sistem Dili / Locale" "System Language / Locale")" \
    --menu "$(T "Sistem dilini secin:" "Select system language:")" 14 55 4 \
    "en_US" "English (US)" \
    "tr_TR" "Turkce" \
    "de_DE" "Deutsch" \
    "fr_FR" "Francais" \
    3>&1 1>&2 2>&3) || exit 0
log "Locale: ${LOCALE}.UTF-8"

# ZRAM
ZRAM_SIZE=$(whiptail --title "$(T "ZRAM Boyutu" "ZRAM Size")" \
    --menu "$(T "ZRAM swap boyutunu secin:" "Select ZRAM swap size:")" 14 55 4 \
    "2048" "2 GB" \
    "4096" "$(T "4 GB (onerilen)" "4 GB (recommended)")" \
    "6144" "6 GB" \
    "8192" "8 GB" \
    3>&1 1>&2 2>&3) || exit 0
log "ZRAM: ${ZRAM_SIZE}MB"

# =============================================================================
# 7. EK PAKETLER
# =============================================================================
section "$(T "Ek Paketler" "Extra Packages")"

EXTRA_PKGS_RAW=$(whiptail --title "$(T "Ek Paketler" "Extra Packages")" \
    --checklist "$(T \
        "Kurmak istedigin ek paketleri sec (SPACE ile sec/kaldir):" \
        "Select extra packages to install (SPACE to toggle):")" \
    22 68 11 \
    "firefox"          "$(T "Firefox tarayici"           "Firefox browser")"          OFF \
    "thunar"           "$(T "Thunar dosya yoneticisi"    "Thunar file manager")"       OFF \
    "neovim"           "$(T "Neovim metin editoru"       "Neovim text editor")"        OFF \
    "htop"             "$(T "Htop sistem monitoru"       "Htop system monitor")"       ON  \
    "brightnessctl"    "$(T "Ekran parlaklik kontrolu"   "Screen brightness control")" OFF \
    "unzip"            "$(T "ZIP arsiv destegi"          "ZIP archive support")"       ON  \
    "ttf-font-awesome" "$(T "Font Awesome ikonlar"       "Font Awesome icons")"        OFF \
    "bat"              "$(T "Renkli cat alternatifi"     "Colorized cat alternative")" OFF \
    "ranger"           "$(T "Terminal dosya yoneticisi"  "Terminal file manager")"     OFF \
    "grim"             "$(T "Ekran goruntusu araci"      "Screenshot tool")"           OFF \
    "fzf"              "$(T "Fuzzy finder arac"          "Fuzzy finder tool")"         OFF \
    3>&1 1>&2 2>&3) || exit 0

EXTRA_PKGS=$(echo "$EXTRA_PKGS_RAW" | tr -d '"')
log "$(T "Ek paketler: ${EXTRA_PKGS:-yok}" "Extra packages: ${EXTRA_PKGS:-none}")"

# =============================================================================
# 8. KURULUM OZETI & SON ONAY
# =============================================================================
GPU_LABELS=([1]="Intel iGPU" [2]="AMD GPU" [3]="NVIDIA Proprietary"
            [4]="NVIDIA Open" [5]="Optimus Proprietary"
            [6]="Optimus Open" [7]="Sanal Makine / VM")

whiptail --title "$(T "!! KURULUM OZETI - SON ONAY !!" "!! INSTALLATION SUMMARY - FINAL CONFIRM !!")" \
    --yesno "$(T \
"Asagidaki ayarlarla kurulum BASLAYACAK:

  Disk       : $DISK
  !! TUM VERi SiLiNECEK !!

  Kullanici  : $USER_NAME
  Hostname   : $HOST_NAME
  GPU        : ${GPU_LABELS[$GPU_CHOICE]}
  Timezone   : $TIMEZONE
  Locale     : ${LOCALE}.UTF-8
  ZRAM       : ${ZRAM_SIZE}MB
  CPU Ucode  : $CPU_UCODE
  Ek Paketler: ${EXTRA_PKGS:-yok}

Onayliyor musun?" \
"Installation will START with these settings:

  Disk       : $DISK
  !! ALL DATA WILL BE ERASED !!

  User       : $USER_NAME
  Hostname   : $HOST_NAME
  GPU        : ${GPU_LABELS[$GPU_CHOICE]}
  Timezone   : $TIMEZONE
  Locale     : ${LOCALE}.UTF-8
  ZRAM       : ${ZRAM_SIZE}MB
  CPU Ucode  : $CPU_UCODE
  Extra Pkgs : ${EXTRA_PKGS:-none}

Do you confirm?")" \
    26 68 || exit 0

# =============================================================================
# 9. GPU PAKET LiSTESi
# =============================================================================
case "$GPU_CHOICE" in
    1) GPU_PKGS="mesa intel-media-driver vulkan-intel" ;;
    2) GPU_PKGS="mesa libva-mesa-driver vulkan-radeon xf86-video-amdgpu" ;;
    3) GPU_PKGS="nvidia nvidia-utils nvidia-settings" ;;
    4) GPU_PKGS="nvidia-open nvidia-utils nvidia-settings" ;;
    5) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia nvidia-utils nvidia-prime nvidia-settings" ;;
    6) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia-open nvidia-utils nvidia-prime nvidia-settings" ;;
    7) GPU_PKGS="mesa virtualbox-guest-utils" ;;
esac

# Disk partition isimlendirme
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1";  ROOT_PART="${DISK}2"
fi

# =============================================================================
# 10. KURULUM — GAUGE
# =============================================================================
(
echo "XXX"; echo "2"
echo "$(T "[1/10] NTP senkronizasyonu..." "[1/10] NTP sync...")"; echo "XXX"
timedatectl set-ntp true >> "$LOG_FILE" 2>&1

echo "XXX"; echo "8"
echo "$(T "[2/10] Disk bolumlendiriliiyor: $DISK" "[2/10] Partitioning: $DISK")"; echo "XXX"
sgdisk --zap-all "$DISK"                           >> "$LOG_FILE" 2>&1
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI"   "$DISK"  >> "$LOG_FILE" 2>&1
sgdisk -n 2:0:0   -t 2:8309 -c 2:"LUKS"  "$DISK"  >> "$LOG_FILE" 2>&1
partprobe "$DISK"                                   >> "$LOG_FILE" 2>&1
sleep 1

echo "XXX"; echo "15"
echo "$(T "[3/10] LUKS2 sifreleniyor..." "[3/10] LUKS2 encryption...")"; echo "XXX"
echo -n "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha512 --pbkdf argon2id \
    --batch-mode --key-file=- \
    "$ROOT_PART" >> "$LOG_FILE" 2>&1
echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "LUKS UUID: $REAL_LUKS_UUID"

echo "XXX"; echo "24"
echo "$(T "[4/10] Btrfs yapılandırılıyor..." "[4/10] Configuring Btrfs...")"; echo "XXX"
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot >> "$LOG_FILE" 2>&1
mount /dev/mapper/cryptroot /mnt
for sub in @ @home @log @pkg @snapshots @tmp; do
    btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1
done
umount /mnt
mount -o "${MOUNT_OPTS},subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
mount -o "${MOUNT_OPTS},subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev" /dev/mapper/cryptroot /mnt/tmp
mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1
mount "$EFI_PART" /mnt/boot

echo "XXX"; echo "33"
echo "$(T "[5/10] Mirror listesi optimize ediliyor..." "[5/10] Optimizing mirror list...")"; echo "XXX"
pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1
pacman -S  --noconfirm reflector         >> "$LOG_FILE" 2>&1
reflector --country Turkey,Germany,Netherlands,France \
    --protocol https --age 12 --sort rate --fastest 10 \
    --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1

echo "XXX"; echo "42"
echo "$(T "[6/10] Temel paketler kuruluyor (bu uzun surebilir)..." "[6/10] Installing base packages (may take a while)...")"; echo "XXX"
pacstrap /mnt \
    base base-devel linux linux-headers linux-firmware "$CPU_UCODE" \
    btrfs-progs nano nano-syntax-highlighting terminus-font \
    networkmanager network-manager-applet \
    git wget curl \
    xorg-server xorg-xauth xorg-xinit xorg-xrandr xorg-xinput \
    i3-wm i3status i3lock dmenu \
    alacritty \
    lxsession polkit polkit-gnome \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    bluez bluez-utils blueman \
    ufw \
    zram-generator \
    snapper snap-pac \
    feh picom dunst \
    ttf-dejavu ttf-liberation noto-fonts \
    man-db man-pages \
    $GPU_PKGS \
    $EXTRA_PKGS >> "$LOG_FILE" 2>&1

echo "XXX"; echo "60"
echo "$(T "[7/10] fstab olusturuluyor..." "[7/10] Generating fstab...")"; echo "XXX"
genfstab -U /mnt >> /mnt/etc/fstab
# Duplicate temizle
grep -v "^[[:space:]]*$" /mnt/etc/fstab | grep -v "^#" | \
    awk '{print $2}' | sort | uniq -d | while read -r dup; do
    awk -v mp="$dup" '$2==mp && seen{next} $2==mp{seen=1} {print}' \
        /mnt/etc/fstab > /tmp/fstab.clean && mv /tmp/fstab.clean /mnt/etc/fstab
done
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

echo "XXX"; echo "65"
echo "$(T "[8/10] Degiskenler aktariliyor..." "[8/10] Passing variables...")"; echo "XXX"
cat > /mnt/chroot_vars.sh << VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
REAL_LUKS_UUID="${REAL_LUKS_UUID}"
ZRAM_SIZE="${ZRAM_SIZE}"
GPU_CHOICE="${GPU_CHOICE}"
CPU_UCODE="${CPU_UCODE}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
VARS

echo "XXX"; echo "70"
echo "$(T "[9/10] Chroot scripti yaziliyor..." "[9/10] Writing chroot script...")"; echo "XXX"

cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[v]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}== $* ==${NC}\n"; }

section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/#${LOCALE}.UTF-8/${LOCALE}.UTF-8/" /etc/locale.gen
sed -i 's/#en_US.UTF-8/en_US.UTF-8/'         /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf
printf "KEYMAP=trq\nCONSOLEFONT=ter-v16n\n" > /etc/vconsole.conf

mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'XKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "tr"
    Option "XkbOptions" "caps:escape"
EndSection
XKB
log "Locale: ${LOCALE} | Timezone: ${TIMEZONE}"

section "Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS
log "Hostname: $HOST_NAME"

section "mkinitcpio"
if [[ "$GPU_CHOICE" =~ ^[3456]$ ]]; then
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P
log "initramfs olusturuldu."

section "systemd-boot"
bootctl install
cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

NV_OPT=""
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && NV_OPT=" nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"
UCODE_IMG="/${CPU_UCODE}.img"

cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3${NV_OPT}
ENTRY

cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY_FB

systemctl enable fstrim.timer
log "Bootloader kuruldu."

section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = min(ram / 2, ${ZRAM_SIZE})
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
log "ZRAM: ${ZRAM_SIZE}MB"

section "UFW"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/'     /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/'                                  /etc/ufw/ufw.conf
systemctl enable ufw
log "UFW yapilandirildi."

section "Snapper"
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root << 'SNAPPER_CONF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="1"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPPER_CONF
echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
mkdir -p /.snapshots
mount -o "rw,noatime,compress=zstd:3,space_cache=v2,subvol=@snapshots" \
    /dev/mapper/cryptroot /.snapshots
chmod 750 /.snapshots
log "Snapper yapilandirildi."

section "Kullanici: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
echo "==> Root sifresi:"
passwd
echo "==> ${USER_NAME} sifresi:"
passwd "$USER_NAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
log "Kullanici olusturuldu: $USER_NAME"

section ".xinitrc"
cat > "/home/${USER_NAME}/.xinitrc" << 'XINIT'
#!/bin/sh
setxkbmap tr &
picom --daemon &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
[ -f "$HOME/Pictures/wallpaper.jpg" ] && feh --bg-scale "$HOME/Pictures/wallpaper.jpg" &
exec i3
XINIT

cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P

if [[ "$GPU_CHOICE" == "5" || "$GPU_CHOICE" == "6" ]]; then
    echo "alias nrun='prime-run'  # NVIDIA dGPU" >> "/home/${USER_NAME}/.bashrc"
fi
[[ "$GPU_CHOICE" == "7" ]] && systemctl enable vboxservice 2>/dev/null || true

section "i3 Config"
mkdir -p "/home/${USER_NAME}/.config/i3"
cat > "/home/${USER_NAME}/.config/i3/config" << 'I3CONF'
set $mod Mod4
font pango:DejaVu Sans Mono 10

gaps inner 8
gaps outer 4
smart_gaps on
smart_borders on
default_border pixel 2
default_floating_border pixel 2

client.focused          #4C7899 #285577 #ffffff #2e9ef4 #285577
client.unfocused        #333333 #222222 #888888 #292d2e #222222
client.urgent           #2f343a #900000 #ffffff #900000 #900000

floating_modifier $mod
bindsym $mod+Return exec alacritty
bindsym $mod+d      exec dmenu_run
bindsym $mod+Shift+q kill

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym Left  resize shrink width  10 px or 10 ppt
    bindsym Down  resize grow   height 10 px or 10 ppt
    bindsym Up    resize shrink height 10 px or 10 ppt
    bindsym Right resize grow   width  10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

bindsym $mod+b split h
bindsym $mod+v split v
bindsym $mod+e layout toggle split
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+space       focus mode_toggle

set $ws1 "1"; set $ws2 "2"; set $ws3 "3"; set $ws4 "4"; set $ws5 "5"
set $ws6 "6"; set $ws7 "7"; set $ws8 "8"; set $ws9 "9"; set $ws10 "10"

bindsym $mod+1 workspace $ws1
bindsym $mod+2 workspace $ws2
bindsym $mod+3 workspace $ws3
bindsym $mod+4 workspace $ws4
bindsym $mod+5 workspace $ws5
bindsym $mod+6 workspace $ws6
bindsym $mod+7 workspace $ws7
bindsym $mod+8 workspace $ws8
bindsym $mod+9 workspace $ws9
bindsym $mod+0 workspace $ws10

bindsym $mod+Shift+1 move container to workspace $ws1
bindsym $mod+Shift+2 move container to workspace $ws2
bindsym $mod+Shift+3 move container to workspace $ws3
bindsym $mod+Shift+4 move container to workspace $ws4
bindsym $mod+Shift+5 move container to workspace $ws5
bindsym $mod+Shift+6 move container to workspace $ws6
bindsym $mod+Shift+7 move container to workspace $ws7
bindsym $mod+Shift+8 move container to workspace $ws8
bindsym $mod+Shift+9 move container to workspace $ws9
bindsym $mod+Shift+0 move container to workspace $ws10

for_window [window_role="pop-up"]         floating enable
for_window [window_role="bubble"]         floating enable
for_window [window_role="dialog"]         floating enable
for_window [window_type="dialog"]         floating enable
for_window [class="Pavucontrol"]          floating enable
for_window [class="Nm-connection-editor"] floating enable
for_window [class="Blueman-manager"]      floating enable
for_window [title="File Transfer*"]       floating enable

bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute   @DEFAULT_SINK@ toggle
bindsym XF86AudioMicMute     exec pactl set-source-mute @DEFAULT_SOURCE@ toggle

bindsym $mod+ctrl+l exec i3lock -c 1a1a2e
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning \
    -m 'Oturumu kapat?' \
    -B 'Evet' 'i3-msg exit' \
    -B 'Yeniden Basla' 'systemctl reboot' \
    -B 'Kapat' 'systemctl poweroff'

bar {
    status_command i3status
    position bottom
    tray_output primary
    colors {
        background #1a1a2e
        statusline #e0e0e0
        separator  #444444
        focused_workspace  #4C7899 #285577 #ffffff
        active_workspace   #333333 #222222 #ffffff
        inactive_workspace #333333 #222222 #888888
        urgent_workspace   #900000 #900000 #ffffff
    }
}
I3CONF

chown -R "${USER_NAME}:${USER_NAME}" \
    "/home/${USER_NAME}/.xinitrc" \
    "/home/${USER_NAME}/.bash_profile" \
    "/home/${USER_NAME}/.config"

section "Servisler"
systemctl enable NetworkManager bluetooth \
    snapper-timeline.timer snapper-cleanup.timer

WANTS_DIR="/home/${USER_NAME}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS_DIR"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS_DIR}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd"
log "Servisler etkinlestirildi."

section "Yay (AUR)"
su - "$USER_NAME" -c '
    git clone https://aur.archlinux.org/yay.git ~/yay
    cd ~/yay && makepkg -si --noconfirm && rm -rf ~/yay
'
log "Yay kuruldu."
CHROOT_EOF

chmod +x /mnt/chroot.sh

echo "XXX"; echo "75"
echo "$(T "[10/10] Hazir! Sistem yapilandirmasi basliyor..." "[10/10] Ready! System configuration starting...")"; echo "XXX"
sleep 1

) | whiptail --title "$(T "Kurulum Ilerliyor" "Installation Progress")" \
    --gauge "$(T "Lutfen bekleyin..." "Please wait...")" 8 72 0

# =============================================================================
# 11. CHROOT — iNTERAKTiF
# =============================================================================
clear
echo -e "\n${CYAN}${BOLD}══ $(T "Sistem Yapilandirmasi" "System Configuration") ══${NC}"
echo -e "\n${YELLOW}$(T \
    "Root ve kullanici sifreleri sorulacak:" \
    "Root and user passwords will be prompted:")${NC}\n"

arch-chroot /mnt /chroot.sh

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh

# =============================================================================
# 12. BiTiS
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << 'ENDSPLASH'

         .88888888:.
        88888888.88888.
      .8888888888888888.
      888888888888888888
      88' _`88'_  `88888
      88 88 88 88  88888
      88_88_::_88_:88888
      88:::,::,:::::8888
      88`::::::::::'8888
     .88  `::::'    8:88.
    8888            `8:888.
  .8888'             `888888.

ENDSPLASH
echo -e "${NC}"

whiptail --title "$(T "KURULUM TAMAMLANDI!" "INSTALLATION COMPLETE!")" \
    --msgbox "$(T \
"Arch Linux basariyla kuruldu!

  [v] LUKS2 (Argon2id) sifreleme
  [v] Btrfs + Snapper otomatik snapshot
  [v] i3wm + gaps masaustu
  [v] Pipewire ses sistemi
  [v] ZRAM ${ZRAM_SIZE}MB swap
  [v] UFW guvenlik duvari
  [v] Yay AUR helper

Ilk boot notlari:
  - Ses gelmezse:
    systemctl --user enable --now
    pipewire pipewire-pulse wireplumber
  - Optimus dGPU: nrun <uygulama>

Log: $LOG_FILE

Yeniden baslatmak icin:
  umount -R /mnt && reboot" \
"Arch Linux installed successfully!

  [v] LUKS2 (Argon2id) encryption
  [v] Btrfs + Snapper auto snapshots
  [v] i3wm + gaps desktop
  [v] Pipewire audio
  [v] ZRAM ${ZRAM_SIZE}MB swap
  [v] UFW firewall
  [v] Yay AUR helper

First boot notes:
  - If no audio:
    systemctl --user enable --now
    pipewire pipewire-pulse wireplumber
  - Optimus dGPU: nrun <app>

Log: $LOG_FILE

To reboot:
  umount -R /mnt && reboot")" \
    32 62
