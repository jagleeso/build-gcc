#! /bin/bash
set -e

# To build gcc, binutils, and gdb:
# $ ./build_cross_gcc.sh
#
# To rebuild just gcc after modifying it / changing GCC_BRANCH:
# (i.e. you've already run this script at least once and have partially built stuff)
# $ ./build_cross_gcc.sh rebuild_gcc

#-------------------------------------------------------------------------------------------
# This script will download packages for, configure, build and install a GCC cross-compiler.
# Customize the variables (INSTALL_PATH, TARGET, etc.) to your liking before running.
# If you get an error and need to resume the script from some point in the middle,
# just delete/comment the preceding lines before running it again.
#
# See: http://preshing.com/20141119/how-to-build-a-gcc-cross-compiler
#-------------------------------------------------------------------------------------------

# ==========================================================================================
# Setup your configuration options.
#

# INSTALL_PATH=$HOME/opt/cross
# GCC_BRANCH=num-args
# GCC_PROGRAM_PREFIX=

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
# --disable-threads --disable-shared
CONFIGURATION_OPTIONS="--disable-multilib"
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

#
# End of configuration options
# ==========================================================================================

get_root() {
    (
        cd "$(dirname $0)"
        pwd
    )
}
ROOT=$(get_root)
mkdir -p $INSTALL_PATH

GCC_PREFIX_ARGS=
if [ ! -z "$GCC_PROGRAM_PREFIX" ]; then
    GCC_PREFIX_ARGS=" --program-prefix=$GCC_PROGRAM_PREFIX"
fi
CONFIGURATION_OPTIONS="$CONFIGURATION_OPTIONS $GCC_PREFIX_ARGS"

#
# Start building everything.
#

build_all() {
    _l download
    _l build_binutils
    _l build_gcc
    _l build_gcc_remaining_01
    _l build_gdb
    _l build_gcc_remaining_02
}

rebuild_gcc() {
    make_gcc
}

#
# Various stages of the build process for the GCC toolchain.
#

build_binutils() {
    mkdir -p build-binutils
    cd build-binutils
    _l ../$BINUTILS_VERSION/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS
    _l make $PARALLEL_MAKE
    _l make install
    cd ..

    # Step 2. Linux Kernel Headers
    if [ $USE_NEWLIB -eq 0 ]; then
        cd $LINUX_KERNEL_VERSION
        make ARCH=$LINUX_ARCH INSTALL_HDR_PATH=$INSTALL_PATH/$TARGET headers_install
        cd ..
    fi
}

build_gcc() {

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
    GCC_PLUGIN_ARGS="--enable-plugin --enable-languages=c"
    # GCC_PLUGIN_ARGS="--with-gmp-include=$(pwd)/gmp --with-gmp-lib=$(pwd)/gmp/.libs --enable-plugin --enable-languages=c"
    _l ../$GCC_REPO/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS $NEWLIB_OPTION \
        $GCC_PLUGIN_ARGS \
        $GCC_PREFIX_ARGS
    make_gcc
    cd ..

    _l install_gmp

}
make_gcc() {
    (
        cd $ROOT/tmp/build-gcc
        _l make $PARALLEL_MAKE all-gcc
        _l make install-gcc
    )
}
install_gmp() {
    # For some reason, GCC build system does not bother to install gmp.h in $INSTALL_PATH/include.
    # (mind you, it does build the library).
    # So, lets manually do it.
    # (Needed for building GCC plugins)
    (
        cd $ROOT/tmp/build-gcc/gmp
        _l make install
    )
}

build_gcc_remaining_01() {
    if [ $USE_NEWLIB -ne 0 ]; then
        # Steps 4-6: Newlib
        mkdir -p build-newlib
        cd build-newlib
        _l ../newlib-master/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS
        _l make $PARALLEL_MAKE
        _l make install
        cd ..
    else
        # Step 4. Standard C Library Headers and Startup Files
        mkdir -p build-glibc
        cd build-glibc
        _l ../$GLIBC_VERSION/configure --prefix=$INSTALL_PATH/$TARGET --build=$MACHTYPE --host=$TARGET --target=$TARGET --with-headers=$INSTALL_PATH/$TARGET/include $CONFIGURATION_OPTIONS libc_cv_forced_unwind=yes
        _l make install-bootstrap-headers=yes install-headers
        _l make $PARALLEL_MAKE csu/subdir_lib
        install csu/crt1.o csu/crti.o csu/crtn.o $INSTALL_PATH/$TARGET/lib
        $TARGET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o $INSTALL_PATH/$TARGET/lib/libc.so
        touch $INSTALL_PATH/$TARGET/include/gnu/stubs.h
        cd ..

        # Step 5. Compiler Support Library
        cd build-gcc
        _l make $PARALLEL_MAKE all-target-libgcc
        _l make install-target-libgcc
        cd ..

        # Step 6. Standard C Library & the rest of Glibc
        cd build-glibc
        _l make $PARALLEL_MAKE
        _l make install
        cd ..
    fi

}

build_gcc_remaining_02() {
    # Step 7. Standard C++ Library & the rest of GCC
    cd build-gcc
    _l make $PARALLEL_MAKE all
    _l make install
    cd ..
}

build_gdb() {
    # Step 8. Build GDB
    mkdir -p build-gdb
    cd build-gdb
    # Use --with-python so that python scripts in CONFIG_GDB_SCRIPTS work (for QEMU kernel development).
    _l ../$GDB_VERSION/configure --prefix=$INSTALL_PATH --target=$TARGET $CONFIGURATION_OPTIONS --with-python
    _l make $PARALLEL_MAKE
    _l make install
    cd ..

}

download() {
    # Download packages
    export http_proxy=$HTTP_PROXY https_proxy=$HTTP_PROXY ftp_proxy=$HTTP_PROXY
    download_if_not_exists() {
        local url="$1"
        shift 1
        if [ ! -e "$(basename "$url")" ]; then
            _l wget -nc "$@" "$url"
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
}

CMD_FILE=
LOG_FILE=
_l() {
    echo "$@" | tee --append $CMD_FILE
    "$@" 
}

build_timestamp() {
    local file="$1"
    shift 1
    echo ":: BUILD STARTED @ $(date) ::" > $file
}

log_cmd() {
    local file="$1"
    shift 1
    (
        set -o pipefail
        set -e
        "$@" 2>&1 
    ) >> $file
}

main() {
    # Setup a log file
    mkdir -p $ROOT/tmp
    cd $ROOT/tmp
    CMD_FILE=$ROOT/tmp/build_cmd.txt
    LOG_FILE=$ROOT/tmp/build_log.txt
    build_timestamp $CMD_FILE
    build_timestamp $LOG_FILE

    do_build() {
        if [ $# -eq 0 ]; then
            _l build_all
        else
            _l "$@"
        fi
    }
    tail -f $CMD_FILE &
    local tail_pid=$!
    local status=0
    if ! log_cmd $LOG_FILE do_build "$@"; then
        status=$?
        echo "FAIL: status = $status"
    fi
    kill $tail_pid
    return $status
}

build_fail() {
    echo
    echo "BUILD FAILED"
    echo "See $CMD_FILE for last commands executed prior to failure."
    echo "See $LOG_FILE for build output."
    echo "NOTE: if you see errors like \"run \`make distclean' and/or \`rm ./config.cache' and start over\", remove the build folder in question from $ROOT/tmp and re-run the build."
    echo
    echo "Grepping build output for \"error\":"
    grep -i 'error:' $LOG_FILE 
}

trap build_fail EXIT
main "$@"
trap - EXIT
echo
echo 'Success!'
