#!/bin/bash

# Exit on errors
set -e

echo "What kernel version would you like? (choose a number 1-3)"
echo "This can be any ChromeOS kernel branch, but the recommended versions are:"
printf "1: chromeos-5.10:\n  (Kernel version that is up-to-date and has good audio support with SOF)\n"
printf "2: alt-chromeos-5.10:\n  (Kernel version that is up-to-date but is pinned to a commit that supports KBL/SKL devices which do not support SOF)\n"
printf "3: chromeos-5.4:\n  (Often causes more issues despite being a commonly-used kernel in ChromeOS)\n"

read KERNEL_VERSION

case $KERNEL_VERSION in
    "1"|"chromeos-5.10")     KERNEL_VERSION="chromeos-5.10"     ;;
    "2"|"alt-chromeos-5.10") KERNEL_VERSION="alt-chromeos-5.10" ;;
    "3"|"chromeos-5.4")      KERNEL_VERSION="chromeos-5.4"      ;;
    *) echo "Please supply a valid kernel version"; exit ;;
esac

echo "Cloning kernel $KERNEL_VERSION"

# Latest commit tested for 5.10: 142ef9297957f6df8a08f75d772ae8a5448c6f6c

if [[ $KERNEL_VERSION == "alt-chromeos-5.10" ]]; then
    git clone --branch $KERNEL_VERSION --single-branch https://chromium.googlesource.com/chromiumos/third_party/kernel.git $KERNEL_VERSION
    git checkout $(git rev-list -n 1 --first-parent --before="2021-08-1 23:59" $KERNEL_VERSION)
else
    git clone --branch $KERNEL_VERSION --single-branch --depth 1 https://chromium.googlesource.com/chromiumos/third_party/kernel.git $KERNEL_VERSION || true
fi

cd $KERNEL_VERSION

echo "Patching the kernel"
git apply ../patches/* || true
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
