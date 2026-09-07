#!/bin/bash
# =============================================================================
# 交叉编译脚本：在 x86_64 上为 RK3566 Armbian (aarch64) 编译支持硬件加速的 wiliwili
# =============================================================================
# 说明：
#   1. 使用 debootstrap 创建 arm64 sysroot，安装所有构建依赖 (基于 Ubuntu 24.04 Noble)
#   2. 交叉编译 jernejsk 的 FFmpeg (v4l2-request 补丁)
#   3. 交叉编译 mpv (使用稳定版 v0.39.0，链接到自定义 FFmpeg)
#   4. 交叉编译 wiliwili (链接到自定义 mpv)
#   5. 输出打包到 out/ 目录，可直接复制到 RK3566 板子运行
#
# 用法：
#   ./build.sh [选项]
#   不带参数默认执行全部流程。
#   源码、sysroot、编译缓存和产物默认放在脚本所在目录（当前工程目录）。
# =============================================================================

set -e
set -o pipefail

# ---------------------------------------------------------------------------
# 用户可配置区域
# ---------------------------------------------------------------------------
# 工作目录：脚本所在目录。可用环境变量 WORK_DIR 覆盖。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}}"
JOBS="$(nproc)"                             # 并行编译任务数
UBUNTU_RELEASE="resolute"                   # sysroot 基础发行版 (noble=24.04)
                                            # 注意：sysroot 的 glibc 不能新于目标板，否则板上无法运行
TOOLCHAIN_PREFIX="aarch64-linux-gnu"        # 交叉编译工具链前缀
MPV_VERSION="v0.41.0"                       # mpv 稳定版本 tag
# ---------------------------------------------------------------------------

SYSROOT="${WORK_DIR}/sysroot"
OUT_DIR="${WORK_DIR}/out"
HOST_CC="/usr/bin/${TOOLCHAIN_PREFIX}-gcc"
HOST_CXX="/usr/bin/${TOOLCHAIN_PREFIX}-g++"
HOST_AR="/usr/bin/${TOOLCHAIN_PREFIX}-ar"
HOST_STRIP="/usr/bin/${TOOLCHAIN_PREFIX}-strip"
HOST_MAKE="/usr/bin/make"
SYSROOT_PKGDIR="${SYSROOT}/usr/local/lib/pkgconfig:${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die() { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 帮助信息
# ---------------------------------------------------------------------------
usage() {
    cat << EOF
用法: $0 [选项]

选项:
  --all               执行全部流程 (默认行为)
  --sysroot           仅检查并创建 sysroot (若已存在则跳过)
  --rebuild-sysroot   删除现有 sysroot 并完全重建 (含 apt 环境)
  --update-sysroot    在现有 sysroot 中更新/追加安装依赖 (不删除现有数据)
  --clean             清理编译缓存与 sysroot 中自行编译的内容后重新编译
                      (FFmpeg/mpv/wiliwili 及 /usr/local；apt 环境不变)
  --ffmpeg            仅编译 FFmpeg
  --mpv               仅编译 mpv（已存在则跳过）
  --rebuild-mpv       删除 mpv/build 后重新配置并编译（音频/硬解变更后需要）
  --wiliwili          仅编译 wiliwili
  --rebuild-wiliwili  删除 wiliwili/build 后重新配置并编译
  -h, --help          显示此帮助信息

补丁（可回溯）:
  mpv:      patches/series
  wiliwili: patches/wiliwili.series
  以 # 开头的行会被跳过；从 series 拿掉的补丁会自动反向打回。
  回到 copy 硬解:     注释 series 里 zerocopy 补丁后 --rebuild-mpv
  回到 1080p60 抖动:  注释 wiliwili.series 对应补丁后 --rebuild-wiliwili
  回到 git 基线:      git revert HEAD  或  git checkout 2d8e3da

示例:
  $0                          # 完整编译
  $0 --update-sysroot         # 仅更新 sysroot 中的依赖包
  $0 --clean                  # 清编译环境后重编 (保留 sysroot apt)
  $0 --mpv                    # 仅重新编译 mpv
  $0 --rebuild-mpv            # 补丁或音频变更后强制重编 mpv
  $0 --rebuild-wiliwili       # 清掉旧 CMake 缓存后重编 wiliwili
EOF
}

