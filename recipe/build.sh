#!/bin/bash

set -ex

# Possible ctng-compiler-activation bug - MESON_SYSTEM is undefined, should be MESON_NAME
# This sets system = 'linux' in the cross file where it's currently empty
# Submitted Issue: https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/174
if [[ $CONDA_BUILD_CROSS_COMPILATION == "1" && "${target_platform}" == linux-* ]]; then
  sed -i "s/^system = ''$/system = 'linux'/" $BUILD_PREFIX/meson_cross_file.txt
  echo "=== Patched meson cross file ==="
  cat $BUILD_PREFIX/meson_cross_file.txt
fi

export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$BUILD_PREFIX/lib/pkgconfig
export PKG_CONFIG=$BUILD_PREFIX/bin/pkg-config

# macOS: Use native macos platform to avoid X11 header conflicts
# The macOS sysroot has old X11 headers that conflict with newer xorg-libx11
if [[ "${target_platform}" == osx-* ]]; then
  MESA_PLATFORMS="macos"
else
  MESA_PLATFORMS="x11"
fi

if [[ $CONDA_BUILD_CROSS_COMPILATION == "1" ]]; then
  if [[ "${CMAKE_CROSSCOMPILING_EMULATOR:-}" == "" ]]; then
    # Mostly taken from https://github.com/conda-forge/pocl-feedstock/blob/b88046a851a95ab3c676c0b7815da8224bd66a09/recipe/build.sh#L52
    rm $PREFIX/bin/llvm-config
    cp $BUILD_PREFIX/bin/llvm-config $PREFIX/bin/llvm-config
    export LLVM_CONFIG=${PREFIX}/bin/llvm-config
  else
    # https://github.com/mesonbuild/meson/issues/4254
    export LLVM_CONFIG=${BUILD_PREFIX}/bin/llvm-config
  fi
fi

# On Linux, enable the software DRI frontend so that the gallium software
# DRI driver (lib/dri/swrast_dri.so via the dril loader stub), the DRI loader
# header (include/GL/internal/dri_interface.h) and dri.pc get built/installed.
# Enabling glx=dri (and egl/gbm) makes `with_dri` true in mesa's meson logic
# (it requires with_gallium && system_has_kms_drm, which holds on linux).
# glvnd is ENABLED so that mesa builds the libglvnd vendor libraries
# (libGLX_mesa.so.0 / libEGL_mesa.so.0 + share/glvnd/egl_vendor.d/50_mesa.json)
# and does NOT ship its own libGL.so / libEGL.so (those collide with
# conda-forge's libglvnd, which provides libGL/libEGL). With glvnd enabled mesa
# also stops installing the GL/EGL/KHR public headers (libgl-devel/libegl-devel
# ship those on conda-forge). swrast_dri.so / dri_interface.h / dri.pc / libgbm
# / libgallium are still built.
# On macOS/Windows we keep the DRI frontend disabled (no kms/drm there).
if [[ "${target_platform}" == linux-* ]]; then
  MESA_DRI_ARGS=(
    -Dglx=dri
    -Degl=enabled
    -Dgbm=enabled
    -Dglvnd=enabled
  )
else
  MESA_DRI_ARGS=(
    -Degl=disabled
    -Dglx=disabled
    -Dgbm=disabled
  )
fi

meson setup builddir/ \
  ${MESON_ARGS} \
  -Dplatforms=${MESA_PLATFORMS} \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dgallium-va=disabled \
  -Dshared-glapi=enabled \
  -Dgallium-drivers=softpipe,llvmpipe \
  "${MESA_DRI_ARGS[@]}" \
  -Dllvm=enabled \
  -Dshared-llvm=enabled \
  -Dlibdir=lib \
  -Dvulkan-drivers=swrast \
  -Dopengl=true \
  -Dglx-direct=false \
  || { cat builddir/meson-logs/meson-log.txt; exit 1; }

ninja -C builddir/ -j ${CPU_COUNT}

ninja -C builddir/ install

# meson test -C builddir/ \
#   -t 4

