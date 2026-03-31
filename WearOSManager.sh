#!/data/data/com.termux/files/usr/bin/sh
ADB=${ADB:-adb}
DEVICE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd || pwd)"
DISABLED_LIST="${SCRIPT_DIR}/disabled_apps.txt"
DEFAULT_PACKAGE_LIST="${SCRIPT_DIR}/package_list.txt"
HOST_EXPORT_DIR="${SCRIPT_DIR}"

trim(){ echo "$1" | awk '{$1=$1;print}'; }
device_arg(){ [ -n "$DEVICE" ] && echo "-s $DEVICE" || echo ""; }
inline_wait(){ printf "\n%s" "${1:-按任意键继续...}"; read -r -n 1 -s __wait 2>/dev/null; printf "\n"; }
err_exit(){ echo "错误: $1"; exit 1; }

check_adb(){
  if command -v "$ADB" >/dev/null 2>&1; then return 0; fi
  printf "未检测到 adb，尝试安装 android-tools...\n"
  if command -v apt >/dev/null 2>&1; then apt update >/dev/null 2>&1 || true; apt install android-tools -y >/dev/null 2>&1 || true
  elif command -v pkg >/dev/null 2>&1; then pkg update >/dev/null 2>&1 || true; pkg install android-tools -y >/dev/null 2>&1 || true
  else err_exit "系统不支持 apt/pkg，请手动安装 adb/android-tools"; fi
  command -v "$ADB" >/dev/null 2>&1 || err_exit "安装 adb 失败，请手动安装 android-tools"
}

clear_and_header(){ clear; printf "=== Wear OS 调试工具 ===\n"; [ -n "$DEVICE" ] && printf "设备: %s\n\n" "$DEVICE" || printf "设备: 默认\n\n"; }

ensure_list_file(){ [ -f "$DISABLED_LIST" ] || { mkdir -p "$(dirname "$DISABLED_LIST")" 2>/dev/null || true; : > "$DISABLED_LIST"; }; }
add_to_disabled_list(){ pkg="$1"; ensure_list_file; grep -Fxq -- "$pkg" "$DISABLED_LIST" 2>/dev/null || echo "$pkg" >> "$DISABLED_LIST"; }
remove_pkg_from_disabled_list(){ pkg="$1"; ensure_list_file; tmp="$(mktemp 2>/dev/null || echo "${DISABLED_LIST}.tmp")"; grep -Fxv -- "$pkg" "$DISABLED_LIST" > "$tmp" 2>/dev/null || true; if [ -s "$tmp" ]; then mv "$tmp" "$DISABLED_LIST"; else : > "$DISABLED_LIST"; rm -f "$tmp" 2>/dev/null || true; fi; }
read_list_packages(){ ensure_list_file; sed -n 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d; p' "$DISABLED_LIST"; }

select_device(){ clear_and_header; printf "检测设备...\n"; $ADB devices | sed -n '1,200p' | sed 's/^/  /'; printf "\n序列号（留空使用默认）： "; read -r input; DEVICE=$(trim "$input"); [ -n "$DEVICE" ] && printf "已选: %s\n" "$DEVICE" || printf "使用默认设备\n"; sleep 1; }
is_system_app(){ pkg="$1"; $ADB $(device_arg) shell "pm list packages -s" | grep -q "$pkg"; return $?; }

list_packages_choice(){
  printf "\n1) 用户应用\n2) 系统应用\n3) 全部应用\n"
  read -r -p "选项 (1/2/3): " opt; opt=$(trim "$opt")
  case "$opt" in 1) cmd="pm list packages -3" ;; 2) cmd="pm list packages -s" ;; 3) cmd="pm list packages" ;; *) printf "无效\n"; inline_wait; return ;; esac
  read -r -p "关键词（留空不筛选）: " kw; kw=$(trim "$kw")
  if [ -n "$kw" ]; then
    $ADB $(device_arg) shell "$cmd" 2>/dev/null | sed "s/^package://g" | tr -d '\r' | grep -i -- "$kw" | sed "s/^/  /"
    PACKS=$($ADB $(device_arg) shell "$cmd" 2>/dev/null | sed "s/^package://g" | tr -d '\r' | grep -i -- "$kw" 2>/dev/null)
  else
    $ADB $(device_arg) shell "$cmd" 2>/dev/null | sed "s/^package://g" | tr -d '\r' | sed "s/^/  /"
    PACKS=$($ADB $(device_arg) shell "$cmd" 2>/dev/null | sed "s/^package://g" | tr -d '\r')
  fi
  read -r -p "保存到文件? (y/N): " save; save=$(trim "$save")
  if [ "$save" = "y" ] || [ "$save" = "Y" ]; then
    read -r -p "路径（默认: ${DEFAULT_PACKAGE_LIST}）: " savepath; savepath=$(trim "$savepath"); [ -z "$savepath" ] && savepath="$DEFAULT_PACKAGE_LIST"
    printf "%s\n" "$PACKS" | sed '/^[[:space:]]*$/d' > "$savepath" 2>/dev/null || { printf "写入失败\n"; inline_wait; return; }
    printf "已保存: %s\n" "$savepath"
  fi
  inline_wait
}

