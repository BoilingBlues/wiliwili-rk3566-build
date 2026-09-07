# wiliwili-rk3566-build

在 x86_64 主机上为 **RK3566** 交叉编译带 **V4L2 Request 硬件解码** 的 [wiliwili](https://github.com/xfangfang/wiliwili)。

**这不是 wiliwili 的 fork**，而是交叉编译脚本和补丁。本仓库由 **Grok Build CLI**（xAI）辅助生成。已在 LCKFB 泰山派 + Armbian（aarch64 主线内核）上验证。

## 这是什么

上游 Linux 发行版里的 mpv / FFmpeg 往往编不进 Rockchip 的 `v4l2request` 硬解。本仓库提供：

- 可重复的交叉编译脚本（sysroot → FFmpeg → mpv → wiliwili）
- 一组可回滚的补丁（零拷贝硬解、1080p60 上屏与缩放）
- 产物目录 `out/`，拷到板子即可运行

FFmpeg、mpv、wiliwili 源码和 sysroot **不进 git**。

## 目标硬件

| 项目 | 值 |
| --- | --- |
| 板卡 | LCKFB Taishan Pi（泰山派） |
| SoC | Rockchip RK3566 |
| CPU | 4× Cortex-A55 |
| GPU | Mali-G52 MC1（Panfrost / OpenGL ES 3.1） |
| VPU | `rkvdec`（H.264 / HEVC，V4L2 Request） |
| 系统 | Armbian aarch64（主线内核；其它 Debian/Ubuntu 主线镜像可试，不保证） |
| 显示 | Wayland（如 KDE Plasma） |

## 特性

- FFmpeg 开启 `--enable-v4l2-request`
- mpv 编进 `v4l2request` 零拷贝 GL 对接
- wiliwili 使用 GLES2 + Wayland GLFW
- 补丁用 `patches/series` 管理，注释一行即可回滚

## 依赖（编译主机）

`build.sh` **不会**在主机上 `sudo` 装包，缺工具会直接退出。请先自行安装。做 sysroot 时仍需要 `sudo`（debootstrap / chroot）。

**Debian / Ubuntu：**

`qemu-aarch64-static` 是**命令名**，不是包名。找不到包时先开 universe：

```bash
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository universe
sudo apt-get update
sudo apt-get install -y \
    crossbuild-essential-arm64 \
    debootstrap binfmt-support \
    cmake meson ninja-build pkg-config \
    git wget curl python3 file
```

再装 QEMU 用户态模拟（二选一）：

```bash
# Ubuntu 24.04 / Debian 12：二进制为 /usr/bin/qemu-aarch64-static
sudo apt-get install -y qemu-user-static

# Ubuntu 25.10 / 26.04：包 qemu-user-static 可能已变成虚包，二进制常为 qemu-aarch64
sudo apt-get install -y qemu-user qemu-user-binfmt
```

**Fedora：**

```bash
sudo dnf install -y \
    gcc-aarch64-linux-gnu gcc-c++-aarch64-linux-gnu \
    qemu-user-static debootstrap \
    cmake meson ninja-build pkgconf \
    git wget curl python3 file
```

交叉编译器须是 **x86_64** 上的 `aarch64-linux-gnu-gcc`，不能是板子上拷来的 aarch64 二进制。

## 快速开始

```bash
git clone https://github.com/BoilingBlues/wiliwili-rk3566-build.git
cd wiliwili-rk3566-build
chmod +x build.sh
./build.sh
```

默认跑完全流程。完成后把 `out/` 整目录拷到板子：

```bash
scp -r out/ user@板子IP:~/
# 在板子上
cd ~/out
./run-wiliwili.sh
```

`run-wiliwili.sh` 会把 `./lib` 加进 `LD_LIBRARY_PATH`，使用一并打进去的 libmpv / FFmpeg。

### 常用命令

```bash
./build.sh --help
./build.sh --update-sysroot      # 只补 sysroot 依赖
./build.sh --rebuild-mpv         # 硬解补丁变更后重编 mpv
./build.sh --rebuild-wiliwili    # 播放/缩放补丁变更后重编客户端
./build.sh --clean               # 清编译缓存，保留 sysroot 的 apt
```

## 目录

```text
.
├── LICENSE                 # Unlicense（本仓库原创内容）
├── README.md
├── build.sh                # 交叉编译入口
├── patches/
│   ├── series              # mpv 补丁顺序
│   ├── wiliwili.series     # wiliwili 补丁顺序
│   └── *.patch
├── FFmpeg/  mpv/  wiliwili/   # 构建时克隆，已 gitignore
├── sysroot/                   # debootstrap 根文件系统，已 gitignore
└── out/                       # 产物，已 gitignore
```

`aarch64-cross.ini`、`aarch64-toolchain.cmake`、`cross-pkg-config` 由 `build.sh` 按当前目录生成，不要提交带本机绝对路径的版本。

## 补丁

`build.sh` 按 series 从上到下 `git apply`。以 `#` 开头的行会跳过；从 series 拿掉且已经打上的补丁会自动反向打回。

### mpv（`patches/series`）

| 文件 | 作用 |
| --- | --- |
| `mpv-v4l2request-hwdec.patch` | 把 `v4l2request` / `v4l2request-copy` 加入硬解白名单 |
| `mpv-v4l2request-zerocopy-interop.patch` | 编进零拷贝 GL 对接驱动 |

### wiliwili（`patches/wiliwili.series`）

| 文件 | 作用 |
| --- | --- |
| `wiliwili-present-sync.patch` | `report_swap` 挪到 SwapBuffers 之后；`video-timing-offset=0.050` |
| `wiliwili-gles-bilinear-1080p60.patch` | GLES 默认 bilinear 缩放 |

回滚某补丁：在对应 series 里注释掉该行，再 `--rebuild-mpv` 或 `--rebuild-wiliwili`。

## 常见问题

**`build.sh` 报主机缺少某某命令。**  
按上面「依赖」一节在编译机上安装，不要改脚本去 `apt-get`/`dnf`。Fedora 没有 `crossbuild-essential-arm64`，用 `gcc-aarch64-linux-gnu`。

**`make install` 报 `mkdir: Permission denied`（`install-examples`）。**  
库已经编完，失败在往 sysroot 里装 examples。sysroot 是 root 建的。拉最新脚本后重跑 `./build.sh --ffmpeg`：会把 `sysroot/usr/local` 改成当前用户可写，并且只安装库和头文件。

**`Unable to locate package qemu-aarch64-static`。**  
那是二进制名。24.04 装 `qemu-user-static`（universe）；25.10+ 装 `qemu-user` / `qemu-user-binfmt`。不要 `apt install qemu-aarch64-static`。

**编出来的程序在板上无法运行。**  
sysroot 的 glibc 不能新于板子。本构建按 Ubuntu/Debian 系 aarch64 交叉，绑的是主线内核 + glibc，不是 Armbian 商标。厂商 4.19 + MPP/`rkmpp`、musl、Android、更新的 Fedora glibc 一般都对不上。

**`git apply` 失败，提示源码不可写。**

```bash
sudo chown -R "$(id -un):$(id -gn)" mpv wiliwili
```

**日志是 `HW: v4l2request-copy`，1080p 比软解还卡。**  
VPU 在解，但帧被拷回 CPU 再上传。零拷贝成功时应为 `HW: v4l2request`（没有 `-copy`）。未打 `mpv-v4l2request-zerocopy-interop.patch` 时，`#ifdef AV_HWDEVICE_TYPE_V4L2REQUEST` 因枚举不是宏而恒为假，对接驱动会被裁掉。

**1080p60 会抖，开「低功耗解码」就好了。**  
硬解路径下 skiploopfilter 几乎不起作用；真正减负的是 `profile=fast` 的 bilinear 缩放。Mali-G52 单核用默认 lanczos 往往画不完一帧（16.6ms）。本仓库 GLES 补丁在未开低功耗时也会用 bilinear。另有上屏时机：FBO 画完立刻 `report_swap` 会让 60fps 对 60Hz 错拍。

**播放器全屏只铺满窗口，任务栏还在。**  
那是应用内全屏。在设置里打开「应用内全屏时自动切换窗口全屏」，走 Wayland 的 `xdg_toplevel_set_fullscreen`。

**内存占用不高，播放仍偶发顿一下。**  
可把 `vm.swappiness` 降到 `10` 左右，减少往 zram 里换页。zram **不改变**硬解路径，只影响会不会随机停顿。

**能在别的系统上跑吗？**  
同 SoC、主线 `rkvdec`、Debian/Ubuntu 系、glibc 不旧于本构建，有机会直接跑。换内核栈或 C 库则基本不行。已验证环境是泰山派 + Armbian。

## 许可

本仓库**原创内容**（`build.sh`、文档、本仓库撰写的补丁文本）使用 [Unlicense](https://unlicense.org/)：**无条件开源**，可任意复制、修改、发布、商用，无需署名。

构建得到的 **wiliwili 可执行文件** 必须遵守上游协议，不能当成 Unlicense：

| 上游 | 协议 | 地址 |
| --- | --- | --- |
| wiliwili | GPL-3.0 | https://github.com/xfangfang/wiliwili |
| mpv | GPL-2.0 | https://github.com/mpv-player/mpv |
| FFmpeg（本构建开启 GPL） | GPL | https://ffmpeg.org |
| jernejsk FFmpeg v4l2-request | 随其 FFmpeg 分支 | 用于 Rockchip Request API |

分发编译产物时，请同时提供对应源码与 GPL 文本。

## 致谢

- [xfangfang/wiliwili](https://github.com/xfangfang/wiliwili)
- [mpv](https://github.com/mpv-player/mpv)、[FFmpeg](https://ffmpeg.org)
- Rockchip mainline `rkvdec` / Mesa Panfrost

## 免责声明

与 B 站、Rockchip、Armbian 均无官方关系。按「现状」提供，不对板砖、账号或版权纠纷负责。
