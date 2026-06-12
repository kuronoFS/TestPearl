#!/bin/bash
set -e

echo "=== 1. Cài đặt thư viện nền tảng ==="
apt-get update && apt-get install -y wget tar

echo "=== 2. Tải và giải nén Rigel Miner v1.19.0 ==="
# SỬA LỖI 404: Tên file chính xác trên GitHub không có chữ 'v' ở tên file
wget https://github.com/rigelminer/rigel/releases/download/v1.19.0/rigel-1.19.0-linux.tar.gz

# Giải nén file
tar -xzvf rigel-1.19.0-linux.tar.gz

# Dùng dấu * để tự động nhảy vào thư mục vừa giải nén, bất kể tên thư mục là gì
cd rigel-1.19.0-linux/ || cd rigel-*

echo "=== 3. Khởi chạy Rigel tối ưu riêng cho NVIDIA RTX 5090 ==="

# --- LỰA CHỌN A: Chạy trên RPLANT POOL (Cổng độ khó cao VarDiff) ---
./rigel -a pearlhash \
  -o stratum+tcp://stratum.rplant.xyz:7084 \
  -u prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
  -w rtx5090

# --- LỰA CHỌN B: Chạy trên LUCKYPOOL (Nếu bạn muốn quay lại Lucky Pool, hãy xóa dấu # ở 5 dòng dưới và thêm dấu # vào 5 dòng trên) ---
# ./rigel -a pearlhash \
#   -o stratum+tcp://pearl-sg1.luckypool.io:3360 \
#   -u prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
#   -w rtx5090