_install_single_apk(){ apk="$1"; [ -f "$apk" ] || { printf "不存在: %s\n" "$apk"; return 1; }; printf "安装: %s\n" "$apk"; $ADB $(device_arg) install -r "$apk"; rc=$?; [ $rc -eq 0 ] && printf "成功: %s\n" "$apk" || printf "失败(%d): %s\n" "$rc" "$apk"; return $rc; }

batch_install_from_dir_with_preview(){
  dir="$1"; [ -d "$dir" ] || { printf "目录不存在\n"; return 1; }
  apks=(); for f in "$dir"/*.apk; do [ -e "$f" ] || continue; apks+=("$f"); done
  [ ${#apks[@]} -gt 0 ] || { printf "未找到 .apk\n"; return 1; }
  printf "将安装 %d 个 APK:\n" "${#apks[@]}"; for a in "${apks[@]}"; do printf "  %s\n" "$a"; done
  read -r -p "确认安装? 输入 y 开始: " conf; conf=$(trim "$conf"); if [ "$conf" != "y" ] && [ "$conf" != "Y" ]; then printf "已取消\n"; return 2; fi
  for a in "${apks[@]}"; do _install_single_apk "$a"; done; return 0
}

install_apks_menu(){
  while true; do clear_and_header; printf "1) 单个安装\n2) 目录批量安装（预览->确认）\n0) 返回\n"; read -r -p "选: " im; im=$(trim "$im")
    case "$im" in
      1) read -r -p "APK 路径: " apk; apk=$(trim "$apk"); [ -z "$apk" ] && { printf "取消\n"; inline_wait; continue; }; _install_single_apk "$apk"; inline_wait ;;
      2) read -r -p "目录路径: " dir; dir=$(trim "$dir"); [ -z "$dir" ] && { printf "取消\n"; inline_wait; continue; }; batch_install_from_dir_with_preview "$dir"; inline_wait ;;
      0) break ;;
      *) printf "无效\n"; inline_wait ;;
    esac
  done
}

get_remote_apk_path(){ pkg="$1"; $ADB $(device_arg) shell "pm path $pkg" 2>/dev/null | sed -n 's/^package://p' | tr -d '\r'; }
get_pkg_version(){
  pkg="$1"
  ver=$($ADB $(device_arg) shell "dumpsys package $pkg" 2>/dev/null | tr -d '\r' | awk -F'=' '/versionName=/{print $2; exit}')
  [ -n "$ver" ] && { printf "%s\n" "$ver"; return 0; }
  verc=$($ADB $(device_arg) shell "dumpsys package $pkg" 2>/dev/null | tr -d '\r' | awk -F'=' '/versionCode=/{print $2; exit}')
  [ -n "$verc" ] && { printf "%s\n" "$verc"; return 0; }
  printf "unknown\n"; return 0
}

extract_apk_flow(){
  read -r -p "包名: " pkg; pkg=$(trim "$pkg"); [ -z "$pkg" ] && { printf "取消\n"; inline_wait; return; }
  printf "查询 APK 路径...\n"; remote_path=$(get_remote_apk_path "$pkg")
  [ -z "$remote_path" ] && { printf "未找到 APK 路径: %s\n" "$pkg"; inline_wait; return; }
  remote_path=$(printf "%s\n" "$remote_path" | sed -n '1p' | sed "s/^package://g" | tr -d '\r')
  printf "设备路径: %s\n" "$remote_path"
  ver=$(get_pkg_version "$pkg"); safe_pkg=$(echo "$pkg" | sed 's/[^A-Za-z0-9._-]/_/g'); safe_ver=$(echo "$ver" | sed 's/[^A-Za-z0-9._-]/_/g')
  outname="${safe_pkg}_${safe_ver}.apk"; outpath="${SCRIPT_DIR}/${outname}"; printf "将提取到: %s\n" "$outpath"
  if $ADB $(device_arg) pull "$remote_path" "$outpath" 2>/dev/null; then [ -s "$outpath" ] && printf "已提取: %s\n" "$outpath" || { printf "提取失败或文件为空\n"; rm -f "$outpath" 2>/dev/null || true; }
  else printf "adb pull 失败\n"; rm -f "$outpath" 2>/dev/null || true; fi
  inline_wait
}

appops_flow(){
  read -r -p "包名: " pkg; pkg=$(trim "$pkg"); [ -z "$pkg" ] && { printf "取消\n"; inline_wait; return; }
  printf "\n常见 appops 示例与说明：\n  MANAGE_EXTERNAL_STORAGE - 管理所有文件访问\n  REQUEST_INSTALL_PACKAGES - 允许安装未知来源 APK\n  WRITE_SETTINGS - 允许修改系统设置\n  RUN_IN_BACKGROUND - 后台运行权限\n  CHANGE_WIFI_STATE - 修改 Wi-Fi 状态\n  WAKE_LOCK - 保持设备唤醒\n\n"
  read -r -p "要操作的权限（例如 MANAGE_EXTERNAL_STORAGE）: " op; op=$(trim "$op"); [ -z "$op" ] && { printf "取消\n"; inline_wait; return; }
  printf "\n设置选项：1) allow  2) deny  3) ignore\n"; read -r -p "选择 (1/2/3): " mode; mode=$(trim "$mode")
  case "$mode" in 1) m="allow" ;; 2) m="deny" ;; 3) m="ignore" ;; *) printf "无效\n"; inline_wait; return ;; esac
  printf "执行: appops set %s %s %s\n" "$pkg" "$op" "$m"
  $ADB $(device_arg) shell "appops set $pkg $op $m" 2>&1 | sed "s/^/  /"
  read -r -p "是否打开应用信息页面以便手动确认? 输入 y 打开: " openinfo; openinfo=$(trim "$openinfo")
  if [ "$openinfo" = "y" ] || [ "$openinfo" = "Y" ]; then $ADB $(device_arg) shell "am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:$pkg" 2>/dev/null; fi
  inline_wait
}

disable_app_flow(){ read -r -p "包名: " pkg; pkg=$(trim "$pkg"); [ -z "$pkg" ] && { printf "取消\n"; return; }; if is_system_app "$pkg"; then read -r -p "系统应用，确认停用输入 y: " c; c=$(trim "$c"); [ "$c" != "y" ] && [ "$c" != "Y" ] && { printf "取消\n"; return; }; fi; $ADB $(device_arg) shell "pm disable-user --user 0 $pkg" 2>&1 | sed "s/^/  /"; add_to_disabled_list "$pkg"; printf "已停用并记录: %s\n" "$pkg"; inline_wait; }

uninstall_app_flow(){ read -r -p "包名: " pkg; pkg=$(trim "$pkg"); [ -z "$pkg" ] && { printf "取消\n"; return; }; if is_system_app "$pkg"; then read -r -p "系统应用，确认卸载输入 y: " c; c=$(trim "$c"); [ "$c" != "y" ] && [ "$c" != "Y" ] && { printf "取消\n"; return; }; $ADB $(device_arg) shell "pm uninstall --user 0 $pkg" 2>&1 | sed "s/^/  /"; remove_pkg_from_disabled_list "$pkg"; printf "已卸载: %s\n" "$pkg"; else $ADB $(device_arg) shell "pm uninstall $pkg" 2>&1 | sed "s/^/  /"; remove_pkg_from_disabled_list "$pkg"; printf "已卸载: %s\n" "$pkg"; fi; inline_wait; }

enable_app_flow(){ read -r -p "包名: " pkg; pkg=$(trim "$pkg"); [ -z "$pkg" ] && { printf "取消\n"; return; }; $ADB $(device_arg) shell "pm enable $pkg" 2>&1 | sed "s/^/  /"; if [ -f "$DISABLED_LIST" ] && grep -Fxq -- "$pkg" "$DISABLED_LIST" 2>/dev/null; then read -r -p "从列表移除? (y/N): " rmv; rmv=$(trim "$rmv"); if [ "$rmv" = "y" ] || [ "$rmv" = "Y" ]; then remove_pkg_from_disabled_list "$pkg" && printf "已移除: %s\n" "$pkg"; fi; fi; inline_wait; }

export_disabled_list_to_host(){ if [ ! -f "$DISABLED_LIST" ]; then printf "本地列表不存在\n"; inline_wait; return; fi; read -r -p "导出到主机路径（默认: ${HOST_EXPORT_DIR}/$(basename "$DISABLED_LIST")）: " dest; dest=$(trim "$dest"); [ -z "$dest" ] && dest="${HOST_EXPORT_DIR}/$(basename "$DISABLED_LIST")"; if cp "$DISABLED_LIST" "$dest" 2>/dev/null; then printf "已导出: %s\n" "$dest"; else printf "导出失败\n"; fi; inline_wait; }

import_disabled_list_from_host(){ read -r -p "主机文件路径（要导入的文件）: " src; src=$(trim "$src"); [ -z "$src" ] && { printf "取消\n"; inline_wait; return; }; if [ -f "$src" ]; then if cp "$src" "$DISABLED_LIST" 2>/dev/null; then printf "已导入: %s\n" "$DISABLED_LIST"; else printf "导入失败\n"; fi; else printf "文件不存在: %s\n" "$src"; fi; inline_wait; }

clear_disabled_list(){ read -r -p "确认清空列表? 输入 y 清空: " conf; conf=$(trim "$conf"); if [ "$conf" != "y" ] && [ "$conf" != "Y" ]; then printf "取消\n"; inline_wait; return; fi; read -r -p "是否先备份到主机? 输入 y 备份: " bak; bak=$(trim "$bak"); if [ "$bak" = "y" ] || [ "$bak" = "Y" ]; then if [ -f "$DISABLED_LIST" ]; then ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "$(date +%s)"); bakfile="${DISABLED_LIST}.bak.${ts}"; if cp "$DISABLED_LIST" "$bakfile" 2>/dev/null; then printf "已备份: %s\n" "$bakfile"; else printf "备份失败\n"; fi; else printf "列表不存在，跳过备份\n"; fi; fi; : > "$DISABLED_LIST"; printf "已清空\n"; inline_wait; }

manage_disabled_list_menu(){
  while true; do clear_and_header; printf "1) 查看列表\n2) 批量停用\n3) 批量启用（不修改记录）\n4) 导出到主机\n5) 从主机导入\n6) 清空列表\n0) 返回\n"; read -r -p "选: " o; o=$(trim "$o")
    case "$o" in
      1) [ -f "$DISABLED_LIST" ] && sed -n '1,200p' "$DISABLED_LIST" | sed "s/^/  /" || printf "列表不存在\n"; inline_wait ;;
      2) for p in $(read_list_packages); do printf "停用: %s\n" "$p"; $ADB $(device_arg) shell "pm disable-user --user 0 $p" 2>&1 | sed "s/^/  /"; done; inline_wait ;;
      3) for p in $(read_list_packages); do printf "启用: %s\n" "$p"; $ADB $(device_arg) shell "pm enable $p" 2>&1 | sed "s/^/  /"; done; inline_wait ;;
      4) export_disabled_list_to_host ;;
      5) import_disabled_list_from_host ;;
      6) clear_disabled_list ;;
      0) break ;;
      *) printf "无效\n"; inline_wait ;;
    esac
  done
}

file_list_in_device_dir(){ remote_dir="$1"; $ADB $(device_arg) shell "ls -l \"$remote_dir\"" 2>&1 | sed "s/^/  /"; }

file_manager_menu(){
  while true; do clear_and_header; printf "文件管理:\n1) 推送本地文件到设备 (adb push)\n2) 从设备拉取文件到本地 (adb pull)\n3) 列出设备目录文件\n4) 删除设备文件\n0) 返回\n"; read -r -p "选: " fm; fm=$(trim "$fm")
    case "$fm" in
      1) read -r -p "本地路径: " local; local=$(trim "$local"); [ -z "$local" ] && { printf "取消\n"; inline_wait; continue; }; [ ! -f "$local" ] && { printf "不存在\n"; inline_wait; continue; }; read -r -p "设备目标 (默认 /sdcard/Download/): " remote; remote=$(trim "$remote"); [ -z "$remote" ] && remote="/sdcard/Download/"; if echo "$remote" | grep -q '/$'; then remote="${remote}$(basename "$local")"; fi; $ADB $(device_arg) push "$local" "$remote" 2>&1 | sed "s/^/  /"; inline_wait ;;
      2) read -r -p "设备路径: " remote; remote=$(trim "$remote"); [ -z "$remote" ] && { printf "取消\n"; inline_wait; continue; }; read -r -p "本地目标路径（默认脚本目录）: " local; local=$(trim "$local"); [ -z "$local" ] && local="$SCRIPT_DIR/$(basename "$remote")"; $ADB $(device_arg) pull "$remote" "$local" 2>&1 | sed "s/^/  /"; inline_wait ;;
      3) read -r -p "设备目录路径 (例如 /sdcard/Download): " rdir; rdir=$(trim "$rdir"); [ -z "$rdir" ] && { printf "取消\n"; inline_wait; continue; }; file_list_in_device_dir "$rdir"; inline_wait ;;
      4) read -r -p "设备文件路径 (将被删除): " rfile; rfile=$(trim "$rfile"); [ -z "$rfile" ] && { printf "取消\n"; inline_wait; continue; }; read -r -p "确认删除? 输入 y 删除: " dconf; dconf=$(trim "$dconf"); if [ "$dconf" = "y" ] || [ "$dconf" = "Y" ]; then $ADB $(device_arg) shell "rm -f \"$rfile\"" 2>&1 | sed "s/^/  /"; printf "已删除: %s\n" "$rfile"; else printf "取消\n"; fi; inline_wait ;;
      0) break ;;
      *) printf "无效\n"; inline_wait ;;
    esac
  done
}

power_menu(){
  while true; do clear_and_header; printf "电源选项:\n1) 重启 (reboot)\n2) 重启到 bootloader\n3) 重启到 recovery\n4) 关机 (reboot -p)\n0) 返回\n"; read -r -p "选: " p; p=$(trim "$p")
    case "$p" in
      1) printf "执行: reboot\n"; $ADB $(device_arg) shell "reboot" 2>&1 | sed "s/^/  /"; inline_wait ;;
      2) printf "执行: reboot bootloader\n"; $ADB $(device_arg) reboot bootloader 2>&1 | sed "s/^/  /"; inline_wait ;;
      3) printf "执行: reboot recovery\n"; $ADB $(device_arg) reboot recovery 2>&1 | sed "s/^/  /"; inline_wait ;;
      4) printf "执行: shutdown\n"; $ADB $(device_arg) shell "reboot -p" 2>&1 | sed "s/^/  /"; inline_wait ;;
      0) break ;;
      *) printf "无效\n"; inline_wait ;;
    esac
  done
}

device_info(){
  clear_and_header
  printf "设备基本信息:\n"; $ADB $(device_arg) shell "getprop ro.product.model; getprop ro.product.brand; getprop ro.build.version.release; getprop ro.build.version.sdk" 2>/dev/null | sed "s/^/  /"
  printf "\n屏幕分辨率:\n"; $ADB $(device_arg) shell "wm size" 2>/dev/null | sed "s/^/  /"
  printf "\nCPU 信息 (部分):\n"; $ADB $(device_arg) shell "cat /proc/cpuinfo | sed -n '1,6p'" 2>/dev/null | sed "s/^/  /"
  printf "\n内存与存储 (部分):\n"; $ADB $(device_arg) shell "cat /proc/meminfo | sed -n '1,4p'; df -h /data | sed -n '1,2p'" 2>/dev/null | sed "s/^/  /"
  printf "\n网络与蓝牙 (部分):\n"; $ADB $(device_arg) shell "ip addr show | sed -n '1,20p'; dumpsys bluetooth_manager | sed -n '1,10p'" 2>/dev/null | sed "s/^/  /"
  inline_wait
}

foreground_info(){
  clear_and_header; printf "查询前台 Activity...\n"
  out=$($ADB $(device_arg) shell "dumpsys activity activities" 2>/dev/null | tr -d '\r' | sed -n '1,200p')
  fg=$(printf "%s\n" "$out" | grep -m1 -E "mResumedActivity|mFocusedActivity|ResumedActivity" || true)
  if [ -z "$fg" ]; then out2=$($ADB $(device_arg) shell "dumpsys window windows" 2>/dev/null | tr -d '\r' | sed -n '1,200p'); fg=$(printf "%s\n" "$out2" | grep -m1 -E "mCurrentFocus|mFocusedApp|mFocusedWindow" || true); fi
  if [ -z "$fg" ]; then printf "无法获取前台信息\n"; inline_wait; return; fi
  printf "原始信息:\n"; printf "%s\n" "$fg" | sed "s/^/  /"
  pkgact=$(printf "%s\n" "$fg" | sed -n 's/.* \([A-Za-z0-9._-]*\/[A-Za-z0-9_.$-]*\).*/\1/p' | sed -n '1p')
  [ -z "$pkgact" ] && pkgact=$(printf "%s\n" "$fg" | grep -oE "[A-Za-z0-9._-]+\/[A-Za-z0-9_.$-]+" | sed -n '1p' || true)
  if [ -n "$pkgact" ]; then pkg=$(printf "%s\n" "$pkgact" | awk -F'/' '{print $1}'); act=$(printf "%s\n" "$pkgact" | awk -F'/' '{print $2}'); printf "\n前台包名: %s\n" "$pkg"; printf "前台 Activity: %s\n" "$act"; else printf "\n未能解析包名/Activity，显示原始行供参考。\n"; fi
  inline_wait
}

