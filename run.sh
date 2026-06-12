#!/bin/bash
# 1. Cập nhật hệ thống và bổ sung đầy đủ thư viện nền tảng cho WildRig
apt-get update && apt-get install -y wget xz-utils libcurl4 libssl-dev dos2unix

# 2. Tải bản WildRig-Multi v0.48.3
wget https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.xz

# 3. Giải nén gói xz
tar -xvf wildrig-multi-linux-0.48.3.tar.xz

# 4. Ép quyền thực thi tối cao cho file binary 
chmod +x wildrig-multi

# 5. Khử sạch lỗi định dạng xuống dòng (nếu script bị chỉnh sửa trên Windows)
dos2unix wildrig-multi 2>/dev/null || true

# 6. Khởi chạy miner đến pool cấu hình
./wildrig-multi --algo pearlhash --url pearl-sg1.luckypool.io:3360 --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 --worker rtx5090
