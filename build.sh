#!/usr/bin/env bash

# ^ /usr/bin/env since we need bash 4 or greater for the associative arrays
#   and for OS X this is only available from homebrew.

# Problems and related bug reports.
#
# 1. ICU cannot be cross compiled atm:
#    https://bugzilla.mozilla.org/show_bug.cgi?id=912371
#
# 2. On Windows, x86_64 must not use SEH exceptions (in fact it probably must use Dwarf-2 exceptions):
#    Release+Asserts/lib/libLLVMExecutionEngine.a(RTDyldMemoryManager.o): In function `llvm::RTDyldMemoryManager::registerEHFrames(unsigned char*, unsigned long long, unsigned long long)':
#    lib/ExecutionEngine/RTDyldMemoryManager.cpp:129: undefined reference to `__register_frame'
#    Release+Asserts/lib/libLLVMExecutionEngine.a(RTDyldMemoryManager.o): In function `llvm::RTDyldMemoryManager::deregisterEHFrames(unsigned char*, unsigned long long, unsigned long long)':
#    lib/ExecutionEngine/RTDyldMemoryManager.cpp:135: undefined reference to `__deregister_frame'
#    http://clang-developers.42468.n3.nabble.com/clang-3-3-does-not-build-with-gcc-4-8-with-Windows-SEH-exception-td4032754.html
#    Reid Kleckner:
#    "__register_frame is for registering DWARF unwind info.  It's currently under __GNUC__, since that usually implies linkage of libgcc, which provides that symbol.
#     Patches and bugs for avoiding this under mingw when libgcc is using SEH for unwinding are welcome."
#
# .. I am currently enabling Linux builds, and have run into:
# 3. Clang needs sysroot passing to it as per Darwin (probably; can't find crti.o or some such)
#
# 4. GTK must be built too and lots of other stuff probably: http://joekiller.com/2012/06/03/install-firefox-on-amazon-linux-x86_64-compiling-gtk/
#    I may need to adapt that ..
#    https://gist.github.com/phstc/4121839
#
# Restarting at steps:
#
# https://sourceware.org/ml/crossgcc/2011-08/msg00119.html

# Errors are fatal (occasionally this will be temporarily disabled)
set -e

THISDIR="$(dirname $0)"
test "$THISDIR" = "." && THISDIR=${PWD}
OSTYPE=${OSTYPE//[0-9.]/}
HOST_ARCH=$(uname -m)
# Much of the following is NYI (and should
# be done via the options processing anyway)
DEBUG_CTNG=no
DARWINVER=10
# Make this an option (and implement it)
DARWINSDKDIR=MacOSX10.6.sdk
# Absolute filepaths for:
# 1. crosstool-ng's final (i.e. non-sample) .config
CROSSTOOL_CONFIG=
# 2. and Mozilla's .mozconfig
MOZILLA_CONFIG=

# I wolud use associative arrays (declare -A) for this
# but OS X with Bash 3 doesn't support that.
TARGET_TO_PREFIX_osx="o"
TARGET_TO_PREFIX_windows="w"
TARGET_TO_PREFIX_linux="l"
TARGET_TO_PREFIX_ps3="p"
TARGET_TO_PREFIX_raspi="r"

VENDOR_OSES_osx="apple-darwin10"
VENDOR_OSES_windows="x86_64-w64-mingw32"
VENDOR_OSES_linux="unknown-linux-gnu"
VENDOR_OSES_raspi="unknown-linux-gnu"

TARGET_GCC_VERSIONS_osx="apple_5666.3"
TARGET_GCC_VERSIONS_windows="4.8.2"
TARGET_GCC_VERSIONS_linux="4.8.2"
TARGET_GCC_VERSIONS_ps3="4.7.0"
TARGET_GCC_VERSIONS_raspi="4.8.2"

TARGET_LLVM_VERSIONS_osx="3.3"
TARGET_LLVM_VERSIONS_windows="head"
TARGET_LLVM_VERSIONS_linux="3.3"
TARGET_LLVM_VERSIONS_ps3="none"
TARGET_LLVM_VERSIONS_raspi="none"

TARGET_IS_LINUX_osx="n"
TARGET_IS_LINUX_windows="n"
TARGET_IS_LINUX_linux="y"
TARGET_IS_LINUX_ps3="n"
TARGET_IS_LINUX_raspi="y"

TARGET_IS_DARWIN_osx="y"
TARGET_IS_DARWIN_windows="n"
TARGET_IS_DARWIN_linux="n"
TARGET_IS_DARWIN_ps3="n"
TARGET_IS_DARWIN_raspi="n"

TARGET_LIBC_osx="none"
TARGET_LIBC_windows="none"
TARGET_LIBC_linux="GLIBC_V_2.18"
TARGET_LIBC_ps3="newlib"
TARGET_LIBC_raspi="EGLIBC_V_2.18"

# Stands for associative lookup!
_al()
{
  local _tmp=${1}_${2}
  echo ${!_tmp}
}

#########################################
# Simple option processing and options. #
#########################################
ALL_OPTIONS_TEXT=
ALL_OPTIONS=
option_to_var()
{
  echo $(echo $1 | tr '[a-z]' '[A-Z]' | tr '-' '_')
}
var_to_option()
{
  echo --$(echo $1 | tr '[A-Z]' '[a-z]' | tr '_' '-')
}
option()
{
  OPTION=$(var_to_option $1)
  if [ -n "$3" ]; then
    ALL_OPTIONS_TEXT=$ALL_OPTIONS_TEXT" $OPTION=$2\n $3\n\n"
  else
    ALL_OPTIONS_TEXT=$ALL_OPTIONS_TEXT" $OPTION=$2\n\n"
  fi
  ALL_OPTIONS="$ALL_OPTIONS "$1
  eval $1=$2
}
option_output_all()
{
  for OPTION in $ALL_OPTIONS; do
    OPTION_OUTPUT="$OPTION_OUTPUT $(var_to_option $OPTION)=${!OPTION}"
  done
  if [ ! $1 = "" ]; then
    echo -e "#!/bin/bash\n./$(basename $0)$OPTION_OUTPUT" > $1
  else
    echo -e "#!/bin/bash\n./$(basename $0)$OPTION_OUTPUT"
  fi
}
print_help()
{
  echo    "Simple build script to compile"
  echo    "a crosstool-ng Clang Darwin cross-compiler"
  echo    "and Firefox (ESR24 or mozilla-central)"
  echo    "by Ray Donnelly <mingw.android@gmail.com>"
  echo    ""
  echo -e "Options are (--option=default)\n\n$ALL_OPTIONS_TEXT"
}
##################################
# This set of options are global #
##################################
option TARGET_OS           osx \
"Target OS for the build, valid values are
osx, linux or windows. All toolchains built
are multilib enabled, so the arch is not
selected at the toolchain build stage."
######################################################
# This set of options are for the crosstool-ng build #
######################################################
option CTNG_PACKAGE        no \
"Make a package for the built cross compiler."
option CTNG_CLEAN          no \
"Remove old crosstool-ng build and artefacts
before starting the build, otherwise an old
crosstool-ng may be re-used."
option CTNG_SAVE_STEPS     yes \
"Save steps so that they can be restarted
later. This doesn't work well for llvm
and clang unfortunately, but while iterating
on GCC it can save a lot of time.

To restart the build you can use:
 ct-ng STEP_NAME+ -> restart at STEP_NAME and continue
 ct-ng STEP_NAME  -> restart at STEP_NAME and stop just after
 ct-ng +STEP_NAME -> start from scratch, and stop just before STEP_NAME

To see all steps:
 ct-ng list-steps"
option CTNG_DEBUGGABLE     no \
"Do you want the toolchain build with crosstool-ng
to be debuggable? Currently, you can't build a GCC
with old-ish ISLs at -O2 on Windows. This was fixed
about a year ago."
option LLVM_VERSION        default \
"default, none, head, 3.3, 3.2, 3.1 or 3.0 (I test with 3.3 most,
then next, then the others hardly at all)."
option GCC_VERSION        default \
"default, none, head, or a sensible GCC version number."
option COPY_SDK            yes \
"Do you want the MacOSX10.6.sdk copied from
\$HOME/MacOSX10.6.sdk to the sysroot of the
built toolchain?"
option COMPILER_RT         yes \
"Compiler-rt allows for profiling, address
sanitization, coverage reporting and other
such runtime nicities, mostly un-tested, and
requires --copy-sdk=yes and (if on x86-64) a
symbolic link to be made from ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/i686-apple-darwin10
.. to ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/x86_64-apple-darwin10
before running this script."

#################################################
# This set of options are for the Firefox build #
#################################################
option MOZ_CLEAN           no \
"Remove old Mozilla build and artefacts
before starting the build. Otherwise an
old build may be packaged."
option MOZ_VERSION         ESR24 \
"Which version of Firefox would you like?
Valid values are ESR24 or mozilla-central"
option MOZ_DEBUG           yes \
"Do you want to be able to debug the built
Firefox? - you'd need to copy the .o files to
an OS X machine or to run the entire thing on
one for this to be useful."
option MOZ_BUILD_IN_SRCDIR yes ""
option MOZ_TARGET_ARCH     i386 \
"Do you want the built firefox to be i386 or x86_64?
Note: cross compilers built to run on 32bit systems
can still target 64bit OS X and vice-versa, however
with 32bit build compilers, linking failures due to
a lack of address space will probably happen."
option MOZ_COMPILER        clang \
"Which compiler do you want to use, valid options
are clang and gcc"

# Check for command-line modifications to options.
while [ "$#" -gt 0 ]; do
  OPT="$1"
  case "$1" in
    --*=*)
      VAR=$(echo $1 | sed "s,^--\(.*\)=.*,\1,")
      VAL=$(echo $1 | sed "s,^--.*=\(.*\),\1,")
      VAR=$(option_to_var $VAR)
      eval "$VAR=\$VAL"
      ;;
    *help)
      print_help
      exit 0
      ;;
  esac
  shift
done
################################################
# For easier reproduction of the build results #
# and packaging of needed scripts and patches. #
# Includes log files to allow easy comparisons #
################################################
copy_build_scripts()
{
  [ -d $1 ] || mkdir $1
  option_output_all $1/regenerate.sh
  chmod +x $1/regenerate.sh
  cp     ${THISDIR}/build.sh ${THISDIR}/tar-sorted.sh ${THISDIR}/mingw-w64-toolchain.sh $1/
  cp -rf ${THISDIR}/mozilla.configs $1/
  cp -rf ${THISDIR}/crosstool-ng.configs $1/
  cp -rf ${THISDIR}/patches $1/
  [ -d $1/final-configs ] && rm -rf $1/final-configs
  mkdir $1/final-configs
  cp $CROSSTOOL_CONFIG $1/final-configs/.config
  cp $MOZILLA_CONFIG $1/final-configs/.mozconfig
  mkdir $1/logs
  cp ${BUILT_XCOMPILER_PREFIX}/build.log.bz2  $1/logs/
  cp $(dirname $MOZILLA_CONFIG)/configure.log $1/logs/
  cp $(dirname $MOZILLA_CONFIG)/build.log     $1/logs/
  cp $(dirname $MOZILLA_CONFIG)/package.log   $1/logs/
  echo "  ****************************  "        > $1/README
  echo "  * crosstool-ng and Firefox *  "       >> $1/README
  echo "  * build script and patches *  "       >> $1/README
  echo "  ****************************  "       >> $1/README
  echo ""                                       >> $1/README
  echo "To regenerate this Firefox cross"       >> $1/README
  echo "build run regenerate.sh"                >> $1/README
  echo ""                                       >> $1/README
  echo "To see options for making another"      >> $1/README
  echo "build run build.sh --help"              >> $1/README
  echo ""                                       >> $1/README
  echo "Some scripts and patches in this"       >> $1/README
  echo "folder structure won't be needed"       >> $1/README
  echo "to re-generate this exact build,"       >> $1/README
  echo "but may be used by other configs"       >> $1/README
  echo ""                                       >> $1/README
  echo "final-configs/ contains two files:"     >> $1/README
  echo ".config is the crosstool-ng config"     >> $1/README
  echo "after it has been created from one"     >> $1/README
  echo "of the more minimal sample configs"     >> $1/README
  echo ".mozconfig is the configuration of"     >> $1/README
  echo "the Firefox build."                     >> $1/README
  echo ""                                       >> $1/README
  echo "Comments/suggestions to:"               >> $1/README
  echo ""                                       >> $1/README
  echo "Ray Donnelly <mingw.android@gmail.com>" >> $1/README
}

if [ "${HOST_ARCH}" = "i686" ]; then
  BITS=32
else
  BITS=64
fi

if [ "${MOZ_TARGET_ARCH}" = "i686" -a "${TARGET_OS}" = "osx" ]; then
  echo "Warning: You set --moz-target-arch=i686, but that's not a valid ${TARGET_OS} arch, changing this to i386 for you."
  MOZ_TARGET_ARCH=i386
elif [ "${MOZ_TARGET_ARCH}" = "i386" -a "${TARGET_OS}" != "osx" ]; then
  echo "Warning: You set --moz-target-arch=i386, but that's not a valid ${TARGET_OS} arch, changing this to i686 for you."
  MOZ_TARGET_ARCH=i686
fi

# Check that compiler-rt can be built if requested.
if [ "$COMPILER_RT" = "yes" ]; then
  if [ ! -d $HOME/MacOSX10.6.sdk/usr/lib/gcc/x86_64-apple-darwin10 ]; then
    if [ "${BITS}" = "64" ]; then
      echo -n "Error: You are trying to build x86_64 hosted cross compilers. Due to
some host/target confusion you need to make a link from ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/i686-apple-darwin10
.. to ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/x86_64-apple-darwin10
.. please do this and then re-run this script."
      exit 1
    fi
  fi
  if [ "$COPY_SDK" = "no" -a "$TARGET_OS" = "osx" ]; then
    echo "Error: You are trying to build compiler-rt but without --copy-sdk=yes. This is currently broken
as there's no way to pass the SDK's location into the build of compiler-rt."
    exit 1
  fi
fi

VENDOR_OS=$(_al VENDOR_OSES ${TARGET_OS})
if [ "$GCC_VERSION" = "default" ]; then
  GCC_VERSION=$(_al TARGET_GCC_VERSIONS ${TARGET_OS})
fi
if [ "$LLVM_VERSION" = "default" ]; then
  LLVM_VERSION=$(_al TARGET_LLVM_VERSIONS ${TARGET_OS})
fi
if [ "$LLVM_VERSION" = "none" ]; then
  COMPILER_RT="no"
fi
GCC_VERS_=$(echo $GCC_VERSION  | tr '.' '_')
LLVM_VERS_=$(echo $LLVM_VERSION | tr '.' '_')

