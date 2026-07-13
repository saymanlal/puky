#!/bin/bash
set -e

INPUT_ICON="puky-icon.jpg"

if [ ! -f "$INPUT_ICON" ]; then
    echo "Error: $INPUT_ICON not found!"
    exit 1
fi

declare -A SIZES
SIZES["mipmap-mdpi"]=48
SIZES["mipmap-hdpi"]=72
SIZES["mipmap-xhdpi"]=96
SIZES["mipmap-xxhdpi"]=144
SIZES["mipmap-xxxhdpi"]=192

for DIR in "${!SIZES[@]}"; do
    SIZE=${SIZES[$DIR]}
    HALF=$((SIZE / 2))
    TARGET_DIR="android/app/src/main/res/$DIR"
    
    echo "Processing $DIR with size ${SIZE}x${SIZE}..."
    
    # Ensure target directory exists
    mkdir -p "$TARGET_DIR"
    
    # Generate ic_launcher.png (square resized)
    convert "$INPUT_ICON" -resize "${SIZE}x${SIZE}!" "$TARGET_DIR/ic_launcher.png"
    
    # Generate ic_launcher_foreground.png (foreground for adaptive icons)
    # We will use the same image but with a transparent border or just full sized
    convert "$INPUT_ICON" -resize "${SIZE}x${SIZE}!" "$TARGET_DIR/ic_launcher_foreground.png"
    
    # Generate ic_launcher_round.png (circular crop)
    # We create a transparent canvas, draw a white circle on it, and composite it
    convert "$TARGET_DIR/ic_launcher.png" \
        \( -size "${SIZE}x${SIZE}" xc:none -fill white -draw "circle $HALF,$HALF $HALF,0" \) \
        -alpha off -compose CopyOpacity -composite "$TARGET_DIR/ic_launcher_round.png"
done

echo "Removing adaptive/vector XML icon files to force fallback to generated PNGs..."
rm -rf android/app/src/main/res/mipmap-anydpi-v26
rm -f android/app/src/main/res/drawable-v24/ic_launcher_foreground.xml
rm -f android/app/src/main/res/drawable/ic_launcher_background.xml

echo "Android app icons generated successfully!"
