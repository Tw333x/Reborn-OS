#!/bin/bash

set -e -u

iso_name=spice
iso_label="SPICE_$(date +%Y%m)"
iso_version=$(date +%Y.%m.%d)
install_dir=arch
work_dir=work
out_dir=out
gpg_key=

arch=$(uname -m)
verbose=""
script_path=$(readlink -f ${0%/*})

_usage ()
{
    echo "usage ${0} [options]"
    echo
    echo " General options:"
    echo "    -N <iso_name>      Set an iso filename (prefix)"
    echo "                        Default: ${iso_name}"
    echo "    -V <iso_version>   Set an iso version (in filename)"
    echo "                        Default: ${iso_version}"
    echo "    -L <iso_label>     Set an iso label (disk label)"
    echo "                        Default: ${iso_label}"
    echo "    -D <install_dir>   Set an install_dir (directory inside iso)"
    echo "                        Default: ${install_dir}"
    echo "    -w <work_dir>      Set the working directory"
    echo "                        Default: ${work_dir}"
    echo "    -o <out_dir>       Set the output directory"
    echo "                        Default: ${out_dir}"
    echo "    -v                 Enable verbose output"
    echo "    -h                 This help message"
    exit ${1}
}

# Helper function to run make_*() only one time per architecture.
run_once() {
    if [[ ! -e ${work_dir}/build.${1}_${arch} ]]; then
        $1
        touch ${work_dir}/build.${1}_${arch}
    fi
}

# Setup custom pacman.conf with current cache directories.
make_pacman_conf() {
    local _cache_dirs
    _cache_dirs=($(pacman -v 2>&1 | grep '^Cache Dirs:' | sed 's/Cache Dirs:\s*//g'))
    sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.conf > ${work_dir}/pacman.conf
}

# Base installation, plus needed packages (airootfs)
make_basefs() {
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" init
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "haveged intel-ucode memtest86+ mkinitcpio-nfs-utils nbd" install
}

# Additional packages (airootfs)
make_packages() {
     setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "$(grep -h -v ^# ${script_path}/packages.{both,${arch}})" install
}

# Needed packages for x86_64 EFI boot
make_packages_efi() {
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "prebootloader" install
}
# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    local _hook
    mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
    mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/install
    for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
        cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
        cp /usr/lib/initcpio/install/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/install
    done
    sed -i "s|/usr/lib/initcpio/|/etc/initcpio/|g" ${work_dir}/${arch}/airootfs/etc/initcpio/install/archiso_shutdown
    cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/${arch}/airootfs/etc/initcpio/install
    cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/${arch}/airootfs/etc/initcpio
    cp ${script_path}/mkinitcpio.conf ${work_dir}/${arch}/airootfs/etc/mkinitcpio-archiso.conf
    gnupg_fd=
    if [[ ${gpg_key} ]]; then
      gpg --export ${gpg_key} >${work_dir}/gpgkey
      exec 17<>${work_dir}/gpgkey
    fi
    ARCHISO_GNUPG_FD=${gpg_key:+17} setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux -g /boot/archiso.img' run
    if [[ ${gpg_key} ]]; then
      exec 17<&-
    fi
}
# Customize installation (airootfs)
make_customize_airootfs() {
    echo
    echo ">>> Installing iso-hotfix-utility..."
    wget "${ISO_HOTFIX_UTILITY_URL}" -O ${SCRIPT_PATH}/iso-hotfix-utility.tar.gz
    tar xfz ${SCRIPT_PATH}/iso-hotfix-utility.tar.gz -C ${SCRIPT_PATH}
    rm -f ${SCRIPT_PATH}/iso-hotfix-utility.tar.gz
    mv "${SCRIPT_PATH}/iso-hotfix-utility-${ISO_HOTFIX_UTILITY_VERSION}" ${SCRIPT_PATH}/iso-hotfix-utility
    cp "${SCRIPT_PATH}/iso-hotfix-utility/iso-hotfix-utility" "${ROOTFS}/usr/bin/pacman-boot"
    chmod 755 "${ROOTFS}/usr/bin/pacman-boot"
    mkdir -p "${ROOTFS}/etc/iso-hotfix-utility.d"
    for _file in ${SCRIPT_PATH}/iso-hotfix-utility/dist/**
    do
        install -m755 -t "${ROOTFS}/etc/iso-hotfix-utility.d" "${_file}"
    done
    for fpath in ${SCRIPT_PATH}/iso-hotfix-utility/po/*; do
        if [[ -f "${fpath}" ]] && [[ "${fpath}" != 'po/CNCHI_UPDATER.pot' ]]; then
            STRING_PO=`echo ${fpath#*/}`
            STRING=`echo ${STRING_PO%.po}`
            mkdir -p "${ROOTFS}/usr/share/locale/${STRING}/LC_MESSAGES"
            msgfmt "${fpath}" -o "${ROOTFS}/usr/share/locale/${STRING}/LC_MESSAGES/CNCHI_UPDATER.mo"
            echo "${STRING} installed..."
        fi
    done
    rm -rf ${SCRIPT_PATH}/iso-hotfix-utility
}
####################################################################################
# Install cnchi installer from Git
make_cnchi() {
    echo
    echo ">>> Warning! Installing Cnchi Installer from GIT (${CNCHI_GIT_BRANCH} branch)"
    wget "${CNCHI_GIT_URL}" -O ${SCRIPT_PATH}/cnchi-git.zip
    unzip ${SCRIPT_PATH}/cnchi-git.zip -d ${SCRIPT_PATH}
    rm -f ${SCRIPT_PATH}/cnchi-git.zip
    CNCHI_SRC="${SCRIPT_PATH}/Cnchi-${CNCHI_GIT_BRANCH}"
    install -d ${ROOT_FS}/usr/share/{cnchi,locale}
	install -Dm755 "${CNCHI_SRC}/bin/cnchi" "${ROOT_FS}/usr/bin/cnchi"
	install -Dm755 "${CNCHI_SRC}/cnchi.desktop" "${ROOT_FS}/usr/share/applications/cnchi.desktop"
	install -Dm644 "${CNCHI_SRC}/data/images/antergos/antergos-icon.png" "${ROOT_FS}/usr/share/pixmaps/cnchi.png"
    # TODO: This should be included in Cnchi's src code as a separate file
    # (as both files are needed to run cnchi)
    sed -r -i 's|\/usr.+ -v|pkexec /usr/share/cnchi/bin/cnchi -s bugsnag|g' "${ROOT_FS}/usr/bin/cnchi"
    for i in ${CNCHI_SRC}/cnchi ${CNCHI_SRC}/bin ${CNCHI_SRC}/data ${CNCHI_SRC}/scripts ${CNCHI_SRC}/ui; do
        cp -R ${i} "${ROOT_FS}/usr/share/cnchi/"
    done
    for files in ${CNCHI_SRC}/po/*; do
        if [ -f "$files" ] && [ "$files" != 'po/cnchi.pot' ]; then
            STRING_PO=`echo ${files#*/}`
            STRING=`echo ${STRING_PO%.po}`
            mkdir -p ${ROOT_FS}/usr/share/locale/${STRING}/LC_MESSAGES
            msgfmt $files -o ${ROOT_FS}/usr/share/locale/${STRING}/LC_MESSAGES/cnchi.mo
            echo "${STRING} installed..."
        fi
    done
}
########################################################################################
# Prepare kernel/initramfs ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/${arch}
    cp ${work_dir}/${arch}/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/${arch}/archiso.img
    cp ${work_dir}/${arch}/airootfs/boot/vmlinuz-linux ${work_dir}/iso/${install_dir}/boot/${arch}/vmlinuz
}
# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    cp ${work_dir}/${arch}/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    cp ${work_dir}/${arch}/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
    cp ${work_dir}/${arch}/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
    cp ${work_dir}/${arch}/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE
}
# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
    for _cfg in ${script_path}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done
    cp ${script_path}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/${arch}/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/${arch}/airootfs/usr/lib/modules/*-ARCH/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
# Enable services
        MKARCHISO_RUN 'systemctl -fq enable pacman-init'
        if [ -f "${ROOTFS}/etc/systemd/system/livecd.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable livecd'
        fi
        MKARCHISO_RUN 'systemctl -fq enable systemd-networkd'
        if [ -f "${ROOTFS}/usr/lib/systemd/system/NetworkManager.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable NetworkManager NetworkManager-wait-online'
        fi
        if [ -f "${ROOTFS}/etc/systemd/system/livecd-alsa-unmuter.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable livecd-alsa-unmuter'
        fi
        if [ -f "${ROOTFS}/etc/systemd/system/vboxservice.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable vboxservice'
        fi
        MKARCHISO_RUN 'systemctl -fq enable ModemManager'
        MKARCHISO_RUN 'systemctl -fq enable upower'
        if [ -f "${SCRIPT_PATH}/plymouthd.conf" ]; then
            MKARCHISO_RUN 'systemctl -fq enable plymouth-start'
        fi
        if [ -f "${ROOTFS}/etc/systemd/system/lightdm.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable lightdm'
            chmod +x ${ROOTFS}/etc/lightdm/Xsession
        fi
        if [ -f "${ROOTFS}/etc/systemd/system/gdm.service" ]; then
            MKARCHISO_RUN 'systemctl -fq enable gdm'
            chmod +x ${ROOTFS}/etc/gdm/Xsession
        fi
        # Disable pamac if present
        if [ -f "${ROOTFS}/usr/lib/systemd/system/pamac.service" ]; then
            MKARCHISO_RUN 'systemctl -fq disable pamac pamac-cleancache.timer pamac-mirrorlist.timer'
        fi
        # Enable systemd-timesyncd (ntp)
        MKARCHISO_RUN 'systemctl -fq enable systemd-timesyncd'
        # Fix /home permissions
        MKARCHISO_RUN 'chown -R antergos:users /home/antergos'
        # Setup gsettings if gsettings folder exists
        if [ -d ${SCRIPT_PATH}/gsettings ]; then
            # Copying GSettings XML schema files
            mkdir -p ${ROOTFS}/usr/share/glib-2.0/schemas
            for _schema in ${SCRIPT_PATH}/gsettings/*.gschema.override; do
                echo ">>> Will use ${_schema}"
                cp ${_schema} ${ROOTFS}/usr/share/glib-2.0/schemas
            done
            # Compile GSettings XML schema files
            MKARCHISO_RUN '/usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas'
        fi
        # BEGIN Pacstrap/Pacman bug where hooks are not run inside the chroot
        if [ -f ${ROOTFS}/usr/bin/update-ca-trust ]; then
            MKARCHISO_RUN '/usr/bin/update-ca-trust'
        fi
        if [ -f ${ROOTFS}/usr/bin/update-desktop-database ]; then
            MKARCHISO_RUN '/usr/bin/update-desktop-database --quiet'
        fi
        if [ -f ${ROOTFS}/usr/bin/update-mime-database ]; then
            MKARCHISO_RUN '/usr/bin/update-mime-database /usr/share/mime'
        fi
        if [ -f ${ROOTFS}/usr/bin/gdk-pixbuf-query-loaders ]; then
            MKARCHISO_RUN '/usr/bin/gdk-pixbuf-query-loaders --update-cache'
        fi
}
# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${script_path}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}
# Prepare /EFI
make_efi() {
    mkdir -p ${work_dir}/iso/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/PreLoader.efi ${work_dir}/iso/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/HashTool.efi ${work_dir}/iso/EFI/boot/
    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/iso/EFI/boot/loader.efi
    mkdir -p ${work_dir}/iso/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/iso/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/iso/loader/entries/
    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${script_path}/efiboot/loader/entries/archiso-x86_64-usb.conf > ${work_dir}/iso/loader/entries/archiso-x86_64.conf
    # EFI Shell 2.0 for UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v2.efi https://raw.githubusercontent.com/tianocore/edk2/master/ShellBinPkg/UefiShell/X64/Shell.efi
    # EFI Shell 1.0 for non UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v1.efi https://raw.githubusercontent.com/tianocore/edk2/master/EdkShellBinPkg/FullShell/X64/Shell_Full.efi
}
# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    mkdir -p ${work_dir}/iso/EFI/archiso
    truncate -s 40M ${work_dir}/iso/EFI/archiso/efiboot.img
    mkfs.vfat -n ARCHISO_EFI ${work_dir}/iso/EFI/archiso/efiboot.img
    mkdir -p ${work_dir}/efiboot
    mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot
    mkdir -p ${work_dir}/efiboot/EFI/archiso
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img
    cp ${work_dir}/iso/${install_dir}/boot/intel_ucode.img ${work_dir}/efiboot/EFI/archiso/intel_ucode.img
    mkdir -p ${work_dir}/efiboot/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/PreLoader.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/HashTool.efi ${work_dir}/efiboot/EFI/boot/
    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/efiboot/EFI/boot/loader.efi
    mkdir -p ${work_dir}/efiboot/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/efiboot/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/efiboot/loader/entries/
    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${script_path}/efiboot/loader/entries/archiso-x86_64-cd.conf > ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
    cp ${work_dir}/iso/EFI/shellx64_v2.efi ${work_dir}/efiboot/EFI/
    cp ${work_dir}/iso/EFI/shellx64_v1.efi ${work_dir}/efiboot/EFI/
    umount -d ${work_dir}/efiboot
}
# Build airootfs filesystem image
make_prepare() {
    cp -a -l -f ${work_dir}/${arch}/airootfs ${work_dir}
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" ${gpg_key:+-g ${gpg_key}} prepare
    rm -rf ${work_dir}/airootfs
    # rm -rf ${work_dir}/${arch}/airootfs (if low space, this helps)
}
# Build ISO
make_iso() {
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -o "${out_dir}" iso "${iso_name}-${iso_version}-x86_64.iso"
}
if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root."
    _usage 1
fi
if [[ ${arch} != x86_64 ]]; then
    echo "This script needs to be run on x86_64"
    _usage 1
fi
while getopts 'N:V:L:D:w:o:g:vh' arg; do
    case "${arg}" in
        N) iso_name="${OPTARG}" ;;
        V) iso_version="${OPTARG}" ;;
        L) iso_label="${OPTARG}" ;;
        D) install_dir="${OPTARG}" ;;
        w) work_dir="${OPTARG}" ;;
        o) out_dir="${OPTARG}" ;;
        g) gpg_key="${OPTARG}" ;;
        v) verbose="-v" ;;
        h) _usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           _usage 1
           ;;
    esac
done
mkdir -p ${work_dir}
run_once make_pacman_conf

for arch in x86_64; do
    run_once make_basefs
    run_once make_packages
done
run_once make_packages_efi
for arch in x86_64; do
    run_once make_setup_mkinitcpio
    run_once make_customize_airootfs
    run_once make_cnchi
done
for arch in x86_64; do
    run_once make_boot
done
# Do all stuff for "iso
run_once make_boot_extra
run_once make_syslinux
run_once make_isolinux
run_once make_efi
run_once make_efiboot

for arch in x86_64; do
    run_once make_prepare
done
run_once make_iso