LIBC_=$(echo $(_al TARGET_LIBC ${TARGET_OS}) | tr '.' '_')

# The first part of CROSSCC is HOST_ARCH and the compilers are
# built to run on that architecture of the host OS. They will
# generally be multilib though, so MOZ_TARGET_ARCH gets used for
# all target folder names. CROSSCC is *only* used as part of
# the filenames for the compiler components.
CROSSCC=${HOST_ARCH}-${VENDOR_OS}

# Before building compiler-rt with 10.6.sdk, we need to:
# pushd /home/ray/x-tools/x86_64-apple-darwin10/x86_64-apple-darwin10/sysroot/usr/lib
# ln -s i686-apple-darwin10 x86_64-apple-darwin10
# .. as otherwise libstdc++.dylib is not found.

SUDO=sudo
GROUP=$USER
if [ "${OSTYPE}" = "darwin" ]; then
  BREWFIX=/usr/local
  GNUFIX=$BREWFIX/bin/g
  CC=clang
  CXX=clang++
#  CC=llvm-gcc
#  CXX=llvm-g++
  # To install gperf 3.0.4 I did:
  set +e
  brew tap homebrew/dupes
  brew install homebrew/dupes/gperf
  GPERF=${BREWFIX}/Cellar/gperf/3.0.4/bin/gperf
  brew tap homebrew/versions
  brew install mercurial gnu-sed gnu-tar grep wget gawk binutils libelf coreutils automake gperf yasm homebrew/versions/autoconf213
  set -e
elif [ "${OSTYPE}" = "linux-gnu" -o "${OSTYPE}" = "msys" ]; then
  if [ "${OSTYPE}" = "msys" ]; then
    if [ ! "${MSYSTEM}" = "MSYS" ]; then
      echo "Please use an MSYS shell, not a MinGW one, i.e. \$MSYSTEM should be \"MSYS\""
      exit 1
    fi
    SUDO=
  fi
  CC=gcc
  CXX=g++
  if [ -f /etc/arch-release -o "${OSTYPE}" = "msys" ]; then
    if [ -f /etc/arch-release ]; then
      HOST_MULTILIB="-multilib"
    fi
    PACKAGES="openssh git python2 tar mercurial gcc${HOST_MULTILIB} libtool${HOST_MULTILIB} wget p7zip unzip zip yasm svn"
    # ncurses for Arch Linux vs ncurses-devel for MSYS is Alexey's fault ;-)
    # .. he has split packages up more than Arch does, so there is not a 1:1
    #    relationship between them anymore.
    if [ -f /etc/arch-release ]; then
      PACKAGES=$PACKAGES" ncurses gcc-ada${HOST_MULTILIB}"
    else
      # Hmm, no yasm package for Windows yet ..
      PACKAGES=$PACKAGES" ncurses-devel base-devel perl-ack"
    fi
    ${SUDO} pacman -S --force --noconfirm --needed $PACKAGES
    GROUP=$(id --group --name)
    if ! which autoconf2.13; then
     (
      pushd /tmp
      curl -SLO http://ftp.gnu.org/gnu/autoconf/autoconf-2.13.tar.gz
      tar -xf autoconf-2.13.tar.gz
      cd autoconf-2.13
      ./configure --prefix=/usr/local --program-suffix=2.13 && make && ${SUDO} make install
     )
    fi
  else
    ${SUDO} apt-get install git mercurial curl bison flex gperf texinfo gawk libtool automake ncurses-dev g++ autoconf2.13 yasm python-dev
  fi
else
  SUDO=
fi

       SED=${GNUFIX}sed
   LIBTOOL=${GNUFIX}libtool
LIBTOOLIZE=${GNUFIX}libtoolize
   OBJCOPY=${GNUFIX}objcopy
   OBJDUMP=${GNUFIX}objdump
   READELF=${GNUFIX}readelf
       TAR=${GNUFIX}tar

firefox_download()
{
  if [ "${MOZ_VERSION}" = "ESR24" ]; then
    FFTARBALLURL=https://ftp.mozilla.org/pub/mozilla.org/firefox/releases/24.1.0esr/source/firefox-24.1.0esr.source.tar.bz2
    FFTRUNKURL=https://hg.mozilla.org/mozilla-central
    FFTARBALL=$(basename "${FFTARBALLURL}")
    [ -f "${FFTARBALL}" ] || curl -SLO "${FFTARBALLURL}"
    [ -d "mozilla-esr24" ] || tar -xf "${FFTARBALL}"
    echo "mozilla-esr24"
  elif [ "${MOZ_VERSION}" = "mozilla-central" ]; then
    [ -d mozilla-central ] || hg clone https://hg.mozilla.org/mozilla-central
    pushd mozilla-central > /dev/null 2>&1
    hg pull > /dev/null 2>&1
    hg update > /dev/null 2>&1
    popd > /dev/null 2>&1
    echo "mozilla-central"
  else
    echo "Error: I don't know what Firefox version ${MOZ_VERSION} is."
    exit 1
  fi
}

firefox_patch()
{
  UNPATCHED=$1
  if [ "${MOZ_CLEAN}" = "yes" ]; then
    [ -d ${UNPATCHED}${BUILDDIRSUFFIX} ] && rm -rf ${UNPATCHED}${BUILDDIRSUFFIX}
  fi
  if [ ! -d ${UNPATCHED}${BUILDDIRSUFFIX} ]; then
    if [ "$MOZ_VERSION" = "mozilla-central" ]; then
      pushd ${UNPATCHED}
      hg archive ../${UNPATCHED}${BUILDDIRSUFFIX}
      popd
    else
      cp -rf ${UNPATCHED} ${UNPATCHED}${BUILDDIRSUFFIX}
    fi
    pushd ${UNPATCHED}${BUILDDIRSUFFIX}
    if [ -d "${THISDIR}/patches/${MOZ_VERSION}" ]; then
      PATCHES=$(find "${THISDIR}/patches/${MOZ_VERSION}" -name "*.patch" | sort)
      for PATCH in $PATCHES; do
        echo "Applying $PATCH"
        patch -p1 < $PATCH
      done
    fi
    popd
  fi
}

do_sed()
{
    if [[ "${OSTYPE}" = "darwin" ]]
    then
        if [[ ! $(which gsed) ]]
        then
            sed -i '.bak' "$1" $2
            rm ${2}.bak
        else
            gsed "$1" -i $2
        fi
    else
        sed "$1" -i $2
    fi
}

#OSXSDKURL="http://packages.siedler25.org/pool/main/a/apple-uni-sdk-10.6/apple-uni-sdk-10.6_20110407.orig.tar.gz"
OSXSDKURL="https://launchpad.net/~flosoft/+archive/cross-apple/+files/apple-uni-sdk-10.6_20110407.orig.tar.gz"

download_sdk()
{
  [ -d "${HOME}"/MacOSX10.6.sdk ] || ( cd "${HOME}"; curl -C - -SLO $OSXSDKURL; tar -xf apple-uni-sdk-10.6_20110407.orig.tar.gz ; mv apple-uni-sdk-10.6.orig/MacOSX10.6.sdk . )
}

MINGW_W64_HASH=
MINGW_W64_PATH=
download_build_compilers()
{
  if [ "$OSTYPE" = "msys" ]; then
    . ${THISDIR}/mingw-w64-toolchain.sh --arch=$HOST_ARCH --root=$PWD --path-out=MINGW_W64_PATH --hash-out=MINGW_W64_HASH --enable-verbose --enable-hash-in-path
    # I'd like to get a hash for all other compilers too.
    test -n "$MINGW_W64_HASH" && MINGW_W64_HASH=-${MINGW_W64_HASH}
    # MinGW compilers must be found before MSYS2 compilers, so add them to the front of PATH. STILL NOT WORKING. WANTS TO BUILD FOR MSYS2.
  fi
}

cross_clang_build()
{
  CTNG_CFG_ARGS=" \
                --disable-local \
                --prefix=$PWD/${INSTALLDIR} \
                --with-libtool=$LIBTOOL \
                --with-libtoolize=$LIBTOOLIZE \
                --with-objcopy=$OBJCOPY \
                --with-objdump=$OBJDUMP \
                --with-readelf=$READELF \
                --with-gperf=$GPERF \
                CC=${CC} CXX=${CXX}"

  CROSSTOOL_CONFIG=${PWD}/${BUILDDIR}/.config
  if [ "${CTNG_CLEAN}" = "yes" ]; then
    [ -d ${BUILT_XCOMPILER_PREFIX} ] && rm -rf ${BUILT_XCOMPILER_PREFIX}
    [ -d crosstool-ng ]              && rm -rf crosstool-ng
    [ -d ${BUILDDIR} ]               && rm -rf ${BUILDDIR}
  fi
  if [ ! -f ${BUILT_XCOMPILER_PREFIX}/bin/${CROSSCC}-clang ]; then
    [ -d "${HOME}"/src ] || mkdir "${HOME}"/src
    [ -d crosstool-ng ] ||
     (
      git clone git@github.com:diorcety/crosstool-ng.git
      pushd crosstool-ng
      if [ -d "${THISDIR}/patches/crosstool-ng" ]; then
        PATCHES=$(find "${THISDIR}/patches/crosstool-ng" -name "*.patch" | sort)
        for PATCH in $PATCHES; do
          git am $PATCH
#           patch -p1 < $PATCH
        done
      fi
      popd
     ) || ( echo "Error: Failed to clone/patch crosstool-ng" && exit 1 )
    pushd crosstool-ng
    CTNG_SAMPLE=mozbuild-${TARGET_OS}-${BITS}
    CTNG_SAMPLE_CONFIG=samples/${CTNG_SAMPLE}/crosstool.config
    [ -d samples/${CTNG_SAMPLE} ] || mkdir -p samples/${CTNG_SAMPLE}
    cp "${THISDIR}"/crosstool-ng.configs/crosstool.config.${TARGET_OS}.${BITS} ${CTNG_SAMPLE_CONFIG}
    LLVM_VERSION_DOT=$(echo $LLVM_VERSION | tr '_' '.')
    echo "CT_LLVM_V_${LLVM_VERSION}"           >> ${CTNG_SAMPLE_CONFIG}
    if [ "$OSTYPE" = "msys" ]; then
      DUMPEDMACHINE=$(${MINGW_W64_PATH}/gcc -dumpmachine)
      echo "CT_BUILD=\"${DUMPEDMACHINE}\""     >> ${CTNG_SAMPLE_CONFIG}
    fi
    if [ "$(_al TARGET_IS_DARWIN ${TARGET_OS})" = "y" ]; then
      if [ "$COPY_SDK" = "yes" ]; then
        echo "CT_DARWIN_COPY_SDK_TO_SYSROOT=y" >> ${CTNG_SAMPLE_CONFIG}
      else
        echo "CT_DARWIN_COPY_SDK_TO_SYSROOT=n" >> ${CTNG_SAMPLE_CONFIG}
      fi
    fi

    if [ "$(_al TARGET_IS_DARWIN ${TARGET_OS})" = "y" ]; then
      echo "CT_BINUTILS_cctools=y"             >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CCTOOLS_V_809=y"                >> ${CTNG_SAMPLE_CONFIG}
      if [ ! "$GCC_VERSION" = "none" ]; then
        echo "CT_CC_GCC_APPLE=y"               >> ${CTNG_SAMPLE_CONFIG}
      fi
    else
      echo "CT_BINUTILS_V_2_22=y"              >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_BINUTILS_FOR_TARGET=y"          >> ${CTNG_SAMPLE_CONFIG}
    fi

    if [ ! "$GCC_VERSION" = "none" ]; then
      echo "CT_CC_gcc=y"                       >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_GCC_V_${GCC_VERS_}=y"        >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_LANG_CXX=y"                  >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_LANG_CXX=y"                  >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_LANG_OBJC=y"                 >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_LANG_OBJCXX=y"               >> ${CTNG_SAMPLE_CONFIG}
    fi

    echo "CT_LIBC_${LIBC_}=y"                  >> ${CTNG_SAMPLE_CONFIG}

    if [ ! "$LLVM_VERSION" = "none" ]; then
      echo "CT_LLVM_V_${LLVM_VERS_}=y"         >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_clang=y"                     >> ${CTNG_SAMPLE_CONFIG}
      if [ "$COMPILER_RT" = "yes" ]; then
        echo "CT_LLVM_COMPILER_RT=y"           >> ${CTNG_SAMPLE_CONFIG}
      else
        echo "CT_LLVM_COMPILER_RT=n"           >> ${CTNG_SAMPLE_CONFIG}
      fi
    fi

    # Gettext fails to build on Windows at -O0. One of the patches:
    # gettext/0.18.3.1/120-Fix-Woe32-link-errors-when-compiling-with-O0.patch
    # .. should have fixed this but it still doesn't work ..)
    if [ "$CTNG_DEBUGGABLE" = "yes" ]; then
      echo "CT_DEBUGGABLE_TOOLCHAIN=y"     >> ${CTNG_SAMPLE_CONFIG}
    else
      echo "CT_DEBUGGABLE_TOOLCHAIN=n"     >> ${CTNG_SAMPLE_CONFIG}
    fi

    if [ "$CTNG_SAVE_STEPS" = "yes" ]; then
      echo "CT_DEBUG_CT=y"                 >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_DEBUG_CT_SAVE_STEPS=y"      >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_DEBUG_CT_SAVE_STEPS_GZIP=y" >> ${CTNG_SAMPLE_CONFIG}
    fi

#    if [ "$OSTYPE" = "msys" ]; then
    # Verbosity 2 doesn't output anything when installing the kernel headers?!
    echo "CT_KERNEL_LINUX_VERBOSITY_1=y"   >> ${CTNG_SAMPLE_CONFIG}
    echo "CT_KERNEL_LINUX_VERBOSE_LEVEL=1" >> ${CTNG_SAMPLE_CONFIG}
    echo "CT_JOBS=1"                       >> ${CTNG_SAMPLE_CONFIG}
    echo "CT_PARALLEL_JOBS=1"              >> ${CTNG_SAMPLE_CONFIG}
    echo "CT_gettext=y"                    >> ${CTNG_SAMPLE_CONFIG}
    # gettext is needed for {e}glibc-2_18; but not just on Windows!
    echo "CT_gettext_VERSION=0.18.3.1"     >> ${CTNG_SAMPLE_CONFIG}

    if [ "$(_al TARGET_IS_DARWIN ${TARGET_OS})" = "y" ]; then
      # Darwin always fails with:
      # "Checking that gcc can compile a trivial statically linked program (CT_WANTS_STATIC_LINK)"
      # We definitely don't want to be forcing CT_CC_GCC_STATIC_LIBSTDCXX=n so this needs to be
      #  fixed properly.
      echo "CT_WANTS_STATIC_LINK=n"        >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_STATIC_TOOLCHAIN=n"         >> ${CTNG_SAMPLE_CONFIG}
      echo "CT_CC_GCC_STATIC_LIBSTDCXX=n"  >> ${CTNG_SAMPLE_CONFIG}
    fi
    echo "CT_PREFIX_DIR=\"${BUILT_XCOMPILER_PREFIX}\""  >> ${CTNG_SAMPLE_CONFIG}
    echo "CT_INSTALL_DIR=\"${BUILT_XCOMPILER_PREFIX}\"" >> ${CTNG_SAMPLE_CONFIG}

    ./bootstrap && ./configure ${CTNG_CFG_ARGS} && make clean && make && make install
    if [ "$OSTYPE" = "msys" ]; then
      PATH="${MINGW_W64_PATH}:${PATH}"
    fi
    PATH="${PATH}":$ROOT/${INSTALLDIR}/bin
    popd
    [ -d ${BUILDDIR} ] || mkdir ${BUILDDIR}
    pushd ${BUILDDIR}
    # Horrible hack to prevent cctools autoreconf from hanging on
    # Ubuntu 12.04.3 .. Sorry.
    # If you get a freeze at "[EXTRA]    Patching 'cctools-809'" then
    # this *might* fix it!
    if [ -f /etc/debian_version ]; then
     trap 'kill $(jobs -pr)' SIGINT SIGTERM EXIT
     ( while [ 0 ] ; do COLM=$(ps aux | grep libtoolize | grep --invert-match grep | awk '{print $2}'); if [ -n "${COLM}" ]; then kill $COLM; echo $COLM; fi; sleep 10; done ) &
    fi
    ct-ng ${CTNG_SAMPLE}
    ct-ng build
    popd
  else
    if [ "$OSTYPE" = "msys" ]; then
      PATH="${MINGW_W64_PATH}:${PATH}"
    fi
  fi
}

