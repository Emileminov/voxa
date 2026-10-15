#!/bin/bash
# Кладёт whisper-cli и его библиотеки внутрь приложения (источник: brew install whisper-cpp).
set -e
APP="${1:-Шёпот.app}"
W="$APP/Contents/Resources/whisper"
CELL="$(dirname "$(readlink -f /opt/homebrew/bin/whisper-cli)")/.."
GGML=/opt/homebrew/opt/ggml
rm -rf "$W"; mkdir -p "$W/bin" "$W/lib"
cp "$CELL/bin/whisper-cli" "$W/bin/"
cp -L "$CELL/lib/libwhisper.1.dylib" "$W/lib/"
cp -L "$GGML/lib/libggml.0.dylib" "$GGML/lib/libggml-base.0.dylib" "$W/lib/"
cp "$GGML"/libexec/*.so "$W/bin/"          # бэкенды ggml рядом с бинарником
cp -L /opt/homebrew/opt/libomp/lib/libomp.dylib "$W/lib/"
chmod -R u+w "$W"
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib "$W/bin/whisper-cli"
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib "$W/bin/whisper-cli"
for f in "$W"/lib/*.dylib "$W"/bin/*.so; do
  for dep in $(otool -L "$f" | awk '/\/opt\/homebrew/ {print $1}'); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f"
  done
done
for f in "$W"/bin/*.so; do install_name_tool -add_rpath @loader_path/../lib "$f" 2>/dev/null || true; done
echo "whisper упакован: $(du -sh "$W" | cut -f1)"
