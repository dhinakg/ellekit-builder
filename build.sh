#!/bin/bash

# Build script to build and package development/nightly builds of ElleKit.
# Should not be used in production!

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

abort() {
    echo "ERROR: $1!"
    exit 1
}

show_help() {
    cat <<EOF

Usage: ${0##*/} [-hlr] [-c CONFIGURATION] [-t TARGET]
Build and package ElleKit for CONFIGURATION and TARGET.

    -h                display this help and exit
    -s                Dhinak's special builds
                      currently:
                      output to /dev/console (serial) 
                      instead of /var/mobile/log.txt
    -c CONFIGURATION  build configuration passed to Xcode
                      Debug or Release (default)
    -t TARGET         target to build for
                      macOS or iOS (default)
EOF
}

while getopts 'c:t:srh' opt; do
    case "${opt}" in
    c)
        if [ "${OPTARG}" != "Release" ] && [ "${OPTARG}" != "Debug" ]; then
            echo "ERROR: Invalid configuration."
            show_help
            exit 1
        fi
        CONFIGURATION="${OPTARG}"
        ;;
    t)
        if [ "${OPTARG}" = "iOS" ]; then
            SDK=iphoneos
        elif [ "${OPTARG}" = "macOS" ]; then
            SDK=macosx
            abort "macOS is not supported at this time."
        else
            echo "ERROR: Invalid target."
            show_help
            exit 1
        fi
        ;;
    s)
        DHINAK=true
        ;;
    h | ?)
        show_help
        exit 0
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [ -z "${CONFIGURATION}" ]; then
    CONFIGURATION=Release
fi

if [ -z "$SDK" ]; then
    SDK=iphoneos
fi

COMMON_OPTIONS=(-sdk "${SDK}" -configuration "${CONFIGURATION}" CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO BUILD_LIBRARIES_FOR_DISTRIBUTION=YES)
GIT_BRANCH="+$(git rev-parse --abbrev-ref HEAD)"
if [ "${GIT_BRANCH}" = "+main" ]; then
    GIT_BRANCH=""
fi

# We can have multiple commits in a day, so use the number of additional commits instead of the date
GIT_COMMIT_HASH="$(git describe --tags --always --dirty | sed 's/-/~/' | sed 's/-/\./g' | sed 's/\.g/\./g' | sed 's/^v//g')"

DEB_VERSION="${GIT_COMMIT_HASH}${GIT_BRANCH}"
APPLIED_PATCHES=()