# ---------------------------------------------------------------------------
# 0. 检查并安装主机依赖
# ---------------------------------------------------------------------------
install_host_deps() {
    info "检查并安装主机构建依赖..."
    sudo apt-get update
    sudo apt-get install -y \
        crossbuild-essential-arm64 \
        qemu-user-static binfmt-support debootstrap \
        cmake meson ninja-build pkg-config \
        git wget curl python3 \
        symlinks || warn "symlinks 安装失败，将使用备用方案修复软链接"

    if [ ! -x "${HOST_CC}" ] || [ ! -x "${HOST_CXX}" ]; then
        die "未找到主机交叉编译器 ${HOST_CC}。请确认已安装 crossbuild-essential-arm64"
    fi

    # 必须跟随符号链接看真实 ELF。否则 file 会输出
    # "symbolic link to aarch64-linux-gnu-gcc-13"，被误判成 aarch64 二进制。
    local cc_real cc_file
    cc_real="$(readlink -f "${HOST_CC}" 2>/dev/null || echo "${HOST_CC}")"
    if command -v file >/dev/null 2>&1; then
        cc_file="$(file -bL "${HOST_CC}" 2>/dev/null || file -b "${cc_real}" 2>/dev/null || true)"
    else
        cc_file=""
    fi

    if echo "${cc_file}" | grep -qiE 'ARM aarch64|, aarch64,'; then
        die "主机交叉编译器 ${HOST_CC} -> ${cc_real} 是 aarch64 二进制，不能用于交叉编译。file 输出: ${cc_file}"
    fi

    if [ -n "${cc_file}" ] && ! echo "${cc_file}" | grep -qiE 'x86-64|x86_64|Intel 80386'; then
        warn "无法从 file 输出确认架构，继续尝试。file 输出: ${cc_file}"
    fi
    info "主机交叉编译器: ${HOST_CC} -> ${cc_real}${cc_file:+ (${cc_file})}"
}

# ---------------------------------------------------------------------------
# 1. 创建 arm64 sysroot (debootstrap)
# ---------------------------------------------------------------------------
create_sysroot() {
    if [ -d "${SYSROOT}/usr/bin" ]; then
        info "Sysroot 已存在，跳过创建。如需重建请使用 --rebuild-sysroot"
        return
    fi

    info "创建 arm64 sysroot (基于 ${UBUNTU_RELEASE})..."
    sudo mkdir -p "${SYSROOT}"

    sudo debootstrap \
        --arch=arm64 \
        --variant=minbase \
        --include=ca-certificates \
        "${UBUNTU_RELEASE}" \
        "${SYSROOT}" \
        http://ports.ubuntu.com/ubuntu-ports/ || die "debootstrap 失败"

    sudo cp /usr/bin/qemu-aarch64-static "${SYSROOT}/usr/bin/"

    install_sysroot_deps

    sudo rm -f "${SYSROOT}/usr/bin/qemu-aarch64-static"
}

# ---------------------------------------------------------------------------
# 1.1 在 sysroot 中安装/更新依赖
# ---------------------------------------------------------------------------
install_sysroot_deps() {
    info "在 sysroot 中安装/更新构建依赖..."

    if [ -f "${SYSROOT}/etc/apt/sources.list" ]; then
        sudo sed -i 's/^deb \(.*\) main$/deb \1 main universe/' "${SYSROOT}/etc/apt/sources.list"
    fi
    if [ -d "${SYSROOT}/etc/apt/sources.list.d" ]; then
        sudo find "${SYSROOT}/etc/apt/sources.list.d" -type f -name '*.sources' -print0 2>/dev/null \
            | sudo xargs -0 -r sed -i 's/Components: main$/Components: main universe/'
    fi

    sudo cp /usr/bin/qemu-aarch64-static "${SYSROOT}/usr/bin/"
    sudo chroot "${SYSROOT}" apt-get update

    sudo chroot "${SYSROOT}" apt-get install -y symlinks 2>/dev/null || warn "symlinks 包不可用"

    # 只装目标架构的开发库。不要依赖 sysroot 里的 gcc/make 做交叉编译。
    sudo chroot "${SYSROOT}" apt-get install -y \
        pkg-config \
        libcurl4-openssl-dev libwebp-dev libass-dev \
        libboost-filesystem-dev \
        libdrm-dev libudev-dev libv4l-dev \
        libgl1-mesa-dev libgles2-mesa-dev \
        libwayland-dev wayland-protocols \
        wayland-scanner++ librust-wayland-scanner-dev \
        libx11-dev libxinerama-dev \
        libxpresent-dev libxcursor-dev libxi-dev \
        libxrandr-dev libxss-dev libxt-dev libxv-dev \
        libxkbcommon-dev libfreetype6-dev \
        lua5.4 liblua5.4-dev lua5.2 liblua5.2-dev \
        libuchardet-dev libplacebo-dev \
        libdisplay-info-dev \
        libgnutls28-dev libdvdnav-dev \
        libegl1-mesa-dev libgbm-dev \
        libdbus-1-dev libssl-dev libmbedtls-dev \
        zlib1g-dev \
        libasound2-dev libpulse-dev libpipewire-0.3-dev \
        || die "安装 sysroot 依赖失败"

    fix_sysroot_symlinks
}

