#!/bin/bash

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
######################################################
# This set of options are for the crosstool-ng build #
######################################################
option CTNG_PACKAGE        no \
"Make a package for the built cross compiler."
option CTNG_CLEAN          no \
"Remove old crosstool-ng build and artefacts
before starting the build, otherwise an old
crosstool-ng may be re-used."
option LLVM_VERSION        HEAD \
"HEAD, 3_3, 3_2, 3_1 or 3_0 (I test with 3_3 most,
then HEAD next, then the others hardly at all)."
option COPY_SDK            no \
"Do you want the MacOSX10.6.sdk copied from
\$HOME/MacOSX10.6.sdk to the sysroot of the
built toolchain?"
option COMPILER_RT         no \
"Compiler-rt allows for profiling, address
sanitization, coverage reporting and other
such runtime nicities, mostly un-tested, and
requires --copy-sdk=yes and (if on x86-64) a
symbolic link to be made from ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/i686-apple-darwin10
.. to ..
\${HOME}/MacOSX10.6.sdk/usr/lib/gcc/x86_64-apple-darwin10
before running this script."
option BUILD_GCC           no \
"Do you want GCC 4.2.1 with that? llvm-gcc is broken
at present."
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
  cp     ${THISDIR}/mozconfig* $1/
  cp     ${THISDIR}/crosstool.config* $1/
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
  echo "  ****************************  "       > $1/README
  echo "  * crosstool-ng and Firefox *  "      >> $1/README
  echo "  * build script and patches *  "      >> $1/README
  echo "  ****************************  "      >> $1/README
  echo ""                                      >> $1/README
  echo "To regenerate this Firefox cross"      >> $1/README
  echo "build run regenerate.sh"               >> $1/README
  echo ""                                      >> $1/README
  echo "To see options for making another"     >> $1/README
  echo "build run build.sh --help"             >> $1/README
  echo ""                                      >> $1/README
  echo "Some scripts and patches in this"      >> $1/README
  echo "folder structure won't be needed"      >> $1/README
  echo "to re-generate this exact build,"      >> $1/README
  echo "but may be used by other configs"      >> $1/README
  echo ""                                      >> $1/README
  echo "final-configs/ contains two files:"    >> $1/README
  echo ".config is the crosstool-ng config"    >> $1/README
  echo "after it has been created from one"    >> $1/README
  echo "of the more minimal sample configs"    >> $1/README
  echo ".mozconfig is the configuration of"    >> $1/README
  echo "the Firefox build."                    >> $1/README
  echo ""                                      >> $1/README
  echo "Comments/suggestions to:             " >> $1/README
  echo ""                                      >> $1/README
  echo "Ray Donnelly <mingw.android@gmail.com" >> $1/README
}

if [ "${HOST_ARCH}" = "i686" ]; then
  BITS=32
else
  BITS=64
fi

if [ "${MOZ_TARGET_ARCH}" = "i686" ]; then
  echo "Warning: You set --moz-target-arch=i686, but that's not a valid Mach-O arch, changing this to i386 for you."
  MOZ_TARGET_ARCH=i386
fi

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
fi

CROSSCC="$(uname -m)"-apple-darwin10

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
  # To install gperf 3.0.4 I did:
  set +e
  brew tap homebrew/dupes
  brew install homebrew/dupes/gperf
  GPERF=${BREWFIX}/Cellar/gperf/3.0.4/bin/gperf
  brew tap homebrew/versions
  brew install mercurial gnu-sed gnu-tar grep wget gawk binutils libelf coreutils automake gperf yasm homebrew/versions/autoconf213
  set -e