# Fixes for the latest commit
if ls -A1q "${SCRIPT_DIR}/fixes" 2>/dev/null | grep -q .; then
    for fix in "${SCRIPT_DIR}"/fixes/*.patch; do
        git apply "${fix}"
        APPLIED_PATCHES+=("${fix}")
    done
    DEB_VERSION+="+fixes"
fi

# Do not add configuration for release builds
if [ "${CONFIGURATION}" = "Debug" ]; then
    DEB_VERSION+="+debug"
    CONTROL_FILE="control-debug"
fi

if [ -n "${DHINAK}" ]; then
    DEB_VERSION+="+dhinak"
    CONTROL_FILE="control-dhinak"
    git apply "${SCRIPT_DIR}/patches/output_serial.patch"
    APPLIED_PATCHES+=("${SCRIPT_DIR}/patches/output_serial.patch")
fi

if [ -z "${CONTROL_FILE}" ]; then
    CONTROL_FILE="control"
fi

CHMOD="$(command -v gchmod || command -v chmod)" || abort "Missing chmod"
CHOWN="$(command -v gchown || command -v chown)" || abort "Missing chown"
FAKEROOT="$(command -v fakeroot)" || abort "Missing fakeroot"
FIND="$(command -v gfind || command -v find)" || abort "Missing find"
INSTALL="$(command -v ginstall || command -v install)" || abort "Missing install"
INSTALL_NAME_TOOL="$(command -v install_name_tool)" || abort "Missing install_name_tool"
# Please be Procursus ldid
LDID="$(command -v ldid)" || abort "Missing ldid"
LN="$(command -v gln || command -v ln)" || abort "Missing ln"
MD5SUM="$(command -v gmd5sum || command -v md5sum)" || abort "Missing md5sum"
MKDIR="$(command -v gmkdir || command -v mkdir)" || abort "Missing mkdir"
RM="$(command -v grm || command -v rm)" || abort "Missing rm"
SED="$(command -v gsed || command -v sed)" || abort "Missing sed"
STRIP="$(command -v strip)" || abort "Missing strip"
TOUCH="$(command -v gtouch || command -v touch)" || abort "Missing touch"
XARGS="$(command -v gxargs || command -v xargs)" || abort "Missing xargs"

xcodebuild -target ellekit "${COMMON_OPTIONS[@]}"
xcodebuild -target launchd "${COMMON_OPTIONS[@]}"
xcodebuild -target loader "${COMMON_OPTIONS[@]}"
xcodebuild -target safemode-ui "${COMMON_OPTIONS[@]}"

for i in 0 1; do
    if [ "$i" = 1 ]; then
        # Rootless
        INSTALL_PREFIX="/var/jb"
        DEB_ARCH="iphoneos-arm64"
    else
        INSTALL_PREFIX=
        DEB_ARCH="iphoneos-arm"
    fi

    if [[ -n "${CI}" ]]; then
        DEB_FILENAME="packages/ellekit_${DEB_VERSION}_${DEB_ARCH}.deb"
    else
        DEB_FILENAME="packages/ellekit_${DEB_VERSION}_${DEB_ARCH}_$(date +%F).deb"
    fi

    "${RM}" -rf work
    "${MKDIR}" -p work/dist

    # Not compatible with BSD install!
    # TODO: adjust for macoS
    "${INSTALL}" -Dm644 build/"${CONFIGURATION}"*/libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libellekit.dylib"
    "${INSTALL}" -Dm644 build/"${CONFIGURATION}"*/pspawn.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib"
    "${INSTALL}" -Dm644 build/"${CONFIGURATION}"*/libsafemode-ui.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/SafeMode.dylib"
    "${INSTALL}" -Dm755 build/"${CONFIGURATION}"*/loader "work/dist/${INSTALL_PREFIX}/usr/libexec/ellekit/loader"

    "${LN}" -s libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libsubstrate.dylib"
    "${LN}" -s libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libhooker.dylib"

    "${INSTALL_NAME_TOOL}" -id "${INSTALL_PREFIX}/usr/lib/libellekit.dylib" "work/dist/${INSTALL_PREFIX}/usr/lib/libellekit.dylib"
    "${INSTALL_NAME_TOOL}" -id "${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib" "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib"
    "${INSTALL_NAME_TOOL}" -id "${INSTALL_PREFIX}/usr/lib/ellekit/SafeMode.dylib" "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/SafeMode.dylib"

    "${MKDIR}" -p "work/dist/${INSTALL_PREFIX}/usr/lib/TweakInject"

    # Symlink the loader into /etc/rc.d/
    "${MKDIR}" -p "work/dist/${INSTALL_PREFIX}/etc/rc.d"
    "${LN}" -s "${INSTALL_PREFIX}/usr/libexec/ellekit/loader" "work/dist/${INSTALL_PREFIX}/etc/rc.d/launchd"

    # Some extra substrate compatibility
    "${MKDIR}" -p "work/dist/${INSTALL_PREFIX}/Library/Frameworks/CydiaSubstrate.framework"
    "${LN}" -s "${INSTALL_PREFIX}/usr/lib/libellekit.dylib" "work/dist/${INSTALL_PREFIX}/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    "${MKDIR}" -p "work/dist/${INSTALL_PREFIX}/Library/MobileSubstrate"
    "${LN}" -s "${INSTALL_PREFIX}/usr/lib/TweakInject" "work/dist/${INSTALL_PREFIX}/Library/MobileSubstrate/DynamicLibraries"

    "${FIND}" "work/dist/${INSTALL_PREFIX}/usr" -type f -exec "${STRIP}" -x {} \;

    "${FIND}" "work/dist/${INSTALL_PREFIX}/usr/lib" -type f -exec "${LDID}" -S {} \;
    "${LDID}" -Sloader/taskforpid.xml "work/dist/${INSTALL_PREFIX}/usr/libexec/ellekit/loader"

    "${RM}" -f work/.fakeroot
    "${TOUCH}" work/.fakeroot
    "${FAKEROOT}" -s work/.fakeroot -- "${CHOWN}" -R 0:0 work/dist/*

    SIZE=$(du -sk work/dist | cut -f 1)
    "${MKDIR}" -p work/dist/DEBIAN
    "${SED}" -e "s|@INSTALL_PREFIX@|${INSTALL_PREFIX}|g" "${SCRIPT_DIR}/packaging/postinst" >work/dist/DEBIAN/postinst
    "${SED}" -e "s|@DEB_VERSION@|${DEB_VERSION}|g" -e "s|@DEB_ARCH@|${DEB_ARCH}|g" "${SCRIPT_DIR}/packaging/${CONTROL_FILE}" >work/dist/DEBIAN/control
    echo "Installed-Size: $SIZE" >>work/dist/DEBIAN/control

    # Not compatible with BSD sed!
    "${SED}" -i'' '$a\' work/dist/DEBIAN/control

    cd work/dist && "${FIND}" . -type f ! -regex '.*?DEBIAN.*' -printf '"%P" ' | "${XARGS}" "${MD5SUM}" >DEBIAN/md5sums
    cd ../..
    "${FAKEROOT}" -i work/.fakeroot -s work/.fakeroot -- "${CHMOD}" 0755 work/dist/DEBIAN/*
    "${FIND}" work/dist -name '.DS_Store' -type f -delete
    if [ ! -d packages ]; then
        "${MKDIR}" packages
    fi
    "${FAKEROOT}" -i work/.fakeroot -s work/.fakeroot -- dpkg-deb -Zgzip -b work/dist "${DEB_FILENAME}"
    # cp "${DEB_FILENAME}" "packages/ellekit_latest_${DEB_ARCH}.deb"
    "${RM}" -rf work
done

# Revert applied patches, in order
for ((idx = ${#APPLIED_PATCHES[@]} - 1; idx >= 0; idx--)); do
    git apply --reverse "${APPLIED_PATCHES[idx]}"
done