cross_clang_package()
{
  if [ "$CTNG_PACKAGE" = "yes" ]; then
    TARFILE=crosstool-ng-${BUILD_PREFIX}-${OSTYPE}-${HOST_ARCH}${MINGW_W64_HASH}.tar.xz
    if [ ! -f ${THISDIR}/${TARFILE} ]; then
      pushd $(dirname ${BUILT_XCOMPILER_PREFIX}) > /dev/null 2>&1
      ${THISDIR}/tar-sorted.sh -cjf ${TARFILE} $(basename ${BUILT_XCOMPILER_PREFIX}) build-scripts --exclude="lib/*.a"
      mv ${TARFILE} ${THISDIR}
      popd
    fi
  fi
}

firefox_build()
{
  DEST=${SRC}${BUILDDIRSUFFIX}
  # OBJDIR is relative to @TOPSRCDIR@ (which is e.g. mozilla-esr24.patched)
  # so have top level objdir as a sibling of that.
  OBJDIR=../obj-moz-${VENDOR_OS}-${MOZ_TARGET_ARCH}
  MOZILLA_CONFIG=${PWD}/${DEST}/.mozconfig
  if [ "${MOZ_CLEAN}" = "yes" -a "${MOZ_BUILD_IN_SRCDIR}" = "no" ]; then
    [ -d ${DEST} ] && rm -rf ${DEST}
  fi
  if [ ! -d ${DEST}/${OBJDIR}/dist/firefox/Firefox${MOZBUILDSUFFIX}.app ]; then
    [ -d ${DEST} ] || mkdir -p ${DEST}
    pushd ${DEST}
    cp "${THISDIR}"/mozilla.configs/mozconfig.${TARGET_OS}            .mozconfig
    do_sed $"s/TARGET_ARCH=/TARGET_ARCH=${MOZ_TARGET_ARCH}/g"         .mozconfig
    do_sed $"s/HOST_ARCH=/HOST_ARCH=${HOST_ARCH}/g"                   .mozconfig
    do_sed $"s/VENDOR_OS=/VENDOR_OS=${VENDOR_OS}/g"                   .mozconfig
    do_sed $"s#TC_STUB=#TC_STUB=${BUILT_XCOMPILER_PREFIX}/bin/${CROSSCC}#g" .mozconfig
    do_sed $"s#OBJDIR=#OBJDIR=${OBJDIR}#g"                            .mozconfig
    TC_PATH_PREFIX=
    if [ "${MOZ_COMPILER}" = "clang" ]; then
      do_sed $"s/CCOMPILER=/CCOMPILER=clang/g"                        .mozconfig
      do_sed $"s/CXXCOMPILER=/CXXCOMPILER=clang++/g"                  .mozconfig
    else
      do_sed $"s/CCOMPILER=/CCOMPILER=gcc/g"                          .mozconfig
      do_sed $"s/CXXCOMPILER=/CXXCOMPILER=g++/g"                      .mozconfig
    fi

    if [ "$MOZ_DEBUG" = "yes" ]; then
      echo "ac_add_options --enable-debug"          >> .mozconfig
      echo "ac_add_options --disable-optimize"      >> .mozconfig
      echo "ac_add_options --disable-install-strip" >> .mozconfig
      echo "ac_add_options --enable-debug-symbols"  >> .mozconfig
    else
      echo "ac_add_options --disable-debug"         >> .mozconfig
      echo "ac_add_options --enable-optimize"       >> .mozconfig
    fi
    popd

    pushd ${DEST}
      echo "Configuring, to see log, tail -F ${PWD}/configure.log from another terminal"
      time make -f ${PWD}/../${SRC}/client.mk configure > configure.log 2>&1 || ( echo "configure failed, see ${PWD}/configure.log" ; exit 1 )
      echo "Building, to see log, tail -F ${PWD}/build.log from another terminal"
      time make -f ${PWD}/../${SRC}/client.mk build     > build.log 2>&1 || ( echo "build failed, see ${PWD}/build.log" ; exit 1 )
      echo "Packaging, to see log, tail -F ${PWD}/package.log from another terminal"
      time make -C obj-macos package INNER_MAKE_PACKAGE=true > package.log 2>&1 || ( echo "package failed, see ${PWD}/package.log" ; exit 1 )
    popd
  fi
}

firefox_package()
{
  pushd ${DEST}
    pushd obj-macos/dist/firefox
      TARFILE=Firefox${MOZBUILDSUFFIX}-${MOZ_VERSION}-darwin-${MOZ_TARGET_ARCH}.app-built-on-${OSTYPE}-${HOST_ARCH}${MINGW_W64_HASH}-clang-${LLVM_VERSION}-${HOSTNAME}-$(date +%Y%m%d).tar.bz2
      [ -f ${TARFILE} ] && rm -f ${TARFILE}
      REGEN_DIR=$PWD/build-scripts
      copy_build_scripts $REGEN_DIR
      ${THISDIR}/tar-sorted.sh -cjf ${TARFILE} Firefox${MOZBUILDSUFFIX}.app build-scripts
      mv ${TARFILE} ${THISDIR}
      echo "All done!"
      echo "ls -l ${THISDIR}/${TARFILE}"
      ls -l ${THISDIR}/${TARFILE}
    popd
  popd
}

ROOT=$PWD
download_build_compilers

if [ "${OSTYPE}" = "msys" ]; then
  export PYTHON=$MINGW_W64_PATH/../opt/bin/python.exe
else
  export PYTHON=python2
fi

BUILD_PREFIX=${LLVM_VERS_}-${GCC_VERS_}-${HOST_ARCH}${MINGW_W64_HASH}
if [ "$COMPILER_RT" = "yes" ]; then
  BUILD_PREFIX="${BUILD_PREFIX}-rt"
fi

STUB=x-$(_al TARGET_TO_PREFIX $TARGET_OS)
if [ "$OSTYPE" = "msys" ]; then
  # Avoid over-long build paths on Windows, a real-world example:
  # echo "C:/msys64/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-gettext-build-x86_64-build_w64-mingw32/gettext-tools/gnulib-lib/.libs/libgettextlib.lax/libcroco_rpl.a/libcroco_rpl_la-cr-additional-sel.o" | wc -c
  # 263.
  BUILDDIR=/c/ctng-build-${STUB}-${BUILD_PREFIX}
else
  BUILDDIR=ctng-build-${STUB}-${BUILD_PREFIX}
fi
INTALLDIR=ctng-install-${STUB}-${BUILD_PREFIX}
BUILT_XCOMPILER_PREFIX=$PWD/${STUB}-${BUILD_PREFIX}

