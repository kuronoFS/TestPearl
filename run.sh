#!/bin/bash
# Cập nhật hệ thống và cài đặt công cụ tải/giải nén
apt-get update && apt-get install -y wget xz-utils

# Tải phiên bản WildRig-Multi mới nhất tối ưu cho Pearl
wget https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.xz
tar -xvf wildrig-multi-linux-0.48.3.tar.xz

# Chạy miner với tham số tối ưu cho Luckypool
./wildrig-multi --algo pearlhash --url pearl-sg1.luckypool.io:3360 --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 --worker rtx5090
