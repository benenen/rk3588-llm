#!/bin/sh
#=============================================================================
# 板卡端 NPU 驱动一键安装脚本
# 
# 用法 (在板卡上直接运行):
#   1. 将 galcore.ko 放在 /tmp/rkllm_driver/ 目录下
#   2. chmod +x install_npu_driver.sh
#   3. ./install_npu_driver.sh
#
# 也可以从 PC 推送后运行:
#   scp galcore.ko root@192.168.31.241:/tmp/rkllm_driver/
#   scp install_npu_driver.sh root@192.168.31.241:/tmp/rkllm_driver/
#   ssh root@192.168.31.241 "cd /tmp/rkllm_driver && sh install_npu_driver.sh"
#=============================================================================

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC}  $*"; }

KERNEL_VER=$(uname -r)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SRC="${SCRIPT_DIR}/galcore.ko"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  RK3588 NPU 驱动安装 (板卡端)            ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  内核版本:   ${KERNEL_VER}"
echo "  架构:       $(uname -m)"
echo "  驱动搜索:   ${SCRIPT_DIR}"
echo ""

#------------------------------------------------------------------------------
# 1. 查找驱动文件
#------------------------------------------------------------------------------
find_driver() {
    log_warn "查找 galcore.ko..."

    # 搜索多个可能的位置
    for path in \
        "${SCRIPT_DIR}/galcore.ko" \
        "/tmp/rkllm_driver/galcore.ko" \
        "/tmp/galcore.ko" \
        "/root/galcore.ko" \
        "$(find / -name 'galcore.ko' -type f 2>/dev/null | head -1)"
    do
        if [ -n "$path" ] && [ -f "$path" ]; then
            DRIVER_SRC="$path"
            log_ok "找到: ${DRIVER_SRC}"
            return 0
        fi
    done

    log_err "未找到 galcore.ko！"
    echo ""
    echo "  请先获取预编译的 galcore.ko，放到以下任一位置:"
    echo "    ${SCRIPT_DIR}/galcore.ko"
    echo "    /tmp/rkllm_driver/galcore.ko"
    echo "    /tmp/galcore.ko"
    echo ""
    echo "  获取方式:"
    echo "    1. 从 RKLLM SDK 下载: https://console.zbox.filez.com/l/RJJDmB (提取码: rkllm)"
    echo "    2. 从 GitHub 下载源码自行编译: https://github.com/airockchip/rknn-llm"
    echo "    3. 从板卡厂商获取"
    return 1
}

#------------------------------------------------------------------------------
# 2. 兼容性检查
#------------------------------------------------------------------------------
check_compat() {
    log_warn "检查驱动兼容性..."

    local mod_vermagic
    mod_vermagic=$(modinfo "$DRIVER_SRC" 2>/dev/null | grep "vermagic" | awk '{print $2}' || echo "unknown")

    if [ "$mod_vermagic" != "unknown" ] && [ "$mod_vermagic" != "$KERNEL_VER" ]; then
        log_err "驱动内核版本不匹配！"
        log_err "  驱动编译自: ${mod_vermagic}"
        log_err "  当前内核:   ${KERNEL_VER}"
        log_err "  驱动必须与内核版本完全一致才能加载"
        return 1
    fi

    log_ok "内核版本匹配: ${mod_vermagic}"
    return 0
}