toggle_theme(){
  clear_and_header
  CUR=$($ADB $(device_arg) shell "cmd uimode night" 2>/dev/null || true)
  lc=$(printf "%s" "$CUR" | tr '[:upper:]' '[:lower:]')
  if printf "%s" "$lc" | grep -q "night mode: yes"; then
    printf "当前: 深色 -> 切换为 浅色\n"; $ADB $(device_arg) shell "cmd uimode night no" 2>/dev/null || $ADB $(device_arg) shell "settings put secure ui_night_mode 1" 2>/dev/null; inline_wait; return
  elif printf "%s" "$lc" | grep -q "night mode: no"; then
    printf "当前: 浅色 -> 切换为 深色\n"; $ADB $(device_arg) shell "cmd uimode night yes" 2>/dev/null || $ADB $(device_arg) shell "settings put secure ui_night_mode 2" 2>/dev/null; inline_wait; return
  fi
  MODE=$($ADB $(device_arg) shell "settings get secure ui_night_mode" 2>/dev/null || echo ""); MODE=$(trim "$MODE")
  case "$MODE" in
    2) printf "当前 (settings): 深色 -> 切换为 浅色\n"; $ADB $(device_arg) shell "settings put secure ui_night_mode 1" 2>/dev/null || $ADB $(device_arg) shell "cmd uimode night no" 2>/dev/null ;;
    1) printf "当前 (settings): 浅色 -> 切换为 深色\n"; $ADB $(device_arg) shell "settings put secure ui_night_mode 2" 2>/dev/null || $ADB $(device_arg) shell "cmd uimode night yes" 2>/dev/null ;;
    0|""|*) printf "当前模式未知，尝试切换（先尝试 cmd uimode，再尝试 settings）\n"; $ADB $(device_arg) shell "cmd uimode night toggle" 2>/dev/null || true; sleep 1; $ADB $(device_arg) shell "cmd uimode night yes" 2>/dev/null || $ADB $(device_arg) shell "settings put secure ui_night_mode 2" 2>/dev/null || true ;;
  esac
  inline_wait
}

