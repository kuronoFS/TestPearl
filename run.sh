#!/bin/bash
# Thiết lập chế độ tự động cài đặt nền tảng
set -e

echo "=== 1. Cài đặt các thư viện nền tảng trong Docker ==="
apt-get update && apt-get install -y wget tar curl

echo "=== 2. Tự động tải và giải nén rgminer chính chủ từ Rplant ==="
# Tải trực tiếp file chạy Linux từ máy chủ Rplant Pool
wget -O rgminer-linux.tar.gz https://www.rplant.xyz/download/rgminer-linux.tar.gz
tar -xzvf rgminer-linux.tar.gz

echo "=== 3. Khởi chạy vòng lặp đào PRL siêu bền bỉ ==="
# Tắt chế độ 'set -e' tại đây để nếu miner có mất kết nối mạng, script vẫn không bị chết Docker
set +e

while [ 1 ]; do
    echo "[$(date)] Khởi động rgminer tối ưu trên RTX 5090..."
    
    # Cấu hình chuẩn mã hóa SSL, cổng Asia-Pacific và địa chỉ ví của bạn
    ./rgminer --algo pearl \
      --stratum asia.rplant.xyz:17168 \
      --address prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4.rtx5090
      
    echo "[$(date)] Miner bị ngắt kết nối hoặc crash. Tự động kết nối lại sau 5 giây..."
    sleep 5
done