elif [ "${OSTYPE}" = "linux-gnu" -o "${OSTYPE}" = "msys" ]; then
  export PYTHON=python2
  if [ "${MSYSTEM}" = "MSYS" ]; then
    SUDO=
    # Avoid
  fi
  CC=gcc
  CXX=g++
  if [ -f /etc/arch-release -o "${OSTYPE}" = "msys" ]; then
    if [ -f /etc/arch-release ]; then
      HOST_MULTILIB="-multilib"
    fi
    PACKAGES="openssh git python2 tar mercurial gcc${HOST_MULTILIB} libtool${HOST_MULTILIB} wget p7zip unzip zip yasm"
    # ncurses for Arch Linux vs ncurses-devel for MSYS is Alexey's fault ;-)
    # .. he has split packages up more than Arch does, so there is not a 1:1
    #    relationship between them anymore.
    if [ -f /etc/arch-release ]; then
      PACKAGES=$PACKAGES" ncurses"
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
                --prefix=$PWD/ctng-install-${BUILD_PREFIX} \
                --with-libtool=$LIBTOOL \
                --with-libtoolize=$LIBTOOLIZE \
                --with-objcopy=$OBJCOPY \
                --with-objdump=$OBJDUMP \
                --with-readelf=$READELF \
                --with-gperf=$GPERF \
                CC=${CC} CXX=${CXX}"

  CROSSTOOL_CONFIG=${PWD}/ctng-build-${BUILD_PREFIX}/.config
  if [ "${CTNG_CLEAN}" = "yes" ]; then
    [ -d ${BUILT_XCOMPILER_PREFIX} ]  && rm -rf ${BUILT_XCOMPILER_PREFIX}
    [ -d crosstool-ng ]               && rm -rf crosstool-ng
    [ -d ctng-build-${BUILD_PREFIX} ] && rm -rf ctng-build-${BUILD_PREFIX}
  fi
  if [ ! -f ${BUILT_XCOMPILER_PREFIX}/bin/${CROSSCC}-clang ]; then
    [ -d "${HOME}"/src ] || mkdir "${HOME}"/src
    [ -d crosstool-ng ] ||
     (
      git clone git@github.com:diorcety/crosstool-ng.git
      pushd crosstool-ng
      git checkout -b cctools-llvm remotes/origin/cctools-llvm
      if [ -d "${THISDIR}/patches/crosstool-ng" ]; then
        PATCHES=$(find "${THISDIR}/patches/crosstool-ng" -name "*.patch" | sort)
        for PATCH in $PATCHES; do
          git am $PATCH
        done
      fi
      popd
     ) || ( echo "Error: Failed to clone/patch crosstool-ng" && exit 1 )
    pushd crosstool-ng
    [ -d samples/gitian-${BITS} ] || mkdir -p samples/gitian-${BITS}
    cp "${THISDIR}"/crosstool.config-${BITS} samples/gitian-${BITS}/crosstool.config
    LLVM_VERSION_DOT=$(echo $LLVM_VERSION | tr '_' '.')
    do_sed $"s/CT_LLVM_V_3_3/CT_LLVM_V_${LLVM_VERSION}/g" samples/gitian-${BITS}/crosstool.config
    if [ "$OSTYPE" = "msys" ]; then
      DUMPEDMACHINE=$(${MINGW_W64_PATH}/gcc -dumpmachine)
      echo "CT_BUILD=\"${DUMPEDMACHINE}\"" >> samples/gitian-${BITS}/crosstool.config
    fi
    if [ "$COPY_SDK" = "yes" ]; then
      do_sed $"s/CT_DARWIN_COPY_SDK_TO_SYSROOT=n/CT_DARWIN_COPY_SDK_TO_SYSROOT=y/g" samples/gitian-${BITS}/crosstool.config
    else
      do_sed $"s/CT_DARWIN_COPY_SDK_TO_SYSROOT=y/CT_DARWIN_COPY_SDK_TO_SYSROOT=n/g" samples/gitian-${BITS}/crosstool.config
    fi
    if [ "$COMPILER_RT" = "yes" ]; then
      do_sed $"s/CT_LLVM_COMPILER_RT=n/CT_LLVM_COMPILER_RT=y/g" samples/gitian-${BITS}/crosstool.config
    else
      do_sed $"s/CT_LLVM_COMPILER_RT=y/CT_LLVM_COMPILER_RT=n/g" samples/gitian-${BITS}/crosstool.config
    fi
    if [ "$BUILD_GCC" = "yes" ]; then
      do_sed $"s/CT_CC_gcc=n/CT_CC_gcc=y/g" samples/gitian-${BITS}/crosstool.config
    else
      do_sed $"s/CT_CC_gcc=y/CT_CC_gcc=n/g" samples/gitian-${BITS}/crosstool.config
    fi

    echo "CT_PREFIX_DIR=\"${BUILT_XCOMPILER_PREFIX}\"" >> samples/gitian-${BITS}/crosstool.config
    echo "CT_INSTALL_DIR=\"${BUILT_XCOMPILER_PREFIX}\"" >> samples/gitian-${BITS}/crosstool.config

    ./bootstrap && ./configure ${CTNG_CFG_ARGS} && make && make install
    if [ "$OSTYPE" = "msys" ]; then
      PATH="${MINGW_W64_PATH}:${PATH}"
    fi
    PATH="${PATH}":$ROOT/ctng-install-${BUILD_PREFIX}/bin
    popd
    [ -d ctng-build-${BUILD_PREFIX} ] || mkdir ctng-build-${BUILD_PREFIX}
    pushd ctng-build-${BUILD_PREFIX}
    # Horrible hack to prevent cctools autoreconf from hanging on
    # Ubuntu 12.04.3 .. Sorry.
    # If you get a freeze at "[EXTRA]    Patching 'cctools-809'" then
    # this *might* fix it!
    if [ -f /etc/debian_version ]; then
     trap 'kill $(jobs -pr)' SIGINT SIGTERM EXIT
     ( while [ 0 ] ; do COLM=$(ps aux | grep libtoolize | grep --invert-match grep | awk '{print $2}'); if [ -n "${COLM}" ]; then kill $COLM; echo $COLM; fi; sleep 10; done ) &
    fi
    ct-ng gitian-${BITS}
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
  MOZILLA_CONFIG=${PWD}/${DEST}/.mozconfig
  if [ "${MOZ_CLEAN}" = "yes" -a "${MOZ_BUILD_IN_SRCDIR}" = "no" ]; then
    [ -d ${DEST} ] && rm -rf ${DEST}
  fi
  if [ ! -d ${DEST}/obj-macos/dist/firefox/Firefox${MOZBUILDSUFFIX}.app ]; then
    [ -d ${DEST} ] || mkdir -p ${DEST}
    pushd ${DEST}
    cp "${THISDIR}"/mozconfig${MOZBUILDSUFFIX} ./.mozconfig
    do_sed $"s#CROSS_TCROOT=\$HOME/x-tools/\${HOST_ARCH}-apple-darwin10#CROSS_TCROOT=${BUILT_XCOMPILER_PREFIX}#g" .mozconfig
    if [ "${HOST_ARCH}" = "i686" ]; then
      do_sed $"s/HOST_ARCH=x86_64/HOST_ARCH=i686/g" .mozconfig
    else
      do_sed $"s/HOST_ARCH=i686/HOST_ARCH=x86_64/g" .mozconfig
    fi
    if [ "${MOZ_TARGET_ARCH}" = "i386" ]; then
      do_sed $"s/TARGET_ARCH=x86_64/TARGET_ARCH=i386/g" .mozconfig
    else
      do_sed $"s/TARGET_ARCH=i386/TARGET_ARCH=x86_64/g" .mozconfig
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

