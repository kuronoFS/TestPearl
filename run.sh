#!/bin/bash
set -e

echo "=== 1. Cập nhật và cài đặt thư viện (Đã bổ sung OpenCL) ==="
# Cài đặt thêm ocl-icd-libopencl1 để sửa lỗi thiếu libOpenCL.so.1
apt-get update && apt-get install -y wget tar libcurl4 libssl-dev ocl-icd-libopencl1

echo "=== 2. Tải WildRig-Multi v0.48.3 bản chuẩn ==="
wget -O wildrig-multi-linux-0.48.3.tar.gz https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.gz

echo "=== 3. Giải nén gói cài đặt ==="
tar -xzvf wildrig-multi-linux-0.48.3.tar.gz
rm wildrig-multi-linux-0.48.3.tar.gz
chmod +x wildrig-multi

echo "=== 4. Khởi chạy đào PRL tối ưu cho RTX 5090 ==="
# Chạy trực tiếp file đã giải nén ở thư mục hiện tại
./wildrig-multi --algo pearlhash --url pearl-sg1.luckypool.io:3360 --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4.rtx5090
