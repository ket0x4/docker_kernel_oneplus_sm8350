#!/bin/bash
#
#	Build to lahaina - ./compile.sh --device=lahaina --compiler=clang
# 	or
#	./compile.sh --device=lahaina --compiler=gcc
#	or
#	./compile.sh --device=lahaina --compiler=clang --compiler32=gcc
#
#	To toolbox (https://containertoolbx.org/):
#	toolbox create --distro fedora --release XX
#	toolbox enter fedora-toolbox-xx
#	toolbox rm fedora-toolbox-xx
#
#	Android Kernel Build Script to k5.x
#

############################################################################
blue='\033[0;34m'
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
green='\e[0;32m'
cyan='\033[0;36m'

msg() {
    echo -e "${green}>> $*${white}"
}

err() {
    echo -e "${red}ERROR: $*${white}"
    exit 1
}

inform() {
    echo -e "${cyan}INFO: $*${white}"
}

# --- Core Cloning and Setup Functions ---

clone_toolchain() {
    msg "Cloning toolchain..."
    local dirtoolchains="toolchains"
    mkdir -p "$dirtoolchains"
    cd "$dirtoolchains" || exit

    # Download WeebX Clang only if 'clang' directory doesn't exist
    if [[ ! -d "clang" ]]; then
        msg "Downloading Weebx Clang..."
        wget "$(curl -s https://raw.githubusercontent.com/XSans0/WeebX-Clang/main/main/link.txt)" -O "weebx-clang.tar.gz"
        mkdir -p clang
        tar -xf weebx-clang.tar.gz -C clang --strip-components=1
        rm -f weebx-clang.tar.gz
        msg "Weebx Clang successfully extracted to 'clang' directory."
    else
        inform "'clang' directory already exists, skipping download."
    fi
    cd ..
}

clone_anykernel() {
	msg "Cloning AnyKernel3..."
	local ANYKERNEL3_DIR="AnyKernel3"
	local REPO_URL="https://github.com/ket0x4/AnyKernel3"
	local BRANCH="Docker-KSU"

	if [[ ! -d "$ANYKERNEL3_DIR" ]]; then
		inform "$ANYKERNEL3_DIR not found, cloning from $REPO_URL ($BRANCH branch)..."
		git clone --depth=1 "$REPO_URL" -b "$BRANCH" "$ANYKERNEL3_DIR"
	else
		inform "$ANYKERNEL3_DIR already exists, skipping clone."
	fi

	cd "$ANYKERNEL3_DIR" || exit
	ANYK_VERSION=$(git rev-parse --abbrev-ref HEAD)
	inform "Using AnyKernel version: $ANYK_VERSION"
	cd ..
}

# --- Configuration and Build ---

# Constants and Variables
export TZ=America/Sao_Paulo
export KBUILD_USER="Ket0x4"
export KBUILD_HOST="Devbox"

KERNEL_DIR=$(pwd)
TLDR="$KERNEL_DIR/toolchains"
AK3_DIR="$KERNEL_DIR/AnyKernel3"
DTB_PATH="$KERNEL_DIR/work/arch/arm64/boot/dts"
DTBO_PATH="$KERNEL_DIR/work/arch/arm64/boot"

muke() {
    make "$@" "${MAKE_ARGS[@]}"
}

compiler_setup() {
    msg "Setting up compiler..."
    local C_PATH="$TLDR/clang"

    # Build arguments for Clang
    MAKE_ARGS=(
        "O=work"
        "ARCH=arm64"
        "LLVM=1"
        "LLVM_IAS=1"
        "CC=clang"
        "CROSS_COMPILE=aarch64-linux-gnu-"
        "CROSS_COMPILE_COMPAT=arm-linux-gnueabi-"
        "HOSTLD=ld.lld"
        "PATH=$C_PATH/bin:$PATH"
        "KBUILD_BUILD_USER=$KBUILD_USER"
        "KBUILD_BUILD_HOST=$KBUILD_HOST"
    )

    local C_NAME
    C_NAME=$("$C_PATH"/bin/clang --version | head -n 1)
    inform "Compiler: $C_NAME"
}

config_generator() {
    if [[ -z $CODENAME ]]; then
        err 'Device codename (--device) not specified.'
    fi

    local DFCF="vendor/${CODENAME}-${SUFFIX}_defconfig"
    if [[ ! -f "arch/arm64/configs/$DFCF" ]]; then
        err "Defconfig file not found: arch/arm64/configs/$DFCF"
    fi

    inform "Generating .config file from defconfig..."
    muke "$DFCF"
}