# Because CT_GetGit doesn't download to $HOME/src, but instead into
# tarballs in the .build folder, and cloning these takes a long
# time, we only remove what we must ..
if [ "${LLVM_VERSION}" = "HEAD" ]; then
  if [ ! -f ${BUILT_XCOMPILER_PREFIX}/bin/${CROSSCC}-clang ]; then
    set +e
    rm -rf ${BUILDDIR}/.build/src ${BUILDDIR}/.build/*
    set -e
  fi
fi

ROOT=$PWD
download_sdk
cross_clang_build
cross_clang_package

PATH="${PATH}":${BUILT_XCOMPILER_PREFIX}/bin

if [ "$MOZ_DEBUG" = "yes" ]; then
  BUILDSUFFIX=${LLVM_VERSION}-${MOZ_TARGET_ARCH}-dbg${MINGW_W64_HASH}
  MOZBUILDSUFFIX=Debug
else
  BUILDSUFFIX=${LLVM_VERSION}-${MOZ_TARGET_ARCH}-rel${MINGW_W64_HASH}
  MOZBUILDSUFFIX=
fi

if [ "$MOZ_BUILD_IN_SRCDIR" = "yes" ]; then
  BUILDDIRSUFFIX=.patched-${BUILDSUFFIX}
else
  BUILDDIRSUFFIX=${BUILDSUFFIX}
fi

echo "About to download Firefox ($MOZ_VERSION)"
SRC=$(firefox_download)
echo "About to patch Firefox ($MOZ_VERSION)"
firefox_patch "${SRC}"
echo "About to build Firefox ($MOZ_VERSION)"
firefox_build
echo "About to package Firefox ($MOZ_VERSION)"
firefox_package
echo "All done!"
exit 0
















































































































































































































# Here be nonsense; scratch area for things I'd otherwise forget. Ignore.

cd libstuff && /Applications/Xcode.app/Contents/Developer/usr/bin/make

pushd /Users/raydonnelly/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cctools-host-x86_64-build_apple-darwin13.0.0/libstuff

x86_64-build_apple-darwin13.0.0-gcc   -DHAVE_CONFIG_H    -I../include -I/Users/raydonnelly/tbb-work/ctng-build/.build/src/cctools-809/include -include ../include/config.h  -O2 -g -pipe  -I/Users/raydonnelly/tbb-work/ctng-build/.build/x86_64-apple-darwin10/buildtools/include/ -D__DARWIN_UNIX03 -D__STDC_LIMIT_MACROS -D__STDC_CONSTANT_MACROS -I/Users/raydonnelly/x-tools/x86_64-apple-darwin10/include -fno-builtin-round -fno-builtin-trunc  -DLTO_SUPPORT -DTRIE_SUPPORT -mdynamic-no-pic -DLTO_SUPPORT -c -o allocate.o /Users/raydonnelly/tbb-work/ctng-build/.build/src/cctools-809/libstuff/allocate.c

# I must stop patching the Apple headers
SDKFILES=$(grep +++ crosstool-ng/patches/cctools/809/100-add_sdkroot_headers.patch | sort | cut -d' ' -f2 | cut -f1)
OTHERPATCHES=$(find crosstool-ng/patches/cctools/809/ -name "*.patch" -and -not -name "100-*" | sort)
for SDKFILE in $SDKFILES; do
 for PATCH in $OTHERPATCHES; do
  if grep "+++ $SDKFILE" $PATCH > /dev/null; then
   echo "Found $SDKFILE in $PATCH"
  fi
 done
done

"
Found b/include/ar.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/include/objc/List.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/include/objc/Object.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/include/objc/objc-class.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/include/objc/objc-runtime.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/include/objc/zone.h in crosstool-ng/patches/cctools/809/110-import_to_include.patch
Found b/ld64/include/mach-o/dyld_images.h in crosstool-ng/patches/cctools/809/280-missing_includes.patch

.. Analysis:
diff -urN a/ld64/include/mach-o/dyld_images.h b/ld64/include/mach-o/dyld_images.h
--- a/ld64/include/mach-o/dyld_images.h 2013-10-07 17:09:15.402543795 +0100
+++ b/ld64/include/mach-o/dyld_images.h 2013-10-07 17:09:15.555879483 +0100
@@ -25,6 +25,9 @@

 #include <stdbool.h>
 #include <unistd.h>
+#ifndef __APPLE__
+#include <uuid/uuid.h>
+#endif
 #include <mach/mach.h>

 #ifdef __cplusplus

# brew install llvm34 --with-clang --with-asan --HEAD

class Llvm34 < Formula
  homepage  'http://llvm.org/'
  head do
    url 'http://llvm.org/git/llvm.git'

    resource 'clang' do
      url 'http://llvm.org/git/clang.git'
    end

    resource 'clang-tools-extra' do
      url 'http://llvm.org/git/clang-tools-extra.git'
    end

    resource 'compiler-rt' do
      url 'http://llvm.org/git/compiler-rt.git'
    end

    resource 'polly' do
      url 'http://llvm.org/git/polly.git'
    end

    resource 'libcxx' do
      url 'http://llvm.org/git/libcxx.git'
    end

    resource 'libcxxabi' do
      url 'http://llvm.org/git/libcxxabi.git'
    end if MacOS.version <= :snow_leopard
  end


pushd /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/lib/Driver
PATH=$PWD/../../../../../../buildtools/bin:$PATH

pushd /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/projects/compiler-rt
PATH=$PWD/../../../../buildtools/bin:$PATH
make -j1 -l CFLAGS="-O2 -g -pipe -DCLANG_GCC_VERSION=' '" CXXFLAGS="-O2 -g -pipe" LDFLAGS="-DCLANG_GCC_VERSION=' '" ONLY_TOOLS="clang" ENABLE_OPTIMIZED=1


pushd /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final
PATH=$PWD/../../buildtools/bin:$PATH
make -j1 CFLAGS="-O2 -g -pipe -DCLANG_GCC_VERSION=" CXXFLAGS="-O2 -g -pipe" LDFLAGS="-DCLANG_GCC_VERSION=" ONLY_TOOLS="clang" ENABLE_OPTIMIZED="1"

# Then the following fails:
pushd /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final
/home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/Release+Asserts/bin/clang -arch x86_64 -dynamiclib -o /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/libcompiler_rt.dylib /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_allocator2.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_dll_thunk.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_fake_stack.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_globals.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_interceptors.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_linux.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_mac.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_malloc_linux.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_malloc_mac.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_malloc_win.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_new_delete.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_poisoning.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_posix.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_preinit.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_report.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_rtl.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_stack.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_stats.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_thread.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_win.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib/int_util.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__interception/interception_linux.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__interception/interception_mac.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__interception/interception_type_test.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__interception/interception_win.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_allocator.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_common.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_common_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_coverage.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_flags.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_libc.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_libignore.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_linux.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_linux_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_mac.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_platform_limits_linux.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_platform_limits_posix.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_posix.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_posix_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_printf.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_stackdepot.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_stacktrace.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_stacktrace_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_stoptheworld_linux_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_suppressions.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_symbolizer.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_symbolizer_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_symbolizer_posix_libcdep.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_symbolizer_win.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_thread_registry.o   /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__sanitizer_common/sanitizer_win.o -DCLANG_GCC_VERSION= -B/home/ray/x-tools/x86_64-apple-darwin10/bin/x86_64-apple-darwin10- --sysroot=/home/ray/x-tools/x86_64-apple-darwin10/x86_64-apple-darwin10/sysroot -framework Foundation -L/home/ray/x-tools/x86_64-apple-darwin10/x86_64-apple-darwin10/sysroot/usr/lib/x86_64-apple-darwin10/4.2.1/ -lstdc++ -undefined dynamic_lookup
ld: warning: can't parse dwarf compilation unit info in /home/ray/tbb-work/ctng-build/.build/x86_64-apple-darwin10/build/build-cc-clang-final/tools/clang/runtime/compiler-rt/clang_darwin/asan_osx_dynamic/x86_64/SubDir.lib__asan/asan_allocator2.o

# More failures:
[INFO ]  Installing final clang compiler: done in 1298.48s (at 37:15)
[INFO ]  =================================================================
[INFO ]  Cleaning-up the toolchain's directory
[INFO ]    Stripping all toolchain executables
[37:15] / /usr/bin/sed: can't read /home/ray/tbb-work/ctng-build-3_3/.build/src/gcc-/gcc/version.c: No such file or directory
[ERROR]
"

# Dsymutil not existing rears its ugly head again, this time with ICU as -g is used ..
# configure:2917: /home/ray/tbb-work/dx-HEAD/bin/x86_64-apple-darwin10-clang -arch x86_64 -isysroot /home/ray/MacOSX10.6.sdk -fPIC -Qunused-arguments -Wall -Wpointer-arith -Wdeclaration-after-statement -Werror=return-type -Wtype-limits -Wempty-body -Wsign-compare -Wno-unused -std=gnu99 -fno-common -fno-math-errno -pthread -pipe -g  -DU_USING_ICU_NAMESPACE=0 -DU_NO_DEFAULT_INCLUDE_UTF_HEADERS=1 -DUCONFIG_NO_LEGACY_CONVERSION -DUCONFIG_NO_TRANSLITERATION -DUCONFIG_NO_REGULAR_EXPRESSIONS -DUCONFIG_NO_BREAK_ITERATION -Qunused-arguments   -framework ExceptionHandling   -lobjc conftest.c  >&5
# x86_64-apple-darwin10-clang: error: unable to execute command: Executable "dsymutil" doesn't exist!
# x86_64-apple-darwin10-clang: error: dsymutil command failed with exit code 1 (use -v to see invocation)

# MSYS64 build failure with LLVM Python:
# mkdir /home/ray/tbb-work/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32-2
# pushd /home/ray/tbb-work/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32-2
# CFLAGS="-O2 -g -pipe -D__USE_MINGW_ANSI_STDIO=1" CXXFLAGS="-O2 -g -pipe  -D__USE_MINGW_ANSI_STDIO=1" ../build-LLVM-host-x86_64-build_w64-mingw32/configure --build=x86_64-build_w64-mingw32 --host=x86_64-build_w64-mingw32 --prefix=/home/ray/tbb-work/dx-HEAD --target=x86_64-apple-darwin10 --enable-optimized=yes


############################################################
# If you ever need to patch llvm/clang configury stuff ... #
# this should fetch, build and path the right autotools ver#
# Build build tools .. only needed when updating autotools #
############################################################

# Versions for llvm
AUTOCONF_VER=2.60
AUTOMAKE_VER=1.9.6
LIBTOOL_VER=1.5.22
# Versions for isl 0.11.1
AUTOCONF_VER=2.68
AUTOMAKE_VER=1.11.3
LIBTOOL_VER=2.4
# Versions for isl 0.12.1
AUTOCONF_VER=2.69
AUTOMAKE_VER=1.11.6
LIBTOOL_VER=2.4
# Versions for GCC 4.8.2
AUTOCONF_VER=2.64
AUTOMAKE_VER=1.11.1
#LIBTOOL_VER=2.2.7a
[ -d tools ] || mkdir tools
pushd tools > /dev/null
if [ ! -f bin/autoconf ]; then
# curl -SLO http://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.bz2
 wget -c http://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.gz
 tar -xf autoconf-${AUTOCONF_VER}.tar.gz
 cd autoconf-${AUTOCONF_VER}
 wget -O config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
 wget -O config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD' 
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
if [ ! -f bin/automake ]; then
 wget -c http://ftp.gnu.org/gnu/automake/automake-${AUTOMAKE_VER}.tar.gz
 tar -xf automake-${AUTOMAKE_VER}.tar.gz
 cd automake-${AUTOMAKE_VER}
 wget -O config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
 wget -O config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD' 
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
if [ ! -f bin/libtool ]; then
 curl -SLO http://ftp.gnu.org/gnu/libtool/libtool-${LIBTOOL_VER}.tar.gz
 tar -xf libtool-${LIBTOOL_VER}.tar.gz
 cd libtool-${LIBTOOL_VER}
 wget -O config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
 wget -O config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD' 
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
# Test re-autoconfigured GCC with my patch ..
export PATH=$PWD/tools/bin:$PATH
popd > /dev/null
pushd /tmp
tar -xf ~/src/gcc-4.8.2.tar.bz2
cp -rf gcc-4.8.2 gcc-4.8.2.orig
pushd gcc-4.8.2
# patch -p1 < ~/ctng-firefox-builds/crosstool-ng/patches/gcc/4.8.2/100-msys-native-paths-gengtype.patch
find ./ -name configure.ac | while read f; do (cd "$(dirname "$f")"/ && [ -f configure ] && autoconf); done
popd
mkdir gcc-build
pushd gcc-build
/tmp/gcc-4.8.2/configure 2>&1 | grep "absolute srcdir"
make 2>&1 | grep "checking the absolute srcdir"
popd
popd

# single liner to iterate quickly on changing configure.ac:
cfg_build()
{
#pushd gcc-4.8.2/gcc
#autoconf
#popd
[ -d gcc-build ] && rm -rf gcc-build
mkdir gcc-build
pushd gcc-build
if [ "$OSTYPE" = "msys" ]; then
  export PATH=/home/ukrdonnell/ctng-firefox-builds/mingw64-235295c4/bin:$PATH
  BHT="--build=x86_64-build_w64-mingw32 --host=x86_64-build_w64-mingw32 --target=x86_64-unknown-linux-gnu \
  --with-gmp=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools --with-mpfr=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools --with-mpc=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools --with-isl=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools --with-cloog=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools --with-libelf=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --prefix=/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools"
fi
/tmp/gcc-4.8.2/configure $BHT 2>&1 > configure.log # | grep "checking the absolute srcdir"
make 2>&1 > make.log # | grep "checking the absolute srcdir"
popd
}

# Regenerate the patch:
find gcc-4.8.2 \( -name "*.orig" -or -name "*.rej" -or -name "*.old" -or -name "autom4te.cache" -or -name "config.in~" \) -exec rm -rf {} \;
diff -urN gcc-4.8.2.orig gcc-4.8.2 > ~/Dropbox/gcc482.new.patch

# Even with sjlj Windows 64bit has problems:
# [ALL  ]    C:/msys64/home/ray/tbb-work-sjlj/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32/Release+Asserts/lib/libgtest.a(gtest-all.o): In function `testing::internal::DefaultDeathTestFactory::~DefaultDeathTestFactory()':
# [ALL  ]    C:/msys64/home/ray/tbb-work-sjlj/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32/utils/unittest/googletest/include/gtest/internal/gtest-death-test-internal.h:148: undefined reference to `testing::internal::DeathTestFactory::~DeathTestFactory()'
# [ALL  ]    C:/msys64/home/ray/tbb-work-sjlj/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32/Release+Asserts/lib/libgtest.a(gtest-all.o): In function `~DefaultDeathTestFactory':
# [ALL  ]    C:/msys64/home/ray/tbb-work-sjlj/ctng-build-HEAD/.build/x86_64-apple-darwin10/build/build-LLVM-host-x86_64-build_w64-mingw32/utils/unittest/googletest/include/gtest/internal/gtest-death-test-internal.h:148: undefined reference to `testing::internal::DeathTestFactory::~DeathTestFactory()'
# [ERROR]    collect2.exe: error: ld returned 1 exit status
# These errors are all to do with libgtest though so maybe disable that for now?


# Updating all config.sub / .guess for MSYS2:
mkdir -p /tmp/configs/
rm -rf a b
#cp -rf mozilla-esr24 a
pushd mozilla-central
hg archive ../a
popd
cp -rf a b
wget -O /tmp/configs/config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
wget -O /tmp/configs/config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
pushd b
CONFIG_SUBS=$(find $PWD -name "config.sub")
for CONFIG_SUB in $CONFIG_SUBS; do
  pushd $(dirname $CONFIG_SUB)
  cp -rf /tmp/configs/* .
  popd
done
popd
diff -urN a b > update-config-sub-config-guess-for-MSYS2.patch

# Making a git am'able patch after a merge has happened ( http://stackoverflow.com/questions/2285699/git-how-to-create-patches-for-a-merge )
# git log -p --pretty=email --stat -m --first-parent 7eafc9dce69a184d1b75e4fa26063dd38c863ea4..HEAD


# Compiling libgcc_s.so uses wrong multilib variant by the look of it.
pushd /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc && rm -f 32/libgcc_s.so && if [ -f 32/libgcc_s.so.1 ]; then mv -f 32/libgcc_s.so.1 32/libgcc_s.so.1.backup; else true; fi && mv 32/libgcc_s.so.1.tmp 32/libgcc_s.so.1 && ln -s libgcc_s.so.1 32/libgcc_s.so
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc -v
# So even though -print-multi-lib shows what we expect .. it doesn't seem to be look in that folder.
# but unfortunately, even if it did look in the right place, they contain the wrong stuff.
# [ray@arch-work libgcc]$ file /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/libc.so
# /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/libc.so: ELF 64-bit LSB  shared object, x86-64, version 1 (SYSV), dynamically linked, not stripped
# [ray@arch-work libgcc]$ file /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/32/libc.so
# /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/32/libc.so: ELF 64-bit LSB  shared object, x86-64, version 1 (SYSV), dynamically linked, not stripped
# [ray@arch-work libgcc]$ ls -l /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/
# Hmm .. here's how mingw-w64 say to do it:
# http://sourceforge.net/apps/trac/mingw-w64/wiki/Answer%20Multilib%20Toolchain

# pushd /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc
# /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc

From: /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/gcc-4.8.2/libgcc/Makefile.in
libgcc_s$(SHLIB_EXT): $(libgcc-s-objects) $(extra-parts) libgcc.a
        # @multilib_flags@ is still needed because this may use
        # $(GCC_FOR_TARGET) and $(LIBGCC2_CFLAGS) directly.
        # @multilib_dir@ is not really necessary, but sometimes it has
        # more uses than just a directory name.
        $(mkinstalldirs) $(MULTIDIR)
        $(subst @multilib_flags@,$(CFLAGS) -B./,$(subst \
                @multilib_dir@,$(MULTIDIR),$(subst \
                @shlib_objs@,$(objects) libgcc.a,$(subst \
                @shlib_base_name@,libgcc_s,$(subst \
                @shlib_map_file@,$(mapfile),$(subst \
                @shlib_slibdir_qual@,$(MULTIOSSUBDIR),$(subst \
                @shlib_slibdir@,$(shlib_slibdir),$(SHLIB_LINK))))))))


/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/libgcc/Makefile

libgcc_s$(SHLIB_EXT): $(libgcc-s-objects) $(extra-parts) libgcc.a
        # @multilib_flags@ is still needed because this may use
        # $(GCC_FOR_TARGET) and $(LIBGCC2_CFLAGS) directly.
        # @multilib_dir@ is not really necessary, but sometimes it has
        # more uses than just a directory name.
        $(mkinstalldirs) $(MULTIDIR)
        $(subst @multilib_flags@,$(CFLAGS) -B./,$(subst \
                @multilib_dir@,$(MULTIDIR),$(subst \
                @shlib_objs@,$(objects) libgcc.a,$(subst \
                @shlib_base_name@,libgcc_s,$(subst \
                @shlib_map_file@,$(mapfile),$(subst \
                @shlib_slibdir_qual@,$(MULTIOSSUBDIR),$(subst \
                @shlib_slibdir@,$(shlib_slibdir),$(SHLIB_LINK))))))))

/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc && rm -f 32/libgcc_s.so && if [ -f 32/libgcc_s.so.1 ]; then mv -f 32/libgcc_s.so.1 32/libgcc_s.so.1.backup; else true; fi && mv 32/libgcc_s.so.1.tmp 32/libgcc_s.so.1 && ln -s libgcc_s.so.1 32/libgcc_s.so

Makefiles:
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/libgcc/Makefile
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc/Makefile

.. 2nd one has ..

MULTIDIRS =
MULTISUBDIR = /32

.. but why MULTIDIRS when the usages in same file are of MULTIDIR

Failure line is:
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc

.. which contains:  -m32 -B./



From Arch linux:
https://projects.archlinux.org/svntogit/community.git/tree/trunk/PKGBUILD?h=packages/lib32-glibc

${srcdir}/${_pkgbasename}-${pkgver}/configure --prefix=/usr \
     --libdir=/usr/lib32 --libexecdir=/usr/lib32 \
     --with-headers=/usr/include \
     --with-bugurl=https://bugs.archlinux.org/ \
     --enable-add-ons=nptl,libidn \
     --enable-obsolete-rpc \
     --enable-kernel=2.6.32 \
     --enable-bind-now --disable-profile \
     --enable-stackguard-randomization \
     --enable-lock-elision \
     --enable-multi-arch i686-unknown-linux-gnu

# enable-multi-arch is something like Apple's fat binaries I think, so probably not relevant to this, also it doesn't take any option.

from /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-libc-startfiles_32/config.log
Our configure for libc_startfiles_32:
$ /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/glibc-2.18/configure --prefix=/usr \
   --build=x86_64-build_unknown-linux-gnu --host=i686-unknown-linux-gnu --cache-file=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-libc-startfiles_32/config.cache \
   --without-cvs --disable-profile --without-gd --with-headers=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/include \
   --disable-debug --disable-sanity-checks --enable-kernel=2.6.33 --with-__thread --with-tls --enable-shared --enable-add-ons=nptl --with-pkgversion=crosstool-NG hg+unknown-20131121.135846

from /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-libc-startfiles/config.log
Out configure for libc_startfiles:
$ /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/glibc-2.18/configure --prefix=/usr \
  --build=x86_64-build_unknown-linux-gnu --host=x86_64-unknown-linux-gnu --cache-file=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-libc-startfiles/config.cache \
  --without-cvs --disable-profile --without-gd --with-headers=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/include \
  --disable-debug --disable-sanity-checks --enable-kernel=2.6.33 --with-__thread --with-tls --enable-shared --enable-add-ons=nptl --with-pkgversion=crosstool-NG hg+unknown-20131121.135846

.. so      --enable-multi-arch i686-unknown-linux-gnu is not being passed in here?

/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/glibc-2.18/configure --help does not list any arguments for --enable-multi-arch

https://wiki.debian.org/Multiarch/HOWTO

from: https://sourceware.org/glibc/wiki/x32 :

they enable x32 like this:
--target=x86_64-x32-linux --build=x86_64-linux --host=x86_64-x32-linux

From gcc-multilib:
https://projects.archlinux.org/svntogit/community.git/tree/trunk/PKGBUILD?h=packages/gcc-multilib

 ${srcdir}/${_basedir}/configure --prefix=/usr \
      --libdir=/usr/lib --libexecdir=/usr/lib \
      --mandir=/usr/share/man --infodir=/usr/share/info \
      --with-bugurl=https://bugs.archlinux.org/ \
      --enable-languages=c,c++,ada,fortran,go,lto,objc,obj-c++ \
      --enable-shared --enable-threads=posix \
      --with-system-zlib --enable-__cxa_atexit \
      --disable-libunwind-exceptions --enable-clocale=gnu \
      --disable-libstdcxx-pch \
      --enable-gnu-unique-object --enable-linker-build-id \
      --enable-cloog-backend=isl --disable-cloog-version-check \
      --enable-lto --enable-gold --enable-ld=default \
      --enable-plugin --with-plugin-ld=ld.gold \
      --with-linker-hash-style=gnu --disable-install-libiberty \
      --enable-multilib --disable-libssp --disable-werror \
      --enable-checking=release

From /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/config.log
$ /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/gcc-4.8.2/configure \
  --build=x86_64-build_unknown-linux-gnu --host=x86_64-build_unknown-linux-gnu --target=x86_64-unknown-linux-gnu \
  --prefix=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-local-prefix=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot \
  --disable-libmudflap \
  --with-sysroot=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot \
  --enable-shared --with-pkgversion=crosstool-NG hg+unknown-20131121.135846 \
  --enable-__cxa_atexit \
  --with-gmp=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-mpfr=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-mpc=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-isl=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-cloog=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-libelf=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools \
  --enable-lto \
  --with-host-libstdcxx=-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm \
  --enable-target-optspace --disable-libgomp --disable-libmudflap --disable-nls --enable-multilib --enable-languages=c

.. Getting to the nuts and bolts of the failure:

pushd /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc
PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin:/home/ray/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/core_perl:/home/ray/ctng-firefox-builds//bin
# /home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin *** <- contains binutils install.
# /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin *** <- contains GCC stage 1 and some shell scripts too (x86_64-unknown-linux-gnu-gcc is GCC stage 1, x86_64-build_unknown-linux-gnu-g++ is shell)
# /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin *** <- contains sed awk wrapper scripts etc.
pushd /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc
PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin:/home/ray/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/core_perl:/home/ray/ctng-firefox-builds//bin \
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -B./ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc


PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin:/home/ray/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/core_perl:/home/ray/ctng-firefox-builds//bin /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/sys-include    -O2  -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include   -fpic -mlong-double-80 -g -DIN_LIBGCC2 -fbuilding-libgcc -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32 -Bm32/ _muldi3_s.o _negdi2_s.o _lshrdi3_s.o _ashldi3_s.o _ashrdi3_s.o _cmpdi2_s.o _ucmpdi2_s.o _clear_cache_s.o _trampoline_s.o __main_s.o _absvsi2_s.o _absvdi2_s.o _addvsi3_s.o _addvdi3_s.o _subvsi3_s.o _subvdi3_s.o _mulvsi3_s.o _mulvdi3_s.o _negvsi2_s.o _negvdi2_s.o _ctors_s.o _ffssi2_s.o _ffsdi2_s.o _clz_s.o _clzsi2_s.o _clzdi2_s.o _ctzsi2_s.o _ctzdi2_s.o _popcount_tab_s.o _popcountsi2_s.o _popcountdi2_s.o _paritysi2_s.o _paritydi2_s.o _powisf2_s.o _powidf2_s.o _powixf2_s.o _powitf2_s.o _mulsc3_s.o _muldc3_s.o _mulxc3_s.o _multc3_s.o _divsc3_s.o _divdc3_s.o _divxc3_s.o _divtc3_s.o _bswapsi2_s.o _bswapdi2_s.o _clrsbsi2_s.o _clrsbdi2_s.o _fixunssfsi_s.o _fixunsdfsi_s.o _fixunsxfsi_s.o _fixsfdi_s.o _fixdfdi_s.o _fixxfdi_s.o _fixunssfdi_s.o _fixunsdfdi_s.o _fixunsxfdi_s.o _floatdisf_s.o _floatdidf_s.o _floatdixf_s.o _floatundisf_s.o _floatundidf_s.o _floatundixf_s.o _divdi3_s.o _moddi3_s.o _udivdi3_s.o _umoddi3_s.o _udiv_w_sdiv_s.o _udivmoddi4_s.o cpuinfo_s.o tf-signs_s.o sfp-exceptions_s.o addtf3_s.o divtf3_s.o eqtf2_s.o getf2_s.o letf2_s.o multf3_s.o negtf2_s.o subtf3_s.o unordtf2_s.o fixtfsi_s.o fixunstfsi_s.o floatsitf_s.o floatunsitf_s.o fixtfdi_s.o fixunstfdi_s.o floatditf_s.o floatunditf_s.o extendsftf2_s.o extenddftf2_s.o extendxftf2_s.o trunctfsf2_s.o trunctfdf2_s.o trunctfxf2_s.o enable-execute-stack_s.o unwind-dw2_s.o unwind-dw2-fde-dip_s.o unwind-sjlj_s.o unwind-c_s.o emutls_s.o libgcc.a -lc -v


/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc


PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin:/home/ray/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/core_perl:/home/ray/ctng-firefox-builds//bin 

/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc \
  -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ \
  -m32 -lc -v -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32  libgcc.a -lc 

PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/tools/bin:/home/ray/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/core_perl:/home/ray/ctng-firefox-builds//bin gdbserver 127.0.0.1:6900 /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc \
-B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/lib/ \
-m32 -lc -v -fno-stack-protector  -shared -nodefaultlibs -Wl,--soname=libgcc_s.so.1 -Wl,--version-script=libgcc.map -o 32/libgcc_s.so.1.tmp -g -Os -m32  libgcc.a -lc 

Gives:
LIBRARY_PATH=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/32/:/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/lib/../lib/:/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/../lib/:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/buildtools/x86_64-unknown-linux-gnu/bin/:/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/lib/:/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot/usr/lib/


# Some info from MinGW-w64 about multilib cross compilers: http://sourceforge.net/apps/trac/mingw-w64/wiki/Cross%20Win32%20and%20Win64%20compiler
# Binutils:
../path/to/configure --target=x86_64-w64-mingw32 \
--enable-targets=x86_64-w64-mingw32,i686-w64-mingw32

[DEBUG]    ==> Executing: 'CFLAGS=-O0 -ggdb -pipe ' 'CXXFLAGS=-O0 -ggdb -pipe ' 'LDFLAGS= ' '/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/src/binutils-2.22/configure' '--build=x86_64-build_unknown-linux-gnu' '--host=x86_64-build_unknown-linux-gnu' '--target=x86_64-unknown-linux-gnu' '--prefix=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64' '--disable-werror' '--enable-ld=yes' '--enable-gold=no' '--with-pkgversion=crosstool-NG hg+unknown-20131121.233230' '--enable-multilib' '--disable-nls' '--with-sysroot=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64/x86_64-unknown-linux-gnu/sysroot' 
# Oddly neither --enable-targets nor --enable-multilib show up from configure --help, and --enable-targets doesn't appear in the script either (--enable-multilib does though)
# It seems like binutils targets can be specified as any free parameters on the end due to:
# *) as_fn_append ac_config_targets " $1"


# GCC:
For multilib:
../path/to/configure --target=x86_64-w64-mingw32 --enable-targets=all

.. I added:

    if [ "${CT_MULTILIB}" = "y" ]; then
        extra_config+=("--enable-multilib")
        extra_config+=("--enable-targets=all")
    else
        extra_config+=("--disable-multilib")
    fi

.. to 100-gcc.sh but it made no difference.


# A difference comparer:
export TEHCC=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/xgcc ; export OPTS="-isystem arse -B. -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/"; $TEHCC ~/Dropbox/a.c $OPTS -m64 -v > ~/Dropbox/m64.txt 2>&1; $TEHCC ~/Dropbox/a.c $OPTS -m32 -v > ~/Dropbox/m32.txt 2>&1
export TEHCC=gcc ; export OPTS="-isystem arse -B. -B/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/./gcc/"; $TEHCC ~/Dropbox/a.c $OPTS -m64 -v > ~/Dropbox/m64.txt 2>&1; $TEHCC ~/Dropbox/a.c $OPTS -m32 -v > ~/Dropbox/m32.txt 2>&1

# bcompare ~/Dropbox/m32.txt ~/Dropbox/m64.txt &

.. At the end of the day, "-B./" is the problem, we got  -m32 -B./ 
and according to:
http://gcc.gnu.org/onlinedocs/gcc/Directory-Options.html
"The runtime support file libgcc.a can also be searched for using the -B prefix, if needed. If it is not found there, the two standard prefixes above are tried, and that is all. The file is left out of the link if it is not found by those means."

# More, so I guess my dummy libc's need to be put in the right folders, which appear to be the stage 2 libgcc folders?
# i.e. /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc
#  and /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-2/x86_64-unknown-linux-gnu/32/libgcc/m32
# http://www.emdebian.org/~zumbi/sysroot/gcc-4.6-arm-sysroot-linux-gnueabihf-0.1/build-sysroot

# Seems like an interesting page:
# http://trac.cross-lfs.org/
# CLFS takes advantage of the target system's capability, by utilizing a multilib capable build system
# CLFS-x86.pdf is a very useful document.

pushd ~/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64/.build/x86_64-unknown-linux-gnu/build/build-cc-gcc-core-pass-1/gcc
build/gengtype.exe                      -S /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/gcc -I gtyp-input.list -w tmp-gtype.state

isl problems (ffs).
pushd /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/build/build-isl-host-x86_64-build_w64-mingw32
rm ./libisl_la-isl_map_simplify.*
export PATH=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools/bin:$PATH
  make V=1

# Leads to:
x86_64-build_w64-mingw32-gcc -DHAVE_CONFIG_H -I. -I/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/isl-0.11.1 -I/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/isl-0.11.1/include -Iinclude/ -I. -I/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/isl-0.11.1 -I/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/isl-0.11.1/include -Iinclude/ -I/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools/include -O0 -ggdb -pipe -D__USE_MINGW_ANSI_STDIO=1 -MT libisl_la-isl_map_simplify.lo -MD -MP -MF .deps/libisl_la-isl_map_simplify.Tpo -c /home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/isl-0.11.1/isl_map_simplify.c -o libisl_la-isl_map_simplify.o


# My old gengtypes patch isn't working?!
export PATH=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64-235295c4/bin:/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools/bin:$PATH
CC_FOR_BUILD=x86_64-build_w64-mingw32-gcc CFLAGS_FOR_BUILD= CFLAGS="-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" \
  CXXFLAGS="-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" LDFLAGS= \
/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/configure \
  --build=x86_64-build_w64-mingw32 --host=x86_64-build_w64-mingw32 --target=x86_64-unknown-linux-gnu \
  --prefix=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-local-prefix=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64-235295c4/x86_64-unknown-linux-gnu/sysroot \
  --disable-libmudflap --with-sysroot=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64-235295c4/x86_64-unknown-linux-gnu/sysroot \
  --with-newlib --enable-threads=no --disable-shared --with-pkgversion=crosstool-NG hg+unknown-20131201.170407 \
  --enable-__cxa_atexit --with-gmp=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-mpfr=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-mpc=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-isl=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-cloog=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --with-libelf=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
  --enable-lto --with-host-libstdcxx="-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm" \
  --enable-target-optspace --disable-libgomp --disable-libmudflap --disable-nls --enable-multilib --enable-targets=all --enable-languages=c


/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/gcc/configure \
--cache-file=./config.cache --prefix=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-local-prefix=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64-235295c4/x86_64-unknown-linux-gnu/sysroot \
--with-sysroot=/home/ray/ctng-firefox-builds/x-l-HEAD-x86_64-235295c4/x86_64-unknown-linux-gnu/sysroot --with-newlib --enable-threads=no \
--disable-shared --with-pkgversion=crosstool-NG hg+unknown-20131201.170407 --enable-__cxa_atexit \
--with-gmp=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-mpfr=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-mpc=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-isl=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-cloog=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--with-libelf=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/x86_64-unknown-linux-gnu/buildtools \
--enable-lto --with-host-libstdcxx="-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm" \
--enable-target-optspace --disable-libgomp --disable-libmudflap --disable-nls --enable-multilib --enable-targets=all --enable-languages=c,lto \
--program-transform-name="s&^&x86_64-unknown-linux-gnu-&" --disable-option-checking \
--build=x86_64-build_w64-mingw32 --host=x86_64-build_w64-mingw32 --target=x86_64-unknown-linux-gnu \
--srcdir=/home/ray/ctng-firefox-builds/ctng-build-x-l-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/gcc



# Current working directory isn't searched on Windows for cc1; well, it is, but not with .exe extension.
# C:\msys64\home\ukrdonnell\ctng-firefox-builds\ctng-build-x-r-HEAD-x86_64-235295c4\.build\src\gcc-4.8.2\libiberty\pex-win32.c

# Got a potential fix .. maybe not, but it fixed the issue when debugging under QtCreator at least.
cp ~/Dropbox/pex-win32.c C:/msys64/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/libiberty
pushd C:/msys64/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1
export PATH=/home/ukrdonnell/ctng-firefox-builds/x-r-HEAD-x86_64-235295c4/bin:/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/bin:/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin:/home/ukrdonnell/ctng-firefox-builds/mingw64-235295c4/bin:$PATH


# Despite that patch seeming to work (it arguably shouldn't be needed due to -B flag anyway):
[ALL  ]    echo "" | /home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ -E -dM - |   sed -n -e 's/^#define ([^_][a-zA-Z0-9_]*).*/1/p' 	 -e 's/^#define (_[^_A-Z][a-zA-Z0-9_]*).*/1/p' |   sort -u > tmp-macro_list
[ALL  ]    echo GCC_CFLAGS = '-g -Os -DIN_GCC -DCROSS_DIRECTORY_STRUCTURE  -W -Wall -Wno-narrowing -Wwrite-strings -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition  -isystem ./include ' >> tmp-libgcc.mvars
[ALL  ]    if /home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ -print-sysroot-headers-suffix > /dev/null 2>&1; then   set -e; for ml in `/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ -print-multi-lib`; do     multi_dir=`echo ${ml} | sed -e 's/;.*$//'`;     flags=`echo ${ml} | sed -e 's/^[^;]*;//' -e 's/@/ -/g'`;     sfx=`/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ ${flags} -print-sysroot-headers-suffix`;     if [ "${multi_dir}" = "." ];       then multi_dir="";     else       multi_dir=/${multi_dir};     fi;     echo "${sfx};${multi_dir}";   done; else   echo ";"; fi > tmp-fixinc_list
[ALL  ]    echo INHIBIT_LIBC_CFLAGS = '-Dinhibit_libc' >> tmp-libgcc.mvars
[ERROR]    xgcc.exe: error: CreateProcess: No such file or directory
[ALL  ]    /usr/bin/bash /home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gcc-4.8.2/gcc/../move-if-change tmp-macro_list macro_list



