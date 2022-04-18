#!/bin/bash

sudo apt install -y netpbm imagemagick git build-essential ncurses-dev xz-utils libssl-dev bc flex libelf-dev bison cgpt vboot-kernel-utils

# Exit on errors
set -e

if [[ $# -eq 0 ]]; then
    
    echo "What kernel version would you like? (choose a number 1-3)"
    echo "This can be any ChromeOS kernel branch, but the recommended versions are:"
    printf "1: chromeos-5.10:\n  (Kernel version that is up-to-date and has good audio support with SOF)\n"
    printf "2: alt-chromeos-5.10:\n  (Kernel version that is up-to-date but is pinned to a commit that supports KBL/SKL devices which do not support SOF)\n"
    printf "3: chromeos-5.4:\n  (Often causes more issues despite being a commonly-used kernel in ChromeOS)\n"
    echo "Older kernels that may provide better support for specific boards:"
    printf "4: chromeos-4.19:\n  (For testing purposes)\n"
    printf "5: chromeos-4.14:\n  (For testing purposes)\n"
    printf "6: chromeos-4.4:\n  (For testing purposes; too old for Mesa3D and some other Linux userspace software)\n"
    echo "Newer kernels that are not widely used within ChromeOS devices:"
    printf "7: chromeos-5.15:\n  (Similar version to those used in Linux distributions, not used in any ChromeOS devices currently)\n"

    read KERNEL_VERSION

else

    export KERNEL_VERSION=$1

fi

case $KERNEL_VERSION in
    "1"|"chromeos-5.10")     KERNEL_VERSION="chromeos-5.10"     ;;
    "2"|"alt-chromeos-5.10") KERNEL_VERSION="alt-chromeos-5.10" ;;
    "3"|"chromeos-5.4")      KERNEL_VERSION="chromeos-5.4"      ;;
    "4"|"chromeos-4.19")     KERNEL_VERSION="chromeos-4.19"     ;;
    "5"|"chromeos-4.14")     KERNEL_VERSION="chromeos-4.14"     ;;
    "6"|"chromeos-4.4")      KERNEL_VERSION="chromeos-4.4"      ;;
    "7"|"chromeos-5.15")      KERNEL_VERSION="chromeos-5.15"    ;;
    *) echo "Please supply a valid kernel version"; exit ;;
esac

echo "Cloning kernel $KERNEL_VERSION"

# Latest commit tested for 5.10: 142ef9297957f6df8a08f75d772ae8a5448c6f6c

if [[ $KERNEL_VERSION == "alt-chromeos-5.10" ]]; then
    git clone --branch chromeos-5.10 --single-branch https://chromium.googlesource.com/chromiumos/third_party/kernel.git $KERNEL_VERSION
    cd $KERNEL_VERSION
    git checkout $(git rev-list -n 1 --first-parent --before="2021-08-1 23:59" chromeos-5.10)
else
    git clone --branch $KERNEL_VERSION --single-branch --depth 1 https://chromium.googlesource.com/chromiumos/third_party/kernel.git $KERNEL_VERSION || true
fi

(
    # Bootlogo not working for now
    cd logo
    mogrify -format ppm "logo.png"
    ppmquant 224 logo.ppm > logo_224.ppm
    pnmnoraw logo_224.ppm > logo_final.ppm
)

cd $KERNEL_VERSION

echo "Patching the kernel"
cp ../logo/logo_final.ppm drivers/video/logo/logo_linux_clut224.ppm
# A somewhat commonly-used device, lesser priority than JSL i915
git apply ../patches/bloog-audio.patch --ignore-space-change --ignore-whitespace --recount || true
# Super important patch, adds support for Jasperlake (many DEDEDE devices)
git apply ../patches/jsl-i915.patch --ignore-space-change --ignore-whitespace --recount -C1 || exit
echo "mod" >> .gitignore
touch .scmversion

echo "Copying and updating kernel config"

if [[ $KERNEL_VERSION == "alt-chromeos-5.10" ]]; then
    BZIMAGE="bzImage.alt"
    MODULES="modules.alt.tar.xz"
    ls .config || cp ../../kernel.alt.conf .config || exit
else
    BZIMAGE="bzImage"
    MODULES="modules.tar.xz"
    ls .config || cp ../../kernel.conf .config || exit
fi

make olddefconfig

if [[ -v PS1 ]]; then

    read -p "Would you like to make edits to the kernel config? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        make menuconfig
    fi

    read -p "Would you like to write the new config to github? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [[ $KERNEL_VERSION == "alt-chromeos-5.10" ]]; then
            cp .config ../../kernel.alt.conf
        else
            cp .config ../../kernel.conf
        fi
    fi

    echo "Building kernel"
    read -p "Would you like a full rebuild? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        make clean; make -j$(nproc) || exit
    else
        make -j$(nproc) || exit
    fi
    
else

    make -j$(nproc)

fi

echo "bzImage and modules built"

cp arch/x86/boot/bzImage ../$BZIMAGE
echo "bzImage created!"

futility --debug vbutil_kernel \
    --arch x86_64 --version 1 \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --bootloader ../kernel.flags \
    --config ../kernel.flags \
    --vmlinuz ../bzImage \
    --pack ../bzImage.signed
echo "Signed bzImage created\!" # Shell expansion weirdness

rm -rf mod || true
mkdir mod
make -j8 modules_install INSTALL_MOD_PATH=mod

# Creates an archive containing /lib/modules/...
cd mod
tar cvfJ ../../$MODULES lib/
cd ..
echo "modules.tar.xz created!"

echo "Command to extract modules to USB:"
echo "sudo rm -rf /mnt/lib/modules/* && sudo cp -Rv kernel/mod/lib/modules/* /mnt/lib/modules && sync"
