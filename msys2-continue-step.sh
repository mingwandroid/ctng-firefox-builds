#!/usr/bin/env bash

# When MSYS2 falls over as it inevitably will, use this script to continue it.
# This and build.sh should be refactored so the shared bits are in a common file.
# .. it's just a quick hack. In reality fixing GNU make on MSYS2 is the proper fix.

THISDIR="$(dirname $0)"
test "${THISDIR}" = "." && THISDIR=${PWD}
echo ""

usage_exit()
{
  echo ""
  echo    "Usage: ${0} ctng-install-dir build-dir final-install-dir step"
  echo -e " e.g.: ${0} ${THISDIR}/install-ctng.diorcety /c/bsd ${THISDIR}/s-eglibc_V_2.15-x86_64-213be3fb cc_core_pass_2"
  exit $1
}

case "${1}" in
  -h|--help|"")
    usage_exit 0
  ;;
esac

GCC_VERSION=4.8.2

# Replace './' with '${THISDIR}/' in any directory arguments so that they are absolute.
# .. of course '../' will still throw us! $(cd $1 ; pwd) would be better but doesn't
# work with error checking logic.
CTNG_PREFIX=${1/.\//${THISDIR}/}  ; shift
BUILD_DIR=${1/.\//${THISDIR}/}    ; shift
FINAL_PREFIX=${1/.\//${THISDIR}/} ; shift
STEP=${1}                         ; shift

# Lots of error checking.
[ -d "${CTNG_PREFIX}" ]           || ( echo "ERROR: ctng-install-dir of \"${CTNG_PREFIX}\" does not exist." ; usage_exit 1 ) || exit 1
[ -f "${CTNG_PREFIX}/bin/ct-ng" ] || ( echo "ERROR: ctng-install-dir of \"${CTNG_PREFIX}\" does not contain the bin/ct-ng script, wrong directory specified?" ; usage_exit 1 ) || exit 1
[ -d "${BUILD_DIR}/.build" ]      || ( echo "ERROR: build-dir of \"${BUILD_DIR}\" does not contain .build sub-directory, wrong directory specified?" ; usage_exit 1 ) || exit 1
[ -d "${FINAL_PREFIX}" ]          || ( echo "ERROR: final-install-dir of \"${FINAL_PREFIX}\" does not exist." ; usage_exit 1 ) || exit 1
[ -n "${STEP}" ]                  || ( echo "ERROR: please specify a step to continue at." ; usage_exit 1 ) || exit 1
STATE_DIR=$( find "${BUILD_DIR}/.build" -maxdepth 3 \( -type d -and -path "*/state/${STEP}" \) )
[ -d "${STATE_DIR}" ]             || ( echo "ERROR: build-dir of \"${BUILD_DIR}/.build\" does not contain a stage/${STEP} sub-directory, wrong step of \"${STEP}\" specified?" ; usage_exit 1 ) || exit 1
MINGW_W64_PREFIX=$( find "${THISDIR}" -maxdepth 1 -name "mingw64-*" )
[ -d "${MINGW_W64_PREFIX}" ]      || ( echo "ERROR: MINGW_W64_PREFIX of \"${MINGW_W64_PREFIX}\" not found. Do you have multiple mingw64-XXXXXXXX directories? Please delete old ones and then re-run." ; usage_exit 1 ) || exit 1

pushd ${BUILD_DIR}
  MSYS2_ARG_CONV_EXCL="-DNATIVE_SYSTEM_HEADER_DIR=;-DNLSPATH=;-DLOCALEDIR=;-DLOCALE_ALIAS_PATH=" ${CTNG_PREFIX}/bin/ct-ng ${STEP}+
popd

cp ${MINGW_W64_PREFIX}/bin/libstdc++*.dll     ${FINAL_PREFIX}/bin
cp ${MINGW_W64_PREFIX}/bin/libgcc*.dll        ${FINAL_PREFIX}/bin
cp ${MINGW_W64_PREFIX}/bin/libwinpthread*.dll ${FINAL_PREFIX}/bin
LIBEXECDIR=$( find ${FINAL_PREFIX}/libexec \( -type d -and -name "$GCC_VERSION" \) )
for FILE in $(find ${BUILD_DIR} -name "libiconv*.dll") ; do
 cp ${FILE} ${LIBEXECDIR}
done

echo "Done! Urgh."

exit 0