show_menu(){ clear_and_header; cat <<EOF
主菜单:
1) 选择设备
2) 设备信息
3) 获取前台包名与 Activity
4) 电源操作
5) 应用管理
6) 文件管理
7) 停用列表管理
8) 切换深/浅色模式
0) 退出
EOF
printf "\n选: "; }

show_app_menu(){ clear_and_header; cat <<EOF
应用管理:
1) 列表（筛选/保存）
2) 启用
3) 停用
4) 卸载
5) 安装 APK
6) 提取 APK
7) 管理 appops
8) 应用信息
9) 查看 appops
0) 返回
EOF
printf "\n选: "; }

check_adb
while true; do
  show_menu
  read -r choice; choice=$(trim "$choice")
  case "$choice" in
    1) select_device ;;
    2) device_info ;;
    3) foreground_info ;;
    4) power_menu ;;
    5)
      while true; do
        show_app_menu
        read -r a; a=$(trim "$a")
        case "$a" in
          1) list_packages_choice ;;
          2) read -r -p "包名: " p; p=$(trim "$p"); [ -z "$p" ] && { printf "取消\n"; inline_wait; continue; }; $ADB $(device_arg) shell "pm enable $p" 2>&1 | sed "s/^/  /"; inline_wait ;;
          3) disable_app_flow ;;
          4) uninstall_app_flow ;;
          5) install_apks_menu ;;
          6) extract_apk_flow ;;
          7) appops_flow ;;
          8) read -r -p "包名: " p; p=$(trim "$p"); [ -z "$p" ] && { printf "取消\n"; inline_wait; continue; }; $ADB $(device_arg) shell "am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:$p" 2>/dev/null; inline_wait ;;
          9) read -r -p "包名: " p; p=$(trim "$p"); [ -z "$p" ] && { printf "取消\n"; inline_wait; continue; }; $ADB $(device_arg) shell "appops get $p" 2>&1 | sed "s/^/  /"; inline_wait ;;
          0) break ;;
          *) printf "无效\n"; inline_wait ;;
        esac
      done
      ;;
    6) file_manager_menu ;;
    7) manage_disabled_list_menu ;;
    8) toggle_theme ;;
    0) clear; printf "退出\n"; exit 0 ;;
    *) printf "无效\n"; inline_wait ;;
  esac
done
