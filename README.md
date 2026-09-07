# wiliwili-rk3566

在 x86_64 主机上为 **RK3566**（LCKFB 泰山派 / Armbian aarch64）交叉编译带 **V4L2 Request 硬件解码** 的 [wiliwili](https://github.com/xfangfang/wiliwili)。

本仓库由 **Grok Build CLI**（xAI）辅助生成。

## 这是什么

上游 Linux 发行版里的 mpv / FFmpeg 往往编不进 Rockchip 的 `v4l2request` 硬解。本仓库提供：

- 可重复的交叉编译脚本（sysroot → FFmpeg → mpv → wiliwili）
- 一组可回滚的补丁：零拷贝硬解、1080p60 上屏时机、GLES 双线性缩放
- 产物目录 `out/`，拷到板子即可运行

克隆下来的 FFmpeg、mpv、wiliwili 源码和 sysroot **不进 git**，避免把数 GB 的树推进 GitHub。

## 目标硬件

| 项目 | 值 |
| --- | --- |
| 板卡 | LCKFB Taishan Pi（泰山派） |
| SoC | Rockchip RK3566 |
| CPU | 4× Cortex-A55 |
| GPU | Mali-G52 MC1（Panfrost / OpenGL ES 3.1） |
| VPU | `rkvdec`（H.264 / HEVC，V4L2 Request） |
| 系统 | Armbian（aarch64，glibc 不新于 sysroot） |
| 显示 | Wayland（如 KDE Plasma） |

1080p60 在这颗 GPU 上要用便宜缩放才能稳住；默认 lanczos 容易抖。硬解走通后日志应为 `HW: v4l2request`，不要带 `-copy`。

## 特性

- FFmpeg 开启 `--enable-v4l2-request`
- mpv 编进 `v4l2request` 零拷贝对接（修正 `#ifdef` 枚举判断）
- wiliwili 使用 GLES2 + Wayland GLFW
- 上屏在 `glfwSwapBuffers` 之后再 `report_swap`，减轻 1080p60 抖屏
- GLES 默认 bilinear 缩放，不必为了流畅去开「低功耗解码」
- 补丁用 `patches/series` 管理，注释一行即可回滚

## 依赖（编译主机）

- x86_64 Linux（Debian / Ubuntu 一类）
- `aarch64-linux-gnu-gcc` 交叉工具链
- `meson`、`ninja`、`cmake`、`pkg-config`、`debootstrap`、`qemu-user-static`
- 能 `sudo`（装主机包、做 sysroot）

脚本会尝试安装主机依赖。sysroot 的 glibc **不能新于板子**，否则编出来的二进制在板上跑不起来。

## 快速开始

```bash
git clone <本仓库 URL>
cd wiliwili-rk3566   # 或你 clone 下来的目录名
chmod +x build.sh
./build.sh
```

默认跑完全流程。完成后把 `out/` 整目录拷到板子：

```bash
scp -r out/ taron@板子IP:~/
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

源码属主若是 root，打补丁前需要：

```bash
sudo chown -R "$(id -un):$(id -gn)" mpv wiliwili
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

`aarch64-cross.ini`、`aarch64-toolchain.cmake`、`cross-pkg-config` 由 `build.sh` 按当前目录生成，不要把带本机绝对路径的版本提交上去。

## 补丁

`build.sh` 按 series 从上到下 `git apply`。以 `#` 开头的行会跳过；从 series 拿掉且已经打上的补丁会自动反向打回。

### mpv（`patches/series`）

| 文件 | 作用 |
| --- | --- |
| `mpv-v4l2request-hwdec.patch` | 把 `v4l2request` / `v4l2request-copy` 加入硬解白名单 |
| `mpv-v4l2request-zerocopy-interop.patch` | 真正编进零拷贝 GL 对接。原补丁用 `#ifdef` 判断枚举，恒为假，只能落到 copy |

回到 copy 路径：注释第二份补丁，然后 `./build.sh --rebuild-mpv`。

### wiliwili（`patches/wiliwili.series`）

| 文件 | 作用 |
| --- | --- |
| `wiliwili-present-sync.patch` | `report_swap` 挪到 SwapBuffers 之后；`video-timing-offset=0.050` |
| `wiliwili-gles-bilinear-1080p60.patch` | GLES 默认 bilinear，1080p60 不必开「低功耗解码」 |

### 板上现象对照

| 日志 / 现象 | 含义 |
| --- | --- |
| `HW: v4l2request-copy` | VPU 在解，但帧被拷回 CPU，1080p 往往比软解还卡 |
| `HW: v4l2request` | 零拷贝，DMA-BUF 进 GPU |
| 关低功耗就 1080p60 抖 | Mali-G52 扛不住默认 lanczos；用 bilinear 补丁 |
| 播放器全屏只铺满窗口 | 设置里打开「应用内全屏时自动切换窗口全屏」 |
| 内存够仍偶发顿 | 降低 `vm.swappiness`（例如 10）。zram 不改变硬解路径 |

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
