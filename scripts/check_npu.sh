#!/bin/sh
#=============================================================================
# 板卡 NPU 诊断脚本
# 全面检查 RK3588 板卡的 NPU 驱动状态
#
# 用法 (在板卡上运行):
#   chmod +x check_npu.sh
#   ./check_npu.sh
#
# 或从 PC 远程运行:
#   ssh root@192.168.31.241 "sh -s" < check_npu.sh
#=============================================================================

echo "╔══════════════════════════════════════════════╗"
echo "║  RK3588 NPU 诊断报告                        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. 系统信息
echo "━━━ 1. 系统信息 ━━━"
echo "  主机名:     $(hostname)"
echo "  内核版本:   $(uname -r)"
echo "  架构:       $(uname -m)"
cat /etc/os-release 2>/dev/null | grep -E "^NAME=|^VERSION=" | sed 's/^/  /' || echo "  (无法获取发行版信息)"
echo ""

# 2. 内存
echo "━━━ 2. 内存 ━━━"
free -h
echo ""

# 3. NPU 硬件
echo "━━━ 3. NPU 硬件 ━━━"
echo "  NPU 设备树:"
ls -la /proc/device-tree/*npu* 2>/dev/null | sed 's/^/    /' || echo "    (无)"
echo ""
echo "  DRI 节点:"
ls -la /dev/dri/ 2>/dev/null | sed 's/^/    /' || echo "    (无)"
echo ""
echo "  DRI 设备名称:"
for n in 0 1 2; do
    name=$(cat /sys/kernel/debug/dri/${n}/name 2>/dev/null || echo "")
    [ -n "$name" ] && echo "    card${n}: ${name}" || true
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

# 显示哪个是 NPU
npu_card=$(dmesg 2>/dev/null | grep "Initialized rknpu" | tail -1 | sed 's/.*minor \([0-9]*\).*/\1/' || echo "?")
echo ""
echo "  NPU 绑定在 DRI card${npu_card} (renderD12${npu_card})"
echo ""

# 4. 驱动状态
echo "━━━ 4. 驱动状态 ━━━"

# galcore
if lsmod 2>/dev/null | grep -q galcore; then
    echo "  galcore 模块: ✓ 已加载"
    galcore_ver=$(cat /sys/kernel/debug/gc/version 2>/dev/null || echo "unknown")
    echo "  galcore 版本: ${galcore_ver}"
else
    echo "  galcore 模块: ✗ 未加载"
fi

# rknpu 内置驱动
rknpu_info=$(dmesg 2>/dev/null | grep "Initialized rknpu" | tail -1 || echo "")
if [ -n "$rknpu_info" ]; then
    echo "  内置 RKNPU:   ✓ (内核内置)"
    rknpu_ver=$(echo "$rknpu_info" | sed 's/.*rknpu \([0-9.]*\).*/\1/' || echo "unknown")
    echo "  内置版本:     ${rknpu_ver}"
    echo "  初始化信息:   ${rknpu_info##*] }"
else
    echo "  内置 RKNPU:   ✗ 未检测到"
fi
echo ""

# 5. 内核配置
echo "━━━ 5. 内核 NPU 配置 ━━━"
if [ -f /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_ROCKCHIP_RKNPU|CONFIG_GALCORE" || echo "  (未找到 NPU 相关配置)"
else
    echo "  (无 /proc/config.gz，无法检查内核配置)"
fi
echo ""

# 6. 驱动文件
echo "━━━ 6. 驱动文件 ━━━"
found_files=$(find /lib/modules /usr/lib /opt -name "*galcore*" -o -name "*rknpu*ko" -o -name "*rknn*rt*" 2>/dev/null | grep -v ".so$")
if [ -n "$found_files" ]; then
    echo "$found_files" | while read f; do
        echo "  $f"
        file "$f" 2>/dev/null | sed 's/^/    /'
    done
else
    echo "  (未找到 NPU 相关文件)"
fi
echo ""

# 7. dmesg NPU 相关
echo "━━━ 7. dmesg NPU 日志 (最近 15 行) ━━━"
dmesg 2>/dev/null | grep -iE "galcore|rknpu|npu" | tail -15 | sed 's/^/  /'
echo ""

# 8. 进程
echo "━━━ 8. NPU 相关进程 ━━━"
ps aux 2>/dev/null | grep -iE "rknn|rkllm|npu" | grep -v grep | sed 's/^/  /' || echo "  (无)"
echo ""

# 9. 判断升级需求
echo "━━━ 9. 升级建议 ━━━"
REQUIRED_MAJOR=0
REQUIRED_MINOR=9
REQUIRED_PATCH=7

galcore_ver=$(cat /sys/kernel/debug/gc/version 2>/dev/null || echo "")
rknpu_ver=$(dmesg 2>/dev/null | grep "Initialized rknpu" | tail -1 | sed 's/.*rknpu \([0-9.]*\).*/\1/' || echo "")

if [ -n "$galcore_ver" ]; then
    CURRENT="$galcore_ver"
    DRIVER_TYPE="galcore"
elif [ -n "$rknpu_ver" ]; then
    CURRENT="$rknpu_ver"
    DRIVER_TYPE="rknpu (内置)"
else
    CURRENT="unknown"
    DRIVER_TYPE="unknown"
fi

echo "  当前驱动:   ${DRIVER_TYPE} v${CURRENT}"
echo "  最低要求:   v${REQUIRED_MAJOR}.${REQUIRED_MINOR}.${REQUIRED_PATCH} (RKLLM v1.2.x)"

CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1 2>/dev/null || echo 0)
CUR_MINOR=$(echo "$CURRENT" | cut -d. -f2 2>/dev/null || echo 0)

if [ "$CURRENT" = "unknown" ]; then
    echo "  状态:       ⚠ 未检测到 NPU 驱动，请安装"
elif [ "$CUR_MAJOR" -gt "$REQUIRED_MAJOR" ] || \
   { [ "$CUR_MAJOR" -eq "$REQUIRED_MAJOR" ] && [ "$CUR_MINOR" -ge "$REQUIRED_MINOR" ]; }; then
    echo "  状态:       ✅ 驱动版本满足要求"
else
    echo "  状态:       ❌ 驱动版本过低，需要升级"
    echo ""
    echo "  升级方案:"
    if echo "$DRIVER_TYPE" | grep -q "内置"; then
        echo "    检测到内核内置 NPU 驱动，升级方案:"
        echo "    A) 从 RKLLM SDK 获取 galcore.ko 并尝试加载"
        echo "       下载: https://console.zbox.filez.com/l/RJJDmB (提取码: rkllm)"
        echo "    B) 如果 A 失败，需要更换内核/固件"
    else
        echo "    替换 galcore.ko 模块文件即可"
        echo "    下载: https://console.zbox.filez.com/l/RJJDmB (提取码: rkllm)"
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  诊断完成                                    ║"
echo "╚══════════════════════════════════════════════╝"
