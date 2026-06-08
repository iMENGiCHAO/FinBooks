#!/bin/bash
# FinBooks 数据备份/恢复脚本
# 用法:
#   bash backup_restore.sh backup [output_dir]
#   bash backup_restore.sh restore <backup.tar.gz>

set -euo pipefail

DATA_DIR="$HOME/Library/Application Support/com.finbooks.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

backup() {
    local out_dir="${1:-$SCRIPT_DIR/../backups}"
    out_dir="${out_dir/#\~/$HOME}"
    mkdir -p "$out_dir"
    
    if [ ! -d "$DATA_DIR" ]; then
        err "数据目录不存在: $DATA_DIR"
    fi
    
    local archive="$out_dir/finbooks_backup_$TIMESTAMP.tar.gz"
    tar -czf "$archive" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")" 2>/dev/null
    
    # 同时备份项目插件配置
    if [ -f "$SCRIPT_DIR/../.codex-plugin/plugin.json" ]; then
        tar -rf "${archive%.tar.gz}_project.tar.gz" \
            -C "$SCRIPT_DIR/.." .codex-plugin/ .hermes-plugin/ .openclaw-plugin/ 2>/dev/null || true
    fi
    
    info "备份完成: $archive"
    echo ""
    echo "  文件列表:"
    ls -la "$DATA_DIR/"*.json 2>/dev/null | wc -l | xargs echo "  JSON 文件数:"
    
    # 显示备份大小
    if [ -f "$archive" ]; then
        du -h "$archive" | awk '{print "  备份大小:", $1}'
    fi
    
    echo ""
    info "恢复命令: bash $(basename "$0") restore $archive"
}

restore() {
    local archive="${1:-}"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        err "请指定备份文件路径"
    fi
    
    # 先备份当前数据
    local tmp_backup="/tmp/finbooks_pre_restore_$TIMESTAMP"
    if [ -d "$DATA_DIR" ]; then
        cp -r "$DATA_DIR" "$tmp_backup" 2>/dev/null || true
        info "当前数据已备份到: $tmp_backup"
    fi
    
    # 解压恢复
    info "正在恢复数据..."
    mkdir -p "$DATA_DIR"
    tar -xzf "$archive" -C "$HOME" 2>/dev/null
    
    # 检查恢复后数据目录是否被放在错误位置
    if [ -d "$HOME/com.finbooks.app" ] && [ ! -d "$DATA_DIR" ]; then
        mv "$HOME/com.finbooks.app"/* "$DATA_DIR"/ 2>/dev/null
        rmdir "$HOME/com.finbooks.app" 2>/dev/null || true
    fi
    
    info "恢复完成！"
    echo ""
    info "请重启 FinBooks App 生效"
    info "如果出现问题，可恢复: cp -r $tmp_backup/* $DATA_DIR/"
}

case "${1:-help}" in
    backup)  backup "${2:-}" ;;
    restore) restore "${2:-}" ;;
    *)
        echo "FinBooks 备份/恢复工具"
        echo ""
        echo "用法:"
        echo "  bash backup_restore.sh backup [输出目录]"
        echo "  bash backup_restore.sh restore <备份文件.tar.gz>"
        echo ""
        echo "示例:"
        echo "  bash backup_restore.sh backup"
        echo "  bash backup_restore.sh backup ~/Desktop"
        echo "  bash backup_restore.sh restore ~/Desktop/finbooks_backup_20260606.tar.gz"
        ;;
esac