BUILD_PREFIX=${LLVM_VERSION}-${HOST_ARCH}${MINGW_W64_HASH}
if [ "$COMPILER_RT" = "yes" ]; then
  BUILD_PREFIX="${BUILD_PREFIX}-rt"
fi

BUILT_XCOMPILER_PREFIX=$PWD/dx-${BUILD_PREFIX}

# Because CT_GetGit doesn't download to $HOME/src, but instead into
# tarballs in the .build folder, and cloning these takes a long
# time, we only remove what we must ..
if [ "${LLVM_VERSION}" = "HEAD" ]; then
  if [ ! -f ${BUILT_XCOMPILER_PREFIX}/bin/${CROSSCC}-clang ]; then
    set +e
    rm -rf ctng-build-${BUILD_PREFIX}/.build/src ctng-build-${BUILD_PREFIX}/.build/*-apple-darwin10
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

[ -d tools ] || mkdir tools
pushd tools > /dev/null
if [ ! -f bin/autoconf ]; then
 curl -SLO http://ftp.gnu.org/gnu/autoconf/autoconf-2.60.tar.bz2
 tar -xf autoconf-2.60.tar.bz2
 cd autoconf-2.60
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
if [ ! -f bin/automake ]; then
 curl -SLO http://ftp.gnu.org/gnu/automake/automake-1.9.6.tar.bz2
 tar -xf automake-1.9.6.tar.bz2
 cd automake-1.9.6
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
if [ ! -f bin/libtool ]; then
 curl -SLO http://ftp.gnu.org/gnu/libtool/libtool-1.5.22.tar.gz
 tar -xf libtool-1.5.22.tar.gz
 cd libtool-1.5.22
 ./configure --prefix=$PWD/.. && make && make install
 cd ..
fi
popd > /dev/null
export PATH=$PWD/tools/bin:$PATH


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
