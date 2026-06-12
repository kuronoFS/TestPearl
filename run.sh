#!/bin/bash

# Bật chế độ kiểm tra lỗi nhưng bỏ qua set -u cho các biến hệ thống dynamic
set -e
set -o pipefail

# --- Cấu hình Môi trường ---
MINER_DIR="/miners/gpu/rgminer"
MINER_BIN="$MINER_DIR/rgminer"
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01-gpu"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"
URL_DOWNLOAD="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"

echo "============================================="
echo " Pearl (PRL) Miner - Chế độ: GPU"
echo " Ví     : $WALLET"
echo " Worker : $WORKER"
echo "============================================="

# 1. Khởi tạo thư mục làm việc
echo "📦 Cài đặt các gói cần thiết và tạo thư mục..."
mkdir -p "$MINER_DIR"
cd "$MINER_DIR"

# 2. Tiến hành tải và cấu hình Miner nếu chưa có file thực thi
if [ ! -f "$MINER_BIN" ]; then
    echo "🔍 Tìm bản mới nhất của rgminer từ GitHub..."
    echo "⬇️ Đang tải rgminer từ: $URL_DOWNLOAD"
    
    # Tải file nén về thư mục tạm
    if wget -q --show-progress "$URL_DOWNLOAD" -O rgminer.tar.gz; then
        echo "📂 Giải nén gói cài đặt..."
        
        # Giải nén thẳng vào thư mục (bỏ qua 1 cấp thư mục bọc ngoài nếu có)
        tar -xzf rgminer.tar.gz -C "$MINER_DIR" --strip-components=1 2>/dev/null || tar -xzf rgminer.tar.gz -C "$MINER_DIR"
        rm -f rgminer.tar.gz
        
        # Kiểm tra và xử lý nếu file thực thi bị lệch vị trí
        if [ ! -f "$MINER_BIN" ]; then
            echo "⚡ Đang định vị lại file thực thi rgminer..."
            FOUND_BIN=$(find "$MINER_DIR" -type f -name "rgminer" | head -n 1)
            if [ -n "$FOUND_BIN" ]; then
                mv "$FOUND_BIN" "$MINER_BIN"
            fi
        fi
        
        # Cấp quyền chạy cho binary
        if [ -f "$MINER_BIN" ]; then
            chmod +x "$MINER_BIN"
            echo "✅ Thiết lập GPU miner (rgminer) thành công!"
        else
            echo "❌ Lỗi: Không tìm thấy file thực thi 'rgminer' sau khi giải nén!"
            ls -R "$MINER_DIR"
            exit 1
        fi
    else
        echo "❌ Lỗi: Không thể tải file từ GitHub. Vui lòng kiểm tra lại network của Container."
        exit 1
    fi
fi

# Đảm bảo file thực thi có quyền chạy trước khi vào loop
chmod +x "$MINER_BIN" 2>/dev/null || true

# 3. Vòng lặp duy trì tiến trình đào (Auto-Restart)
echo "🚀 Bắt đầu tiến trình đào Pearl..."
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🔄 Khởi chạy miner..."
    
    # Gọi trực tiếp bằng biến tuyệt đối đã được fix sạch double-slash
    "$MINER_BIN" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "$WORKER"
    
    EXIT_CODE=$?
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️ [$CURRENT_TIME] [GPU] Miner thoát (code=$EXIT_CODE). Thử lại sau 5s... (lần lặp tiếp theo)"
    sleep 5
done