.. hmm something in the env is bad, to repro:
pushd $HOME/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/linux-3.10.19
. ~/Dropbox/ctng-firefox-builds/env.sh
pushd $HOME/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers
make -C $HOME/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/linux-3.10.19 O=$HOME/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers ARCH=arm INSTALL_HDR_PATH=$HOME/ctng-firefox-builds/x-r-HEAD-x86_64-235295c4/armv6hl-unknown-linux-gnueabi/sysroot/usr V=1 headers_install

.. problem is the internal processing in fixdep.exe (or maybe the inputs to it)

pushd C:/msys64/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers/
C:/msys64/home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers/scripts/basic/fixdep.exe scripts/basic/.fixdep.d scripts/basic/fixdep "gcc -Wp,-MD,scripts/basic/.fixdep.d -Iscripts/basic -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -o scripts/basic/fixdep /home/ukrdonnell/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/linux-3.10.19/scripts/basic/fixdep.c  "


# Windows build of unifdef is broken .. here's how to test making a fix for it.
export PATH=~/ctng-firefox-builds/mingw64-235295c4/bin:$PATH

ROOT=/tmp/kern-head
INSTROOT=/tmp/kern-head/install
mkdir -p $INSTROOT
[ -d $ROOT/src ] || (
  mkdir -p $ROOT/src
  pushd $ROOT/src
  tar -xf ~/src/linux-3.10.19.tar.xz
  pushd linux-3.10.19
  patch -p1 < ~/ctng-firefox-builds/crosstool-ng/patches/linux/3.10.19/120-unifdef-win32.patch
  popd
  git clone git://dotat.at/unifdef.git
  popd
)

