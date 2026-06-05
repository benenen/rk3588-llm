#!/bin/bash
#=============================================================================
# RK3588 NPU Driver 一键准备脚本（在 Mac/PC 上运行）
# 
# 功能:
#   1. 检查板卡当前驱动版本
#   2. 下载最新的 NPU 驱动
#   3. 推送到板卡并安装
#   4. 验证升级结果
#
# 用法:
#   ./setup_npu_driver.sh --board-ip 192.168.31.241 --board-user root --board-pass fa
#
# 前置条件:
#   - 本机有 sshpass (brew install sshpass)
#   - 本机能访问 GitHub
#   - 本机能通过 SSH 连接到板卡
#=============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# 配置（可通过命令行参数覆盖）
#------------------------------------------------------------------------------
BOARD_IP="${BOARD_IP:-192.168.31.241}"
BOARD_USER="${BOARD_USER:-root}"
BOARD_PASS="${BOARD_PASS:-fa}"
TARGET_PLATFORM="${TARGET_PLATFORM:-rk3588}"

# RKLLM SDK 下载地址（可能需要手动下载后放到本地）
# 官方 SDK: https://console.zbox.filez.com/l/RJJDmB (提取码: rkllm)
# 驱动源码: https://github.com/airockchip/rknn-llm (rknpu-driver/)
RKLLM_GITHUB="https://github.com/airockchip/rknn-llm"
DRIVER_REPO_PATH="rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2"
DRIVER_RAW_URL="https://github.com/airockchip/rknn-llm/raw/main/${DRIVER_REPO_PATH}"

# 工作目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="/tmp/rkllm_driver_upgrade"
DRIVER_PKG="rknpu_driver_0.9.8.tar.bz2"
DRIVER_DIR="rknpu_driver"

#------------------------------------------------------------------------------
# 颜色输出
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

#------------------------------------------------------------------------------
# SSH 辅助函数
#------------------------------------------------------------------------------
ssh_board() {
    sshpass -p "${BOARD_PASS}" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${BOARD_USER}@${BOARD_IP}" "$@"
}

scp_to_board() {
    sshpass -p "${BOARD_PASS}" scp -o StrictHostKeyChecking=no \
        "$1" "${BOARD_USER}@${BOARD_IP}:$2"
}

#------------------------------------------------------------------------------
# 参数解析
#------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board-ip)   BOARD_IP="$2"; shift 2 ;;
            --board-user) BOARD_USER="$2"; shift 2 ;;
            --board-pass) BOARD_PASS="$2"; shift 2 ;;
            --platform)   TARGET_PLATFORM="$2"; shift 2 ;;
            --local-driver) LOCAL_DRIVER="$2"; shift 2 ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --board-ip IP      板卡 IP 地址 (默认: 192.168.31.241)"
                echo "  --board-user USER  SSH 用户名 (默认: root)"
                echo "  --board-pass PASS  SSH 密码 (默认: fa)"
                echo "  --platform PLAT    目标平台 (默认: rk3588)"
                echo "  --local-driver PATH 本地驱动包路径 (跳过下载)"
                echo "  -h, --help         显示帮助"
                echo ""
                echo "示例:"
                echo "  $0                                                    # 使用默认配置"
                echo "  $0 --board-ip 192.168.1.100 --board-pass mypass       # 自定义板卡"
                echo "  $0 --local-driver ./galcore.ko                        # 本地已有驱动"
                exit 0
                ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

#------------------------------------------------------------------------------
# 1. 检查前置条件
#------------------------------------------------------------------------------
check_prerequisites() {
    log_info "检查前置条件..."

    # 检查 sshpass
    if ! command -v sshpass &>/dev/null; then
        log_error "未安装 sshpass。请执行: brew install sshpass"
        exit 1
    fi

    # 检查板卡连接
    log_info "检查板卡连接 (${BOARD_USER}@${BOARD_IP})..."
    if ! ssh_board "echo 'connected'" &>/dev/null; then
        log_error "无法连接到板卡 ${BOARD_USER}@${BOARD_IP}"
        log_error "请确认板卡 IP 地址和 SSH 凭据正确"
        exit 1
    fi
    log_ok "板卡连接正常"
}

