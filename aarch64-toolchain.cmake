set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_SYSROOT /home/taron/code/wiliwili/sysroot)

# 必须使用主机上的交叉编译器（x86_64 ELF），禁止搜到 sysroot 里的 aarch64 gcc
set(CMAKE_C_COMPILER /usr/bin/aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER /usr/bin/aarch64-linux-gnu-g++)
set(CMAKE_AR /usr/bin/aarch64-linux-gnu-ar CACHE FILEPATH "")
set(CMAKE_STRIP /usr/bin/aarch64-linux-gnu-strip CACHE FILEPATH "")
set(CMAKE_MAKE_PROGRAM /usr/bin/make CACHE FILEPATH "")
set(CMAKE_ASM_COMPILER /usr/bin/aarch64-linux-gnu-gcc)

set(CMAKE_FIND_ROOT_PATH /home/taron/code/wiliwili/sysroot /home/taron/code/wiliwili/sysroot/usr/local)
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

set(PKG_CONFIG_EXECUTABLE /home/taron/code/wiliwili/cross-pkg-config)
