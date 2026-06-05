#!/bin/bash
#=============================================================================
# RK3588 NPU 驱动一键升级 (针对 192.168.31.241 板卡)
#
# 简化版入口脚本，封装完整流程:
#   1. 检查板卡当前状态
#   2. 下载驱动
#   3. 推送到板卡并安装
#
# 用法:
#   ./upgrade.sh
#   ./upgrade.sh --skip-download   # 跳过下载 (驱动已在本地)
#=============================================================================

set -euo pipefail

cd "$(dirname "$0")"

BOARD_IP="192.168.31.241"
BOARD_USER="root"
BOARD_PASS="fa"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  RK3588 NPU 驱动一键升级                    ║"
echo "║  目标: ${BOARD_USER}@${BOARD_IP}                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 调用主脚本
./setup_npu_driver.sh \
    --board-ip "${BOARD_IP}" \
    --board-user "${BOARD_USER}" \
    --board-pass "${BOARD_PASS}" \
    --platform rk3588 \
    "$@"
