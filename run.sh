#!/bin/bash
set -e
set -u # Giữ nguyên chế độ kiểm tra biến nghiêm ngặt của bạn

# =====================================================================
# LỖI DÒNG 10: Sửa BASH_SOURCE để không bị crash "unbound variable" 
# khi bạn chạy script dạng stream/pipe qua Docker hoặc Curl
# =====================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Cấu hình các biến gốc của bạn ---
MINING_MODE="GPU" # Có thể chuyển đổi giữa GPU và CPU tùy nhu cầu
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"

# Cấu hình đường dẫn (Xử lý triệt để việc ghép chuỗi sinh ra dấu //)
MINER_ROOT="/miners"
if [ "$MINING_MODE" = "GPU" ]; then
    MINER_DIR="$MINER_ROOT/gpu/rgminer"
    WORKER_NAME="${WORKER}-gpu"
else
    MINER_DIR="$MINER_ROOT/cpu/rgminer"
    WORKER_NAME="${WORKER}-cpu"
fi
MINER_BIN="$MINER_DIR/rgminer"

# Giao diện hiển thị gốc của bạn
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💎 Pearl (PRL) Miner - Chế độ: $MINING_MODE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 Ví     : $WALLET"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛠️  Worker : $WORKER_NAME"
echo "-------------------------------------------------------"

echo "📦 Cài đặt các gói cần thiết..."
mkdir -p "$MINER_DIR"

echo "🛠️ --- Thiết lập $MINING_MODE miner (rgminer) ---"
echo "🔍 Tìm bản mới nhất của rgminer từ GitHub..."

# Link v0.9.4 chuẩn bạn đã kiểm tra
URL_DOWNLOAD="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"
echo "📥 Tải rgminer: $URL_DOWNLOAD"

if [ ! -f "$MINER_BIN" ]; then
    # Tải file vào thư mục tạm /tmp để tránh rác thư mục chính
    wget -q --show-progress "$URL_DOWNLOAD" -O /tmp/rgminer.tar.gz
    
    echo "📂 Giải nén gói cài đặt..."
    # =====================================================================
    # SỬA LỖI GIẢI NÉN (No such file or directory): 
    # Thêm --strip-components=1 để ép bung ruột gói tar thẳng vào $MINER_DIR
    # =====================================================================
    tar -xzf /tmp/rgminer.tar.gz -C "$MINER_DIR" --strip-components=1 2>/dev/null || \
    tar -xzf /tmp/rgminer.tar.gz -C "$MINER_DIR"
    
    rm -f /tmp/rgminer.tar.gz
    
    # Cơ chế dự phòng tự động tìm file thực thi nếu cấu trúc gói đổi
    if [ ! -f "$MINER_BIN" ]; then
        FOUND_BIN=$(find "$MINER_DIR" -type f -name "rgminer" | head -n 1)
        if [ -n "$FOUND_BIN" ]; then
            mv "$FOUND_BIN" "$MINER_BIN"
        fi
    fi
    
    # Cấp quyền chạy cho file thực thi
    if [ -f "$MINER_BIN" ]; then
        chmod +x "$MINER_BIN"
        echo "✅ Thiết lập $MINING_MODE miner thành công!"
    else
        echo "❌ Lỗi: Không thể cấu hình file thực thi tại $MINER_BIN"
        exit 1
    fi
fi

# --- Vòng lặp duy trì đào gốc của bạn ---
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🚀 Khởi chạy miner..."
    
    # Gọi trực tiếp bằng biến đường dẫn tuyệt đối đã được làm sạch
    "$MINER_BIN" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "$WORKER_NAME"
    
    EXIT_CODE=$?
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️ [$CURRENT_TIME] [$MINING_MODE] Miner thoát (code=$EXIT_CODE). Thử lại sau 5s..."
    sleep 5
    echo "-------------------------------------------------------"
done
