#!/bin/bash

# Configuration variables
BRANCH='stable'
DEVICE='rpi4'
EDITION='minimal'
VERSION=$(date +'%y'.'%m')
LIBDIR='/usr/share/manjaro-arm-tools/lib'
BUILDDIR='/var/lib/manjaro-arm-tools/pkg'
BUILDSERVER='https://repo.manjaro.org/repo'
PACKAGER=$(cat /etc/makepkg.conf | grep PACKAGER)
PKGDIR='/var/cache/manjaro-arm-tools/pkg'
ROOTFS_IMG='/var/lib/manjaro-arm-tools/img'
TMPDIR='/var/lib/manjaro-arm-tools/tmp'
IMGDIR='/var/cache/manjaro-arm-tools/img'
IMGNAME="Manjaro-ARM-${EDITION-$DEVICE}-${VERSION}"
PROFILES='/usr/share/manjaro-arm-tools/profiles'
NSPAWN='systemd-nspawn -q --resolv-conf=copy-host --timezone=off -D'
OSDN='storage.osdn.net:/storage/groups/m/ma/manjaro-arm'
STORAGE_USER=$(whoami)
FLASHVERSION=$(date +'%y'.'%m')
ARCH='aarch64'
USER='manjaro'
HOSTNAME='manjaro-arm'
PASSWORD='manjaro'
CARCH=$(uname -m)
COLORS='true'
FILESYSTEM='ext4'
SERVICES_LIST='/tmp/services_list'