# ---------------------------------------------------------------------------
# 1.2 修复 sysroot 中的绝对路径软链接
# ---------------------------------------------------------------------------
fix_sysroot_symlinks() {
    info "修复 sysroot 中的绝对路径软链接..."
    if command -v symlinks >/dev/null 2>&1; then
        sudo chroot "${SYSROOT}" symlinks -cr / 2>/dev/null || true
    fi

    sudo bash -c "
        find ${SYSROOT} -type l -print0 | while IFS= read -r -d '' link; do
            target=\$(readlink \"\$link\")
            if [[ \"\$target\" == /* ]]; then
                real_target=\"${SYSROOT}\$target\"
                if [ -e \"\$real_target\" ]; then
                    dir=\$(dirname \"\$link\")
                    rel=\$(python3 -c \"import os.path; print(os.path.relpath('\$real_target', '\$dir'))\" 2>/dev/null || echo \"\$target\")
                    ln -sf \"\$rel\" \"\$link\"
                fi
            fi
        done
    "
}

# ---------------------------------------------------------------------------
# 1.3 更新现有的 sysroot (热更新依赖)
# ---------------------------------------------------------------------------
update_sysroot() {
    if [ ! -d "${SYSROOT}/usr/bin" ]; then
        warn "Sysroot 不存在，将执行完整创建流程..."
        create_sysroot
        return
    fi

    info "更新现有 sysroot 中的依赖..."
    sudo cp /usr/bin/qemu-aarch64-static "${SYSROOT}/usr/bin/"

    install_sysroot_deps

    sudo rm -f "${SYSROOT}/usr/bin/qemu-aarch64-static"
    info "Sysroot 依赖更新完成！"
}

# ---------------------------------------------------------------------------
# 1.4 清理编译环境（保留 sysroot apt，不重建 debootstrap）
# ---------------------------------------------------------------------------
# 删除：各组件源码树内的编译缓存、sysroot/usr/local 中自行编译安装的
# FFmpeg/mpv、以及 out/ 产物。
# 保留：sysroot 的 debootstrap 根文件系统与 apt 已装依赖、已克隆的源码。
clean_compile_env() {
    info "清理编译环境（保留 sysroot apt 依赖）..."

    if [ -d "${WORK_DIR}/FFmpeg" ]; then
        info "清理 FFmpeg 编译缓存..."
        if [ -f "${WORK_DIR}/FFmpeg/Makefile" ]; then
            make -C "${WORK_DIR}/FFmpeg" distclean >/dev/null 2>&1 || true
        fi
    fi

    if [ -d "${WORK_DIR}/mpv/build" ]; then
        info "清理 mpv 编译缓存..."
        rm -rf "${WORK_DIR}/mpv/build"
    fi

    if [ -d "${WORK_DIR}/wiliwili/build" ]; then
        info "清理 wiliwili 编译缓存..."
        rm -rf "${WORK_DIR}/wiliwili/build"
    fi

    # FFmpeg/mpv 的 --prefix 都是 sysroot/usr/local；apt 包在 /usr，互不重叠
    if [ -d "${SYSROOT}/usr/local" ]; then
        info "清理 sysroot 中的编译安装内容: ${SYSROOT}/usr/local"
        sudo rm -rf "${SYSROOT}/usr/local"
        sudo mkdir -p "${SYSROOT}/usr/local"
    fi

    if [ -e "${OUT_DIR}" ]; then
        info "清理输出目录: ${OUT_DIR}"
        rm -rf "${OUT_DIR}"
    fi

    info "编译环境已清理完毕（sysroot apt 环境未改动）"
}

# ---------------------------------------------------------------------------
# 2. 生成交叉编译配置文件
# ---------------------------------------------------------------------------
generate_toolchain_files() {
    info "生成交叉编译配置文件..."

    cat > "${WORK_DIR}/aarch64-toolchain.cmake" << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_SYSROOT ${SYSROOT})

# 必须使用主机上的交叉编译器（x86_64 ELF），禁止搜到 sysroot 里的 aarch64 gcc
set(CMAKE_C_COMPILER ${HOST_CC})
set(CMAKE_CXX_COMPILER ${HOST_CXX})
set(CMAKE_AR ${HOST_AR} CACHE FILEPATH "")
set(CMAKE_STRIP ${HOST_STRIP} CACHE FILEPATH "")
set(CMAKE_MAKE_PROGRAM ${HOST_MAKE} CACHE FILEPATH "")
set(CMAKE_ASM_COMPILER ${HOST_CC})

set(CMAKE_FIND_ROOT_PATH ${SYSROOT} ${SYSROOT}/usr/local)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

# 不要用 STATIC_LIBRARY 做 try-compile：check_library_exists() 会因此
# 误判成功，bundled curl/cpr 会把 -lsocket -liconv 加进链接行。
# glibc 的 socket/iconv 都在 libc 里，Linux 上没有这两个独立库。
set(Iconv_IS_BUILT_IN TRUE)
set(HAVE_LIBSOCKET FALSE CACHE BOOL "" FORCE)
set(HAVE_LIBICONV FALSE CACHE BOOL "" FORCE)
set(HAVE_ICONV TRUE CACHE BOOL "" FORCE)

set(PKG_CONFIG_EXECUTABLE ${WORK_DIR}/cross-pkg-config)
EOF

    cat > "${WORK_DIR}/aarch64-cross.ini" << EOF
[binaries]
c = '${HOST_CC}'
cpp = '${HOST_CXX}'
ar = '${HOST_AR}'
strip = '${HOST_STRIP}'
pkg-config = '${WORK_DIR}/cross-pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'

[built-in options]
c_args = ['--sysroot=${SYSROOT}']
cpp_args = ['--sysroot=${SYSROOT}']
c_link_args = ['--sysroot=${SYSROOT}']
cpp_link_args = ['--sysroot=${SYSROOT}']

[properties]
sys_root = '${SYSROOT}'
pkg_config_libdir = '${SYSROOT_PKGDIR}'
EOF

    cat > "${WORK_DIR}/cross-pkg-config" << EOF
#!/bin/bash
export PKG_CONFIG_DIR=
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR="${SYSROOT_PKGDIR}"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
exec pkg-config "\$@"
EOF
    chmod +x "${WORK_DIR}/cross-pkg-config"
}

# ---------------------------------------------------------------------------
# 3. 设置交叉编译环境变量
# ---------------------------------------------------------------------------
setup_env() {
    export CC="${HOST_CC}"
    export CXX="${HOST_CXX}"
    export AR="${HOST_AR}"
    export STRIP="${HOST_STRIP}"
    export PKG_CONFIG="${WORK_DIR}/cross-pkg-config"
    export PKG_CONFIG_DIR=""
    export PKG_CONFIG_PATH=""
    export PKG_CONFIG_LIBDIR="${SYSROOT_PKGDIR}"
    export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
    export CFLAGS="--sysroot=${SYSROOT} -I${SYSROOT}/usr/include"
    export CXXFLAGS="--sysroot=${SYSROOT} -I${SYSROOT}/usr/include"
    export LDFLAGS="--sysroot=${SYSROOT} -L${SYSROOT}/usr/local/lib -L${SYSROOT}/usr/lib/aarch64-linux-gnu -L${SYSROOT}/lib/aarch64-linux-gnu"
    # 兜底：万一仍有 aarch64 ELF 被 binfmt 拉起，让 qemu 去 sysroot 找动态链接器
    export QEMU_LD_PREFIX="${SYSROOT}"
}

# ---------------------------------------------------------------------------
# 4. 交叉编译 FFmpeg
# ---------------------------------------------------------------------------
build_ffmpeg() {
    local src="${WORK_DIR}/FFmpeg"
    if [ -f "${SYSROOT}/usr/local/lib/libavcodec.so" ]; then
        info "FFmpeg 已编译安装到 sysroot，跳过"
        return
    fi

    info "下载 jernejsk 的 FFmpeg (v4l2-request 补丁)..."
    [ -d "${src}" ] || git clone -b v4l2-request-n7.1 --depth 1 \
        https://github.com/jernejsk/FFmpeg.git "${src}"

    cd "${src}"
    info "配置 FFmpeg (交叉编译)..."

    ./configure \
        --prefix="${SYSROOT}/usr/local" \
        --enable-cross-compile \
        --cross-prefix="${TOOLCHAIN_PREFIX}-" \
        --arch=arm64 \
        --target-os=linux \
        --sysroot="${SYSROOT}" \
        --pkg-config="${WORK_DIR}/cross-pkg-config" \
        --extra-cflags="${CFLAGS}" \
        --extra-ldflags="${LDFLAGS}" \
        --enable-shared \
        --disable-static \
        --enable-v4l2-request \
        --enable-libdrm \
        --enable-libudev \
        --enable-gnutls \
        --enable-gpl \
        --disable-doc \
        --enable-asm \
        --enable-neon \
        --disable-programs \
        --disable-debug || die "FFmpeg configure 失败"

    info "编译 FFmpeg..."
    make -j"${JOBS}" || die "FFmpeg 编译失败"
    make install || die "FFmpeg 安装失败"
    make distclean || true
}

# ---------------------------------------------------------------------------
# 5. 交叉编译 mpv
# ---------------------------------------------------------------------------
# 读取 patches/series 中未注释的补丁名，写入 MPV_SERIES_PATCHES。
read_mpv_series() {
    local series="${WORK_DIR}/patches/series"
    local line name
    MPV_SERIES_PATCHES=()
    [ -f "${series}" ] || die "缺少补丁序列: ${series}"
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        case "${line}" in
            ''|\#*) continue ;;
        esac
        name="${line%%#*}"
        name="${name%"${name##*[![:space:]]}"}"
        [ -n "${name}" ] || continue
        MPV_SERIES_PATCHES+=("${name}")
    done < "${series}"
    [ "${#MPV_SERIES_PATCHES[@]}" -gt 0 ] || die "patches/series 中没有有效补丁"
}

mpv_git_apply() {
    git -c "safe.directory=${1}" apply --whitespace=nowarn "${@:2}"
}

# 补丁是否已经打在 src 上。
mpv_patch_applied() {
    local src="$1" patch="$2"
    (cd "${src}" && mpv_git_apply "${src}" --reverse --check "${patch}") >/dev/null 2>&1
}

mpv_patch_can_apply() {
    local src="$1" patch="$2"
    (cd "${src}" && mpv_git_apply "${src}" --check "${patch}") >/dev/null 2>&1
}

apply_one_mpv_patch() {
    local src="$1" patch="$2" name
    name="$(basename "${patch}")"
    [ -f "${patch}" ] || die "缺少 mpv 补丁: ${patch}"
    if mpv_patch_applied "${src}" "${patch}"; then
        info "补丁已应用，跳过: ${name}"
        return 0
    fi
    if mpv_patch_can_apply "${src}" "${patch}"; then
        info "应用补丁: ${name}"
        (cd "${src}" && mpv_git_apply "${src}" "${patch}") || die "应用补丁失败: ${name}"
        PATCHES_CHANGED=true
        return 0
    fi
    die "补丁无法应用（既不是未打也不是已打）: ${name}"
}

reverse_one_mpv_patch() {
    local src="$1" patch="$2" name
    name="$(basename "${patch}")"
    [ -f "${patch}" ] || return 0
    if mpv_patch_applied "${src}" "${patch}"; then
        info "按 series 回滚补丁: ${name}"
        (cd "${src}" && mpv_git_apply "${src}" --reverse "${patch}") || die "回滚补丁失败: ${name}"
        PATCHES_CHANGED=true
    fi
}

apply_mpv_patches() {
    local src="${WORK_DIR}/mpv"
    local patch_dir="${WORK_DIR}/patches"
    local name patch wanted found i

    PATCHES_CHANGED=false
    [ -d "${src}" ] || die "mpv 源码不存在: ${src}"
    if [ ! -w "${src}/video/out/hwdec/hwdec_drmprime.c" ]; then
        die "mpv 源码不可写（属主多半是 root）。请先: sudo chown -R \"$(id -un):$(id -gn)\" \"${src}\""
    fi

    apply_named_patch_series "${src}" "${WORK_DIR}/patches/series" "${patch_dir}/mpv-*.patch"
}

apply_named_patch_series() {
    local src="$1" series="$2" glob="$3"
    local name patch wanted found i extra_patches=()
    local -a listed=()

    local line
    [ -f "${series}" ] || die "缺少补丁序列: ${series}"
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        case "${line}" in
            ''|\#*) continue ;;
        esac
        name="${line%%#*}"
        name="${name%"${name##*[![:space:]]}"}"
        [ -n "${name}" ] || continue
        listed+=("${name}")
    done < "${series}"
    [ "${#listed[@]}" -gt 0 ] || die "${series} 中没有有效补丁"

    for patch in ${glob}; do
        [ -f "${patch}" ] || continue
        name="$(basename "${patch}")"
        found=false
        for wanted in "${listed[@]}"; do
            if [ "${wanted}" = "${name}" ]; then
                found=true
                break
            fi
        done
        if [ "${found}" = false ]; then
            extra_patches+=("${patch}")
        fi
    done
    for ((i = ${#extra_patches[@]} - 1; i >= 0; i--)); do
        reverse_one_mpv_patch "${src}" "${extra_patches[$i]}"
    done
    for name in "${listed[@]}"; do
        apply_one_mpv_patch "${src}" "${WORK_DIR}/patches/${name}"
    done
}

apply_wiliwili_patches() {
    local src="${WORK_DIR}/wiliwili"
    PATCHES_CHANGED=false
    [ -d "${src}" ] || die "wiliwili 源码不存在: ${src}"
    if [ ! -w "${src}/wiliwili/source/view/mpv_core.cpp" ]; then
        die "wiliwili 源码不可写（属主多半是 root）。请先: sudo chown -R \"$(id -un):$(id -gn)\" \"${src}\""
    fi
    apply_named_patch_series "${src}" "${WORK_DIR}/patches/wiliwili.series" "${WORK_DIR}/patches/wiliwili-*.patch"
}

build_mpv() {
    local src="${WORK_DIR}/mpv"
    local force_rebuild="${1:-false}"

    info "下载 mpv 源码 (稳定版 ${MPV_VERSION})..."
    [ -d "${src}" ] || git clone --depth 1 --branch "${MPV_VERSION}" https://github.com/mpv-player/mpv.git "${src}"

    apply_mpv_patches
    if [ "${PATCHES_CHANGED}" = true ]; then
        warn "mpv 补丁有变化，将重新编译"
        force_rebuild=true
    fi

    if [ "${force_rebuild}" != "true" ] && [ -f "${SYSROOT}/usr/local/lib/libmpv.so" ]; then
        if [ -f "${src}/build/config.h" ] && grep -q '^#define HAVE_PULSE 1' "${src}/build/config.h" \
            && grep -q 'v4l2request' "${src}/video/decode/vd_lavc.c" 2>/dev/null; then
            info "mpv 已编译安装到 sysroot（含 Pulse 与 v4l2request），跳过"
            return
        fi
        warn "已有 mpv，但缺少 Pulse 音频或 v4l2request 硬解，将重新编译"
        force_rebuild=true
    fi

    if [ "${force_rebuild}" = "true" ]; then
        info "强制重建 mpv，删除旧 build 目录..."
        rm -rf "${src}/build"
    fi

    cd "${src}"
    info "配置 mpv (meson 交叉编译)..."

    meson setup build \
        --cross-file "${WORK_DIR}/aarch64-cross.ini" \
        --prefix="${SYSROOT}/usr/local" \
        --pkg-config-path="${SYSROOT}/usr/local/lib/pkgconfig" \
        -Dlibmpv=true \
        -Dbuild-date=false \
        -Dlua=enabled \
        -Ddrm=enabled \
        -Dwayland=enabled \
        -Dx11=enabled \
        -Dgl=enabled \
        -Degl-drm=enabled \
        -Dalsa=enabled \
        -Dpulse=enabled \
        -Dpipewire=enabled || die "mpv meson 配置失败"

    if ! grep -q '^#define HAVE_PULSE 1' "${src}/build/config.h"; then
        die "mpv 未启用 Pulse。请先运行: $0 --update-sysroot"
    fi
    if ! grep -q '^#define HAVE_ALSA 1' "${src}/build/config.h"; then
        die "mpv 未启用 ALSA。请先运行: $0 --update-sysroot"
    fi

    info "编译 mpv..."
    ninja -C build || die "mpv 编译失败"
    ninja -C build install || die "mpv 安装失败"
}

# ---------------------------------------------------------------------------
# 6. 交叉编译 wiliwili
# ---------------------------------------------------------------------------
build_wiliwili() {
    local src="${WORK_DIR}/wiliwili"
    local force_rebuild="${1:-false}"

    info "下载 wiliwili 源码..."
    if [ ! -d "${src}" ]; then
        git clone --recursive https://github.com/xfangfang/wiliwili.git "${src}"
    else
        cd "${src}"
        git submodule update --init --recursive || true
    fi

    apply_wiliwili_patches
    if [ "${PATCHES_CHANGED}" = true ]; then
        warn "wiliwili 补丁有变化，将重新编译"
        force_rebuild=true
    fi

    if [ "${force_rebuild}" = "true" ]; then
        info "强制重建 wiliwili，删除旧 build 目录..."
        rm -rf "${src}/build"
    fi

    if [ "${force_rebuild}" != "true" ] && [ -f "${src}/build/wiliwili" ]; then
        info "wiliwili 已编译，跳过"
        return
    fi

    cd "${src}"

    # 只有编译器路径被污染时才清缓存，避免已经编到 100% 的 .o 被删掉
    if [ -f build/CMakeCache.txt ]; then
        if grep -q "${SYSROOT}/usr/bin" build/CMakeCache.txt 2>/dev/null; then
            warn "CMakeCache 含 sysroot 内编译器路径，删除 build 后重配"
            rm -rf build
        fi
    fi

    info "配置 wiliwili (CMake 交叉编译)..."

    # 默认 USE_SYSTEM_CURL=OFF，cpr 会编进一份 curl 8.4。
    # 交叉编译时 curl 的 CURL_CA_BUNDLE=auto 不会探测主机证书路径，
    # 结果 curl_config.h 里 CA bundle/path/fallback 全是 #undef，
    # 板上 HTTPS 全部变成 "unable to get local issuer certificate"。
    # 目标是 Ubuntu/Debian 板，把 CA 路径写死到目标文件系统，并打开 OpenSSL 内置 CA 回退。
    cmake -B build \
        -DCMAKE_TOOLCHAIN_FILE="${WORK_DIR}/aarch64-toolchain.cmake" \
        -DCMAKE_MAKE_PROGRAM="${HOST_MAKE}" \
        -DPKG_CONFIG_EXECUTABLE="${WORK_DIR}/cross-pkg-config" \
        -DPLATFORM_DESKTOP=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_GLES2=ON \
        -DGLFW_BUILD_WAYLAND=ON \
        -DCMAKE_INSTALL_PREFIX="${OUT_DIR}" \
        -DCMAKE_PREFIX_PATH="${SYSROOT}/usr/local" \
        -DIconv_IS_BUILT_IN=TRUE \
        -DHAVE_LIBSOCKET=FALSE \
        -DHAVE_LIBICONV=FALSE \
        -DHAVE_ICONV=TRUE \
        -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        -DCURL_CA_PATH=/etc/ssl/certs \
        -DCURL_CA_FALLBACK=ON \
        || die "wiliwili cmake 配置失败"

    local cached_cc
    cached_cc="$(grep -E '^CMAKE_C_COMPILER:' build/CMakeCache.txt | head -n1 || true)"
    info "CMake 选用的 C 编译器: ${cached_cc}"
    if echo "${cached_cc}" | grep -q "${SYSROOT}"; then
        die "CMake 仍选中了 sysroot 内的编译器，请检查 PATH / CMAKE_PREFIX_PATH"
    fi

    # 兜底：从已生成的链接命令里去掉 glibc 不存在的库
    find build -name link.txt -o -name link.txts -o -name build.make \
        | while read -r f; do
            if grep -qE -- '-lsocket|-liconv' "$f" 2>/dev/null; then
                warn "从 ${f} 移除 -lsocket/-liconv"
                sed -i -E 's/(^|[[:space:]])-lsocket([[:space:]]|$)/ /g; s/(^|[[:space:]])-liconv([[:space:]]|$)/ /g' "$f"
            fi
        done

    info "编译 wiliwili..."
    cmake --build build --target wiliwili -j"${JOBS}" || die "wiliwili 编译失败"
}

# ---------------------------------------------------------------------------
# 7. 打包输出
# ---------------------------------------------------------------------------
package_output() {
    info "打包输出文件..."
    mkdir -p "${OUT_DIR}/lib"

    if [ ! -f "${WORK_DIR}/wiliwili/build/wiliwili" ]; then
        die "未找到编译产物 ${WORK_DIR}/wiliwili/build/wiliwili"
    fi
    cp "${WORK_DIR}/wiliwili/build/wiliwili" "${OUT_DIR}/"

    for lib in avcodec avformat avutil avfilter swresample swscale mpv; do
        local sofile
        sofile=$(ls "${SYSROOT}/usr/local/lib/lib${lib}.so"* 2>/dev/null | head -n1)
        if [ -n "${sofile}" ]; then
            cp -a "${SYSROOT}/usr/local/lib/lib${lib}.so"* "${OUT_DIR}/lib/" 2>/dev/null || \
                cp -a "${sofile}" "${OUT_DIR}/lib/"
        fi
    done

    # Desktop 构建把资源路径编译成 "./resources/"（相对 CWD）。
    # 必须把 resources 打进包，启动脚本也要切到包目录，否则 XML/字体/i18n 全部找不到。
    local resources_src=""
    if [ -d "${WORK_DIR}/wiliwili/build/resources" ]; then
        resources_src="${WORK_DIR}/wiliwili/build/resources"
    elif [ -d "${WORK_DIR}/wiliwili/resources" ]; then
        resources_src="${WORK_DIR}/wiliwili/resources"
    else
        die "未找到 resources 目录（wiliwili/build/resources 或 wiliwili/resources）"
    fi
    if [ ! -f "${resources_src}/xml/activity/main.xml" ]; then
        die "resources 不完整：缺少 xml/activity/main.xml (${resources_src})"
    fi
    info "复制 UI 资源: ${resources_src} -> ${OUT_DIR}/resources"
    rm -rf "${OUT_DIR}/resources"
    cp -a "${resources_src}" "${OUT_DIR}/resources"

    cat > "${OUT_DIR}/run-wiliwili.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}" || exit 1
export LD_LIBRARY_PATH="${SCRIPT_DIR}/lib:${LD_LIBRARY_PATH}"
exec "${SCRIPT_DIR}/wiliwili" "$@"
EOF
    chmod +x "${OUT_DIR}/run-wiliwili.sh"

    info "打包完成！输出目录: ${OUT_DIR}"
    info "把整个 out/ 目录拷到板上后运行: ./run-wiliwili.sh"
}

# ---------------------------------------------------------------------------
# 主流程与参数解析
# ---------------------------------------------------------------------------
main() {
    DO_ALL=true
    DO_SYSROOT=false
    DO_REBUILD_SYSROOT=false
    DO_UPDATE_SYSROOT=false
    DO_CLEAN=false
    DO_FFMPEG=false
    DO_MPV=false
    DO_REBUILD_MPV=false
    DO_WILIWILI=false
    DO_REBUILD_WILIWILI=false

    if [ $# -eq 0 ]; then
        DO_ALL=true
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all) DO_ALL=true; shift ;;
            --sysroot) DO_SYSROOT=true; DO_ALL=false; shift ;;
            --rebuild-sysroot) DO_REBUILD_SYSROOT=true; DO_ALL=false; shift ;;
            --update-sysroot) DO_UPDATE_SYSROOT=true; DO_ALL=false; shift ;;
            --clean)
                DO_CLEAN=true
                DO_FFMPEG=true
                DO_MPV=true
                DO_WILIWILI=true
                DO_ALL=false
                shift
                ;;
            --ffmpeg) DO_FFMPEG=true; DO_ALL=false; shift ;;
            --mpv) DO_MPV=true; DO_ALL=false; shift ;;
            --rebuild-mpv) DO_REBUILD_MPV=true; DO_MPV=true; DO_ALL=false; shift ;;
            --wiliwili) DO_WILIWILI=true; DO_ALL=false; shift ;;
            --rebuild-wiliwili) DO_REBUILD_WILIWILI=true; DO_WILIWILI=true; DO_ALL=false; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知选项: $1"; usage; exit 1 ;;
        esac
    done

    info "========================================"
    info "  wiliwili 交叉编译脚本 (x86_64 -> aarch64)"
    info "========================================"
    info "工作目录: ${WORK_DIR}"
    info "Sysroot : ${SYSROOT} (Ubuntu ${UBUNTU_RELEASE})"
    info "mpv 版本: ${MPV_VERSION}"
    info "并行任务: ${JOBS}"
    echo

    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"

    install_host_deps

    if [ "$DO_REBUILD_SYSROOT" = true ]; then
        info "准备重建 sysroot..."
        sudo rm -rf "${SYSROOT}"
        create_sysroot
    elif [ "$DO_UPDATE_SYSROOT" = true ]; then
        update_sysroot
    elif [ "$DO_ALL" = true ] || [ "$DO_SYSROOT" = true ] || [ "$DO_CLEAN" = true ]; then
        create_sysroot
    fi

    if [ "$DO_SYSROOT" = true ] || [ "$DO_REBUILD_SYSROOT" = true ] || [ "$DO_UPDATE_SYSROOT" = true ]; then
        if [ "$DO_ALL" = false ] && [ "$DO_CLEAN" = false ]; then
            info "Sysroot 操作完成，退出。"
            exit 0
        fi
    fi

    if [ "$DO_CLEAN" = true ]; then
        clean_compile_env
    fi

    generate_toolchain_files
    setup_env

    if [ "$DO_ALL" = true ] || [ "$DO_FFMPEG" = true ]; then
        build_ffmpeg
    fi

    if [ "$DO_ALL" = true ] || [ "$DO_MPV" = true ] || [ "$DO_REBUILD_MPV" = true ]; then
        if [ "$DO_REBUILD_MPV" = true ]; then
            build_mpv true
        else
            build_mpv false
        fi
    fi

    if [ "$DO_ALL" = true ] || [ "$DO_WILIWILI" = true ] || [ "$DO_REBUILD_WILIWILI" = true ]; then
        if [ "$DO_REBUILD_WILIWILI" = true ]; then
            build_wiliwili true
        else
            build_wiliwili false
        fi
    fi

    if [ "$DO_ALL" = true ] || [ "$DO_WILIWILI" = true ] || [ "$DO_REBUILD_WILIWILI" = true ] \
        || [ "$DO_MPV" = true ] || [ "$DO_REBUILD_MPV" = true ]; then
        package_output
    fi

    info "========================================"
    info " 任务执行完毕！"
    info "========================================"
}

main "$@"