#------------------------------------------------------------------------------
# 2. 检查板卡当前驱动状态
#------------------------------------------------------------------------------
check_board_driver() {
    log_info "检查板卡当前 NPU 驱动状态..."

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  板卡信息"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 系统信息
    local os_info kernel_ver
    os_info=$(ssh_board "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'unknown'")
    kernel_ver=$(ssh_board "uname -r")
    echo "  操作系统:   ${os_info}"
    echo "  内核版本:   ${kernel_ver}"
    echo "  平台架构:   $(ssh_board 'uname -m')"

    # NPU 驱动信息
    echo ""
    echo "  NPU 驱动状态:"

    # 检查 galcore 模块
    local galcore_loaded galcore_ver
    galcore_loaded=$(ssh_board "lsmod 2>/dev/null | grep galcore || echo ''")
    galcore_ver=$(ssh_board "cat /sys/kernel/debug/gc/version 2>/dev/null || echo ''")

    if [ -n "$galcore_loaded" ]; then
        echo "    galcore 模块: ✓ 已加载"
        echo "    galcore 版本: ${galcore_ver:-unknown}"
    else
        echo "    galcore 模块: ✗ 未加载"
    fi

    # 检查内置 rknpu 驱动
    local rknpu_ver
    rknpu_ver=$(ssh_board "dmesg 2>/dev/null | grep 'Initialized rknpu' | tail -1 | grep -oP 'rknpu \K[0-9.]+' || echo ''")
    if [ -n "$rknpu_ver" ]; then
        echo "    内置 RKNPU:   v${rknpu_ver} (内核内置)"
    fi

    # NPU 设备
    local npu_render
    npu_render=$(ssh_board "cat /sys/kernel/debug/dri/1/name 2>/dev/null || echo ''")
    echo "    NPU DRI 设备: ${npu_render}"

    # 内存
    echo ""
    echo "  内存:"
    ssh_board "free -h | head -2"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 判断是否需要升级
    NEED_UPGRADE=false
    if [ -z "$galcore_loaded" ] && [ -n "$rknpu_ver" ]; then
        local major_ver=$(echo "$rknpu_ver" | cut -d. -f1)
        local minor_ver=$(echo "$rknpu_ver" | cut -d. -f2)
        if [ "$major_ver" -lt 0 ] || { [ "$major_ver" -eq 0 ] && [ "$minor_ver" -lt 9 ]; }; then
            log_warn "当前 NPU 驱动版本过低 (v${rknpu_ver})，需要升级到 v0.9.7+"
            NEED_UPGRADE=true
        else
            log_ok "当前 NPU 驱动版本满足要求"
        fi
    elif [ -n "$galcore_ver" ]; then
        local major_ver=$(echo "$galcore_ver" | cut -d. -f1)
        local minor_ver=$(echo "$galcore_ver" | cut -d. -f2)
        if [ "$major_ver" -lt 0 ] || { [ "$major_ver" -eq 0 ] && [ "$minor_ver" -lt 9 ]; }; then
            log_warn "当前 galcore 驱动版本过低 (v${galcore_ver})，需要升级"
            NEED_UPGRADE=true
        else
            log_ok "当前 galcore 驱动版本满足要求"
        fi
    fi
}

