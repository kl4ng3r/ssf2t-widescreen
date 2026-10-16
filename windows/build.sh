#!/bin/sh
# Cross-compiles NBAJamWS.exe on Linux (Ubuntu/Debian: apt install mingw-w64 git make perl curl).
# Run from the repository root:  sh windows/build.sh   -> windows/NBAJamWS.exe
set -e
ROOT=$(pwd)
SDLV=2.30.9
mkdir -p build && cd build
if [ ! -d fbneo ]; then
  git clone --filter=blob:none https://github.com/libretro/FBNeo.git fbneo
  cd fbneo && git checkout "$(cat "$ROOT/core/BASE_COMMIT.txt")"
  git apply "$ROOT/core/fbneo-nbajamrw.diff"
  cp "$ROOT/core/nbajamrw_patches.h" src/burn/drv/midway/
  cd ..
fi
if [ ! -d SDL2-$SDLV ]; then
  curl -sSL -o sdl2.tgz https://github.com/libsdl-org/SDL/releases/download/release-$SDLV/SDL2-devel-$SDLV-mingw.tar.gz
  tar xzf sdl2.tgz
fi
cd fbneo/src/burner/libretro
make SUBSET=tunit generate-files
make -j"$(nproc)" SUBSET=tunit platform=win CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ AR=x86_64-w64-mingw32-ar
cd ../..
rm -f ../../libfbneo_win.a
find . -name '*.o' -print0 | xargs -0 x86_64-w64-mingw32-ar rcs ../../libfbneo_win.a
cd "$ROOT/windows"
SDL="$ROOT/build/SDL2-$SDLV/x86_64-w64-mingw32"
x86_64-w64-mingw32-windres nbajamws.rc -O coff -o ../build/nbajamws_res.o
x86_64-w64-mingw32-g++ -O2 -std=c++17 -I"$SDL/include/SDL2" -Dmain=SDL_main -o NBAJamWS.exe nbajamws.cpp \
  ../build/nbajamws_res.o ../build/libfbneo_win.a -L"$SDL/lib" -static -lmingw32 -lSDL2main -lSDL2 -mwindows \
  -lm -ldinput8 -ldxguid -ldxerr8 -luser32 -lgdi32 -lwinmm -limm32 -lole32 -loleaut32 -lshell32 -lsetupapi \
  -lversion -luuid -static-libgcc -static-libstdc++
x86_64-w64-mingw32-strip NBAJamWS.exe
echo "built windows/NBAJamWS.exe"
