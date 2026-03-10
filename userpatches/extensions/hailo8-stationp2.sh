#!/bin/bash

LOG_NAME="station-p2"

function post_install_kernel_debs__hailo8_initramfs() {
    display_alert "Hailo8: Adding firmware to initramfs" "station-p2" "info"
    
    # Create initramfs hook in the target rootfs
    cat > "${SDCARD}/etc/initramfs-tools/hooks/hailo8" << 'INITRAMFS'
#!/bin/sh

PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac

. /usr/share/initramfs-tools/hook-functions

# Copy firmware to initramfs
if [ -f /lib/firmware/hailo/hailo8_fw.bin ]; then
    mkdir -p ${DESTDIR}/lib/firmware/hailo
    cp /lib/firmware/hailo/hailo8_fw.bin ${DESTDIR}/lib/firmware/hailo/
    echo "Hailo firmware added to initramfs" >> ${DESTDIR}/initramfs-debug.log
fi
INITRAMFS

    chmod +x "${SDCARD}/etc/initramfs-tools/hooks/hailo8"
    
    # Update initramfs in the target
    chroot "${SDCARD}" /bin/bash -c "update-initramfs -u"
    
    display_alert "Hailo8: Initramfs updated with firmware" "station-p2" "ok"
}

function extension_prepare_config__hailo8_001() {
    display_alert "Hailo8: Adding dependencies" "station-p2" "info"
    
    # Add build dependencies - these will be installed on the build host
    # Note: These are for the build system, not the target
    HOSTPACKAGES="$HOSTPACKAGES cmake build-essential"
    
    # Add target dependencies (will be installed in the image)
    add_packages_to_image dkms libssl-dev libopencv-dev build-essential

    display_alert "Hailo8: Ensuring cmake is installed on build host" "station-p2" "info"
    
    # Check if we're in Docker and install cmake if needed
    if [[ -f /.dockerenv ]]; then
        display_alert "Hailo8: Running in Docker, installing cmake" "station-p2" "ext"
        
        # Update package list and install cmake
        apt-get update
        apt-get install -y cmake build-essential
        
        if command -v cmake &> /dev/null; then
            display_alert "Hailo8: cmake installed successfully" "$(cmake --version | head -1)" "ok"
        else
            display_alert "Hailo8: Failed to install cmake" "Check network/mirrors" "err"
            return 1
        fi
    else
        # Not in Docker, check if cmake is available
        if ! command -v cmake &> /dev/null; then
            display_alert "Hailo8: cmake not found!" "Please install: sudo apt install cmake" "err"
            return 1
        else
            display_alert "Hailo8: cmake found" "$(cmake --version | head -1)" "ok"
        fi
    fi
}

# In your extension, add these to the build environment
function pre_install_kernel_debs__hailo_python_deps() {
    display_alert "Hailo8: Installing Python bindings dependencies" "station-p2" "info"

    HOSTPACKAGES="$HOSTPACKAGES python3-dev python3-pip python3-venv python3-numpy python3-pybind11"
}