mkdir -p $ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers
pushd $ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers; make -C $ROOT/src/linux-3.10.19 O=$ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers ARCH=arm INSTALL_HDR_PATH=$INSTROOT/armv6hl-unknown-linux-gnueabi/sysroot/usr V=1 headers_install; popd

# Making new unifdef patches for Linux Kernel headers_install.
# First, remove any existing unifdef patches!
KVER=3.10.19
ROOT=/tmp/kern-head.new
rm -rf $ROOT
INSTROOT=$ROOT/install
mkdir -p $INSTROOT
mkdir -p $ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers
[ -d $ROOT/src ] || mkdir -p $ROOT/src
  pushd $ROOT/src
   tar -xf ~/src/linux-${KVER}.tar.xz
   # Apply any existing patches.
   pushd linux-${KVER}
   PATCHES=$(find ~/ctng-firefox-builds/crosstool-ng/patches/linux/${KVER} -name "*.patch" | sort)
   for PATCH in $PATCHES; do
#     if [ "${PATCH/unifdef/}" = "$PATCH" ]; then
       echo "Applying pre-existing kernel patch $PATCH"
       patch -p1 < $PATCH
#     fi
   done
   popd
   cp -rf linux-${KVER} linux-${KVER}.orig
   pushd linux-${KVER}/scripts
    pushd /tmp
     [ -d unifdef ] && rm -rf unifdef
     git clone git://dotat.at/unifdef.git
     pushd unifdef
      ./scripts/reversion.sh
     popd
    popd
    mkdir unifdef-upstream
    mkdir unifdef-upstream/FreeBSD
    mkdir unifdef-upstream/win32
    cp -f /tmp/unifdef/COPYING          unifdef-upstream/
    # Duplicate all files into platform specific subdirs.
    cp -f /tmp/unifdef/FreeBSD/err.c    unifdef-upstream/win32/
    cp -f /tmp/unifdef/FreeBSD/getopt.c unifdef-upstream/win32/
    cp -f /tmp/unifdef/win32/win32.c    unifdef-upstream/win32/
    cp -f /tmp/unifdef/win32/unifdef.h  unifdef-upstream/win32/
    cp -f /tmp/unifdef/unifdef.c        unifdef-upstream/win32/
    cp -f /tmp/unifdef/version.h        unifdef-upstream/win32/
   popd
   pushd linux-${KVER}
   # Patch the Makefile.
    patch -p1 <<- "EOF"
	--- linux-3.10.19.orig/scripts/Makefile      2013-11-13 03:05:59.000000000 +0000
	+++ linux-3.10.19.orig/scripts/Makefile   2013-12-06 11:07:46.000000000 +0000
	@@ -26,6 +26,15 @@
	 # The following hostprogs-y programs are only build on demand
	 hostprogs-y += unifdef docproc
	
	+cc_machine := $(shell $(CC) -dumpmachine)
	+ifneq (, $(findstring linux, $(cc_machine)))
	+  unifdef-objs := unifdef.o
	+else
	+  ifneq (, $(findstring mingw, $(cc_machine)))
	+    unifdef-objs := unifdef-upstream/win32/unifdef.o unifdef-upstream/win32/err.o unifdef-upstream/win32/getopt.o unifdef-upstream/win32/win32.o
	+  endif
	+endif
	+
	 # These targets are used internally to avoid "is up to date" messages
	 PHONY += build_unifdef
	 build_unifdef: scripts/unifdef FORCE
	EOF
   popd
  popd

pushd $ROOT/src
find . -type f -and \( -name "*.orig" -or -name "*.rej" \) -exec rm {} \;
[ -d ~/ctng-firefox-builds/crosstool-ng/patches/linux/${KVER} ] || mkdir -p ~/ctng-firefox-builds/crosstool-ng/patches/linux/${KVER}
#diff -urN linux-${KVER}.orig linux-${KVER} > ~/ctng-firefox-builds/crosstool-ng/patches/linux/${KVER}/120-Win32-FreeBSD-use-upstream-unifdef.patch2
diff -urN linux-${KVER}.orig linux-${KVER} > ~/Dropbox/120-Win32-FreeBSD-use-upstream-unifdef.patch.${KVER}
popd

# Testing it:
mkdir -p $ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers
pushd $ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers; make -C $ROOT/src/linux-${KVER} O=$ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers ARCH=arm INSTALL_HDR_PATH=$INSTROOT/armv6hl-unknown-linux-gnueabi/sysroot/usr V=1 headers_install; popd

make install_root=$ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers install-bootstrap-headers=yes
-C $ROOT/src/linux-${KVER} O=$ROOT/armv6hl-unknown-linux-gnueabi/build/build-kernel-headers ARCH=arm INSTALL_HDR_PATH=$INSTROOT/armv6hl-unknown-linux-gnueabi/sysroot/usr V=1 headers_install; popd

cat ~/Dropbox/ctng-firefox-builds/120-win32-use-upstream-unifdef.patch

pushd armv6hl-unknown-linux-gnueabi/build/build-kernel-headers
gcc -Wp,-MD,scripts/unifdef-upstream/FreeBSD/.err.o.d -Iscripts -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer   -I/Users/raydonnelly/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64/.build/src/linux-3.10.19/tools/include -c -o scripts/unifdef-upstream/FreeBSD/err.o /Users/raydonnelly/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64/.build/src/linux-3.10.19/scripts/unifdef-upstream/FreeBSD/err.c


# Hang when --target-os=ps3 during patch cloog-ppl-0.15.11 seems to be from:

EXTRA]    Patching 'cloog-ppl-0.15.11'
[00:30] / /home/ray/ctng-firefox-builds/lib/ct-ng.hg+unknown-20131207.020612/scripts/functions: line 216: 92084 Terminated              ( for i in "$@";
do
    cur_cmd+="'${i}' ";
done; while true; do
    case "${1}" in
        *=*)
            eval export "'${1}'"; shift
        ;;
        *)
            break
        ;;
    esac;
done; while true; do
    rm -f "${CT_BUILD_DIR}/repeat"; CT_DoLog DEBUG "==> Executing: ${cur_cmd}"; "${@}" 2>&1 | CT_DoLog "${level}"; ret="${?}"; if [ -f "${CT_BUILD_DIR}/repeat" ]; then
        rm -f "${CT_BUILD_DIR}/repeat"; continue;
    else
        if [ -f "${CT_BUILD_DIR}/skip" ]; then
            rm -f "${CT_BUILD_DIR}/skip"; ret=0; break;
        else
            break;
        fi;
    fi;
done; exit ${ret} )
[ERROR]  >>
[ERROR]  >>  Build failed in step 'Extracting and patching toolchain components'
[ERROR]  >>        called in step '(top-level)'
[ERROR]  >>
[ERROR]  >>  Error happened in: CT_DoExecLog[scripts/functions@216]
[ERROR]  >>        called from: do_cloog_extract[scripts/build/companion_libs/130-cloog.sh@47]
[ERROR]  >>        called from: do_companion_libs_extract[scripts/build/companion_libs.sh@22]
[ERROR]  >>        called from: main[scripts/crosstool-NG.sh@649]
[ERROR]  >>
[ERROR]  >>  For more info on this error, look at the file: 'build.log'
[ERROR]  >>  There is a list of known issues, some with workarounds, in:
[ERROR]  >>      '/home/ray/ctng-firefox-builds/share/doc/crosstool-ng/ct-ng.hg+unknown-20131207.020612/B - Known issues.txt'
[ERROR]
[ERROR]  (elapsed: 17:29.38)
[17:32] / /home/ray/ctng-firefox-builds//bin/ct-ng:148: recipe for target 'build' failed
make: *** [build] Error 143

# On Linux a hang in the same place seemed to be libtoolize related.

# build.log contains:
[DEBUG]    Entering '/home/ray/ctng-firefox-builds/ctng-build-x-p-HEAD-x86_64-235295c4/.build/src/cloog-ppl-0.15.11'
[DEBUG]    ==> Executing: './autogen.sh'


# CreateProcess error leads to a make error which doesn't propagate
pushd /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/gcc
if /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ -print-sysroot-headers-suffix > /dev/null 2>&1; then   set -e; for ml in `/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ -print-multi-lib`; do     multi_dir=`echo ${ml} | sed -e 's/;.*$//'`;     flags=`echo ${ml} | sed -e 's/^[^;]*;//' -e 's/@/ -/g'`;     sfx=`/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/xgcc -B/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/./gcc/ ${flags} -print-sysroot-headers-suffix`;     if [ "${multi_dir}" = "." ];       then multi_dir="";     else       multi_dir=/${multi_dir};     fi;     echo "${sfx};${multi_dir}";   done; else   echo ";"; fi > tmp-fixinc_list
[ERROR]    xgcc.exe: error: CreateProcess: No such file or directory
[ALL  ]    make[2]: Leaving directory '/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/gcc'
[ALL  ]    make[1]: INTERNAL: Exiting with 8 jobserver tokens available; should be 9!


