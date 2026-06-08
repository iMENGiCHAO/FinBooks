#!/bin/bash
# FinBooks Bridge - 快速启动脚本
# 启动 HTTP API 服务 (localhost:9090)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 优先使用项目内的 bridge
BRIDGE_SCRIPT="$SCRIPT_DIR/finbooks_bridge.py"

if [ ! -f "$BRIDGE_SCRIPT" ]; then
    # 尝试 Hermes scripts 目录
    BRIDGE_SCRIPT="$HOME/.hermes/scripts/finbooks_bridge.py"
fi

if [ ! -f "$BRIDGE_SCRIPT" ]; then
    echo "[ERROR] 找不到 finbooks_bridge.py"
    echo "  请确认项目结构完整: ls $SCRIPT_DIR/"
    exit 1
fi

echo "FinBooks Bridge v2.2"
echo "启动中..."
echo "  Script: $BRIDGE_SCRIPT"
echo "  Port:   9090"
echo "  URL:    http://127.0.0.1:9090"
echo ""
python3 "$BRIDGE_SCRIPT"