function post_install_kernel_debs__build_hailo8_driver_cross() {
    display_alert "Hailo8 cross compilation" ${LOG_NAME} "info"

    local worktree_base="${SRC}/cache/sources/linux-kernel-worktree"

    local arch="arm64"
    local kernel_version="${KERNELVERSION:-$(ls ${SDCARD}/lib/modules | head -1)}"
    local major_minor="${kernel_version%.*}"
    local kernel_build_dir="${worktree_base}/${major_minor}__${LINUXFAMILY}__${arch}"
    local fw_version="4.23.0"

    local hailo_driver_dir="${SRC}/cache/sources/hailort-drivers"
    
    display_alert "Cross-compiling for kernel: ${kernel_version}" ${LOG_NAME} "info"

    # Clone or update Hailo-8 driver
    if [[ ! -d "${hailo_driver_dir}" ]]; then
        display_alert "Cloning Hailo-8 driver" ${LOG_NAME} "info"
        run_host_command_logged git clone --depth 1 --branch hailo8  \
                  https://github.com/hailo-ai/hailort-drivers.git \
                  "${hailo_driver_dir}"
    else
        display_alert "Updating Hailo-8 driver" ${LOG_NAME} "info"
        cd "${hailo_driver_dir}" && git pull
    fi
    
    # Build the driver using kernel build directory
    cd "${hailo_driver_dir}"
    run_host_command_logged ./download_firmware.sh

    chroot "${SDCARD}" /bin/bash -c "mkdir -p /lib/firmware/hailo"
    run_host_command_logged cp "${hailo_driver_dir}/hailo8_fw.${fw_version}.bin" "${SDCARD}/lib/firmware/hailo/"
    run_host_command_logged cp "${hailo_driver_dir}/hailo8_fw.${fw_version}.bin" "${SDCARD}/lib/firmware/hailo/hailo8_fw.bin"
    
    # Set cross-compilation environment
    export ARCH=${arch}
    export CROSS_COMPILE=aarch64-linux-gnu-
    export KERNELDIR="${kernel_build_dir}"

    # Build the module
    make -C "${kernel_build_dir}" M="${hailo_driver_dir}/linux/pcie" modules

    # Check if module was built successfully
    if [[ -f "${hailo_driver_dir}/linux/pcie/hailo_pci.ko" ]]; then
        display_alert "Hailo8 module built successfully" ${LOG_NAME} "info"
        
        # Create modules directory in the target rootfs if it doesn't exist
        local target_modules_dir="${SDCARD}/lib/modules/${kernel_version}/kernel/drivers/net/"
        run_host_command_logged mkdir -p "${target_modules_dir}"
        
        # Install the .ko file to the target rootfs
        display_alert "Installing Hailo8 module to target rootfs" ${LOG_NAME} "info"
        run_host_command_logged cp "${hailo_driver_dir}/linux/pcie/hailo_pci.ko" "${target_modules_dir}/"
        
        # Set proper permissions
        run_host_command_logged chmod 644 "${target_modules_dir}/hailo_pci.ko"
        
        # Update module dependencies in target rootfs
        display_alert "Updating module dependencies" ${LOG_NAME} "info"
        chroot "${SDCARD}" /sbin/depmod -a "${kernel_version}"
        
        # Verify installation
        if [[ -f "${SDCARD}/lib/modules/${kernel_version}/kernel/drivers/net/hailo_pci.ko" ]]; then
            display_alert "Hailo8 module installed successfully" ${LOG_NAME} "info"
        else
            display_alert "Hailo8 module installation failed" ${LOG_NAME} "err"
        fi
    else
        display_alert "Hailo8 module build failed" ${LOG_NAME} "err"
        return 1
    fi
    
    # Load the module on boot (optional)
    display_alert "Configuring Hailo8 module to load on boot" ${LOG_NAME} "info"
    
    # Create or append to modules-load.d configuration
    local modules_load_conf="${SDCARD}/etc/modules-load.d/hailo_pci.conf"
    echo "hailo_pci" | run_host_command_logged tee "${modules_load_conf}"
    
    # Create modprobe configuration if needed (optional)
    local modprobe_conf="${SDCARD}/etc/modprobe.d/hailo_pci.conf"
    echo "# Hailo8 module options" | run_host_command_logged tee "${modprobe_conf}"
    
    display_alert "Hailo8 driver installation complete" ${LOG_NAME} "info"

    # RT

    local hailo_src_dir="${SRC}/cache/sources/hailort"
    # Clone HailoRT repository (hailo8 branch for Hailo-8 support)
    if [[ ! -d "${hailo_src_dir}" ]]; then
        display_alert "Cloning HailoRT repository" "hailo8" "ext"
        run_host_command_logged git clone --depth 1 --branch hailo8 \
            https://github.com/hailo-ai/hailort.git "${hailo_src_dir}"
    fi

   # Create build directory
    local build_dir="${hailo_src_dir}/build"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    
    # Configure and build for ARM64
    cd "${build_dir}"

    display_alert "Configuring HailoRT build" "hailo8" "ext"
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="${CROSS_COMPILE}gcc" \
        -DCMAKE_CXX_COMPILER="${CROSS_COMPILE}g++" \
        -DCMAKE_LINKER="${CROSS_COMPILE}ld" \
        -DCMAKE_C_FLAGS="-D_GNU_SOURCE -D_FORTIFY_SOURCE=2 --sysroot=${SDCARD} -std=gnu17" \
        -DCMAKE_CXX_FLAGS="-D_GNU_SOURCE -D_FORTIFY_SOURCE=2 --sysroot=${SDCARD} -std=gnu++17" \
        -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
        -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
        -DCMAKE_FIND_ROOT_PATH="${SDCARD}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DHAILO_BUILD_EXAMPLES=ON

    if [[ $? -ne 0 ]]; then
        display_alert "Hailo8: CMake configuration failed" "Check dependencies" "err"
        return 1
    fi
    
    display_alert "Hailo8: Building with cross-compilation" "hailo8" "ext"
    make -j$(nproc)
    
    if [[ $? -ne 0 ]]; then
        display_alert "Hailo8: Build failed" "Check errors above" "err"
        return 1
    fi
    
    # Create package structure
    local package_dir="${hailo_src_dir}/hailo8-package"
    rm -rf "${package_dir}"
    mkdir -p "${package_dir}/DEBIAN"
    local deb_dir="${package_dir}/DEBIAN"
    mkdir -p "${deb_dir}"
    
    # Install to package directory (using DESTDIR for cross-compilation)
    make install DESTDIR="${package_dir}"

    # Create Debian control file
    cat <<- EOF > "${deb_dir}/control"
Package: hailo8-all
Version: 4.27.0-${REVISION}
Architecture: arm64
Maintainer: Armbian User <user@example.com>
Description: Hailo-8 AI Accelerator driver and runtime
 Built from source for kernel ${kernel_version}
Depends: dkms, build-essential, libopencv-dev
EOF
    
    # Build the package
    cd "${hailo_src_dir}"
    dpkg-deb -b "hailo8-package" "${DEB_STORAGE}/hailo8-all_arm64.deb"
    
    display_alert "Hailo-8 package created" "${DEB_STORAGE}/hailo8-all_arm64.deb" "info"

    display_alert "Installing Hailo-8 package" "hailo8" "info"

    # wget https://hailo-hailort.s3.eu-west-2.amazonaws.com/arm64/debian12/hailort_4.23.0_arm64.deb

    # cp hailort_4.23.0_arm64.deb ${DEB_STORAGE}/hailo8-all_arm64.deb
    
    if [[ -f "${DEB_STORAGE}/hailo8-all_arm64.deb" ]]; then
        cp "${DEB_STORAGE}/hailo8-all_arm64.deb" "${SDCARD}/tmp/"
        chroot "${SDCARD}" /bin/bash -c "dpkg -i /tmp/hailo8-all_arm64.deb || true"
        chroot "${SDCARD}" /bin/bash -c "apt-get install -f -y"
        rm -f "${SDCARD}/tmp/hailo8-all_arm64.deb"
    fi
}

