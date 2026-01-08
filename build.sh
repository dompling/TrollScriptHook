#!/bin/bash

#
# build.sh
# TrollScriptHook
#
# 编译脚本 - 不依赖 Theos，直接使用 clang 编译
# 生成的 dylib 可直接通过 insert_dylib 注入
#

set -e

# 配置
DYLIB_NAME="TrollScriptHook"
SOURCE_FILE="Tweak.m"
OUTPUT_DIR="build"
MIN_IOS_VERSION="14.0"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  TrollScriptHook Build Script${NC}"
echo -e "${GREEN}========================================${NC}"

# 检查 Xcode 工具链
if ! command -v xcrun &> /dev/null; then
    echo -e "${RED}Error: Xcode command line tools not found${NC}"
    echo "Please install with: xcode-select --install"
    exit 1
fi

# 获取 SDK 路径
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$SDK_PATH" ]; then
    echo -e "${RED}Error: iOS SDK not found${NC}"
    echo "Please install Xcode with iOS SDK"
    exit 1
fi

echo -e "${YELLOW}Using SDK: $SDK_PATH${NC}"

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 编译 arm64
echo -e "${YELLOW}Compiling for arm64...${NC}"
xcrun -sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=$MIN_IOS_VERSION \
    -isysroot "$SDK_PATH" \
    -dynamiclib \
    -fobjc-arc \
    -fmodules \
    -framework Foundation \
    -framework UIKit \
    -framework UserNotifications \
    -install_name "@executable_path/Frameworks/${DYLIB_NAME}.dylib" \
    -o "$OUTPUT_DIR/${DYLIB_NAME}_arm64.dylib" \
    "$SOURCE_FILE"

# 编译 arm64e
echo -e "${YELLOW}Compiling for arm64e...${NC}"
xcrun -sdk iphoneos clang \
    -arch arm64e \
    -miphoneos-version-min=$MIN_IOS_VERSION \
    -isysroot "$SDK_PATH" \
    -dynamiclib \
    -fobjc-arc \
    -fmodules \
    -framework Foundation \
    -framework UIKit \
    -framework UserNotifications \
    -install_name "@executable_path/Frameworks/${DYLIB_NAME}.dylib" \
    -o "$OUTPUT_DIR/${DYLIB_NAME}_arm64e.dylib" \
    "$SOURCE_FILE"

# 创建 fat binary
echo -e "${YELLOW}Creating universal binary...${NC}"
lipo -create \
    "$OUTPUT_DIR/${DYLIB_NAME}_arm64.dylib" \
    "$OUTPUT_DIR/${DYLIB_NAME}_arm64e.dylib" \
    -output "$OUTPUT_DIR/${DYLIB_NAME}.dylib"

# 签名 (ad-hoc)
echo -e "${YELLOW}Signing dylib...${NC}"
codesign -f -s - "$OUTPUT_DIR/${DYLIB_NAME}.dylib"

# 清理临时文件
rm -f "$OUTPUT_DIR/${DYLIB_NAME}_arm64.dylib"
rm -f "$OUTPUT_DIR/${DYLIB_NAME}_arm64e.dylib"

# 显示结果
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Output: ${YELLOW}$OUTPUT_DIR/${DYLIB_NAME}.dylib${NC}"
echo ""

# 显示文件信息
echo "File info:"
file "$OUTPUT_DIR/${DYLIB_NAME}.dylib"
echo ""
echo "Size: $(du -h "$OUTPUT_DIR/${DYLIB_NAME}.dylib" | cut -f1)"
echo ""

# 显示架构信息
echo "Architectures:"
lipo -info "$OUTPUT_DIR/${DYLIB_NAME}.dylib"
