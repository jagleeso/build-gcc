#! /bin/bash
set -e
trap 'previous_command=$this_command; this_command=$BASH_COMMAND' DEBUG
trap 'echo FAILED COMMAND: $previous_command' EXIT

#-------------------------------------------------------------------------------------------
# This script will download packages for, configure, build and install a GCC cross-compiler.
# Customize the variables (INSTALL_PATH, TARGET, etc.) to your liking before running.
# If you get an error and need to resume the script from some point in the middle,
# just delete/comment the preceding lines before running it again.
#
# See: http://preshing.com/20141119/how-to-build-a-gcc-cross-compiler
#-------------------------------------------------------------------------------------------

INSTALL_PATH=$HOME/opt/cross
GCC_BRANCH=num-args
GCC_PROGRAM_PREFIX=

INSTALL_PATH=$HOME/opt/cross/investigate-slowness
GCC_BRANCH=investigate-slowness
GCC_PROGRAM_PREFIX=investigate-slowness-

# INSTALL_PATH=$HOME/opt/cross/nohyperdrive
# # Commit I originally based changes off of.
# GCC_BRANCH=a7aa383874520cd5762701f1c790c930c5ab5bb5
# GCC_PROGRAM_PREFIX=nohyperdrive-

# INSTALL_PATH=$HOME/opt/cross/wenbo
# GCC_BRANCH=wenbo

TARGET=aarch64-linux
USE_NEWLIB=0
LINUX_ARCH=arm64
CONFIGURATION_OPTIONS="--disable-multilib" # --disable-threads --disable-shared
NUM_CPUS=$(grep -c ^processor /proc/cpuinfo)
PARALLEL_MAKE=-j$NUM_CPUS
BINUTILS_VERSION=binutils-2.24
GCC_REPO=gcc
GCC_URL=https://github.com/jagleeso/$GCC_REPO.git
LINUX_KERNEL_VERSION=linux-3.17.2
GLIBC_VERSION=glibc-2.20
MPFR_VERSION=mpfr-3.1.2
GMP_VERSION=gmp-6.0.0a
MPC_VERSION=mpc-1.0.2
ISL_VERSION=isl-0.12.2
CLOOG_VERSION=cloog-0.18.1
GDB_VERSION=gdb-7.9
export PATH=$INSTALL_PATH/bin:$PATH

get_root() {
    (
        cd "$(dirname $0)"
        pwd
    )
}
ROOT=$(get_root)

mkdir -p $INSTALL_PATH

# # Download packages
export http_proxy=$HTTP_PROXY https_proxy=$HTTP_PROXY ftp_proxy=$HTTP_PROXY
download_if_not_exists() {
    local url="$1"
    shift 1
    if [ ! -e "$(basename "$url")" ]; then
        wget -nc "$@" "$url"
    fi
}
extract() {
    local tarfile="$1"
    # local extracted="$(echo "$tarfile" | sed 's/\.tar.*$//')"

    # tar files usually have 1 directory in them.
    tar_folder() {
        tar --list --file binutils-2.24.tar.gz \
            | ruby -lane 'if m = $_.match(/^([^\/]+)\//); then puts m.captures[0]; end' \
            | sort --unique
    }
    local tar_dir="$(tar_folder $tarfile)"
    if [ ! -d  "$tar_dir" ]; then
        tar xfk $tarfile
    fi
}


#
# Download everything.
#
download_if_not_exists https://ftp.gnu.org/gnu/binutils/$BINUTILS_VERSION.tar.gz
if [ ! -d $GCC_REPO ]; then
    git clone $GCC_URL
fi
(
    cd $GCC_REPO
    git checkout $GCC_BRANCH
)
if [ $USE_NEWLIB -ne 0 ]; then
    download_if_not_exists newlib-master.zip https://github.com/bminor/newlib/archive/master.zip -O || true
    unzip -qo newlib-master.zip
else
    download_if_not_exists https://www.kernel.org/pub/linux/kernel/v3.x/$LINUX_KERNEL_VERSION.tar.xz
    download_if_not_exists https://ftp.gnu.org/gnu/glibc/$GLIBC_VERSION.tar.xz
fi
download_if_not_exists https://ftp.gnu.org/gnu/mpfr/$MPFR_VERSION.tar.xz
download_if_not_exists https://ftp.gnu.org/gnu/gmp/$GMP_VERSION.tar.xz
download_if_not_exists https://ftp.gnu.org/gnu/mpc/$MPC_VERSION.tar.gz
download_if_not_exists ftp://gcc.gnu.org/pub/gcc/infrastructure/$ISL_VERSION.tar.bz2
download_if_not_exists ftp://gcc.gnu.org/pub/gcc/infrastructure/$CLOOG_VERSION.tar.gz
download_if_not_exists https://ftp.gnu.org/gnu/gdb/$GDB_VERSION.tar.gz

