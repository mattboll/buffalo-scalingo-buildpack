#!/usr/bin/env bash
# bin/compile <build-dir> <cache-dir>

# fail fast
set -e

# debug
if [ "$BUILDPACK_DEBUG" = "true" ] ; then
  set -x
fi

# parse and derive params
BUILD_DIR=$1
CACHE_DIR=$2
LP_DIR=`cd $(dirname $0); cd ..; pwd`

function error() {
  echo " !     $*" >&2
  exit 1
}

function topic() {
  echo "-----> $*"
}

function indent() {
  c='s/^/       /'
  case $(uname) in
    Darwin) sed -l "$c";;
    *)      sed -u "$c";;
  esac
}

APT_CACHE_DIR="$CACHE_DIR/apt/cache"
APT_STATE_DIR="$CACHE_DIR/apt/state"
APT_SOURCELIST_DIR="$CACHE_DIR/apt/sources"   # place custom sources.list here

APT_SOURCES="$APT_SOURCELIST_DIR/sources.list"
APT_FILE_MANIFEST="${APT_FILE_MANIFEST:-Aptfile}"

if [ -f $APT_CACHE_DIR/$APT_FILE_MANIFEST ] && cmp -s $BUILD_DIR/$APT_FILE_MANIFEST $APT_CACHE_DIR/$APT_FILE_MANIFEST ; then
  # Old Aptfile is the same as new
  topic "Reusing cache"
else
  # Aptfile changed or does not exist
  topic "Detected Aptfile changes, flushing cache"
  rm -rf $APT_CACHE_DIR
  mkdir -p "$APT_CACHE_DIR/archives/partial"
  mkdir -p "$APT_STATE_DIR/lists/partial"
  mkdir -p "$APT_SOURCELIST_DIR"   # make dir for sources
  cp -f "$BUILD_DIR/$APT_FILE_MANIFEST" "$APT_CACHE_DIR/$APT_FILE_MANIFEST"
  cat "/etc/apt/sources.list" > "$APT_SOURCES"    # no cp here
  # add custom repositories from Aptfile to sources.list
  # like>>    :repo:deb http://cz.archive.ubuntu.com/ubuntu artful main universe
  topic "Adding custom repositories"
  cat $BUILD_DIR/$APT_FILE_MANIFEST | grep -s -e "^:repo:" | sed 's/^:repo:\(.*\)\s*$/\1/g' >> $APT_SOURCES
fi

APT_OPTIONS="-o debug::nolocking=true -o dir::cache=$APT_CACHE_DIR -o dir::state=$APT_STATE_DIR"
# Override the use of /etc/apt/sources.list (sourcelist) and /etc/apt/sources.list.d/* (sourceparts).
APT_OPTIONS="$APT_OPTIONS -o dir::etc::sourcelist=$APT_SOURCES -o dir::etc::sourceparts=/dev/null"

topic "Updating apt caches"
apt-get $APT_OPTIONS update | indent

for PACKAGE in $(cat $BUILD_DIR/$APT_FILE_MANIFEST | grep -v -s -e '^#' | grep -v -s -e "^:repo:"); do
  if [[ $PACKAGE == *deb ]]; then
    PACKAGE_NAME=$(basename $PACKAGE .deb)
    PACKAGE_FILE=$APT_CACHE_DIR/archives/$PACKAGE_NAME.deb

    topic "Fetching $PACKAGE"
    curl -s -L -z $PACKAGE_FILE -o $PACKAGE_FILE $PACKAGE 2>&1 | indent
  else
    topic "Fetching .debs for $PACKAGE"
    apt-get $APT_OPTIONS -y --allow-downgrades -d install --reinstall $PACKAGE | indent
  fi
done

mkdir -p $BUILD_DIR/.apt

for DEB in $(ls -1 $APT_CACHE_DIR/archives/*.deb); do
  topic "Installing $(basename $DEB)"
  dpkg -x $DEB $BUILD_DIR/.apt/
done

topic "Writing profile script"
mkdir -p $BUILD_DIR/.profile.d
cat <<EOF >$BUILD_DIR/.profile.d/000_apt.sh
export PATH="\$HOME/.apt/usr/bin:\$PATH"
export LD_LIBRARY_PATH="\$HOME/.apt/lib/x86_64-linux-gnu:\$HOME/.apt/usr/lib/x86_64-linux-gnu:\$HOME/.apt/usr/lib/i386-linux-gnu:\$HOME/.apt/lib:\$HOME/.apt/usr/lib:\$LD_LIBRARY_PATH"
export LIBRARY_PATH="\$HOME/.apt/lib/x86_64-linux-gnu:\$HOME/.apt/usr/lib/x86_64-linux-gnu:\$HOME/.apt/usr/lib/i386-linux-gnu:\$HOME/.apt/lib:\$HOME/.apt/usr/lib:\$LIBRARY_PATH"
export INCLUDE_PATH="\$HOME/.apt/usr/include:\$HOME/.apt/usr/include/x86_64-linux-gnu:\$INCLUDE_PATH"
export CPATH="\$INCLUDE_PATH"
export CPPPATH="\$INCLUDE_PATH"
export PKG_CONFIG_PATH="\$HOME/.apt/usr/lib/x86_64-linux-gnu/pkgconfig:\$HOME/.apt/usr/lib/i386-linux-gnu/pkgconfig:\$HOME/.apt/usr/lib/pkgconfig:\$PKG_CONFIG_PATH"
EOF

export PATH="$BUILD_DIR/.apt/usr/bin:$PATH"
export LD_LIBRARY_PATH="$BUILD_DIR/.apt/lib/x86_64-linux-gnu:$BUILD_DIR/.apt/usr/lib/x86_64-linux-gnu:$BUILD_DIR/.apt/usr/lib/i386-linux-gnu:$BUILD_DIR/.apt/lib:$BUILD_DIR/.apt/usr/lib:$LD_LIBRARY_PATH"
export LIBRARY_PATH="$BUILD_DIR/.apt/lib/x86_64-linux-gnu:$BUILD_DIR/.apt/usr/lib/x86_64-linux-gnu:$BUILD_DIR/.apt/usr/lib/i386-linux-gnu:$BUILD_DIR/.apt/lib:$BUILD_DIR/.apt/usr/lib:$LIBRARY_PATH"
export INCLUDE_PATH="$BUILD_DIR/.apt/usr/include:$BUILD_DIR/.apt/usr/include/x86_64-linux-gnu:$INCLUDE_PATH"
export CPATH="$INCLUDE_PATH"
export CPPPATH="$INCLUDE_PATH"
export PKG_CONFIG_PATH="$BUILD_DIR/.apt/usr/lib/x86_64-linux-gnu/pkgconfig:$BUILD_DIR/.apt/usr/lib/i386-linux-gnu/pkgconfig:$BUILD_DIR/.apt/usr/lib/pkgconfig:$PKG_CONFIG_PATH"

#give environment to later buildpacks
export | grep -E -e ' (PATH|LD_LIBRARY_PATH|LIBRARY_PATH|INCLUDE_PATH|CPATH|CPPPATH|PKG_CONFIG_PATH)='  > "$LP_DIR/export"

topic "Rewrite package-config files"
find $BUILD_DIR/.apt -type f -ipath '*/pkgconfig/*.pc' | xargs --no-run-if-empty -n 1 sed -i -e 's!^prefix=\(.*\)$!prefix='"$BUILD_DIR"'/.apt\1!g'