# Helper function to copy toolchain libs
function post_install_kernel_debs__copy_complete_glibc() {
    display_alert "Hailo8: Copying complete glibc suite from toolchain" "station-p2" "info"
    
    local TOOLCHAIN_LIB_DIR="/usr/aarch64-linux-gnu/lib"
    local TARGET_LIB_DIR="${SDCARD}/opt/hailo-libs"
    
    mkdir -p "${TARGET_LIB_DIR}"
    
    # Copy ALL glibc components, not just libc.so.6
    local GLIBC_COMPONENTS=(
        # Core libraries
        "libc.so.6"
        "libc-*.so"
        "ld-linux-aarch64.so.1"
        "ld-*.so"
        
        # Essential libraries
        "libm.so.6"
        "libm-*.so"
        "libpthread.so.0"
        "libpthread-*.so"
        "libdl.so.2"
        "libdl-*.so"
        "librt.so.1"
        "librt-*.so"
        "libresolv.so.2"
        "libresolv-*.so"
        "libnss_files.so.2"
        "libnss_files-*.so"
        "libnss_dns.so.2"
        "libnss_dns-*.so"
        
        # C++ and GCC support
        "libstdc++.so.6"
        "libstdc++.so.*"
        "libgcc_s.so.1"
    )
    
    # Copy each component (using wildcards)
    for pattern in "${GLIBC_COMPONENTS[@]}"; do
        find "${TOOLCHAIN_LIB_DIR}" -name "${pattern}" -exec cp -vf {} "${TARGET_LIB_DIR}/" \; 2>/dev/null || true
    done
    
    # Also copy the dynamic linker if it exists in different locations
    find "${TOOLCHAIN_LIB_DIR}" -name "ld-linux-aarch64.so.1" -o -name "ld-*.so" \
        -exec cp -vf {} "${TARGET_LIB_DIR}/" \; 2>/dev/null || true
    
    # Create a version script to verify
    cat > "${TARGET_LIB_DIR}/README.txt" << 'EOF'
GLIBC SUITE for Hailo-8
Copied from toolchain. Use with:
    export LD_LIBRARY_PATH=/opt/hailo-libs:$LD_LIBRARY_PATH
    /opt/hailo-libs/ld-linux-aarch64.so.1 /usr/bin/hailortcli
EOF
    
    display_alert "Complete glibc suite copied" "aa" "ok"
}