#------------------------------------------------------------------------------
# 3. 卸载旧驱动
#------------------------------------------------------------------------------
unload_old() {
    log_warn "卸载旧的 NPU 驱动..."

    # 检查 galcore
    if lsmod 2>/dev/null | grep -q galcore; then
        rmmod galcore 2>/dev/null && log_ok "已卸载 galcore" || {
            log_warn "galcore 正在使用中，将尝试强制卸载"
            rmmod -f galcore 2>/dev/null || log_warn "galcore 强制卸载失败，重启后生效"
        }
    fi

    # 检查 rknpu 模块
    if lsmod 2>/dev/null | grep -q "rknpu "; then
        rmmod rknpu 2>/dev/null && log_ok "已卸载 rknpu 模块" || true
    fi

    # 检查是否是内核内置驱动
    if dmesg 2>/dev/null | grep -q "Initialized rknpu"; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn " 检测到内核内置 NPU 驱动"
        log_warn " 内置驱动无法通过 rmmod 卸载"
        log_warn ""
        log_warn " 如果加载 galcore.ko 失败，需要:"
        log_warn "  1. 更换不使用内置 NPU 驱动的内核"
        log_warn "  2. 或使用支持 RKLLM 的完整固件"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

#------------------------------------------------------------------------------
# 4. 安装新驱动
#------------------------------------------------------------------------------
install_new() {
    log_warn "安装新驱动..."

    # 目标目录
    MODULES_DIR="/lib/modules/${KERNEL_VER}/extra"
    mkdir -p "$MODULES_DIR"

    # 复制
    cp "$DRIVER_SRC" "$MODULES_DIR/galcore.ko"
    chmod 644 "$MODULES_DIR/galcore.ko"
    log_ok "已复制到: $MODULES_DIR/galcore.ko"

    # 更新依赖
    depmod -a 2>/dev/null && log_ok "depmod 完成" || log_warn "depmod 失败 (可能不影响)"

    # 配置开机自动加载
    if [ -d /etc/modules-load.d ]; then
        echo "galcore" > /etc/modules-load.d/galcore.conf
        log_ok "开机自启: /etc/modules-load.d/galcore.conf"
    elif [ -f /etc/modules ]; then
        if ! grep -q "^galcore" /etc/modules 2>/dev/null; then
            echo "galcore" >> /etc/modules
        fi
        log_ok "开机自启: /etc/modules"
    else
        log_warn "无法配置开机自启，请手动添加 'modprobe galcore' 到启动脚本"
    fi

    # 尝试加载
    log_warn "尝试加载 galcore..."
    if modprobe galcore 2>/dev/null; then
        log_ok "galcore 加载成功! (modprobe)"
        return 0
    elif insmod "$MODULES_DIR/galcore.ko" 2>/dev/null; then
        log_ok "galcore 加载成功! (insmod)"
        return 0
    else
        log_warn "直接加载失败"
        dmesg | tail -5 | while read line; do echo "  dmesg: $line"; done
        return 1
    fi
}

#------------------------------------------------------------------------------
# 5. 验证
#------------------------------------------------------------------------------
verify() {
    log_warn "验证驱动..."
    echo ""

    echo "  [模块状态]"
    if lsmod | grep -q galcore; then
        log_ok "galcore 已加载"
    else
        log_warn "galcore 未加载 (请重启后检查)"
    fi

    echo ""
    echo "  [调试信息]"
    mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    
    if [ -f /sys/kernel/debug/gc/version ]; then
        echo "  galcore 版本: $(cat /sys/kernel/debug/gc/version)"
        log_ok "驱动版本信息可用"
    fi

    echo ""
    echo "  [DRI 节点]"
    ls -la /dev/dri/render* 2>/dev/null || echo "  (无 DRI 节点)"

    echo ""
    echo "  [dmesg 最后 5 行 NPU 相关]"
    dmesg 2>/dev/null | grep -iE "galcore|rknpu|npu" | tail -5
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    find_driver || exit 1
    check_compat || exit 1
    unload_old
    install_new || log_warn "加载失败，将在重启后重试"
    
    echo ""
    verify

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  安装完成                                ║"
    echo "║                                          ║"
    echo "║  请重启板卡:                             ║"
    echo "║    reboot                                ║"
    echo "║                                          ║"
    echo "║  重启后验证:                             ║"
    echo "║    lsmod | grep galcore                  ║"
    echo "║    cat /sys/kernel/debug/gc/version      ║"
    echo "╚══════════════════════════════════════════╝"
}

main