#
# Extract everything.
#
for f in *.tar*; do 
    extract $f
done
# Make symbolic links
cd $GCC_REPO
ln -sf `ls -1d ../mpfr-*/` mpfr
ln -sf `ls -1d ../gmp-*/` gmp
ln -sf `ls -1d ../mpc-*/` mpc
ln -sf `ls -1d ../isl-*/` isl
ln -sf `ls -1d ../cloog-*/` cloog
cd ..

#
# Start building everything.
#

mkdir -p build-binutils
cd build-binutils
../$BINUTILS_VERSION/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS
make $PARALLEL_MAKE
make install
cd ..

# Step 2. Linux Kernel Headers
if [ $USE_NEWLIB -eq 0 ]; then
    cd $LINUX_KERNEL_VERSION
    make ARCH=$LINUX_ARCH INSTALL_HDR_PATH=$INSTALL_PATH/$TARGET headers_install
    cd ..
fi

# Step 3. C/C++ Compilers
mkdir -p build-gcc
cd build-gcc
if [ $USE_NEWLIB -ne 0 ]; then
    NEWLIB_OPTION=--with-newlib
fi
# Options needed for GCC plugin support.
#
# NOTE:
# For whatever reason, if you use --enable-languages=c,c++, plugin headers (needed to 
# build plugins) won't get installed to lib/gcc/aarch64-linux/4.9.0/plugin/include.
GCC_PLUGIN_ARGS="--with-gmp-include=$(pwd)/gmp --with-gmp-lib=$(pwd)/gmp/.libs --enable-plugin --enable-languages=c"
GCC_PREFIX_ARGS=
if [ ! -z "$GCC_PROGRAM_PREFIX" ]; then
    GCC_PREFIX_ARGS=" --program-prefix=$GCC_PROGRAM_PREFIX"
fi
../$GCC_REPO/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS $NEWLIB_OPTION \
    $GCC_PLUGIN_ARGS \
    $GCC_PREFIX_ARGS
make $PARALLEL_MAKE all-gcc
make install-gcc
cd ..

# For some reason, GCC build system does not bother to install gmp.h in $INSTALL_PATH/include.
# (mind you, it does build the library).
# So, lets manually do it.
# (Needed for building GCC plugins)
(
    cd build-gcc/gmp
    make install
)

if [ $USE_NEWLIB -ne 0 ]; then
    # Steps 4-6: Newlib
    mkdir -p build-newlib
    cd build-newlib
    ../newlib-master/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS
    make $PARALLEL_MAKE
    make install
    cd ..
else
    # Step 4. Standard C Library Headers and Startup Files
    mkdir -p build-glibc
    cd build-glibc
    ../$GLIBC_VERSION/configure --prefix=$INSTALL_PATH/$TARGET --build=$MACHTYPE --host=$TARGET --target=$TARGET --with-headers=$INSTALL_PATH/$TARGET/include $CONFIGURATION_OPTIONS libc_cv_forced_unwind=yes
    make install-bootstrap-headers=yes install-headers
    make $PARALLEL_MAKE csu/subdir_lib
    install csu/crt1.o csu/crti.o csu/crtn.o $INSTALL_PATH/$TARGET/lib
    $TARGET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o $INSTALL_PATH/$TARGET/lib/libc.so
    touch $INSTALL_PATH/$TARGET/include/gnu/stubs.h
    cd ..

    # Step 5. Compiler Support Library
    cd build-gcc
    make $PARALLEL_MAKE all-target-libgcc
    make install-target-libgcc
    cd ..

    # Step 6. Standard C Library & the rest of Glibc
    cd build-glibc
    make $PARALLEL_MAKE
    make install
    cd ..
fi

# Step 7. Standard C++ Library & the rest of GCC
cd build-gcc
make $PARALLEL_MAKE all
make install
cd ..

# Step 8. Build GDB
mkdir -p build-gdb
cd build-gdb
# Use --with-python so that python scripts in CONFIG_GDB_SCRIPTS work (for QEMU kernel development).
../$GDB_VERSION/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS --with-python
make $PARALLEL_MAKE
make install
cd ..

trap - EXIT
echo 'Success!'