function post_install_kernel_debs__create_hailo_runner() {
    display_alert "Hailo8: Creating runner with custom dynamic linker" "station-p2" "info"
    
    local TARGET_LIB_DIR="${SDCARD}/opt/hailo-libs"
    local TOOLCHAIN_LINKER="/usr/aarch64-linux-gnu/lib/ld-linux-aarch64.so.1"
    
    # Copy the dynamic linker
    if [[ -f "${TOOLCHAIN_LINKER}" ]]; then
        cp -v "${TOOLCHAIN_LINKER}" "${TARGET_LIB_DIR}/"
    else
        # Try to find it
        find /usr -name "ld-linux-aarch64.so.1" -exec cp -v {} "${TARGET_LIB_DIR}/" \; 2>/dev/null
    fi
    
    # Create a wrapper that uses the correct linker and library path
    cat > "${SDCARD}/usr/local/bin/hailo-run" << 'EOF'
#!/bin/bash
# Use custom dynamic linker and libraries for Hailo

HAILO_LIBS="/opt/hailo-libs"
HOST_LIBS="/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu"

# First try with custom linker and library path
if [[ -f "${HAILO_LIBS}/ld-linux-aarch64.so.1" ]]; then
    exec "${HAILO_LIBS}/ld-linux-aarch64.so.1" \
        --library-path "${HAILO_LIBS}:${HOST_LIBS}" \
        /usr/bin/hailortcli "$@"
else
    # Fallback to standard method
    export LD_LIBRARY_PATH="${HAILO_LIBS}:${LD_LIBRARY_PATH}"
    exec /usr/bin/hailortcli "$@"
fi
EOF
    
    chmod +x "${SDCARD}/usr/local/bin/hailo-run"
    
    # Also create a simple alias
    echo "alias hailortcli='/usr/local/bin/hailo-run'" >> "${SDCARD}/root/.bashrc"
    
    display_alert "Hailo runner created" "Use 'hailo-run' or 'hailortcli' (after login)" "ok"
}

function post_install_kernel_debs__build_hailo_python_bindings() {
    display_alert "Hailo8: Building Python bindings from source" "station-p2" "info"
    
    local hailo_src_dir="${SRC}/cache/sources/hailort"
    local python_bindings_dir="${hailo_src_dir}/hailort/libhailort/bindings/python/platform"
    
    if [[ ! -d "${python_bindings_dir}" ]]; then
        display_alert "Python bindings directory not found" "hailo8" "err"
        return 1
    fi
    
    # Copy entire source to image (needed for the build)
    cp -r "${hailo_src_dir}" "${SDCARD}/tmp/hailo-src"
    
    chroot "${SDCARD}" /bin/bash << 'CHROOT'
        # Create symlink to satisfy the build script
        ln -sf /tmp/hailo-src /tmp/src
        
        # Install dependencies
        apt-get update
        apt-get install -y git python3-dev python3-pip python3-pybind11 \
            python3-numpy cmake build-essential python3-opencv
        
        # Build and install Python bindings
        cd /tmp/hailo-src/hailort/libhailort/bindings/python/platform
        python3 setup.py build_ext --inplace
        python3 setup.py install
        
        # Verify installation
        /opt/hailo-libs/ld-linux-aarch64.so.1 --library-path /opt/hailo-libs /usr/bin/python3 -c "import hailo_platform; print('Success!')"

        # For next
        /opt/hailo-libs/ld-linux-aarch64.so.1 --library-path /opt/hailo-libs /usr/bin/python3 -m venv /root/hailo-env

        # Clean up
        cd / && rm -rf /tmp/hailo-src /tmp/src
CHROOT
    
    display_alert "Hailo8 Python bindings installed" "station-p2" "ok"
}