#!/bin/bash

# Build script to build and package development/nightly builds of ElleKit.
# Should not be used in production!

set -e

abort() {
    echo "ERROR: $1!"
    exit 1
}

show_help() {
    cat <<EOF

Usage: ${0##*/} [-hlr] [-c CONFIGURATION] [-t TARGET]
Build and package ElleKit for CONFIGURATION and TARGET.

    -h                display this help and exit
    -l                enable logging on RELEASE builds.
                      (Already enabled on debug builds.)
    -s                output to /dev/console (serial) 
                      instead of /var/mobile/log.txt
    -r                package for rootless iOS
    -c CONFIGURATION  build configuration passed to Xcode
                      Debug or Release (default)
    -t TARGET         target to build for
                      macOS or iOS (default)
EOF
}

while getopts 'c:t:lsrh' opt; do
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
    l)
        ENABLE_LOGGING=true
        ;;
    s)
        OUTPUT_SERIAL=true
        ;;
    r)
        ROOTLESS=true
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

if [ -n "${ROOTLESS}" ]; then
    INSTALL_PREFIX="/var/jb"
    DEB_ARCH="iphoneos-arm64"
else
    INSTALL_PREFIX=
    DEB_ARCH="iphoneos-arm"
fi

COMMON_OPTIONS=(-sdk "${SDK}" -configuration "${CONFIGURATION}" CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO BUILD_LIBRARIES_FOR_DISTRIBUTION=YES)
GIT_BRANCH="+$(git rev-parse --abbrev-ref HEAD)"
if [ "${GIT_BRANCH}" = "+main" ]; then
    GIT_BRANCH=""
fi

# We can have multiple commits in a day, so use the number of additional commits instead of the date
GIT_COMMIT_HASH="$(git describe --tags --always --dirty | sed 's/-/./g' | sed 's/^v//g')"

DEB_VERSION="${GIT_COMMIT_HASH}${GIT_BRANCH}"

# Fixes for the latest commit
git apply "fixes/add_shared_region.patch"
DEB_VERSION+="+fixes"

if [ -n "${ROOTLESS}" ]; then
    # This should be evident from iphoneos-arm64
    # DEB_VERSION+="+rootless"
    true
fi

# Do not add configuration for release builds
if [ "${CONFIGURATION}" = "Debug" ]; then
    DEB_VERSION+="+debug"
    CONTROL_PATH="control-debug"
    git apply "patches/enable_logging.patch"
fi

if [ -n "${ENABLE_LOGGING}" ] && [ "${CONFIGURATION}" != "Debug" ]; then
    # Logging is already enabled on debug
    COMMON_OPTIONS+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$SWIFT_ACTIVE_COMPILATION_CONDITIONS ENABLE_LOGGING')
    DEB_VERSION+="+logging"
    CONTROL_PATH="control-logging"
    git apply "patches/enable_logging.patch"
fi

if [ -n "${OUTPUT_SERIAL}" ]; then
    DEB_VERSION+="+serial"
    git apply "patches/output_serial.patch"
fi

if [ -z "${CONTROL_PATH}" ]; then
    CONTROL_PATH="control"
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

"${RM}" -rf work
"${MKDIR}" -p work/dist

# Not compatible with BSD install!
# TODO: adjust for macoS
"${INSTALL}" -Dm644 build/"${CONFIGURATION}"*/libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libellekit.dylib"
"${INSTALL}" -Dm644 build/"${CONFIGURATION}"*/pspawn.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib"
"${INSTALL}" -Dm755 build/"${CONFIGURATION}"*/loader "work/dist/${INSTALL_PREFIX}/usr/libexec/ellekit/loader"

"${LN}" -s libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libsubstrate.dylib"
"${LN}" -s libellekit.dylib "work/dist/${INSTALL_PREFIX}/usr/lib/libhooker.dylib"

"${INSTALL_NAME_TOOL}" -id "${INSTALL_PREFIX}/usr/lib/libellekit.dylib" "work/dist/${INSTALL_PREFIX}/usr/lib/libellekit.dylib"
"${INSTALL_NAME_TOOL}" -id "${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib" "work/dist/${INSTALL_PREFIX}/usr/lib/ellekit/pspawn.dylib"

"${MKDIR}" -p "work/dist/${INSTALL_PREFIX}/usr/lib/TweakInject"

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
"${SED}" -e "s|@DEB_VERSION@|${DEB_VERSION}|g" -e "s|@DEB_ARCH@|${DEB_ARCH}|g" "packaging/${CONTROL_PATH}" > work/dist/DEBIAN/control
echo "Installed-Size: $SIZE" >> work/dist/DEBIAN/control

# Not compatible with BSD sed!
"${SED}" -i'' '$a\' work/dist/DEBIAN/control

cd work/dist && "${FIND}" . -type f ! -regex '.*?DEBIAN.*' -printf '"%P" ' | "${XARGS}" "${MD5SUM}" >DEBIAN/md5sums
cd ../..
"${FAKEROOT}" -i work/.fakeroot -s work/.fakeroot -- "${CHMOD}" 0755 work/dist/DEBIAN/*
"${FIND}" work/dist -name '.DS_Store' -type f -delete
if [ ! -d packages ]; then
    "${MKDIR}" packages
fi
"${FAKEROOT}" -i work/.fakeroot -s work/.fakeroot -- dpkg-deb -Zgzip -b work/dist "packages/ellekit_${DEB_VERSION}_${DEB_ARCH}_$(date +%F).deb"
cp "packages/ellekit_${DEB_VERSION}_${DEB_ARCH}_$(date +%F).deb" "packages/ellekit_latest_${DEB_ARCH}.deb"