kernel_builder() {
    msg "Starting kernel build process..."

    local BUILD_START
    BUILD_START=$(date +"%s")

    inform "Build started. Device: $DEVICENAME, Kernel: $(muke kernelrelease -s)"
    muke -j"$(nproc)"

    if grep -q "CONFIG_MODULES=y" "work/.config"; then
        muke -j"$(nproc)" modules_install INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="modules"
    fi

    local BUILD_END
    BUILD_END=$(date +"%s")
    local DIFF=$((BUILD_END - BUILD_START))

    inform "Build finished. Duration: $((DIFF / 60)) minutes, $((DIFF % 60)) seconds."
    zipper
}

zipper() {
    msg "Creating flashable ZIP package..."
    local TARGET="arch/arm64/boot/Image"

    if [[ ! -f "$KERNEL_DIR/work/$TARGET" ]]; then
        err 'Kernel image file (Image) not found.'
    fi
    if [[ ! -d "$AK3_DIR" ]]; then
        err 'AnyKernel3 directory not found.'
    fi

    # Clean AnyKernel3 directory and copy files
    rm -rf "$AK3_DIR"/*.zip "$AK3_DIR"/Image "$AK3_DIR"/dtb

    cp "$KERNEL_DIR/work/$TARGET" "$AK3_DIR/"
    find "$DTB_PATH"/vendor/*/* -name '*.dtb' -exec cat {} + > "$AK3_DIR"/dtb
    mv -f "$DTBO_PATH"/*.img "$AK3_DIR" 2>/dev/null

    # Copy modules
    if grep -q "CONFIG_MODULES=y" "work/.config"; then
        local MOD_NAME
        MOD_NAME=$(muke kernelrelease -s)
        local MOD_PATH="work/modules/lib/modules/$MOD_NAME"
        mkdir -p "$AK3_DIR/modules/vendor/lib/modules"
        cp -r "$MOD_PATH"/* "$AK3_DIR/modules/vendor/lib/modules/"
    fi

    cd "$AK3_DIR" || exit

    local MOBILEDEVICE
    if [ "$CODENAME" = "lahaina" ]; then
                MOBILEDEVICE="op9x"
        else
            MOBILEDEVICE="${CODENAME}"
        fi

    local BUILD_TIME
    BUILD_TIME=$(date +"%d%m%Y-%H%M")
    local ZIP_NAME="${ANYK_VERSION}-${MOBILEDEVICE}-${BUILD_TIME}"

    zip -r9 "${ZIP_NAME}.zip" ./*
    java -jar zipsigner-3.0.jar "${ZIP_NAME}.zip" "${ZIP_NAME}-signed.zip"

    inform "ZIP package successfully created and signed: ${yellow}${ZIP_NAME}-signed.zip${white}"

    # Move the signed ZIP to the main 'out' folder
    mkdir -p "$KERNEL_DIR/out"
    mv "${ZIP_NAME}-signed.zip" "$KERNEL_DIR/out/"

    cd "$KERNEL_DIR" || exit
}

# --- Main Execution Flow ---

# Argument Parsing
if [[ -z "$*" ]]; then
    echo "Usage: $0 --device=<device_name> [--clean]"
    exit 1
fi

for arg in "$@"; do
    case "${arg}" in
        "--device="*)
            CODE_NAME=${arg#*=}
            case $CODE_NAME in
                lahaina)
                    DEVICENAME='lahaina common qgki kernel'
                    CODENAME='lahaina'
                    SUFFIX='qgki'
                    ;;
                *)
                    err "Unsupported device: $CODE_NAME"
                    ;;
            esac
            ;;
        "--clean")
            BUILD='clean'
            ;;
    esac
done

# Cleanup, Clones, and Setup
msg "Cleaning up old build artifacts..."
rm -rf out/ error.log

clone_toolchain
clone_anykernel
compiler_setup

# Handle --clean option
if [[ $BUILD == "clean" ]]; then
    inform "Cleaning up build directory..."
    muke clean && muke mrproper
fi

# Generate .config from defconfig
config_generator

# Ask user for menuconfig
read -p "Do you want to run menuconfig? (y/N): " menu_choice
if [[ "$menu_choice" =~ ^[Yy]$ ]]; then
    msg "Launching menuconfig..."
    muke menuconfig
    inform "Menuconfig closed. Proceeding with the build..."
fi

# Build the kernel with the (possibly modified) .config
kernel_builder

msg "All operations completed successfully."