#------------------------------------------------------------------------------
# 3. 下载/准备驱动
#------------------------------------------------------------------------------
download_driver() {
    log_info "准备 NPU 驱动..."

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"

    # 如果用户提供了本地驱动路径
    if [ -n "${LOCAL_DRIVER:-}" ]; then
        if [ -f "${LOCAL_DRIVER}" ]; then
            log_info "使用本地驱动: ${LOCAL_DRIVER}"
            cp "${LOCAL_DRIVER}" "${WORK_DIR}/"
            DRIVER_FILE=$(basename "${LOCAL_DRIVER}")
            
            # 如果是 tar.bz2 包，解压
            if [[ "$DRIVER_FILE" == *.tar.bz2 ]] || [[ "$DRIVER_FILE" == *.tar.gz ]]; then
                tar -xf "$DRIVER_FILE"
                rm -f "$DRIVER_FILE"
            fi
            return 0
        else
            log_error "本地驱动文件不存在: ${LOCAL_DRIVER}"
            exit 1
        fi
    fi

    # 尝试从 GitHub 下载驱动源码包
    log_info "尝试从 GitHub 下载驱动源码..."
    local download_success=false

    if command -v wget &>/dev/null; then
        if wget -q --timeout=30 "${DRIVER_RAW_URL}" -O "${DRIVER_PKG}" 2>/dev/null; then
            download_success=true
        fi
    elif command -v curl &>/dev/null; then
        if curl -sL --connect-timeout 30 "${DRIVER_RAW_URL}" -o "${DRIVER_PKG}" 2>/dev/null; then
            download_success=true
        fi
    fi

    if [ "$download_success" = true ] && [ -s "${DRIVER_PKG}" ]; then
        log_ok "驱动源码包下载成功 ($(du -h ${DRIVER_PKG} | cut -f1))"
        tar -xjf "${DRIVER_PKG}" -C "${WORK_DIR}/"
        rm -f "${DRIVER_PKG}"
        log_info "驱动源码已解压到 ${WORK_DIR}"
        return 0
    fi

    # GitHub 下载失败，提示用户手动下载
    log_warn "自动下载失败（网络限制或 GitHub 不可达）"
    log_warn ""
    log_warn "请手动下载驱动包，推荐以下方式之一:"
    log_warn ""
    log_warn "方式 1: RKLLM 官方 SDK (推荐，含预编译驱动)"
    log_warn "  地址: https://console.zbox.filez.com/l/RJJDmB"
    log_warn "  提取码: rkllm"
    log_warn "  下载后解压，找到 rknpu_driver/ 目录中的 galcore.ko"
    log_warn ""
    log_warn "方式 2: GitHub 驱动源码 (需自行编译)"
    log_warn "  地址: https://github.com/airockchip/rknn-llm/tree/main/rknpu-driver"
    log_warn ""
    log_warn "方式 3: 从板卡厂商获取匹配内核版本的 galcore.ko"
    log_warn "  联系板卡厂商获取对应 Linux 5.10.66 的驱动文件"
    log_warn ""
    log_warn "下载后将 galcore.ko 放到 ${WORK_DIR}/ 目录"
    log_warn "然后重新运行: $0 --local-driver ${WORK_DIR}/galcore.ko"
    log_warn ""

    # 创建占位目录让脚本可以继续
    mkdir -p "${WORK_DIR}/${DRIVER_DIR}"
    exit 1
}

