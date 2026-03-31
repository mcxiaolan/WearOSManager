#!/bin/bash

# --- 1. 依赖检查 ---
if ! command -v adb &> /dev/null || ! command -v aapt2 &> /dev/null; then
    echo "正在安装依赖..."
    apt update && apt install android-tools-adb aapt2 -y
fi

# --- 2. 参数处理 ---
usage() {
    echo "用法: $0 -i <输入文件> [-o <输出文件>]"
    exit 1
}

INPUT_FILE=""
OUTPUT_FILE=""

while getopts "i:o:h" opt; do
    case $opt in
        i) INPUT_FILE=$OPTARG ;;
        o) OUTPUT_FILE=$OPTARG ;;
        *) usage ;;
    esac
done

if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    usage
fi

# --- 3. 读取包名到数组 (关键改动) ---
# 使用 mapfile 将文件内容一次性读入内存，并去除 Windows 换行符
mapfile -t PACKAGES < <(tr -d '\r' < "$INPUT_FILE")

TOTAL=${#PACKAGES[@]}
echo "已加载 $TOTAL 个包名，准备开始解析..."

if [ -n "$OUTPUT_FILE" ]; then
    echo "Package Name | App Label" > "$OUTPUT_FILE"
    echo "--------------------------" >> "$OUTPUT_FILE"
fi

# --- 4. 遍历数组 ---
COUNT=0
for package in "${PACKAGES[@]}"; do
    # 跳过空行
    package=$(echo "$package" | xargs)
    [ -z "$package" ] && continue

    ((COUNT++))
    echo -n "[$COUNT/$TOTAL] 正在处理: $package ... "

    # 获取路径 (彻底重定向 stdin)
    apk_path=$(adb shell pm path "$package" 2>/dev/null </dev/null | cut -d':' -f2 | tr -d '\r' | xargs)

    if [ -z "$apk_path" ]; then
        label="[未安装/未找到]"
    else
        # 拉取 APK (指定临时文件名防止冲突)
        temp_apk="temp_${COUNT}.apk"
        adb pull "$apk_path" "$temp_apk" &> /dev/null </dev/null
        
        if [ -f "$temp_apk" ]; then
            # 解析标签 (优先中文)
            all_info=$(aapt2 dump badging "$temp_apk" 2>/dev/null)
            label=$(echo "$all_info" | grep "application-label-zh-CN" | cut -d"'" -f2)
            [ -z "$label" ] && label=$(echo "$all_info" | grep "application-label-zh" | cut -d"'" -f2 | head -n 1)
            [ -z "$label" ] && label=$(echo "$all_info" | grep "application-label:" | cut -d"'" -f2)
            [ -z "$label" ] && label="Unknown"
            
            rm -f "$temp_apk"
        else
            label="[提取失败]"
        fi
    fi

    echo "$label"

    # 导出结果
    if [ -n "$OUTPUT_FILE" ]; then
        echo "$package | $label" >> "$OUTPUT_FILE"
    fi
done

echo "--------------------------------------"
[ -n "$OUTPUT_FILE" ] && echo "完成！结果已保存至: $OUTPUT_FILE" || echo "完成！"