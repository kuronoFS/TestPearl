#!/bin/bash
set -u # Kiểm tra biến nghiêm ngặt

# Tránh crash biến môi trường khi chạy pipe/stream.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Cấu hình các biến gốc của bạn ---
MINING_MODE="GPU" # Chuyển đổi linh hoạt: CPU | GPU | DUAL
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"
URL_DOWNLOAD="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💎 Pearl (PRL) Miner - Chế độ: $MINING_MODE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 Ví     : $WALLET"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛠️  Worker : $WORKER"
echo "-------------------------------------------------------"

# --- Hàm cài đặt cô lập thẳng vào thư mục hệ thống /usr/local/bin ---
install_miner_setup() {
    local mode_suffix=$1 # "cpu" hoặc "gpu"
    local target_bin="/usr/local/bin/rgminer-$mode_suffix"
    
    if [ ! -f "$target_bin" ]; then
        echo "📥 Đang tải gói cài đặt rgminer v0.9.4 cho phân vùng [$mode_suffix]..."
        rm -rf /tmp/rgminer_extract
        mkdir -p /tmp/rgminer_extract
        
        if wget -q --show-progress "$URL_DOWNLOAD" -O /tmp/rgminer.tar.gz; then
            echo "📂 Giải nén và nạp vào vùng thực thi hệ thống..."
            tar -xzf /tmp/rgminer.tar.gz -C /tmp/rgminer_extract
            
            # Tìm chính xác file binary gốc
            local real_bin=$(find /tmp/rgminer_extract -type f -name "rgminer" | head -n 1)
            
            if [ -n "$real_bin" ]; then
                mv "$real_bin" "$target_bin"
                chmod +x "$target_bin"
                echo "✅ Đã kích hoạt file thực thi hệ thống: $target_bin"
            else
                echo "❌ Lỗi: Không tìm thấy file thực thi trong gói tải về!"
                exit 1
            fi
            rm -rf /tmp/rgminer_extract /tmp/rgminer.tar.gz
        else
            echo "❌ Lỗi: Không thể tải file từ GitHub!"
            exit 1
        fi
    fi
    chmod +x "$target_bin" 2>/dev/null || true
}

# --- Kích hoạt cài đặt theo Mode vào /usr/local/bin ---
if [ "$MINING_MODE" = "GPU" ]; then
    install_miner_setup "gpu"
elif [ "$MINING_MODE" = "CPU" ]; then
    install_miner_setup "cpu"
elif [ "$MINING_MODE" = "DUAL" ]; then
    echo "⚙️ Thiết lập môi trường chạy song song hệ thống (DUAL)..."
    install_miner_setup "cpu"
    install_miner_setup "gpu"
fi

# --- Vòng lặp duy trì tiến trình đào (Bỏ set -e để tự phục hồi khi sập luồng) ---
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🚀 Kích hoạt trình đào từ phân vùng hệ thống..."
    
    if [ "$MINING_MODE" = "GPU" ]; then
        /usr/local/bin/rgminer-gpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"

    elif [ "$MINING_MODE" = "CPU" ]; then
        /usr/local/bin/rgminer-cpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu"

    elif [ "$MINING_MODE" = "DUAL" ]; then
        /usr/local/bin/rgminer-cpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu" > /dev/null 2>&1 &
        local cpu_pid=$!
        
        /usr/local/bin/rgminer-gpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"
        
        kill $cpu_pid 2>/dev/null || true
    fi
    
    EXIT_CODE=$?
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️ [$CURRENT_TIME] Trình đào thoát (Code=$EXIT_CODE). Khởi động lại sau 5s..."
    sleep 5
    echo "-------------------------------------------------------"
done