#------------------------------------------------------------------------------
# 4. 准备板卡端安装脚本
#------------------------------------------------------------------------------
prepare_board_install_script() {
    log_info "准备板卡端安装脚本..."

    cat > "${WORK_DIR}/install_on_board.sh" << 'BOARD_SCRIPT'
#!/bin/sh
#=============================================================================
# 板卡端 NPU 驱动安装脚本
# 在板卡上以 root 身份运行
#=============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_VER=$(uname -r)
KERNEL_ARCH=$(uname -m)

echo "============================================"
echo "  RK3588 NPU 驱动安装"
echo "============================================"
echo "  内核版本:   ${KERNEL_VER}"
echo "  架构:       ${KERNEL_ARCH}"
echo "============================================"
echo ""

#------------------------------------------------------------------------------
# 步骤 1: 定位驱动文件
#------------------------------------------------------------------------------
find_driver() {
    # 优先查找 galcore.ko
    DRIVER_FILE=$(find "${SCRIPT_DIR}" -name "galcore.ko" -type f 2>/dev/null | head -1)
    if [ -n "$DRIVER_FILE" ]; then
        echo "找到 galcore.ko: ${DRIVER_FILE}"
        return 0
    fi

    # 检查 rknpu 驱动源码
    if [ -d "${SCRIPT_DIR}/drivers/rknpu" ]; then
        echo "找到 rknpu 驱动源码: ${SCRIPT_DIR}/drivers/rknpu"
        DRIVER_TYPE="source"
        DRIVER_FILE="${SCRIPT_DIR}/drivers/rknpu"
        return 0
    fi

    log_err "未找到驱动文件！"
    log_err "请将 galcore.ko 放在 ${SCRIPT_DIR}/ 目录下"
    return 1
}

#------------------------------------------------------------------------------
# 步骤 2: 检查驱动兼容性
#------------------------------------------------------------------------------
check_compatibility() {
    if [ "$DRIVER_TYPE" = "source" ]; then
        log_warn "驱动为源码形式，需要编译"
        
        # 检查编译工具
        if ! command -v gcc >/dev/null 2>&1; then
            log_err "未安装 gcc，无法编译驱动"
            log_err "请先在板卡上安装编译工具:"
            log_err "  apk add gcc make musl-dev linux-headers"
            return 1
        fi
        
        if [ ! -d "/lib/modules/${KERNEL_VER}/build" ]; then
            log_err "未安装内核头文件 /lib/modules/${KERNEL_VER}/build"
            log_err "板卡内核可能不支持模块编译"
            log_err ""
            log_err "替代方案:"
            log_err "  1. 下载预编译的 galcore.ko (推荐)"
            log_err "  2. 从 RKLLM SDK 获取预编译驱动"
            log_err "  3. 在另一台机器上交叉编译"
            return 1
        fi

        log_ok "编译工具和内核头文件已就绪"
        return 0
    fi

    # 检查 .ko 文件与内核的兼容性
    local mod_vermagic
    mod_vermagic=$(modinfo "$DRIVER_FILE" 2>/dev/null | grep "vermagic" | awk '{print $2}' || echo "")
    
    if [ -n "$mod_vermagic" ] && [ "$mod_vermagic" != "$KERNEL_VER" ]; then
        log_warn "驱动编译内核版本 (${mod_vermagic}) 与当前内核 (${KERNEL_VER}) 不匹配"
        log_warn "可能需要重新编译驱动"
        echo ""
        read -p "是否继续尝试加载? [y/N] " answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            return 1
        fi
    fi
    
    log_ok "驱动兼容性检查通过"
    return 0
}

#------------------------------------------------------------------------------
# 步骤 3: 编译驱动 (如果需要)
#------------------------------------------------------------------------------
compile_driver() {
    if [ "$DRIVER_TYPE" != "source" ]; then
        return 0
    fi

    log_warn "正在编译 NPU 驱动..."
    cd "$DRIVER_FILE"
    
    if make -C /lib/modules/${KERNEL_VER}/build M=$(pwd) modules; then
        DRIVER_FILE=$(pwd)/rknpu.ko
        DRIVER_TYPE="binary"
        log_ok "驱动编译成功: ${DRIVER_FILE}"
    else
        log_err "驱动编译失败"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 步骤 4: 备份并卸载旧驱动
#------------------------------------------------------------------------------
unload_old_driver() {
    log_warn "检查并卸载旧 NPU 驱动..."

    # 检查 galcore 模块
    if lsmod | grep -q galcore; then
        log_warn "正在卸载 galcore..."
        rmmod galcore 2>/dev/null || {
            log_warn "galcore 正在使用中，将在重启后生效"
        }
    fi

    # 检查 rknpu 模块 (如果是模块形式)
    if lsmod | grep -q rknpu; then
        log_warn "正在卸载 rknpu..."
        rmmod rknpu 2>/dev/null || true
    fi

    # 备份旧驱动文件
    local old_drivers=$(find /lib/modules -name "galcore.ko" -o -name "rknpu.ko" 2>/dev/null)
    if [ -n "$old_drivers" ]; then
        local backup_dir="/root/npu_driver_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        for f in $old_drivers; do
            log_warn "备份: $f -> $backup_dir/"
            cp "$f" "$backup_dir/"
        done
        log_ok "旧驱动已备份到: $backup_dir"
    else
        log_warn "未找到旧的模块文件"
    fi

    # 检查内置驱动
    if dmesg | grep -q "Initialized rknpu"; then
        log_warn "检测到内核内置 RKNPU 驱动 (dmesg)"
        log_warn "内核内置驱动无法通过 rmmod 卸载"
        log_warn ""
        log_warn "解决方案:"
        log_warn "  需要修改内核启动参数来禁用内置驱动"
        log_warn "  但这需要重新编译内核或修改 bootloader"
        log_warn ""
        log_warn "当前将尝试直接加载 galcore.ko，可能会失败"
        log_warn "如果失败，需要替换整个内核/固件"
    fi
}

#------------------------------------------------------------------------------
# 步骤 5: 安装新驱动
#------------------------------------------------------------------------------
install_new_driver() {
    if [ "$DRIVER_TYPE" != "binary" ]; then
        log_err "没有可用的二进制驱动文件"
        return 1
    fi

    log_warn "正在安装新驱动..."

    # 确定安装路径
    local target_dir="/lib/modules/${KERNEL_VER}/extra"
    mkdir -p "$target_dir"

    # 复制驱动
    cp "$DRIVER_FILE" "$target_dir/"
    chmod 644 "$target_dir/$(basename "$DRIVER_FILE")"

    # 更新模块依赖
    depmod -a 2>/dev/null || log_warn "depmod 失败 (可能不影响加载)"

    # 设置开机自动加载
    echo "galcore" > /etc/modules-load.d/galcore.conf 2>/dev/null || {
        # Alpine Linux 可能没有 modules-load.d
        if ! grep -q "galcore" /etc/modules 2>/dev/null; then
            echo "galcore" >> /etc/modules 2>/dev/null || true
        fi
    }

    log_ok "驱动安装完成"

    # 尝试加载
    log_warn "正在加载新驱动..."
    if modprobe galcore 2>/dev/null; then
        log_ok "galcore 加载成功!"
    elif insmod "$target_dir/$(basename "$DRIVER_FILE")" 2>/dev/null; then
        log_ok "galcore 加载成功 (insmod)!"
    else
        log_warn "直接加载失败 (可能因为内置驱动占用硬件)"
        log_warn "将在重启后自动尝试加载"
    fi
}

#------------------------------------------------------------------------------
# 步骤 6: 验证
#------------------------------------------------------------------------------
verify_installation() {
    log_warn "验证驱动安装..."

    echo ""
    echo "--- lsmod ---"
    lsmod | grep -E "galcore|rknpu|npu" || echo "  (无相关模块)"

    echo ""
    echo "--- dmesg (最后 5 行 NPU 相关) ---"
    dmesg | grep -iE "galcore|rknpu|npu" | tail -5 || echo "  (无相关日志)"

    echo ""
    echo "--- debugfs ---"
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
    cat /sys/kernel/debug/gc/version 2>/dev/null && log_ok "galcore 版本信息正常" || {
        log_warn "无法读取 galcore 版本 (可能未加载)"
        cat /sys/kernel/debug/dri/1/name 2>/dev/null && echo "  以上是 NPU DRI 节点"
    }

    echo ""
    echo "--- /dev/dri ---"
    ls -la /dev/dri/ 2>/dev/null
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    find_driver || exit 1
    
    # 确定驱动类型
    if echo "$DRIVER_FILE" | grep -q "\.ko$"; then
        DRIVER_TYPE="binary"
    else
        DRIVER_TYPE="source"
    fi

    check_compatibility || exit 1
    compile_driver || exit 1
    unload_old_driver
    install_new_driver
    
    echo ""
    echo "============================================"
    echo "  需要重启板卡使驱动生效"
    echo "  执行: reboot"
    echo "============================================"
    echo ""
    
    verify_installation
}

main
BOARD_SCRIPT

    chmod +x "${WORK_DIR}/install_on_board.sh"
    log_ok "板卡安装脚本已准备"
}

#------------------------------------------------------------------------------
# 5. 推送到板卡并执行
#------------------------------------------------------------------------------
push_and_install() {
    log_info "推送驱动到板卡..."

    # 推送整个工作目录
    ssh_board "rm -rf /tmp/rkllm_driver && mkdir -p /tmp/rkllm_driver"
    
    # 推送文件
    cd "${WORK_DIR}"
    if [ -f "galcore.ko" ]; then
        scp_to_board "galcore.ko" "/tmp/rkllm_driver/"
        log_ok "galcore.ko 已推送"
    fi
    if [ -d "drivers" ]; then
        ssh_board "rm -rf /tmp/rkllm_driver/drivers"
        tar -czf - drivers 2>/dev/null | sshpass -p "${BOARD_PASS}" ssh -o StrictHostKeyChecking=no \
            "${BOARD_USER}@${BOARD_IP}" "cd /tmp/rkllm_driver && tar -xzf -" || true
        log_ok "驱动源码已推送"
    fi
    
    scp_to_board "install_on_board.sh" "/tmp/rkllm_driver/"
    log_ok "安装脚本已推送"

    # 在板卡上执行安装
    log_info "在板卡上执行安装..."
    echo ""
    ssh_board "cd /tmp/rkllm_driver && sh install_on_board.sh"
    
    local install_result=$?
    echo ""
    
    if [ $install_result -eq 0 ]; then
        log_ok "驱动安装流程完成"
        
        # 询问是否重启
        echo ""
        log_warn "建议重启板卡使驱动生效"
        read -p "是否现在重启板卡? [y/N] " reboot_answer
        if [ "$reboot_answer" = "y" ] || [ "$reboot_answer" = "Y" ]; then
            log_info "正在重启板卡..."
            ssh_board "reboot" || true
            log_info "板卡正在重启，请等待约 30 秒..."
            sleep 5
            
            # 等待板卡重新上线
            log_info "等待板卡重新上线..."
            for i in $(seq 1 30); do
                if ssh_board "echo 'online'" 2>/dev/null; then
                    log_ok "板卡已重新上线"
                    break
                fi
                sleep 2
            done
            
            # 重启后验证
            echo ""
            log_info "重启后验证..."
            ssh_board "
                echo '--- galcore 状态 ---'
                lsmod | grep galcore || echo 'galcore 未加载'
                echo ''
                echo '--- dmesg NPU ---'
                dmesg | grep -iE 'galcore|rknpu' | tail -5
                echo ''
                echo '--- 驱动版本 ---'
                mount -t debugfs none /sys/kernel/debug 2>/dev/null
                cat /sys/kernel/debug/gc/version 2>/dev/null || echo '无法获取版本'
            "
        else
            log_info "请手动执行 'reboot' 重启板卡"
        fi
    else
        log_error "驱动安装失败，请检查错误信息"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# 主函数
#------------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  RK3588 NPU 驱动一键升级工具            ║"
    echo "║  目标平台: ${TARGET_PLATFORM}                  ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    check_board_driver

    if [ "${NEED_UPGRADE:-false}" = false ]; then
        log_ok "板卡驱动版本已满足要求，无需升级"
        exit 0
    fi

    echo ""
    read -p "确认升级 NPU 驱动? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "已取消"
        exit 0
    fi

    download_driver
    prepare_board_install_script
    push_and_install

    echo ""
    log_ok "升级流程完成!"
    echo ""
    log_info "重要提示:"
    echo "  1. 如果板卡的 NPU 驱动是内核内置的 (CONFIG_ROCKCHIP_RKNPU=y)"
    echo "     加载外部 galcore.ko 可能会冲突"
    echo "  2. 若加载失败，需要更换内核或固件"
    echo "  3. 如果板卡上还没有 RKLLM Runtime，请继续部署"
    echo ""
}

main "$@"