PROGNAME=${0##*/}

# Import the configuration file
source /etc/manjaro-arm-tools/manjaro-arm-tools.conf 

# PKGDIR and IMGDIR may not exist if they were changed in the loaded
# configuration, so make sure they do exist
mkdir -p ${PKGDIR}/pkg-cache
mkdir -p ${IMGDIR}

usage_deploy_img() {
    echo "Usage: $PROGNAME [options]"
    echo "    -i <image>         Image to upload, should be an .xz compressed file"
    echo "    -d <device>        Targeted device; default is rpi4, options are $(ls -m --width=0 "$PROFILES/arm-profiles/devices/")"
    echo "    -e <edition>       Image edition; default is minimal, options are $(ls -m --width=0 "$PROFILES/arm-profiles/editions/")"
    echo "    -v <version>       Image version; default is the current YY.MM"
    echo "    -k <GPG_key_ID>    Email address associated with the signing GPG key"
    echo "    -u <username>      OSDN account username with upload access; default is the currently logged-in local user"
    echo "    -t                 Create a torrent of the image"
    echo "    -h                 Show this help"
    exit $1
}

usage_build_pkg() {
    echo "Usage: $PROGNAME [options]"
    echo "    -a <arch>          Architecture; default is aarch64, options are any or aarch64"
    echo "    -p <package>       Directory with a package to build"
    echo "    -k                 Keep the previous root filesystem for this build"
    echo "    -b <branch>        Branch for the image; default is stable, options are stable, testing and unstable"
    echo "    -n                 Install the built package into the root filesystem"
    echo "    -i <packages>      Directory with local packages to install to the root filesystem"
    echo "    -r <repository>    Use a custom repository in the root filesystem"
    echo "    -h                 Show this help"
    exit $1
}

usage_build_img() {
    echo "Usage: $PROGNAME [options]"
    echo "    -d <device>        Targeted device; default is rpi4, options are $(ls -m --width=0 "$PROFILES/arm-profiles/devices/")"
    echo "    -e <edition>       Image edition; default is minimal, options are $(ls -m --width=0 "$PROFILES/arm-profiles/editions/")"
    echo "    -v <version>       Image version; default is the current YY.MM"
    echo "    -k <repository>    Overlay repository; options are kde-unstable and mobile, or url https://server/path/custom_repo.db"
    echo "    -i <packages>      Directory with local packages to install to the root filesystem"
    echo "    -b <branch>        Branch for the image; default is stable, options are stable, testing and unstable"
    echo "    -m                 Create bmap; 'bmap-tools' package needs to be installed"
    echo "    -n                 Force downloading of the new root filesystem"
    echo "    -s <hostname>      Custom hostname to be used"
    echo "    -x                 Do not compress the image"
    echo "    -c                 Disable support for colors"
    echo "    -f                 Create image with factory settings"
    echo "    -p <filesystem>    Filesystem for the root partition; default is ext4, options are ext4 and btrfs"
    echo "    -h                 Show this help"
    exit $1
}

usage_build_emmcflasher() {
    echo "Usage: $PROGNAME [options]"
    echo "    -d <device>        Targeted device; default is rpi4, options are $(ls -m --width=0 "$PROFILES/arm-profiles/devices/")"
    echo "    -e <edition>       Image edition; default is minimal, options are $(ls -m --width=0 "$PROFILES/arm-profiles/editions/")"
    echo "    -v <version>       Image version; default is the current YY.MM"
    echo "    -f <flash_version> eMMC flasher image version; default is the current YY.MM"
    echo "    -i <packages>      Directory with local packages to install to the root filesystem"
    echo "    -n                 Force downloading of the the new root filesystem"
    echo "    -x                 Do not compress the image"
    echo "    -h                 Show this help"
    exit $1
}

usage_getarmprofiles() {
    echo "Usage: $PROGNAME [options]"
    echo '    -f                 Force downloading of the current profiles from the git repository'
    echo '    -p                 Use profiles from the pp-factory branch'
    echo "    -h                 Show this help"
    exit $1
}

enable_colors() {
    ALL_OFF="\e[1;0m"
    BOLD="\e[1;1m"
    GREEN="${BOLD}\e[1;32m"
    BLUE="${BOLD}\e[1;34m"
}

msg() {
    local mesg=$1; shift
    printf "${GREEN}==>${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
 }
 
info() {
    local mesg=$1; shift
    printf "${BLUE}  ->${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
 }

error() {
    local mesg=$1; shift
    printf "${RED}==> ERROR:${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

cleanup() {
    umount $ROOTFS_IMG/rootfs_$ARCH/var/cache/pacman/pkg
    exit ${1:-0}
}

abort() {
    error 'Aborting...'
    cleanup 255
}

prune_cache(){
    info "Prune and unmount package cache..."
    $NSPAWN $CHROOTDIR paccache -r
    umount $PKG_CACHE
}

load_vars() {
    local VAR

    [[ -f $1 ]] || return 1

    for VAR in {SRC,SRCPKG,PKG,LOG}DEST MAKEFLAGS PACKAGER CARCH GPGKEY; do
        [[ -z ${!VAR} ]] && eval $(grep -a "^${VAR}=" "$1")
    done

    return 0
}

get_timer(){
    echo $(date +%s)
}

# $1: start timer
elapsed_time(){
    echo $(echo $1 $(get_timer) | awk '{ printf "%0.2f",($2-$1)/60 }')
}

show_elapsed_time(){
    msg "Time %s: %s minutes..." "$1" "$(elapsed_time $2)"
}

create_torrent() {
    info "Creating torrent of $IMAGE..."
    cd $IMGDIR
    mktorrent -v -a udp://tracker.opentrackr.org:1337 -w https://osdn.net/dl/manjaro-arm/$IMAGE \
              -o $IMAGE.torrent $IMAGE
}

check_root () {
    if [ "$EUID" -ne 0 ]; then
        echo "This utility requires root permissions to run"
        exit
    fi
}

check_branch () {
    if [[ "$BRANCH" != "stable" && "$BRANCH" != "testing" && "$BRANCH" != "unstable" ]]; then
	msg "Unknown branch, please use stable, testing or unstable"
	exit 1
    fi
}

check_running() {
    for pid in $(pidof -x $PROGNAME); do
        if [ $pid != $$ ]; then
            echo "Process already running as PID $pid"
            exit 1
        fi
    done
}

checksum_img() {
    # Create checksums for the image
    info "Creating checksums for $IMAGE..."

    cd $IMGDIR
    sha1sum $IMAGE > $IMAGE.sha1
    sha256sum $IMAGE > $IMAGE.sha256
    info "Creating signature for [$IMAGE]..."
    gpg --detach-sign -u $GPGMAIL "$IMAGE"

    if [ ! -f "$IMAGE.sig" ]; then
        echo "Image not signed. Aborting..."
        exit 1
    fi
}

img_upload() {
    # Upload image + checksums to image server
    msg "Uploading image and checksums to server..."
    info "Please use your server login details..."

    img_name=${IMAGE%%.*}
    rsync -raP $img_name* $STORAGE_USER@$OSDN/$DEVICE/$EDITION/$VERSION
}

create_rootfs_pkg() {
    msg "Building $PACKAGE for $ARCH..."

    # Remove old rootfs if it exists
    if [ -d $CHROOTDIR ]; then
        info "Removing old rootfs..."
        rm -rf $CHROOTDIR
    fi

    # Perform basic rootfs initialization
    msg "Creating rootfs..."
    mkdir -p $CHROOTDIR
    info "Switching branch to $BRANCH..."
    sed -i s/"arm-stable"/"arm-$BRANCH"/g $LIBDIR/pacman.conf.$ARCH
    $LIBDIR/pacstrap -G -M -C $LIBDIR/pacman.conf.$ARCH $CHROOTDIR fakeroot-qemu base-devel
    echo "Server = $BUILDSERVER/arm-$BRANCH/\$repo/\$arch" > $CHROOTDIR/etc/pacman.d/mirrorlist
    sed -i s/"arm-$BRANCH"/"arm-stable"/g $LIBDIR/pacman.conf.$ARCH

    if [[ $CARCH != "aarch64" ]]; then
        # Enable cross-architecture chrooting
        cp /usr/bin/qemu-aarch64-static $CHROOTDIR/usr/bin
    fi

    msg "Configuring rootfs for building..."
    $NSPAWN $CHROOTDIR pacman-key --init > /dev/null 2>&1
    $NSPAWN $CHROOTDIR pacman-key --populate archlinuxarm manjaro manjaro-arm > /dev/null 2>&1
    cp $LIBDIR/makepkg $CHROOTDIR/usr/bin
    $NSPAWN $CHROOTDIR chmod +x /usr/bin/makepkg > /dev/null 2>&1
    $NSPAWN $CHROOTDIR update-ca-trust

    if [[ ! -z ${CUSTOM_REPO} ]]; then
        info "Adding repo [$CUSTOM_REPO] to rootfs"

        if [[ "$CUSTOM_REPO" =~ ^https?://.*db ]]; then
            CUSTOM_REPO_NAME="${CUSTOM_REPO##*/}" # remove everyting before last slash
            CUSTOM_REPO_NAME="${CUSTOM_REPO_NAME%.*}" # remove everything after last dot
            CUSTOM_REPO_URL="${CUSTOM_REPO%/*}" # remove everything after last slash
            sed -i "s/^\[core\]/\[$CUSTOM_REPO_NAME\]\nSigLevel = Optional TrustAll\nServer = ${CUSTOM_REPO_URL//\//\\/}\n\n\[core\]/" \
                $CHROOTDIR/etc/pacman.conf
        else
            sed -i "s/^\[core\]/\[$CUSTOM_REPO\]\nInclude = \/etc\/pacman.d\/mirrorlist\n\n\[core\]/" $CHROOTDIR/etc/pacman.conf
        fi
    fi

    sed -i s/'#PACKAGER="John Doe <john@doe.com>"'/"$PACKAGER"/ $CHROOTDIR/etc/makepkg.conf
    sed -i s/'#MAKEFLAGS="-j2"'/'MAKEFLAGS="-j$(nproc)"'/ $CHROOTDIR/etc/makepkg.conf
    sed -i s/'COMPRESSXZ=(xz -c -z -)'/'COMPRESSXZ=(xz -c -z - --threads=0)'/ $CHROOTDIR/etc/makepkg.conf

    $NSPAWN $CHROOTDIR pacman -Syy
}

create_rootfs_img() {
    # Check if device file exists
    if [ ! -f "$PROFILES/arm-profiles/devices/$DEVICE" ]; then 
        echo "Device $DEVICE not valid, please choose one of the listed below"
        echo "$(ls $PROFILES/arm-profiles/devices)"
        exit 1
    fi

    # Check if edition file exists
    if [ ! -f "$PROFILES/arm-profiles/editions/$EDITION" ]; then 
        echo "Edition $EDITION not valid, please choose one of the listed below"
        echo "$(ls $PROFILES/arm-profiles/editions)"
        exit 1
    fi

    msg "Creating $EDITION image for $DEVICE..."

    # Remove old rootfs if it exists
    if [ -d "$ROOTFS_IMG/rootfs_$ARCH" ]; then
        info "Removing old $ARCH rootfs..."
        rm -rf $ROOTFS_IMG/rootfs_$ARCH
    fi
    mkdir -p $ROOTFS_IMG/rootfs_$ARCH
    if [[ "$KEEPROOTFS" = "false" ]]; then
        info "Removing old $ARCH rootfs archive..."
        rm -rf $ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz*
    fi

    # Fetch new rootfs, if it does not exist
    if [ ! -f "$ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz" ]; then
        info "Downloading latest $ARCH rootfs archive..."
        cd $ROOTFS_IMG
        wget -q -N --show-progress --progress=bar:force:noscroll \
             https://github.com/manjaro-arm/rootfs/releases/latest/download/Manjaro-ARM-$ARCH-latest.tar.gz
    fi
    
    info "Extracting $ARCH rootfs..."
    bsdtar -xpf $ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz -C $ROOTFS_IMG/rootfs_$ARCH
    
    info "Setting up keyrings..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman-key --init > /dev/null || abort
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman-key --populate archlinuxarm manjaro manjaro-arm > /dev/null || abort
    
    if [[ ! -z ${CUSTOM_REPO} ]]; then
        info "Adding $CUSTOM_REPO repository to rootfs..."

        if [[ "$CUSTOM_REPO" =~ ^https?://.*db ]]; then
            CUSTOM_REPO_NAME="${CUSTOM_REPO##*/}"       # Remove everyting before last slash
            CUSTOM_REPO_NAME="${CUSTOM_REPO_NAME%.*}"   # Remove everything after last dot
            CUSTOM_REPO_URL="${CUSTOM_REPO%/*}"         # Remove everything after last slash
            sed -i "s/^\[core\]/\[$CUSTOM_REPO_NAME\]\nSigLevel = Optional TrustAll\nServer = ${CUSTOM_REPO_URL//\//\\/}\n\n\[core\]/" \
                $ROOTFS_IMG/rootfs_$ARCH/etc/pacman.conf
        else
            sed -i "s/^\[core\]/\[$CUSTOM_REPO\]\nInclude = \/etc\/pacman.d\/mirrorlist\n\n\[core\]/" \
                $ROOTFS_IMG/rootfs_$ARCH/etc/pacman.conf
        fi
    fi

    info "Setting branch to $BRANCH..."
    echo "Server = $BUILDSERVER/arm-$BRANCH/\$repo/\$arch" > $ROOTFS_IMG/rootfs_$ARCH/etc/pacman.d/mirrorlist
    
    # Install device- and edition-specific packages
    msg "Installing packages for $EDITION edition on $DEVICE..."
    mount --bind $PKGDIR/pkg-cache $PKG_CACHE
    case "$EDITION" in
        cubocore|gnome-mobile|phosh|plasma-mobile|plasma-mobile-dev|kde-bigscreen|maui-shell|nemomobile)
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                pacman -Syyu base systemd systemd-libs manjaro-system manjaro-release \
                             $PKG_EDITION $PKG_DEVICE --noconfirm || abort
            ;;

        minimal|server)
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                pacman -Syyu base systemd systemd-libs dialog manjaro-arm-oem-install manjaro-system manjaro-release \
                             $PKG_EDITION $PKG_DEVICE --noconfirm || abort
            ;;

        *)
            # This device does not support Calamares, because of the low pixel height of the display (480)
            if [[ "$DEVICE" = "clockworkpi-a06" ]]; then
                $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                    pacman -Syyu base systemd systemd-libs dialog manjaro-arm-oem-install manjaro-system manjaro-release \
                                 $PKG_EDITION $PKG_DEVICE --noconfirm || abort
            else
                $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                    pacman -Syyu base systemd systemd-libs calamares-arm-oem manjaro-system manjaro-release \
                                 $PKG_EDITION $PKG_DEVICE --noconfirm || abort
            fi
            ;;
    esac

    if [[ ! -z "${ADD_PACKAGES}" ]]; then
        local STATUS
        msg "Importing $ADD_PACKAGES local packages directory to rootfs..."
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkdir -p local
        mount --bind "$(realpath $ADD_PACKAGES)" "$ROOTFS_IMG/rootfs_$ARCH/local"
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman -U local/*.pkg.tar.* --noconfirm || abort
        STATUS=$?
        umount "$ROOTFS_IMG/rootfs_$ARCH/local"
        rm -rf "$ROOTFS_IMG/rootfs_$ARCH/local"
        if [[ $STATUS != 0 ]]; then
            echo "Installing local packages failed, aborting"
            exit 1
        fi
    fi

    info "Generating mirrorlist..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
        pacman-mirrors --protocols https --method random --api --set-branch $BRANCH > /dev/null 2>&1
    
    # Enable services
    info "Enabling services..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl enable getty.target > /dev/null 2>&1
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl enable pacman-init.service > /dev/null 2>&1
    if [[ "$CUSTOM_REPO" = "kde-unstable" ]]; then
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl enable sshd.service > /dev/null 2>&1
    fi

    local SERVICE
    while read SERVICE; do
        if [ -e $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/$SERVICE ]; then
            echo "Enabling $SERVICE..."
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl enable $SERVICE > /dev/null 2>&1
        else
            echo "$SERVICE not found in rootfs, skipping"
        fi
    done < $SERVICES_LIST

    info "Applying overlay for $EDITION edition..."
    cp -a $PROFILES/arm-profiles/overlays/$EDITION/* $ROOTFS_IMG/rootfs_$ARCH

    # System setup
    info "Setting up system settings..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH update-ca-trust
    echo "$HOSTNAME" | tee --append $ROOTFS_IMG/rootfs_$ARCH/etc/hostname > /dev/null 2>&1
    case "$EDITION" in
        cubocore|plasma-mobile|plasma-mobile-dev|kde-bigscreen|maui-shell)
            echo "No OEM setup!"
            # Lock root user
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH passwd --lock root
            ;;

        gnome-mobile|phosh|lomiri)
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH groupadd -r autologin
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH gpasswd -a "$USER" autologin
            # Lock root user
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH passwd --lock root
            ;;

        nemomobile)
            echo "Create user manjaro for nemomobile..."
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH groupadd -r autologin
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                useradd -m -g users -G wheel,sys,audio,input,video,storage,lp,network,users,power,autologin \
                        -p $(openssl passwd -6 123456) -s /bin/bash manjaro
            ;;

        minimal|server)
            echo "Enabling SSH login for root user for headless setup..."
            sed -i s/"#PermitRootLogin prohibit-password"/"PermitRootLogin yes"/g $ROOTFS_IMG/rootfs_$ARCH/etc/ssh/sshd_config
            sed -i s/"#PermitEmptyPasswords no"/"PermitEmptyPasswords yes"/g $ROOTFS_IMG/rootfs_$ARCH/etc/ssh/sshd_config
            echo "Enabling autologin for first setup..."
            mv $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service.bak
            cp $LIBDIR/getty\@.service $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service
            ;;
    esac

    # Device does not support Calamares because of low screen resolution, so enable TUI OEM setup on it
    if [[ "$DEVICE" = "clockworkpi-a06" ]]; then
        echo "Enabling SSH login for root user for headless setup..."
        sed -i s/"#PermitRootLogin prohibit-password"/"PermitRootLogin yes"/g $ROOTFS_IMG/rootfs_$ARCH/etc/ssh/sshd_config
        sed -i s/"#PermitEmptyPasswords no"/"PermitEmptyPasswords yes"/g $ROOTFS_IMG/rootfs_$ARCH/etc/ssh/sshd_config

        echo "Enabling autologin for first setup..."
        mv $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service.bak
        cp $LIBDIR/getty\@.service $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/getty\@.service
        if [ -e $ROOTFS_IMG/rootfs_$ARCH/usr/bin/lightdm ]; then
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl disable lightdm.service > /dev/null 2>&1
        elif [ -e $ROOTFS_IMG/rootfs_$ARCH/usr/bin/sddm ]; then
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl disable sddm.service > /dev/null 2>&1
        elif [ -e $ROOTFS_IMG/rootfs_$ARCH/usr/bin/gdm ]; then
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl disable gdm.service > /dev/null 2>&1
        elif [ -e $ROOTFS_IMG/rootfs_$ARCH/usr/bin/greetd ]; then
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH systemctl disable greetd.service > /dev/null 2>&1
        fi
    fi
    
    # Create the OEM user
    if [ -d $ROOTFS_IMG/rootfs_$ARCH/usr/share/calamares ]; then
        echo "Creating OEM user..."
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH groupadd -r autologin
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            useradd -m -g users -u 984 -G wheel,sys,audio,input,video,storage,lp,network,users,power,autologin \
                    -p $(openssl passwd -6 oem) -s /bin/bash oem
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH echo "oem ALL=(ALL) NOPASSWD: ALL" > $ROOTFS_IMG/rootfs_$ARCH/etc/sudoers.d/g_oem

        case "$EDITION" in
            desq|kde-plasma|wayfire|sway)
                SESSION=$(ls $ROOTFS_IMG/rootfs_$ARCH/usr/share/wayland-sessions/ | head -1)
                ;;
            *)
                SESSION=$(ls $ROOTFS_IMG/rootfs_$ARCH/usr/share/xsessions/ | head -1)
                ;;
        esac

        # For sddm based systems
        if [ -f $ROOTFS_IMG/rootfs_$ARCH/usr/bin/sddm ]; then
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkdir -p /etc/sddm.conf.d
            echo "# Created by Manjaro ARM OEM Setup

[Autologin]
User=oem
Session=$SESSION" > $ROOTFS_IMG/rootfs_$ARCH/etc/sddm.conf.d/90-autologin.conf
        fi

        # For lightdm-based systems
        if [ -f $ROOTFS_IMG/rootfs_$ARCH/usr/bin/lightdm ]; then
            SESSION=$(echo ${SESSION%.*})
            sed -i s/"#autologin-user="/"autologin-user=oem"/g $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm.conf
            sed -i s/"#autologin-user-timeout=0"/"autologin-user-timeout=0"/g $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm.conf

            if [[ "$EDITION" = "lxqt" ]]; then
                sed -i s/"#autologin-session="/"autologin-session=lxqt"/g $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm.conf
            elif [[ "$EDITION" = "i3" ]]; then
                echo "autologin-user=oem
autologin-user-timeout=0
autologin-session=i3" >> $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm.conf
                sed -i s/"# Autostart applications"/"# Autostart applications\nexec --no-startup-id sudo -E calamares"/g \
                    $ROOTFS_IMG/rootfs_$ARCH/home/oem/.i3/config
            else
                sed -i s/"#autologin-session="/"autologin-session=$SESSION"/g $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm.conf
            fi
        fi

        # For greetd based Sway edition
        if [ -f $ROOTFS_IMG/rootfs_$ARCH/usr/bin/sway ]; then
            echo '[initial_session]
command = "sway --config /etc/greetd/oem-setup"
user = "oem"' >> $ROOTFS_IMG/rootfs_$ARCH/etc/greetd/config.toml
        fi
        # For Gnome edition
        if [ -f $ROOTFS_IMG/rootfs_$ARCH/usr/bin/gdm ]; then
            sed -i s/"\[daemon\]"/"\[daemon\]\nAutomaticLogin=oem\nAutomaticLoginEnable=True"/g \
                $ROOTFS_IMG/rootfs_$ARCH/etc/gdm/custom.conf
        fi
    fi
    
    # Lomiri services Temporary in function until it is moved to an individual package.
    if [[ "$EDITION" = "lomiri" ]]; then
        echo "Fixing indicators..."
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkdir -pv /usr/lib/systemd/user/ayatana-indicators.target.wants
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-datetime.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-datetime.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-display.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-display.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-messages.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-messages.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-power.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-power.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-session.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-session.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/ayatana-indicator-sound.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/ayatana-indicator-sound.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/indicator-network.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/indicator-network.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/indicator-transfer.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/indicator-transfer.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/indicator-bluetooth.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/indicator-bluetooth.service
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/indicator-location.service \
                    /usr/lib/systemd/user/ayatana-indicators.target.wants/indicator-location.service
        
        echo "Fixing background..."
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkdir -pv /usr/share/backgrounds
        #$NSPAWN $ROOTFS_IMG/rootfs_$ARCH convert -verbose /usr/share/wallpapers/manjaro.jpg /usr/share/wallpapers/manjaro.png
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH ln -sfv /usr/share/wallpapers/manjaro.png /usr/share/backgrounds/warty-final-ubuntu.png
        
        echo "Fixing Maliit..."
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkdir -pv /usr/lib/systemd/user/graphical-session.target.wants
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
            ln -sfv /usr/lib/systemd/user/maliit-server.service \
                    /usr/lib/systemd/user/graphical-session.target.wants/maliit-server.service
    fi
    ### Lomiri Temporary service ends here 

    echo "Correcting permissions from overlay..."
    chown -R 0:0 $ROOTFS_IMG/rootfs_$ARCH/etc
    chown -R 0:0 $ROOTFS_IMG/rootfs_$ARCH/usr/{local,share}
    if [[ -d $ROOTFS_IMG/rootfs_$ARCH/etc/polkit-1/rules.d ]]; then
        chown 0:102 $ROOTFS_IMG/rootfs_$ARCH/etc/polkit-1/rules.d
    fi
    if [[ -d $ROOTFS_IMG/rootfs_$ARCH/usr/share/polkit-1/rules.d ]]; then
        chown 0:102 $ROOTFS_IMG/rootfs_$ARCH/usr/share/polkit-1/rules.d
    fi
    
    if [[ "$FILESYSTEM" = "btrfs" ]]; then
        info "Adding btrfs support to system..."
        if [ -f $ROOTFS_IMG/rootfs_$ARCH/boot/extlinux/extlinux.conf ]; then
            sed -i 's/APPEND/& rootflags=subvol=@/' $ROOTFS_IMG/rootfs_$ARCH/boot/extlinux/extlinux.conf
        elif [ -f $ROOTFS_IMG/rootfs_$ARCH/boot/boot.ini ]; then
            sed -i 's/setenv bootargs "/&rootflags=subvol=@ /' $ROOTFS_IMG/rootfs_$ARCH/boot/boot.ini
        elif [ -f $ROOTFS_IMG/rootfs_$ARCH/boot/uEnv.ini ]; then
            sed -i 's/setenv bootargs "/&rootflags=subvol=@ /' $ROOTFS_IMG/rootfs_$ARCH/boot/uEnv.ini
        #elif [ -f $ROOTFS_IMG/rootfs_$ARCH/boot/cmdline.txt ]; then
        #    sed -i 's/^/rootflags=subvol=@ rootfstype=btrfs /' $ROOTFS_IMG/rootfs_$ARCH/boot/cmdline.txt
        elif [ -f $ROOTFS_IMG/rootfs_$ARCH/boot/boot.txt ]; then
            sed -i 's/setenv bootargs/& rootflags=subvol=@/' $ROOTFS_IMG/rootfs_$ARCH/boot/boot.txt
            $NSPAWN $ROOTFS_IMG/rootfs_$ARCH \
                mkimage -A arm -O linux -T script -C none -n "U-Boot boot script" -d /boot/boot.txt /boot/boot.scr
        fi

        echo "LABEL=ROOT_MNJRO / btrfs  subvol=@,compress=zstd,defaults,noatime  0  0" >> $ROOTFS_IMG/rootfs_$ARCH/etc/fstab
        echo "LABEL=ROOT_MNJRO /home btrfs  subvol=@home,compress=zstd,defaults,noatime  0  0" >> $ROOTFS_IMG/rootfs_$ARCH/etc/fstab
        sed -i '/^MODULES/{s/)/ btrfs)/}' $ROOTFS_IMG/rootfs_$ARCH/etc/mkinitcpio.conf
        $NSPAWN $ROOTFS_IMG/rootfs_$ARCH mkinitcpio -P > /dev/null 2>&1
    fi
    
    if [[ "$FACTORY" = "true" ]]; then
        info "Making settings for factory-specific image..."
        case "$EDITION" in
            kde-plasma)
                sed -i s@'Bamboo at Night/contents/images/5120x2880.png'@'manjaro-arm/generic/manjaro-pine64-2b.png'@g \
                    $ROOTFS_IMG/rootfs_$ARCH/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
                ;;

            xfce)
                sed -i s/"manjaro-bamboo.png"/"manjaro-pine64-2b.png"/g \
                    $ROOTFS_IMG/rootfs_$ARCH/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
                sed -i s/"manjaro-bamboo.png"/"manjaro-pine64-2b.png"/g \
                    $ROOTFS_IMG/rootfs_$ARCH/etc/lightdm/lightdm-gtk-greeter.conf
                ;;
        esac

        sed -i "s/arm-$BRANCH/arm-stable/g" $ROOTFS_IMG/rootfs_$ARCH/etc/pacman.d/mirrorlist
        sed -i "s/arm-$BRANCH/arm-stable/g" $ROOTFS_IMG/rootfs_$ARCH/etc/pacman-mirrors.conf
        echo "$EDITION - $(date +'%y'.'%m'.'%d')" | tee --append $ROOTFS_IMG/rootfs_$ARCH/etc/factory-version > /dev/null 2>&1
    else
        echo "$DEVICE - $EDITION - $VERSION" | tee --append $ROOTFS_IMG/rootfs_$ARCH/etc/manjaro-arm-version > /dev/null 2>&1
    fi
    
    msg "Creating package list $IMGDIR/$IMGNAME-pkgs.txt..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman -Qr / > $ROOTFS_IMG/rootfs_$ARCH/var/tmp/pkglist.txt 2>/dev/null
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH sed -i '1s/^[^l]*l//' /var/tmp/pkglist.txt
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH sed -i '$d' /var/tmp/pkglist.txt
    mv $ROOTFS_IMG/rootfs_$ARCH/var/tmp/pkglist.txt "$IMGDIR/$IMGNAME-pkgs.txt"
    
    info "Removing unwanted files from rootfs..."
    prune_cache
    rm $ROOTFS_IMG/rootfs_$ARCH/usr/bin/qemu-aarch64-static
    rm -f $ROOTFS_IMG/rootfs_$ARCH/var/log/* > /dev/null 2>&1
    rm -rf $ROOTFS_IMG/rootfs_$ARCH/var/log/journal/*
    rm -rf $ROOTFS_IMG/rootfs_$ARCH/etc/*.pacnew
    rm -rf $ROOTFS_IMG/rootfs_$ARCH/usr/lib/systemd/system/systemd-firstboot.service
    rm -rf $ROOTFS_IMG/rootfs_$ARCH/etc/machine-id
    rm -rf $ROOTFS_IMG/rootfs_$ARCH/etc/pacman.d/gnupg

    msg "$DEVICE $EDITION rootfs complete"
}

create_emmc_install() {
    msg "Creating eMMC install image of $EDITION for $DEVICE..."

    # Remove old rootfs if it exists
    if [ -d $CHROOTDIR ]; then
        info "Removing old rootfs..."
        rm -rf $CHROOTDIR
    fi
    mkdir -p $CHROOTDIR
    if [[ "$KEEPROOTFS" = "false" ]]; then
        info "Removing old $ARCH rootfs archive..."
        rm -rf $ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz*
    fi

    # Fetch new rootfs, if it does not exist
    if [ ! -f "$ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz" ]; then
        info "Downloading latest $ARCH rootfs archive..."
        cd $ROOTFS_IMG
        wget -q -N --show-progress --progress=bar:force:noscroll \
             https://github.com/manjaro-arm/rootfs/releases/latest/download/Manjaro-ARM-$ARCH-latest.tar.gz
    fi
    
    info "Extracting $ARCH rootfs..."
    bsdtar -xpf $ROOTFS_IMG/Manjaro-ARM-$ARCH-latest.tar.gz -C $CHROOTDIR
    
    info "Setting up keyrings..."
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman-key --init || abort
    $NSPAWN $ROOTFS_IMG/rootfs_$ARCH pacman-key --populate archlinuxarm manjaro manjaro-arm || abort
    
    # Install device- and edition-specific packages
    msg "Installing packages for eMMC installer edition of $EDITION on $DEVICE..."
    echo "Server = $BUILDSERVER/arm-$BRANCH/\$repo/\$arch" > $CHROOTDIR/etc/pacman.d/mirrorlist
    mount --bind $PKGDIR/pkg-cache $PKG_CACHE
    $NSPAWN $CHROOTDIR pacman -Syyu base manjaro-system manjaro-release manjaro-arm-emmc-flasher $PKG_EDITION $PKG_DEVICE --noconfirm

    # Enable services
    info "Enabling services..."
    $NSPAWN $CHROOTDIR systemctl enable getty.target > /dev/null 2>&1
    
    # Set the hostname
    info "Setting up system settings..."
    echo "$HOSTNAME" | tee --append $ROOTFS_IMG/rootfs_$ARCH/etc/hostname > /dev/null 2>&1

    # Anable autologin
    mv $CHROOTDIR/usr/lib/systemd/system/getty\@.service $CHROOTDIR/usr/lib/systemd/system/getty\@.service.bak
    cp $LIBDIR/getty\@.service $CHROOTDIR/usr/lib/systemd/system/getty\@.service
    
    if [ -f $IMGDIR/Manjaro-ARM-$EDITION-$DEVICE-$VERSION.img.xz ]; then
        info "Copying local $DEVICE $EDITION image..."
        cp $IMGDIR/Manjaro-ARM-$EDITION-$DEVICE-$VERSION.img.xz $CHROOTDIR/var/tmp/Manjaro-ARM.img.xz
        sync
    else
        info "Downloading $DEVICE $EDITION image..."
        cd $CHROOTDIR/var/tmp
        wget -q --show-progress --progress=bar:force:noscroll -O Manjaro-ARM.img.xz \
             https://github.com/manjaro-arm/$DEVICE-images/releases/download/$VERSION/Manjaro-ARM-$EDITION-$DEVICE-$VERSION.img.xz
    fi
    
    info "Cleaning rootfs for unwanted files..."
    prune_cache
    rm $CHROOTDIR/usr/bin/qemu-aarch64-static
    rm -rf $CHROOTDIR/var/log/*
    rm -rf $CHROOTDIR/etc/*.pacnew
    rm -rf $CHROOTDIR/usr/lib/systemd/system/systemd-firstboot.service
    rm -rf $CHROOTDIR/etc/machine-id
}

create_img_halium() {
    msg "Finishing image for $DEVICE $EDITION edition..."
    info "Creating image..."

    ARCH='aarch64'
    SIZE=$(du -s --block-size=MB $CHROOTDIR | awk '{print $1}' | sed -e 's/MB//g')
    EXTRA_SIZE=300
    REAL_SIZE=`echo "$(($SIZE+$EXTRA_SIZE))"`

    # Make blank .img to be used and create the filsystem on it
    dd if=/dev/zero of=$IMGDIR/$IMGNAME.img bs=1M count=$REAL_SIZE > /dev/null 2>&1
    mkfs.ext4 $IMGDIR/$IMGNAME.img -L ROOT_MNJRO > /dev/null 2>&1

    info "Copying files to image..."
    mkdir -p $TMPDIR/root
    mount $IMGDIR/$IMGNAME.img $TMPDIR/root
    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root

    umount $TMPDIR/root
    rm -r $TMPDIR/root
    
    chmod 0666 $IMGDIR/$IMGNAME.img
}

create_img() {
    msg "Finishing image for $DEVICE $EDITION edition..."
    info "Creating partitions..."

    ARCH='aarch64'
    SIZE=$(du -s --block-size=MB $CHROOTDIR | awk '{print $1}' | sed -e 's/MB//g')
    EXTRA_SIZE=800
    REAL_SIZE=`echo "$(($SIZE+$EXTRA_SIZE))"`
    
    # Make blank .img to be used
    dd if=/dev/zero of=$IMGDIR/$IMGNAME.img bs=1M count=$REAL_SIZE > /dev/null 2>&1

    # Load the loop kernel module
    modprobe loop > /dev/null 2>&1

    # Set up the loop device
    LDEV=`losetup -f`
    DEV=`echo $LDEV | cut -d "/" -f 3`

    # Mount the image to the loop device
    losetup -P $LDEV $IMGDIR/$IMGNAME.img > /dev/null 2>&1

    case "$FILESYSTEM" in
        btrfs)
            # Create partitions
            # Clear the first 32 MB
            dd if=/dev/zero of=${LDEV} bs=1M count=32 > /dev/null 2>&1

            # Partition with boot and root
            case "$DEVICE" in
                oc2|on2|on2-plus|oc4|ohc4|vim1|vim2|vim3|vim3l|radxa-zero|radxa-zero2|gtking-pro|gsking-x|rpi3|rpi4|rpi4-cutiepi|pinephone)
                    parted -s $LDEV mklabel msdos > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary btrfs "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.btrfs -m single -L ROOT_MNJRO "${LDEV}p2" > /dev/null 2>&1
    
                    # Copy the rootfs contents over to the filesystem
                    info "Creating subvolumes..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot

                    # Create the subvolumes
                    mount -o compress=zstd "${LDEV}p2" $TMPDIR/root
                    btrfs su cr $TMPDIR/root/@ > /dev/null 2>&1
                    btrfs su cr $TMPDIR/root/@home > /dev/null 2>&1
                    umount $TMPDIR/root
                    mount -o compress=zstd,subvol=@ "${LDEV}p2" $TMPDIR/root
                    mkdir -p $TMPDIR/root/home
                    mount -o compress=zstd,subvol=@home "${LDEV}p2" $TMPDIR/root/home
                    info "Copying files to image..."
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                generic)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 0% 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary btrfs "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.btrfs -m single -L ROOT_MNJRO "${LDEV}p2" > /dev/null 2>&1
    
                    # Copy the rootfs contents over to the filesystem
                    info "Creating subvolumes..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot

                    # Create the subvolumes
                    mount -o compress=zstd "${LDEV}p2" $TMPDIR/root
                    btrfs su cr $TMPDIR/root/@ > /dev/null 2>&1
                    btrfs su cr $TMPDIR/root/@home > /dev/null 2>&1
                    umount $TMPDIR/root
                    mount -o compress=zstd,subvol=@ "${LDEV}p2" $TMPDIR/root
                    mkdir -p $TMPDIR/root/home
                    mount -o compress=zstd,subvol=@home "${LDEV}p2" $TMPDIR/root/home
                    info "Copying files to image..."
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                generic-efi)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 0% 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary btrfs "${END_SECTOR}s" 100% > /dev/null 2>&1
                    parted -s $LDEV set 1 esp on
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.btrfs -m single -L ROOT_MNJRO "${LDEV}p2" > /dev/null 2>&1
                
                    # Copy the rootfs contents over to the filsystem
                    info "Creating subvolumes..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot

                    # Create the subvolumes
                    mount -o compress=zstd "${LDEV}p2" $TMPDIR/root
                    btrfs su cr $TMPDIR/root/@ > /dev/null 2>&1
                    btrfs su cr $TMPDIR/root/@home > /dev/null 2>&1
                    umount $TMPDIR/root
                    mount -o compress=zstd,subvol=@ "${LDEV}p2" $TMPDIR/root
                    mkdir -p $TMPDIR/root/home
                    mount -o compress=zstd,subvol=@home "${LDEV}p2" $TMPDIR/root/home
                    info "Copying files to image..."
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                quartz64-bsp)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart uboot fat32 8MiB 16MiB > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p2/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p2/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary btrfs "${END_SECTOR}s" 100% > /dev/null 2>&1
                    parted -s $LDEV set 2 esp on
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p2" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.btrfs -m single -L ROOT_MNJRO "${LDEV}p3" > /dev/null 2>&1
                
                    # Copy the rootfs contents over to the filesystem
                    info "Creating subvolumes..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/boot

                    # Create the subvolumes
                    mount -o compress=zstd "${LDEV}p3" $TMPDIR/root
                    btrfs su cr $TMPDIR/root/@ > /dev/null 2>&1
                    btrfs su cr $TMPDIR/root/@home > /dev/null 2>&1
                    umount $TMPDIR/root
                    mount -o compress=zstd,subvol=@ "${LDEV}p3" $TMPDIR/root
                    mkdir -p $TMPDIR/root/home
                    mount -o compress=zstd,subvol=@home "${LDEV}p3" $TMPDIR/root/home
                    info "Copying files to image..."
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                *)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary btrfs "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.btrfs -m single -L ROOT_MNJRO "${LDEV}p2" > /dev/null 2>&1
    
                    # Copy the rootfs contents over to the filesystem
                    info "Creating subvolumes..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot

                    # Create the subvolumes
                    mount -o compress=zstd "${LDEV}p2" $TMPDIR/root
                    btrfs su cr $TMPDIR/root/@ > /dev/null 2>&1
                    btrfs su cr $TMPDIR/root/@home > /dev/null 2>&1
                    umount $TMPDIR/root
                    mount -o compress=zstd,subvol=@ "${LDEV}p2" $TMPDIR/root
                    mkdir -p $TMPDIR/root/home
                    mount -o compress=zstd,subvol=@home "${LDEV}p2" $TMPDIR/root/home
                    info "Copying files to image..."
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;
            esac
            ;;

        *)
            # Create the partitions and clear the first 32 MB
            dd if=/dev/zero of=${LDEV} bs=1M count=32 > /dev/null 2>&1

            # Partition with boot and root
            case "$DEVICE" in
                oc2|on2|on2-plus|oc4|ohc4|vim1|vim2|vim3|vim3l|radxa-zero|radxa-zero2|gtking-pro|gsking-x|rpi3|rpi4|rpi4-cutiepi|pinephone)
                    parted -s $LDEV mklabel msdos > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary ext4 "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p2" -L ROOT_MNJRO > /dev/null 2>&1

                    # Copy the rootfs contents over to the filsysstem
                    info "Copying files to image..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/root
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                generic)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 0% 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary ext4 "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p2" -L ROOT_MNJRO > /dev/null 2>&1

                    # Copy the rootfs contents over to the filesystem
                    info "Copying files to image..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/root
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                generic-efi)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 0% 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary ext4 "${END_SECTOR}s" 100% > /dev/null 2>&1
                    parted -s $LDEV set 1 esp on
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p2" -L ROOT_MNJRO > /dev/null 2>&1
                    info "Copying files to image..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/root
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                quartz64-bsp)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart uboot fat32 8M 16M > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p2/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p2/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary ext4 "${END_SECTOR}s" 100% > /dev/null 2>&1
                    parted -s $LDEV set 2 esp on
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p2" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p3" -L ROOT_MNJRO > /dev/null 2>&1
                    info "Copying files to image..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/boot
                    mount ${LDEV}p3 $TMPDIR/root
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;

                *)
                    parted -s $LDEV mklabel gpt > /dev/null 2>&1
                    parted -s $LDEV mkpart primary fat32 32M 512M > /dev/null 2>&1
                    START=`cat /sys/block/$DEV/${DEV}p1/start`
                    SIZE=`cat /sys/block/$DEV/${DEV}p1/size`
                    END_SECTOR=$(expr $START + $SIZE)
                    parted -s $LDEV mkpart primary ext4 "${END_SECTOR}s" 100% > /dev/null 2>&1
                    partprobe $LDEV > /dev/null 2>&1
                    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO > /dev/null 2>&1
                    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p2" -L ROOT_MNJRO > /dev/null 2>&1

                    # Copy the rootfs contents over to the filesystem
                    info "Copying files to image..."
                    mkdir -p $TMPDIR/root
                    mkdir -p $TMPDIR/boot
                    mount ${LDEV}p1 $TMPDIR/boot
                    mount ${LDEV}p2 $TMPDIR/root
                    cp -a $ROOTFS_IMG/rootfs_$ARCH/* $TMPDIR/root
                    mv $TMPDIR/root/boot/* $TMPDIR/boot
                    ;;
            esac
            ;;
    esac
        
    # Flash the boot loader
    if [[ "$DEVICE" != "generic" ]] && [[ "$DEVICE" != "generic-efi" ]]; then
        info "Flashing bootloader..."
        case "$DEVICE" in
            # AMLogic U-Boots
            oc2)
                dd if=$TMPDIR/boot/bl1.bin.hardkernel of=${LDEV} conv=fsync bs=1 count=442 > /dev/null 2>&1
                dd if=$TMPDIR/boot/bl1.bin.hardkernel of=${LDEV} conv=fsync bs=512 skip=1 seek=1 > /dev/null 2>&1
                dd if=$TMPDIR/boot/u-boot.gxbb of=${LDEV} conv=fsync bs=512 seek=97 > /dev/null 2>&1
                ;;
            on2|on2-plus|oc4|ohc4)
                dd if=$TMPDIR/boot/u-boot.bin of=${LDEV} conv=fsync,notrunc bs=512 seek=1 > /dev/null 2>&1
                ;;
            vim1|vim2|vim3|vim3l|radxa-zero|radxa-zero2|gtking-pro|gsking-x)
                dd if=$TMPDIR/boot/u-boot.bin of=${LDEV} conv=fsync,notrunc bs=442 count=1 > /dev/null 2>&1
                dd if=$TMPDIR/boot/u-boot.bin of=${LDEV} conv=fsync,notrunc bs=512 skip=1 seek=1 > /dev/null 2>&1
                ;;

            # Allwinner U-Boots
            pinebook|pine64-lts|pine64|pinetab|pine-h64)
               dd if=$TMPDIR/boot/u-boot-sunxi-with-spl-$DEVICE.bin of=${LDEV} conv=fsync bs=128k seek=1 > /dev/null 2>&1
                ;;
            opi3-lts)
                dd if=$TMPDIR/boot/u-boot-sunxi-with-spl-orangepi3-lts.bin of=${LDEV} conv=fsync bs=128k seek=1 > /dev/null 2>&1
                ;;
            pinephone)
                dd if=$TMPDIR/boot/u-boot-sunxi-with-spl-$DEVICE-528.bin of=${LDEV} conv=fsync bs=8k seek=1 > /dev/null 2>&1
                ;;

            # Rockchip RK33XX and RK35XX mainline U-Boots
            pbpro|rockpro64|rockpi4b|rockpi4c|nanopc-t4|rock64|roc-cc|stationp1|pinephonepro|clockworkpi-a06|quartz64-a|quartz64-b|soquartz-cm4|rock3a|pinenote|edgev|station-m2|station-p2|om1)
                dd if=$TMPDIR/boot/idbloader.img of=${LDEV} seek=64 conv=notrunc,fsync > /dev/null 2>&1
                dd if=$TMPDIR/boot/u-boot.itb of=${LDEV} seek=16384 conv=notrunc,fsync > /dev/null 2>&1
                ;;

            # Pinebook Pro BSP U-boot is no longer packaged, so download it directly from the GitLab
            pbpro-bsp)
                wget -q -N "https://gitlab.manjaro.org/manjaro-arm/packages/core/uboot-pinebookpro-bsp/-/raw/v1.24.126/idbloader.img" \
                     -O $TMPDIR/idbloader.img
                wget -q -N "https://gitlab.manjaro.org/manjaro-arm/packages/core/uboot-pinebookpro-bsp/-/raw/v1.24.126/uboot.img" \
                     -O $TMPDIR/uboot.img
                wget -q -N "https://gitlab.manjaro.org/manjaro-arm/packages/core/uboot-pinebookpro-bsp/-/raw/v1.24.126/trust.img" \
                     -O $TMPDIR/trust.img

                mkdir -p $TMPDIR/boot/extlinux
                wget -q -N "https://gitlab.manjaro.org/manjaro-arm/packages/core/uboot-pinebookpro-bsp/-/raw/v1.24.126/extlinux.conf" \
                     -O $TMPDIR/boot/extlinux/extlinux.conf

                dd if=$TMPDIR/idbloader.img of=${LDEV} seek=64 conv=notrunc,fsync > /dev/null 2>&1
                dd if=$TMPDIR/uboot.img of=${LDEV} seek=16384 conv=notrunc,fsync > /dev/null 2>&1
                dd if=$TMPDIR/trust.img of=${LDEV} seek=24576 conv=notrunc,fsync > /dev/null 2>&1
                rm $TMPDIR/{idbloader,uboot,trust}.img
                ;;

            # Rockchip RK35XX U-Boots
            quartz64-bsp)
                dd if=$TMPDIR/boot/idblock.bin of=${LDEV} seek=64 conv=notrunc,fsync > /dev/null 2>&1
                dd if=$TMPDIR/boot/uboot.img of=${LDEV}p1 conv=notrunc,fsync > /dev/null 2>&1
                ;;
        esac
    fi
    
    info "Writing PARTUUIDs..."
    if [[ "$DEVICE" = "quartz64-bsp" ]]; then
        BOOT_PART=$(lsblk -p -o NAME,PARTUUID | grep "${LDEV}p2" | awk '{print $2}')
        ROOT_PART=$(lsblk -p -o NAME,PARTUUID | grep "${LDEV}p3" | awk '{print $2}')
    else
        BOOT_PART=$(lsblk -p -o NAME,PARTUUID | grep "${LDEV}p1" | awk '{print $2}')
        ROOT_PART=$(lsblk -p -o NAME,PARTUUID | grep "${LDEV}p2" | awk '{print $2}')
    fi

    echo "Boot PARTUUID is $BOOT_PART..."
    #if [[ "$DEVICE" = "generic-efi" ]]; then
    #  sed -i "s@/boot@/boot/efi@g" $TMPDIR/root/etc/fstab
    #fi

    sed -i "s/LABEL=BOOT_MNJRO/PARTUUID=$BOOT_PART/g" $TMPDIR/root/etc/fstab
    echo "Root PARTUUID is $ROOT_PART..."

    if [ -f $TMPDIR/boot/extlinux/extlinux.conf ]; then
        sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/extlinux/extlinux.conf
        elif [ -f $TMPDIR/boot/efi/extlinux/extlinux.conf ]; then
            sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/efi/extlinux/extlinux.conf
        elif [ -f $TMPDIR/boot/boot.ini ]; then
            sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/boot.ini
        elif [ -f $TMPDIR/boot/uEnv.ini ]; then
            sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/uEnv.ini
        #elif [ -f $TMPDIR/boot/cmdline.txt ]; then
        #    sed -i "s/PARTUUID=/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/cmdline.txt
        #elif [ -f $TMPDIR/boot/boot.txt ]; then
        #   sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/boot/boot.txt
        #   cd $TMPDIR/boot
        #   ./mkscr
        #   cd $HOME
    fi
    
    if [[ "$DEVICE" = "rpi4" ]] && [[ "$FILESYSTEM" = "btrfs" ]]; then
        echo "===> Installing default btrfs RPi cmdline.txt /boot..."
        echo "rootflags=subvol=@ root=PARTUUID=$ROOT_PART rw rootwait console=serial0,115200 console=tty3 selinux=0 quiet splash plymouth.ignore-serial-consoles smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 usbhid.mousepoll=8 audit=0" > $TMPDIR/boot/cmdline.txt
    elif [[ "$DEVICE" = "rpi4" ]]; then
        echo "===> Installing default ext4 RPi cmdline.txt /boot..."
        echo "root=PARTUUID=$ROOT_PART rw rootwait console=serial0,115200 console=tty3 selinux=0 quiet splash plymouth.ignore-serial-consoles smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 usbhid.mousepoll=8 audit=0" >  $TMPDIR/boot/cmdline.txt
    elif [[ "$DEVICE" = "rpi4-cutiepi" ]]; then
        echo "===> Installing default ext4 RPi cmdline.txt /boot..."
        echo "console=tty1 root=PARTUUID=$ROOT_PART rootfstype=ext4 fsck.repair=yes rootwait plymouth.ignore-serial-consoles video=HDMI-A-2:D video=DSI-1:800x1280@60" > $TMPDIR/boot/cmdline.txt
    fi

    if [[ "$DEVICE" = "rpi4" ]]; then
        echo "===> Installing default config.txt file to /boot/..."
        echo "# See /boot/overlays/README for all available options" > $TMPDIR/boot/config.txt
        echo "" >> $TMPDIR/boot/config.txt
        echo "#gpu_mem=64" >> $TMPDIR/boot/config.txt
        echo "initramfs initramfs-linux.img followkernel" >> $TMPDIR/boot/config.txt
        echo "kernel=kernel8.img" >> $TMPDIR/boot/config.txt
        echo "arm_64bit=1" >> $TMPDIR/boot/config.txt
        echo "disable_overscan=1" >> $TMPDIR/boot/config.txt
        echo "dtparam=krnbt=on" >> $TMPDIR/boot/config.txt
        echo "" >> $TMPDIR/boot/config.txt
        echo "#enable sound" >> $TMPDIR/boot/config.txt
        echo "dtparam=audio=on" >> $TMPDIR/boot/config.txt
        echo "#hdmi_drive=2" >> $TMPDIR/boot/config.txt
        echo "" >> $TMPDIR/boot/config.txt
        echo "#enable vc4" >> $TMPDIR/boot/config.txt
        echo "dtoverlay=vc4-kms-v3d" >> $TMPDIR/boot/config.txt
        echo "max_framebuffers=2"  >> $TMPDIR/boot/config.txt
        echo "disable_splash=1" >> $TMPDIR/boot/config.txt
    fi
    
    if [[ "$FILESYSTEM" = "btrfs" ]]; then
        sed -i "s/LABEL=ROOT_MNJRO/PARTUUID=$ROOT_PART/g" $TMPDIR/root/etc/fstab
    else
        echo "PARTUUID=$ROOT_PART   /   $FILESYSTEM     defaults    0   1" >> $TMPDIR/root/etc/fstab
    fi
    
    ## TODO
    ## Figure out how to generate a working .efi file in our rootfs for the efi devices
    
    # Clean up
    info "Cleaning up image..."
    if [[ "$FILESYSTEM" = "btrfs" ]]; then
        umount $TMPDIR/root/home
    fi
    umount $TMPDIR/root
    #if [[ "$DEVICE" = "generic-efi" ]]; then
    #    umount $TMPDIR/boot/efi
    #else
        umount $TMPDIR/boot
    #fi

    losetup -d $LDEV > /dev/null 2>&1
    rm -r $TMPDIR/root $TMPDIR/boot
    partprobe $LDEV > /dev/null 2>&1
    chmod 0666 $IMGDIR/$IMGNAME.img
}

create_bmap() {
    if [ ! -e /usr/bin/bmaptool ]; then
        echo "'bmap-tools' package not installed, skipping"
    else
        info "Creating bmap..."
        cd ${IMGDIR}
        rm ${IMGNAME}.img.bmap 2>/dev/null
        bmaptool create -o ${IMGNAME}.img.bmap ${IMGNAME}.img
    fi
}

compress() {
    if [ -f $IMGDIR/$IMGNAME.img.xz ]; then
        info "Removing existing compressed image file $IMGNAME.img.xz..."
        rm -rf $IMGDIR/$IMGNAME.img.xz
    fi

    info "Compressing $IMGNAME.img..."
    # Compress the image
    cd $IMGDIR
    xz -zv --threads=0 $IMGNAME.img
    chmod 0666 $IMGDIR/$IMGNAME.img.xz

    info "Removing rootfs_$ARCH..."
    mount | grep "$ROOTFS_IMG/rootfs_$ARCH/var/cache/pacman/pkg" > /dev/null 2>&1
    STATUS=$?
    [ $STATUS -eq 0 ] && umount $ROOTFS_IMG/rootfs_$ARCH/var/cache/pacman/pkg
    rm -rf $CHROOTDIR
}

build_pkg() {
    # Install local packages to rootfs before building
    if [[ ! -z "${ADD_PACKAGES}" ]]; then
        local STATUS
        msg "Importing $ADD_PACKAGES local packages directory to rootfs..."
        $NSPAWN $CHROOTDIR mkdir -p local
        mount --bind "$(realpath $ADD_PACKAGES)" "$CHROOTDIR/local"
        $NSPAWN $CHROOTDIR pacman -U local/*.pkg.tar.* --noconfirm
        STATUS=$?
        umount "$CHROOTDIR/local"
        rm -rf "$CHROOTDIR/local"
        if [[ $STATUS != 0 ]]; then
            echo "Installing local packages failed, aborting"
            exit 1
        fi
    fi

    # Build the actual package
    msg "Importing $PACKAGE build directory to rootfs..."
    $NSPAWN $CHROOTDIR mkdir -p build
    mount --bind "$PACKAGE" "$CHROOTDIR/build"

    msg "Building $PACKAGE..."
    mount --bind $PKGDIR/pkg-cache $PKG_CACHE
    $NSPAWN $CHROOTDIR pacman -Syu --noconfirm > /dev/null 2>&1
    if [[ $INSTALL_NEW = true ]]; then
        $NSPAWN $CHROOTDIR --chdir=/build makepkg -Asci --noconfirm
    else
        $NSPAWN $CHROOTDIR --chdir=/build makepkg -Asc --noconfirm
    fi
}

export_and_clean() {
    if ls $CHROOTDIR/build/*.pkg.tar.* > /dev/null 2>&1; then
        # Pull package out of the rootfs
        msg "Building package succeeded..."
        mkdir -p $PKGDIR/$ARCH
        cp -a $CHROOTDIR/build/*.pkg.tar.* $PKGDIR/$ARCH
        chown -R $SUDO_USER $PKGDIR
        msg "Package saved as $PACKAGE in $PKGDIR/$ARCH..."
        umount $CHROOTDIR/build

        # Clean up the rootfs
        info "Cleaning build files from rootfs..."
        rm -rf $CHROOTDIR/build
    else
        # Build failed
        msg "Package $PACKAGE failed to build, aborting"
        umount $CHROOTDIR/build
        prune_cache
        rm -rf $CHROOTDIR/build
        exit 1
    fi
}

clone_profiles() {
    cd $PROFILES
    git clone --branch $1 https://gitlab.manjaro.org/manjaro-arm/applications/arm-profiles.git
}

get_profiles() {
    local BRANCH='master'

    if ls $PROFILES/arm-profiles/* > /dev/null 2>&1; then
        if [[ $(grep branch $PROFILES/arm-profiles/.git/config | cut -d\" -f2) = "$BRANCH" ]]; then
            cd $PROFILES/arm-profiles
            git pull
        else
            rm -rf $PROFILES/arm-profiles
            clone_profiles $BRANCH
        fi
    else
        clone_profiles $BRANCH
    fi
}

check_local_pkgs() {
    # Check for valid directory
    if [[ -z "${ADD_PACKAGES}" || ! -d "${ADD_PACKAGES}" ]]; then
        echo "No valid directory with local packages specified, aborting"
        exit 1
    fi
    if [[ "${ADD_PACKAGES}" == *"/"* ]]; then
        echo "Directory ${ADD_PACKAGES} not a valid path, aborting"
        exit 1
    fi
    if ! ls ${ADD_PACKAGES}/*.pkg.tar.* > /dev/null 2>&1; then
        echo "Directory ${ADD_PACKAGES} contains no packages, aborting"
        exit 1
    fi

    # Go through all package files in the directory
    local PACKAGE
    for PACKAGE in ${ADD_PACKAGES}/*.pkg.tar.*; do
        # Make sure it's a valid tar archive
        tar tf "${PACKAGE}" > /dev/null 2>&1
        if [[ $? != 0 ]]; then
            echo "Local package ${PACKAGE} not a valid tar archive"
            exit 1
        fi

        # Check does the archive contain .BUILDINFO
        tar xfp "$(realpath ${PACKAGE})" -C /tmp .BUILDINFO > /dev/null 2>&1
        if [[ $? != 0 || ! -f /tmp/.BUILDINFO ]]; then
            echo "Local package ${PACKAGE} invalid, no .BUILDINFO found"
            exit 1
        fi

        # Check the architecture and clean up
        local PACKAGE_ARCH=$(grep 'pkgarch' /tmp/.BUILDINFO | head -n 1)
        rm -f /tmp/.BUILDINFO

        if [[ ${PACKAGE_ARCH} == *"aarch64"* || ${PACKAGE_ARCH} == *"any"* ]]; then
            echo "Local package ${PACKAGE} verified and will be installed"
        else
            echo "Local package ${PACKAGE} not compatible with aarch64"
            exit 1
        fi
    done
}