# General flakiness?!
# pushd /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1
# export PATH=~/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/bin:$PATH
# /usr/bin/make "DESTDIR=" "RPATH_ENVVAR=PATH" "TARGET_SUBDIR=armv6hl-unknown-linux-gnueabi" "bindir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/bin" "datadir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share" "exec_prefix=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools" "includedir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/include" "datarootdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share" "docdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share/doc/" "infodir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share/info" "pdfdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share/doc/" "htmldir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share/doc/" "libdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib" "libexecdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/libexec" "lispdir=" "localstatedir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/var" "mandir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/share/man" "oldincludedir=/usr/include" "prefix=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools" "sbindir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/sbin" "sharedstatedir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/com" "sysconfdir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/etc" "tooldir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi" "build_tooldir=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi" "target_alias=armv6hl-unknown-linux-gnueabi" "AWK=gawk" "BISON=bison" "CC_FOR_BUILD=x86_64-build_w64-mingw32-gcc" "CFLAGS_FOR_BUILD=" "CXX_FOR_BUILD=x86_64-build_w64-mingw32-g++" "EXPECT=expect" "FLEX=flex" "INSTALL=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin/install -c" "INSTALL_DATA=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin/install -c -m 644" "INSTALL_PROGRAM=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin/install -c" "INSTALL_SCRIPT=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin/install -c" "LDFLAGS_FOR_BUILD=" "LEX=flex" "M4=m4" "MAKE=/usr/bin/make" "RUNTEST=runtest" "RUNTESTFLAGS=" "SED=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/tools/bin/sed" "SHELL=/usr/bin/bash" "YACC=bison -y" "`echo 'ADAFLAGS=' | sed -e s'/[^=][^=]*=$/XFOO=/'`" "ADA_CFLAGS=" "AR_FLAGS=rc" "`echo 'BOOT_ADAFLAGS=-gnatpg' | sed -e s'/[^=][^=]*=$/XFOO=/'`" "BOOT_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format" "BOOT_LDFLAGS= -Wl,--stack,12582912" "CFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1 -D__USE_MINGW_ACCESS" "CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "LDFLAGS= -Wl,--stack,12582912" "LIBCFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1 -D__USE_MINGW_ACCESS" "LIBCXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1 -fno-implicit-templates" "STAGE1_CHECKING=--enable-checking=yes,types" "STAGE1_LANGUAGES=c,lto" "GNATBIND=x86_64-build_w64-mingw32-gnatbind" "GNATMAKE=x86_64-build_w64-mingw32-gnatmake" "AR_FOR_TARGET=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/ar" "AS_FOR_TARGET=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/as" "CC_FOR_TARGET= $r/./gcc/xgcc -B$r/./gcc/" "CFLAGS_FOR_TARGET=-g -Os" "CPPFLAGS_FOR_TARGET=" "CXXFLAGS_FOR_TARGET=-g -Os" "DLLTOOL_FOR_TARGET=armv6hl-unknown-linux-gnueabi-dlltool" "FLAGS_FOR_TARGET=-B/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/ -B/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/lib/ -isystem /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/include -isystem /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/sys-include" "GCJ_FOR_TARGET= armv6hl-unknown-linux-gnueabi-gcj" "GFORTRAN_FOR_TARGET= armv6hl-unknown-linux-gnueabi-gfortran" "GOC_FOR_TARGET= armv6hl-unknown-linux-gnueabi-gccgo" "GOCFLAGS_FOR_TARGET=-O2 -g" "LD_FOR_TARGET=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/ld" "LIPO_FOR_TARGET=armv6hl-unknown-linux-gnueabi-lipo" "LDFLAGS_FOR_TARGET=" "LIBCFLAGS_FOR_TARGET=-g -Os" "LIBCXXFLAGS_FOR_TARGET=-g -Os -fno-implicit-templates" "NM_FOR_TARGET=armv6hl-unknown-linux-gnueabi-nm" "OBJDUMP_FOR_TARGET=armv6hl-unknown-linux-gnueabi-objdump" "RANLIB_FOR_TARGET=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/ranlib" "READELF_FOR_TARGET=armv6hl-unknown-linux-gnueabi-readelf" "STRIP_FOR_TARGET=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/armv6hl-unknown-linux-gnueabi/bin/strip" "WINDRES_FOR_TARGET=armv6hl-unknown-linux-gnueabi-windres" "WINDMC_FOR_TARGET=armv6hl-unknown-linux-gnueabi-windmc" "BUILD_CONFIG=" "`echo 'LANGUAGES=' | sed -e s'/[^=][^=]*=$/XFOO=/'`" "LEAN=false" "STAGE1_CFLAGS=-g" "STAGE1_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGE1_TFLAGS=" "STAGE2_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format" "STAGE2_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGE2_TFLAGS=" "STAGE3_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format" "STAGE3_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGE3_TFLAGS=" "STAGE4_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format" "STAGE4_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGE4_TFLAGS=" "STAGEprofile_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format -fprofile-generate" "STAGEprofile_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGEprofile_TFLAGS=" "STAGEfeedback_CFLAGS=-g -O2 -D__USE_MINGW_ACCESS -Wno-pedantic-ms-format -fprofile-use" "STAGEfeedback_CXXFLAGS=-O0 -ggdb -pipe  -D__USE_MINGW_ANSI_STDIO=1" "STAGEfeedback_TFLAGS=" "CXX_FOR_TARGET= armv6hl-unknown-linux-gnueabi-c++" "TFLAGS=" "CONFIG_SHELL=/usr/bin/bash" "MAKEINFO=makeinfo --split-size=5000000" 'AR=x86_64-build_w64-mingw32-ar' 'AS=x86_64-build_w64-mingw32-as' 'CC=x86_64-build_w64-mingw32-gcc' 'CXX=x86_64-build_w64-mingw32-g++' 'DLLTOOL=x86_64-build_w64-mingw32-dlltool' 'GCJ=' 'GFORTRAN=' 'GOC=' 'LD=c:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/bin/ld.exe' 'LIPO=lipo' 'NM=x86_64-build_w64-mingw32-nm' 'OBJDUMP=x86_64-build_w64-mingw32-objdump' 'RANLIB=x86_64-build_w64-mingw32-ranlib' 'READELF=readelf' 'STRIP=x86_64-build_w64-mingw32-strip' 'WINDRES=x86_64-build_w64-mingw32-windres' 'WINDMC=windmc' LDFLAGS="${LDFLAGS}" HOST_LIBS="${HOST_LIBS}" "GCC_FOR_TARGET= $r/./gcc/xgcc -B$r/./gcc/" "`echo 'STMP_FIXPROTO=' | sed -e s'/[^=][^=]*=$/XFOO=/'`" "`echo 'LIMITS_H_TEST=' | sed -e s'/[^=][^=]*=$/XFOO=/'`" all
# ...
# echo "" | "C:/msys64/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-cc-gcc-core-pass-1/gcc/cc1.exe" "-E" "-quiet" "-iprefix" "c:\msys64\home\ray\ctng-firefox-builds\ctng-build-x-r-head-x86_64-235295c4\.build\armv6hl-unknown-linux-gnueabi\build\build-cc-gcc-core-pass-1\gcc\../lib/gcc/armv6hl-unknown-linux-gnueabi/4.8.2/" "-" "-march=armv6" "-mtune=arm1176jzf-s" "-mfloat-abi=hard" "-mfpu=vfp" "-mtls-dialect=gnu" "-dM"

.. where its at:

[INFO ]  Installing pass-1 core C gcc compiler
[EXTRA]    Configuring core C gcc compiler
[EXTRA]    Building core C gcc compiler
[ERROR]    cc1.exe: error: no include path in which to search for stdc-predef.h
[EXTRA]    Installing core C gcc compiler
[INFO ]  Installing pass-1 core C gcc compiler: done in 1833.37s (at 72:13)
[EXTRA]  Saving state to restart at step 'kernel_headers'...
[INFO ]  =================================================================
[INFO ]  Installing kernel headers
[EXTRA]    Installing kernel headers
[EXTRA]    Checking installed headers
[INFO ]  Installing kernel headers: done in 192.54s (at 75:35)
[EXTRA]  Saving state to restart at step 'libc_start_files'...
[INFO ]  =================================================================
[INFO ]  Installing C library headers & start files
[EXTRA]    Configuring C library
[EXTRA]    Installing C library headers
[ERROR]    rpc_main.c:41:21: fatal error: libintl.h: No such file or directory
[ERROR]    make[3]: *** [/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-libc-startfiles/sunrpc/cross-rpc_main.o] Error 1
[ERROR]    make[2]: *** [sunrpc/install-headers] Error 2
[ERROR]    make[1]: *** [install-headers] Error 2


mkdir /tmp/gettext
pushd /tmp/gettext
CFLAGS= LDFLAGS= /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/configure --prefix=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools

pushd /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-libiconv-build-x86_64-build_w64-mingw32/lib
/usr/bin/bash ../libtool --mode=compile x86_64-build_w64-mingw32-gcc -O0 -ggdb  -D__USE_MINGW_ANSI_STDIO=1 -I. -I/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/libiconv-1.14/lib -I../include -I/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/libiconv-1.14/lib/../include -I.. -I/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/libiconv-1.14/lib/..  -fvisibility=hidden -DLIBDIR="/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib" -DBUILDING_LIBICONV -DBUILDING_DLL -DENABLE_RELOCATABLE=1 -DIN_LIBRARY -DINSTALLDIR="/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib" -DNO_XMALLOC -Dset_relocation_prefix=libiconv_set_relocation_prefix -Drelocate=libiconv_relocate -DHAVE_CONFIG_H -c /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/libiconv-1.14/lib/iconv.c


#pushd /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-gettext-build-x86_64-build_w64-mingw32
export PATH=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/bin:"${PATH}"
mkdir /tmp/gettext-build
pushd /tmp/gettext-build
CFLAGS= LDFLAGS= /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/configure --prefix=/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools --host=x86_64-build_w64-mingw32 --disable-java --disable-native-java --disable-csharp --enable-static --enable-threads=win32 --without-emacs --disable-openmp



/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:67:1: error: conflicting types for ‘rpl_lstat’
 rpl_lstat (const char *file, struct stat *sbuf)
 ^
In file included from /usr/include/time.h:145:0,
                 from ./time.h:39,
                 from /usr/include/sys/stat.h:9,
                 from ./sys/stat.h:32,
                 from /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:35:
./sys/stat.h:782:1: note: previous declaration of ‘rpl_lstat’ was here
 _GL_FUNCDECL_RPL (lstat, int, (const char *name, struct stat *buf)
 ^
/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c: In function ‘rpl_lstat’:
/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:70:3: warning: passing argument 2 of ‘orig_lstat’ from incompatible pointer type [enabled by default]
   int lstat_result = orig_lstat (file, sbuf);
   ^
/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:39:1: note: expected ‘struct stat *’ but argument is of type ‘struct _stati64 *’
 orig_lstat (const char *filename, struct stat *buf)
 ^
In file included from ./sys/stat.h:32:0,
                 from /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:35:
/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:81:44: error: dereferencing pointer to incomplete type
   if (file[len - 1] != '/' || S_ISDIR (sbuf->st_mode))
                                            ^
/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/gnulib-lib/lstat.c:89:21: error: dereferencing pointer to incomplete type
   if (!S_ISLNK (sbuf->st_mode))
                     ^
Makefile:1436: recipe for target 'lstat.o' failed


# With ctng:
pushd /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/build/build-gettext-build-x86_64-build_w64-mingw32/gettext-runtime/libasprintf
/usr/bin/bash ./libtool  --tag=CC   --mode=compile x86_64-build_w64-mingw32-gcc -O0 -ggdb  -D__USE_MINGW_ANSI_STDIO=1 -DIN_LIBASPRINTF -DHAVE_CONFIG_H -I. -I/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/src/gettext-0.18.3.1/gettext-runtime/libasprintf      -c -o lib-asprintf.lo lib-asprintf.c

# With Pacman:
pushd /home/ray/MINGW-packages/mingw-w64-gettext/src/build-x86_64/gettext-runtime/libasprintf
libtool: compile:  x86_64-w64-mingw32-gcc -DIN_LIBASPRINTF -DHAVE_CONFIG_H -I. -I../../../gettext-0.18.3.1/gettext-runtime/libasprintf -D_FORTIFY_SOURCE=2 -march=x86-64 -mtune=generic -O2 -pipe -I/mingw64/include -fexceptions --param=ssp-buffer-size=4 -c ../../../gettext-0.18.3.1/gettext-runtime/libasprintf/lib-asprintf.c  -DDLL_EXPORT -DPIC -o .libs/lib-asprintf.o

# It's -D__USE_MINGW_ANSI_STDIO=1 that is killing us here! :-(

# With that 'fixed' we run into link errors:
[ALL  ]    /usr/bin/bash ../libtool  --tag=CXX   --mode=link x86_64-build_w64-mingw32-g++  -g -O2  -no-undefined  -L/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -liconv -R/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib ../intl/libintl.la -L/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -liconv -R/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib      -release 0.18.3 -Wl,--export-all-symbols    -L/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -liconv -R/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -L/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -liconv -R/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib   -o libgettextlib.la -rpath /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib copy-acl.lo set-acl.lo allocator.lo areadlink.lo argmatch.lo gl_array_list.lo backupfile.lo addext.lo basename.lo binary-io.lo c-ctype.lo c-strcasecmp.lo c-strncasecmp.lo c-strcasestr.lo c-strstr.lo careadlinkat.lo classpath.lo clean-temp.lo cloexec.lo closeout.lo concat-filename.lo copy-file.lo csharpcomp.lo csharpexec.lo error-progname.lo execute.lo exitfail.lo fatal-signal.lo fd-hook.lo fd-ostream.lo fd-safer-flag.lo dup-safer-flag.lo file-ostream.lo findprog.lo fstrcmp.lo full-write.lo fwriteerror.lo gcd.lo ../woe32dll/gettextlib-exports.lo hash.lo html-ostream.lo  ../woe32dll/c++html-styled-ostream.lo javacomp.lo javaexec.lo javaversion.lo gl_linkedhash_list.lo gl_list.lo localcharset.lo localename.lo glthread/lock.lo malloca.lo mbchar.lo mbiter.lo mbslen.lo mbsstr.lo mbswidth.lo mbuiter.lo ostream.lo pipe-filter-ii.lo pipe-filter-aux.lo pipe2.lo pipe2-safer.lo progname.lo propername.lo acl-errno-valid.lo file-has-acl.lo qcopy-acl.lo qset-acl.lo quotearg.lo safe-read.lo safe-write.lo sh-quote.lo sig-handler.lo spawn-pipe.lo striconv.lo striconveh.lo striconveha.lo strnlen1.lo styled-ostream.lo tempname.lo term-ostream.lo  ../woe32dll/c++term-styled-ostream.lo glthread/threadlib.lo glthread/tls.lo tmpdir.lo trim.lo uniconv/u8-conv-from-enc.lo unilbrk/lbrktables.lo unilbrk/u8-possible-linebreaks.lo unilbrk/u8-width-linebreaks.lo unilbrk/ulc-common.lo unilbrk/ulc-width-linebreaks.lo uniname/uniname.lo unistd.lo dup-safer.lo fd-safer.lo pipe-safer.lo unistr/u16-mbtouc.lo unistr/u16-mbtouc-aux.lo unistr/u8-check.lo unistr/u8-mblen.lo unistr/u8-mbtouc.lo unistr/u8-mbtouc-aux.lo unistr/u8-mbtouc-unsafe.lo unistr/u8-mbtouc-unsafe-aux.lo unistr/u8-mbtoucr.lo unistr/u8-prev.lo unistr/u8-uctomb.lo unistr/u8-uctomb-aux.lo uniwidth/width.lo wait-process.lo wctype-h.lo xmalloc.lo xstrdup.lo xconcat-filename.lo xerror.lo gl_xlist.lo xmalloca.lo xreadlink.lo xsetenv.lo xsize.lo xstriconv.lo xstriconveh.lo xvasprintf.lo xasprintf.lo asnprintf.lo canonicalize-lgpl.lo close.lo dup2.lo error.lo fcntl.lo fnmatch.lo fopen.lo fstat.lo getdelim.lo getdtablesize.lo getline.lo gettimeofday.lo malloc.lo mbrtowc.lo mbsinit.lo mbsrtowcs.lo mbsrtowcs-state.lo mkdtemp.lo msvc-inval.lo msvc-nothrow.lo obstack.lo open.lo printf-args.lo printf-parse.lo raise.lo rawmemchr.lo read.lo readlink.lo realloc.lo rmdir.lo secure_getenv.lo setenv.lo setlocale.lo sigaction.lo sigprocmask.lo snprintf.lo spawn_faction_addclose.lo spawn_faction_adddup2.lo spawn_faction_addopen.lo spawn_faction_destroy.lo spawn_faction_init.lo spawnattr_destroy.lo spawnattr_init.lo spawnattr_setflags.lo spawnattr_setsigmask.lo spawni.lo spawnp.lo stat.lo stdio-write.lo stpcpy.lo stpncpy.lo strchrnul.lo strerror.lo strerror-override.lo strstr.lo tparm.lo tputs.lo unsetenv.lo vasnprintf.lo vsnprintf.lo waitpid.lo wcwidth.lo write.lo libcroco_rpl.la libglib_rpl.la libxml_rpl.la 
[ALL  ]    libtool: link: x86_64-build_w64-mingw32-g++ -shared -nostdlib c:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/lib/../lib/dllcrt2.o c:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/lib/../lib/crtbegin.o  .libs/copy-acl.o .libs/set-acl.o .libs/allocator.o .libs/areadlink.o .libs/argmatch.o .libs/gl_array_list.o .libs/backupfile.o .libs/addext.o .libs/basename.o .libs/binary-io.o .libs/c-ctype.o .libs/c-strcasecmp.o .libs/c-strncasecmp.o .libs/c-strcasestr.o .libs/c-strstr.o .libs/careadlinkat.o .libs/classpath.o .libs/clean-temp.o .libs/cloexec.o .libs/closeout.o .libs/concat-filename.o .libs/copy-file.o .libs/csharpcomp.o .libs/csharpexec.o .libs/error-progname.o .libs/execute.o .libs/exitfail.o .libs/fatal-signal.o .libs/fd-hook.o .libs/fd-ostream.o .libs/fd-safer-flag.o .libs/dup-safer-flag.o .libs/file-ostream.o .libs/findprog.o .libs/fstrcmp.o .libs/full-write.o .libs/fwriteerror.o .libs/gcd.o ../woe32dll/.libs/gettextlib-exports.o .libs/hash.o .libs/html-ostream.o ../woe32dll/.libs/c++html-styled-ostream.o .libs/javacomp.o .libs/javaexec.o .libs/javaversion.o .libs/gl_linkedhash_list.o .libs/gl_list.o .libs/localcharset.o .libs/localename.o glthread/.libs/lock.o .libs/malloca.o .libs/mbchar.o .libs/mbiter.o .libs/mbslen.o .libs/mbsstr.o .libs/mbswidth.o .libs/mbuiter.o .libs/ostream.o .libs/pipe-filter-ii.o .libs/pipe-filter-aux.o .libs/pipe2.o .libs/pipe2-safer.o .libs/progname.o .libs/propername.o .libs/acl-errno-valid.o .libs/file-has-acl.o .libs/qcopy-acl.o .libs/qset-acl.o .libs/quotearg.o .libs/safe-read.o .libs/safe-write.o .libs/sh-quote.o .libs/sig-handler.o .libs/spawn-pipe.o .libs/striconv.o .libs/striconveh.o .libs/striconveha.o .libs/strnlen1.o .libs/styled-ostream.o .libs/tempname.o .libs/term-ostream.o ../woe32dll/.libs/c++term-styled-ostream.o glthread/.libs/threadlib.o glthread/.libs/tls.o .libs/tmpdir.o .libs/trim.o uniconv/.libs/u8-conv-from-enc.o unilbrk/.libs/lbrktables.o unilbrk/.libs/u8-possible-linebreaks.o unilbrk/.libs/u8-width-linebreaks.o unilbrk/.libs/ulc-common.o unilbrk/.libs/ulc-width-linebreaks.o uniname/.libs/uniname.o .libs/unistd.o .libs/dup-safer.o .libs/fd-safer.o .libs/pipe-safer.o unistr/.libs/u16-mbtouc.o unistr/.libs/u16-mbtouc-aux.o unistr/.libs/u8-check.o unistr/.libs/u8-mblen.o unistr/.libs/u8-mbtouc.o unistr/.libs/u8-mbtouc-aux.o unistr/.libs/u8-mbtouc-unsafe.o unistr/.libs/u8-mbtouc-unsafe-aux.o unistr/.libs/u8-mbtoucr.o unistr/.libs/u8-prev.o unistr/.libs/u8-uctomb.o unistr/.libs/u8-uctomb-aux.o uniwidth/.libs/width.o .libs/wait-process.o .libs/wctype-h.o .libs/xmalloc.o .libs/xstrdup.o .libs/xconcat-filename.o .libs/xerror.o .libs/gl_xlist.o .libs/xmalloca.o .libs/xreadlink.o .libs/xsetenv.o .libs/xsize.o .libs/xstriconv.o .libs/xstriconveh.o .libs/xvasprintf.o .libs/xasprintf.o .libs/asnprintf.o .libs/canonicalize-lgpl.o .libs/close.o .libs/dup2.o .libs/error.o .libs/fcntl.o .libs/fnmatch.o .libs/fopen.o .libs/fstat.o .libs/getdelim.o .libs/getdtablesize.o .libs/getline.o .libs/gettimeofday.o .libs/malloc.o .libs/mbrtowc.o .libs/mbsinit.o .libs/mbsrtowcs.o .libs/mbsrtowcs-state.o .libs/mkdtemp.o .libs/msvc-inval.o .libs/msvc-nothrow.o .libs/obstack.o .libs/open.o .libs/printf-args.o .libs/printf-parse.o .libs/raise.o .libs/rawmemchr.o .libs/read.o .libs/readlink.o .libs/realloc.o .libs/rmdir.o .libs/secure_getenv.o .libs/setenv.o .libs/setlocale.o .libs/sigaction.o .libs/sigprocmask.o .libs/snprintf.o .libs/spawn_faction_addclose.o .libs/spawn_faction_adddup2.o .libs/spawn_faction_addopen.o .libs/spawn_faction_destroy.o .libs/spawn_faction_init.o .libs/spawnattr_destroy.o .libs/spawnattr_init.o .libs/spawnattr_setflags.o .libs/spawnattr_setsigmask.o .libs/spawni.o .libs/spawnp.o .libs/stat.o .libs/stdio-write.o .libs/stpcpy.o .libs/stpncpy.o .libs/strchrnul.o .libs/strerror.o .libs/strerror-override.o .libs/strstr.o .libs/tparm.o .libs/tputs.o .libs/unsetenv.o .libs/vasnprintf.o .libs/vsnprintf.o .libs/waitpid.o .libs/wcwidth.o .libs/write.o  -Wl,--whole-archive ./.libs/libcroco_rpl.a ./.libs/libglib_rpl.a ./.libs/libxml_rpl.a -Wl,--no-whole-archive  -L/home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib ../intl/.libs/libintl.dll.a -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2 -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/lib/../lib -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../lib -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/lib -Lc:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../.. -lstdc++ -lmingw32 -lgcc_s -lgcc -lmoldname -lmingwex -lmsvcrt -ladvapi32 -lshell32 -luser32 -lkernel32 /home/ray/ctng-firefox-builds/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib/libiconv.dll.a -lmingw32 -lgcc_s -lgcc -lmoldname -lmingwex -lmsvcrt c:/msys64/home/ray/ctng-firefox-builds/mingw64-235295c4/bin/../lib/gcc/x86_64-w64-mingw32/4.8.2/../../../../x86_64-w64-mingw32/lib/../lib/crtend.o  -O2 -Wl,--export-all-symbols   -o .libs/libgettextlib-0-18-3.dll -Wl,--enable-auto-image-base -Xlinker --out-implib -Xlinker .libs/libgettextlib.dll.a
[ALL  ]    ../woe32dll/.libs/c++html-styled-ostream.o: In function `html_styled_ostream(float, long double,...)(...)':
[ALL  ]    C:msys64homerayctng-firefox-buildsctng-build-x-r-HEAD-x86_64-235295c4.buildarmv6hl-unknown-linux-gnueabibuildbuild-gettext-build-x86_64-build_w64-mingw32gettext-toolsgnulib-lib/html-styled-ostream.oo.c:70: undefined reference to `html_ostream_free(any_ostream_representation*)'
[ALL  ]    ../woe32dll/.libs/c++html-styled-ostream.o: In function `html_styled_ostream_create':
[ALL  ]    C:msys64homerayctng-firefox-buildsctng-build-x-r-HEAD-x86_64-235295c4.buildarmv6hl-unknown-linux-gnueabibuildbuild-gettext-build-x86_64-build_w64-mingw32gettext-toolsgnulib-lib/html-styled-ostream.oo.c:143: undefined reference to `ostream_write_mem(any_ostream_representation*, void const*, unsigned long long)'
..
[ALL  ]    C:msys64homerayctng-firefox-buildsctng-build-x-r-HEAD-x86_64-235295c4.buildarmv6hl-unknown-linux-gnueabibuildbuild-gettext-build-x86_64-build_w64-mingw32gettext-toolsgnulib-lib/term-styled-ostream.oo.c:107: undefined reference to `term_ostream_free(any_ostream_representation*)'
[ALL  ]    ../woe32dll/.libs/c++term-styled-ostream.o: In function `term_styled_ostream__write_mem':
[ALL  ]    C:msys64homerayctng-firefox-buildsctng-build-x-r-HEAD-x86_64-235295c4.buildarmv6hl-unknown-linux-gnueabibuildbuild-gettext-build-x86_64-build_w64-mingw32gettext-toolsgnulib-lib/term-styled-ostream.oo.c:89: undefined reference to `term_ostream_set_color(any_ostream_representation*, int)'


# Stupid gettext bug and broken patch

mkdir /tmp/gettext-bug
pushd /tmp/gettext-bug
AUTOMAKE_VER=1.14.3
if [ ! -f bin/autoconf ]; then
# curl -SLO http://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.bz2
 wget -c http://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.gz
 tar -xf autoconf-${AUTOCONF_VER}.tar.gz
 cd autoconf-${AUTOCONF_VER}
 wget -O config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
 wget -O config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
export PATH=$PWD/bin:"$PATH"
tar -xf ~/src/gettext-0.18.3.1.tar.gz
mv gettext-0.18.3.1 a
pushd a
patch -p1 < ~/ctng-firefox-builds/crosstool-ng/patches/gettext/0.18.3.1/110-Fix-linker-error-redefinition-of-vasprintf.patch
popd
cp -rf a b
pushd b
patch -p1 < ~/ctng-firefox-builds/crosstool-ng/patches/gettext/0.18.3.1/120-Fix-Woe32-link-errors-when-compiling-with-O0.patch
# Fix the mess made of color.o handling in that patch
pushd b/gettext-tools && /tmp/gettext-bug/b/build-aux/missing automake-1.13 --gnits src/Makefile





# .. with sunrpc test also:

ROOT=/tmp/eglibc-test
CT_BUILDTOOLS_PREFIX_DIR=/c/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools
rm -rf $ROOT
mkdir -p $ROOT
pushd $ROOT
tar -xf ~/src/eglibc-2_18.tar.bz2
pushd eglibc-2_18
patch -p1 < ~/ctng-firefox-builds/crosstool-ng/patches/eglibc/2_18/100-make-4.patch
popd
popd
mkdir -p $ROOT/armv6hl-unknown-linux-gnueabi/build/eglibc
pushd $ROOT/armv6hl-unknown-linux-gnueabi/build/eglibc
echo "libc_cv_forced_unwind=yes" >>config.cache
echo "libc_cv_c_cleanup=yes" >>config.cache
export PATH=/c/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/bin:"$PATH"
BUILD_CC=x86_64-build_w64-mingw32-gcc CFLAGS="-U_FORTIFY_SOURCE  -mlittle-endian -march=armv6   -mtune=arm1176jzf-s -mfpu=vfp -mhard-float -O2" \
      CC=armv6hl-unknown-linux-gnueabi-gcc AR=armv6hl-unknown-linux-gnueabi-ar RANLIB=armv6hl-unknown-linux-gnueabi-ranlib \
      /tmp/eglibc-test/eglibc-2_18/configure --prefix=/usr --build=x86_64-build_w64-mingw32 --host=armv6hl-unknown-linux-gnueabi -without-cvs \
      --disable-profile --without-gd --with-headers=/home/ray/ctng-firefox-builds/x-r-HEAD-x86_64-235295c4/armv6hl-unknown-linux-gnueabi/sysroot/usr/include --libdir=/usr/lib/. --enable-obsolete-rpc --enable-kernel=3.10.19 \
      --with-__thread --with-tls --enable-shared --with-fp --enable-add-ons=nptl,ports \
      --cache-file="$(pwd)/config.cache" CPPFLAGS="-I${CT_BUILDTOOLS_PREFIX_DIR}/include/" LDFLAGS="-L${CT_BUILDTOOLS_PREFIX_DIR}/lib/"

make ${JOBSFLAGS}                                    \
     install_root="$PWD/...eglibc-install"           \
     install-bootstrap-headers=yes                   \
     "${extra_make_args[@]}"                         \
     BUILD_CPPFLAGS="-I${CT_BUILDTOOLS_PREFIX_DIR}/include/"  \
     BUILD_LDFLAGS="-L${CT_BUILDTOOLS_PREFIX_DIR}/lib -lintl" \
     sunrpc/install-headers

.. that gets us as far as #include <sys/wait.h> in C:\msys64\tmp\eglibc-test\eglibc-2_18\sunrpc\rpc_main.c

.. commenting that out gets to:

In file included from rpc_parse.c:39:0:
rpc/types.h:73:1: error: unknown type name '__u_char'
 typedef __u_char u_char;
 
for __u_char __u_short __u_int __u_long __quad_t __u_quad_t __fsid_t __daddr_t __caddr_t
that block in types.h is not needed, nor is 
#include <netinet/in.h>

.. and eventually to:

x86_64-build_w64-mingw32-gcc /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_hout.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_cout.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_parse.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_scan.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_util.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_svcout.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_clntout.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_tblout.o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_sample.o -L/c/ctng-build-x-r-HEAD-x86_64-235295c4/.build/armv6hl-unknown-linux-gnueabi/buildtools/lib -lintl -o /tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpcgen
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x781): undefined reference to `pipe'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x7a0): undefined reference to `fork'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x952): undefined reference to `waitpid'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x971): undefined reference to `WIFSIGNALED'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x97f): undefined reference to `WEXITSTATUS'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x991): undefined reference to `WIFSIGNALED'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x99f): undefined reference to `WTERMSIG'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x9d6): undefined reference to `WEXITSTATUS'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x1be1): undefined reference to `rindex'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x1c3b): undefined reference to `stpncpy'
C:/msys64/tmp/eglibc-test/armv6hl-unknown-linux-gnueabi/build/eglibc/sunrpc/cross-rpc_main.o:rpc_main.c:(.text+0x2a22): undefined reference to `stpcpy'

.. so rpc_main.c calls C-preprocessor:
/*
* Open input file with given define for C-preprocessor
*/
