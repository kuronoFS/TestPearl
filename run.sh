#!/bin/bash
# ============================================================================
#  Pearl (PRL) Miner Launcher — rgminer (repo: Printscan/rgminer)
# ----------------------------------------------------------------------------
#  - Tự tải, kiểm định (ELF/arch/sha256) và chạy rgminer, log debug từng bước.
#  - Mọi biến cấu hình đều override được bằng biến môi trường khi chạy:
#       WALLET=prl1... WORKER=rig02 DEBUG=0 ./run.sh
#       curl -fsSL <url>/run.sh | MINING_MODE=GPU bash
#  - QUAN TRỌNG: mỗi lần sửa file này, hãy TĂNG SCRIPT_VERSION bên dưới
#    để khi xem log biết chính xác đang chạy bản code cũ hay mới.
# ============================================================================
set -u   # Báo lỗi khi dùng biến chưa khai báo
set -E   # Cho phép ERR trap hoạt động bên trong function

# ----------------------------------------------------------------------------
# [PHIÊN BẢN SCRIPT] — tăng số này mỗi lần chỉnh sửa code
# ----------------------------------------------------------------------------
SCRIPT_VERSION="2.2.0"
SCRIPT_BUILD_DATE="2026-06-12"
# CHANGELOG:
#  2.2.0: KẾ HOẠCH B cho lỗi exec "câm" của launcher: tự tìm backend đã giải
#         nén trong cache và chạy TRỰC TIẾP (LD_LIBRARY_PATH trỏ vào cache để
#         nạp libssl đi kèm) — bỏ qua hẳn launcher; thêm chẩn đoán strace tự
#         động (nếu có) để chỉ ra chính xác syscall exec bị lỗi.
#  2.1.0: rgminer là launcher tự giải nén backend vào cache => xử lý Code=126
#         "câm": quản lý cache (RGMINER_BUNDLE_CACHE), probe quyền exec, tự xoá
#         cache hỏng + thử lại; kiểm tra driver cho RTX 50xx (cần >= 595.58.03);
#         tự chọn RGMINER_BACKEND (cuda12/cuda13) như h-run.sh chính chủ.
#  2.0.0: viết lại toàn bộ: log 7 bước, kiểm định binary, chẩn đoán exit code.

# ----------------------------------------------------------------------------
# [CẤU HÌNH ĐÀO]
# ----------------------------------------------------------------------------
MINING_MODE="${MINING_MODE:-GPU}"   # GPU | CPU | DUAL
WALLET="${WALLET:-prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4}"
WORKER="${WORKER:-rig01}"
POOL="${POOL:-asia.rplant.xyz:17168}"
ALGO="${ALGO:-pearl}"
EXTRA_ARGS="${EXTRA_ARGS:-}"        # Tham số thêm cho rgminer, vd: "--pearl-protocol akoya"

# ----------------------------------------------------------------------------
# [CẤU HÌNH MINER] — rgminer chính chủ tại https://github.com/Printscan/rgminer
# (LƯU Ý: repo cũ rplant8/rgminer KHÔNG tồn tại — đây là nguyên nhân lỗi trước)
# ----------------------------------------------------------------------------
RGMINER_VERSION="${RGMINER_VERSION:-latest}"   # "latest" hoặc tag cụ thể, vd "v0.9.4"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"        # 1 = xoá binary cũ và tải lại từ đầu
EXPECTED_SHA256="${EXPECTED_SHA256:-}"         # Để trống = không so khớp checksum

# rgminer là LAUNCHER: lúc chạy nó tự giải nén backend (rgminer.cuda12/cuda13)
# vào thư mục cache rồi exec. Cache hỏng / bị chặn exec => Code=126 không log.
RGMINER_BACKEND="${RGMINER_BACKEND:-}"         # trống = tự chọn | cuda12 | cuda13 | auto
RGMINER_BUNDLE_CACHE="${RGMINER_BUNDLE_CACHE:-/usr/local/lib/rgminer-cache}"
MIN_CUDA13_DRIVER="595.58.03"                  # driver tối thiểu cho backend CUDA 13 (RTX 50xx)

if [ "$RGMINER_VERSION" = "latest" ]; then
    URL_DEFAULT="https://github.com/Printscan/rgminer/releases/latest/download/rgminer"
else
    URL_DEFAULT="https://github.com/Printscan/rgminer/releases/download/${RGMINER_VERSION}/rgminer"
fi
URL_DOWNLOAD="${URL_DOWNLOAD:-$URL_DEFAULT}"   # Hỗ trợ cả link .tar.gz nếu cần

# ----------------------------------------------------------------------------
# [CẤU HÌNH DEBUG / RESTART]
# ----------------------------------------------------------------------------
DEBUG="${DEBUG:-1}"                            # 1 = hiện log [DEBUG] chi tiết, 0 = gọn
RESTART_DELAY="${RESTART_DELAY:-5}"            # Giây chờ giữa các lần restart
LONG_RESTART_DELAY="${LONG_RESTART_DELAY:-60}" # Giây chờ khi crash liên tục
MAX_RETRIES="${MAX_RETRIES:-0}"                # Tổng số lần chạy tối đa, 0 = vô hạn
MIN_UPTIME="${MIN_UPTIME:-20}"                 # Chạy dưới N giây => tính là "crash nhanh"
FAST_FAIL_LIMIT="${FAST_FAIL_LIMIT:-5}"        # N lần crash nhanh liên tiếp => chẩn đoán sâu

TOTAL_STEPS=7
BIN_PATH="$INSTALL_DIR/rgminer"
CPU_LOG="/tmp/rgminer-cpu.log"
TMP_DIR=""
CPU_PID=""
MINER_PID=""
MINER_EXEC_MODE="launcher"   # launcher = chạy qua rgminer | direct = chạy thẳng backend
BACKEND_DIR=""
BACKEND_BIN=""

# ============================================================================
#  HÀM LOG — mọi dòng đều có timestamp + cấp độ để dễ truy vết
# ============================================================================
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_RED=""; C_YEL=""; C_CYN=""; C_DIM=""; C_RST=""
fi

ts()        { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "[$(ts)] [INFO ] $*"; }
log_warn()  { echo "${C_YEL}[$(ts)] [WARN ] $*${C_RST}" >&2; }
log_error() { echo "${C_RED}[$(ts)] [ERROR] $*${C_RST}" >&2; }
log_debug() { if [ "$DEBUG" = "1" ]; then echo "${C_DIM}[$(ts)] [DEBUG] $*${C_RST}"; fi; }
log_step()  { echo; echo "${C_CYN}[$(ts)] [BƯỚC $1/$TOTAL_STEPS] ===== $2 =====${C_RST}"; }
hr()        { echo "-------------------------------------------------------------"; }

die() {
    log_error "$*"
    log_error "Script DỪNG tại đây (run.sh v$SCRIPT_VERSION). Sửa lỗi trên rồi chạy lại."
    exit 1
}

# Bắt các lệnh thất bại ngoài dự kiến — in ra đúng dòng và lệnh gây lỗi
trap 'log_error "Lệnh thất bại ngoài dự kiến tại DÒNG $LINENO: \"$BASH_COMMAND\""' ERR

cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR" 2>/dev/null || true; fi; }
trap cleanup EXIT

on_signal() {
    echo
    log_warn "Nhận tín hiệu dừng (Ctrl+C / docker stop) — đang tắt miner sạch sẽ..."
    if [ -n "$MINER_PID" ]; then kill "$MINER_PID" 2>/dev/null || true; fi
    if [ -n "$CPU_PID" ];   then kill "$CPU_PID"   2>/dev/null || true; fi
    wait 2>/dev/null || true
    log_warn "Đã dừng toàn bộ tiến trình đào."
    exit 130
}
trap on_signal INT TERM

# Cho phép kiểm tra nhanh phiên bản: ./run.sh --version
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "run.sh v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
    exit 0
fi

# ============================================================================
#  HÀM CHẨN ĐOÁN
# ============================================================================

# Đọc 4 byte đầu của file — ELF chuẩn Linux phải là "7f 45 4c 46"
# (echo không ngoặc kép để gom khoảng trắng thừa của od)
magic_of() { local m; m=$(od -An -N4 -t x1 "$1" 2>/dev/null) || true; echo $m; }
is_elf()   { [ "$(magic_of "$1")" = "7f 45 4c 46" ]; }

# Đọc kiến trúc CPU mà binary được build cho (offset 18 của ELF header)
elf_arch_of() {
    local m
    m=$(od -An -j18 -N2 -t x1 "$1" 2>/dev/null | tr -d ' \n')
    case "$m" in
        3e00) echo "x86_64" ;;
        b700) echo "aarch64" ;;
        0300) echo "i386 (32-bit)" ;;
        *)    echo "không rõ (mã: $m)" ;;
    esac
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# So sánh version dạng a.b.c — version_ge A B nghĩa là A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# ----------------------------------------------------------------------------
# CACHE BACKEND: binary rgminer là launcher tự giải nén rgminer.cuda12/cuda13
# vào cache (RGMINER_BUNDLE_CACHE > XDG_CACHE_HOME > ~/.cache/rgminer-dual >
# /tmp) rồi exec. Nếu cache bị hỏng (giải nén dở dang do bị kill) hoặc thư mục
# bị mount noexec thì launcher thoát Code=126 mà KHÔNG in lỗi nào.
# ----------------------------------------------------------------------------

# Kiểm tra 1 thư mục có cho phép GHI + THỰC THI file không (bắt noexec)
exec_probe() {
    local d=$1 probe="" src=""
    probe="$d/.exec_probe.$$"
    for src in /bin/true /usr/bin/true; do
        if [ -x "$src" ]; then break; fi
    done
    if [ ! -x "$src" ]; then return 0; fi   # không có 'true' để thử => bỏ qua probe
    cp "$src" "$probe" 2>/dev/null || return 1
    chmod +x "$probe" 2>/dev/null || true
    if "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null || true
        return 0
    fi
    rm -f "$probe" 2>/dev/null || true
    return 1
}

# Chọn thư mục cache đầu tiên cho phép ghi + exec, rồi export cho launcher
prepare_bundle_cache() {
    local d
    for d in "$RGMINER_BUNDLE_CACHE" "${HOME:-/root}/.cache/rgminer-dual" "/var/tmp/rgminer-cache" "/tmp/rgminer-cache"; do
        if [ -z "$d" ]; then continue; fi
        if mkdir -p "$d" 2>/dev/null && [ -w "$d" ] && exec_probe "$d"; then
            RGMINER_BUNDLE_CACHE="$d"
            export RGMINER_BUNDLE_CACHE
            log_info "Cache backend : $RGMINER_BUNDLE_CACHE (đã kiểm tra: ghi + thực thi OK)"
            return 0
        fi
        log_warn "Thư mục cache '$d' không ghi/exec được (noexec?) — thử vị trí khác..."
    done
    die "Không tìm được thư mục nào cho phép GHI + THỰC THI để launcher giải nén backend rgminer!"
}

# Xoá sạch payload đã giải nén (kể cả cache mặc định cũ) để launcher làm lại từ đầu
clean_bundle_cache() {
    if [ -n "$RGMINER_BUNDLE_CACHE" ] && [ -d "$RGMINER_BUNDLE_CACHE" ]; then
        log_info "🧹 Dọn cache backend: $RGMINER_BUNDLE_CACHE (launcher sẽ tự giải nén lại sạch sẽ)"
        rm -rf "${RGMINER_BUNDLE_CACHE:?}"/* "${RGMINER_BUNDLE_CACHE:?}"/.[!.]* 2>/dev/null || true
    fi
    rm -rf "${HOME:-/root}/.cache/rgminer-dual" 2>/dev/null || true
    rm -rf /tmp/rgminer-dual* 2>/dev/null || true
}

# Tìm backend đã được launcher giải nén sẵn trong cache (cho chế độ DIRECT).
# Ưu tiên cuda13 trừ khi RGMINER_BACKEND=cuda12. Tìm cả cache cũ ~/.cache.
locate_backend() {
    BACKEND_DIR=""
    BACKEND_BIN=""
    local names=("rgminer.cuda13" "rgminer.cuda12")
    if [ "${RGMINER_BACKEND:-}" = "cuda12" ]; then names=("rgminer.cuda12" "rgminer.cuda13"); fi
    local base n f
    for base in "$RGMINER_BUNDLE_CACHE" "${HOME:-/root}/.cache/rgminer-dual"; do
        if [ ! -d "$base" ]; then continue; fi
        for n in "${names[@]}"; do
            f=$(find "$base" -maxdepth 2 -type f -name "$n" 2>/dev/null | head -n1)
            if [ -n "$f" ] && is_elf "$f"; then
                chmod +x "$f" 2>/dev/null || true
                BACKEND_BIN="$f"
                BACKEND_DIR=$(dirname "$f")
                log_debug "Tìm thấy backend trong cache: $BACKEND_BIN ($(stat -c %s "$f" 2>/dev/null) bytes)"
                return 0
            fi
        done
    done
    return 1
}

# In hiện trạng cache backend — gọi khi gặp Code=126 để biết hỏng chỗ nào
dump_cache_info() {
    hr
    log_warn "CHẨN ĐOÁN CACHE BACKEND (RGMINER_BUNDLE_CACHE=$RGMINER_BUNDLE_CACHE):"
    if [ -d "$RGMINER_BUNDLE_CACHE" ]; then
        while IFS= read -r f; do
            log_warn "   | $(ls -ld "$f" 2>/dev/null)"
        done < <(find "$RGMINER_BUNDLE_CACHE" -maxdepth 2 2>/dev/null | head -15)
        while IFS= read -r f; do
            if is_elf "$f"; then
                log_warn "   -> $(basename "$f"): $(stat -c %s "$f" 2>/dev/null) bytes — ELF hợp lệ"
            else
                log_warn "   -> $(basename "$f"): $(stat -c %s "$f" 2>/dev/null) bytes — HỎNG (không phải ELF — giải nén dở dang?)"
            fi
        done < <(find "$RGMINER_BUNDLE_CACHE" -maxdepth 2 -name 'rgminer.cuda*' -type f 2>/dev/null)
    else
        log_warn "   (thư mục cache chưa tồn tại — launcher sẽ tự tạo khi chạy)"
    fi
    hr
}

# In toàn bộ thông tin về 1 file để biết chính xác nó là gì / hỏng chỗ nào
dump_file_info() {
    local p=$1
    hr
    log_warn "CHẨN ĐOÁN SÂU FILE: $p"
    if [ ! -e "$p" ]; then
        log_warn "  -> File KHÔNG TỒN TẠI."
        hr
        return 0
    fi
    log_warn "  -> ls -ld : $(ls -ld "$p" 2>&1)"
    if [ -d "$p" ]; then
        log_warn "  -> Đây là THƯ MỤC, không phải file! (chạy thư mục => lỗi Code=126)"
        log_warn "  -> Nội dung: $(ls -A "$p" 2>/dev/null | head -5 | tr '\n' ' ')"
        hr
        return 0
    fi
    log_warn "  -> Kích thước : $(stat -c %s "$p" 2>/dev/null || echo '?') bytes"
    log_warn "  -> Magic bytes: '$(magic_of "$p")' (ELF Linux chuẩn = '7f 45 4c 46')"
    log_warn "  -> SHA256     : $(sha256_of "$p")"
    if command -v file >/dev/null 2>&1; then
        log_warn "  -> file(1)    : $(file -b "$p" 2>&1)"
    fi
    if is_elf "$p"; then
        log_warn "  -> Build cho  : $(elf_arch_of "$p") | Máy này: $(uname -m)"
        if command -v ldd >/dev/null 2>&1; then
            local missing
            missing=$(ldd "$p" 2>&1 | grep "not found" || true)
            if [ -n "$missing" ]; then
                log_warn "  -> THIẾU THƯ VIỆN (nguyên nhân không chạy được):"
                echo "$missing" | while IFS= read -r line; do log_warn "       $line"; done
            else
                log_warn "  -> Thư viện   : đầy đủ (ldd OK)"
            fi
        fi
    else
        log_warn "  -> KHÔNG PHẢI binary ELF Linux => không thể thực thi (Code=126)."
        log_warn "  -> Nội dung đầu file: $(head -c 200 "$p" 2>/dev/null | tr -cd '[:print:]' | head -c 150)"
    fi
    if [ ! -x "$p" ]; then
        log_warn "  -> File CHƯA có quyền thực thi (cần chmod +x)."
    fi
    # Kiểm tra phân vùng có bị mount noexec không
    local mp
    mp=$(df -P "$p" 2>/dev/null | awk 'NR==2{print $6}') || true
    if [ -n "${mp:-}" ] && grep -E "[[:space:]]${mp}[[:space:]]" /proc/mounts 2>/dev/null | grep -q noexec; then
        log_warn "  -> Phân vùng '$mp' bị mount NOEXEC => không cho chạy file (Code=126)!"
    fi
    hr
}

# Giải thích ý nghĩa exit code của miner + gợi ý cách sửa
explain_exit_code() {
    local code=$1
    case "$code" in
        0)   log_warn "Code=0: miner tự thoát bình thường (bất thường với miner — có thể bị pool ngắt kết nối)." ;;
        1)   log_error "Code=1: lỗi chung — thường do sai tham số, sai wallet/pool, hoặc pool từ chối. Đọc log miner ngay phía trên." ;;
        2)   log_error "Code=2: sai cú pháp tham số dòng lệnh." ;;
        42)  log_error "Code=42: watchdog của rgminer phát hiện GPU CUDA failure (GPU treo/rớt khỏi bus) — kiểm tra driver, nhiệt độ, nguồn điện." ;;
        126) log_error "Code=126: file TỒN TẠI nhưng KHÔNG THỂ THỰC THI."
             log_error "  Với rgminer: đây thường là LAUNCHER không exec được backend (rgminer.cuda12/13)"
             log_error "  đã giải nén vào cache — do cache hỏng (bị kill giữa chừng) hoặc thư mục noexec."
             log_error "  Script sẽ tự dọn cache và thử lại; nếu vẫn lỗi: thử FORCE_REINSTALL=1,"
             log_error "  hoặc đổi chỗ cache: RGMINER_BUNDLE_CACHE=/duong/dan/khac" ;;
        127) log_error "Code=127: không tìm thấy file, hoặc thiếu dynamic loader/thư viện hệ thống (glibc quá cũ?)." ;;
        130) log_warn  "Code=130: bị dừng bởi Ctrl+C (SIGINT)." ;;
        132) log_error "Code=132 (SIGILL): CPU không hỗ trợ tập lệnh binary cần — sai kiến trúc hoặc CPU quá cũ." ;;
        134) log_error "Code=134 (SIGABRT): miner tự abort — thường do lỗi CUDA runtime/driver không tương thích." ;;
        137) log_error "Code=137 (SIGKILL): bị hệ thống kill — thường do HẾT RAM (OOM killer) hoặc docker stop."
             log_error "  => Kiểm tra giới hạn RAM của container (docker run -m) và RAM còn trống." ;;
        139) log_error "Code=139 (SIGSEGV): miner crash — thường do driver NVIDIA/CUDA không tương thích với GPU." ;;
        143) log_warn  "Code=143: bị dừng bởi SIGTERM (docker stop?)." ;;
        *)   log_error "Code=$code: xem log miner phía trên để biết chi tiết." ;;
    esac
}

# ============================================================================
#  BƯỚC 1: THÔNG TIN MÔI TRƯỜNG & PHIÊN BẢN
# ============================================================================
echo "============================================================="
echo "  💎 Pearl (PRL) Miner Launcher"
echo "  📌 PHIÊN BẢN SCRIPT : v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
echo "============================================================="

log_step 1 "Thông tin môi trường"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_SOURCE="file: ${BASH_SOURCE[0]}"
    log_debug "SHA256 của script: $(sha256_of "${BASH_SOURCE[0]}" | head -c 16)..."
else
    SCRIPT_SOURCE="stdin/pipe (vd: curl ... | bash)"
fi
log_info "Nguồn script  : $SCRIPT_SOURCE"
log_info "Thời gian     : $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
OS_NAME=$(grep -s PRETTY_NAME /etc/os-release | cut -d'"' -f2) || true
log_info "OS            : ${OS_NAME:-$(uname -s)}"
log_info "Kernel / Arch : $(uname -r) / $(uname -m)"
log_info "User          : $(id -un 2>/dev/null || echo '?') (uid=$(id -u 2>/dev/null || echo '?'))"
if [ -f /.dockerenv ] || grep -qs docker /proc/1/cgroup 2>/dev/null; then
    log_info "Container     : Docker (đã phát hiện)"
else
    log_info "Container     : không phát hiện (chạy trực tiếp trên máy)"
fi
log_debug "Bash version  : $BASH_VERSION"
log_debug "CPU cores     : $(nproc 2>/dev/null || echo '?')"
if command -v free >/dev/null 2>&1; then
    log_debug "RAM           : $(free -h | awk 'NR==2{printf "tổng %s / trống %s", $2, $7}')"
fi
log_debug "Dung lượng đĩa: /tmp = $(df -h /tmp 2>/dev/null | awk 'NR==2{print $4}') trống, $INSTALL_DIR = $(df -h "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}') trống"

# ============================================================================
#  BƯỚC 2: KIỂM TRA CẤU HÌNH
# ============================================================================
log_step 2 "Kiểm tra cấu hình"

MINING_MODE=$(printf '%s' "$MINING_MODE" | tr '[:lower:]' '[:upper:]')
case "$MINING_MODE" in
    GPU|CPU|DUAL) : ;;
    *) die "MINING_MODE='$MINING_MODE' không hợp lệ. Chỉ chấp nhận: GPU | CPU | DUAL" ;;
esac

# Đảm bảo các biến cấu hình dạng số là số hợp lệ (tránh lỗi so sánh số học)
ensure_number() {
    local name=$1 def=$2 val
    eval "val=\${$name}"
    case "$val" in
        ''|*[!0-9]*)
            log_warn "$name='$val' không phải số hợp lệ — dùng giá trị mặc định: $def"
            eval "$name=$def"
            ;;
    esac
}
ensure_number RESTART_DELAY 5
ensure_number LONG_RESTART_DELAY 60
ensure_number MAX_RETRIES 0
ensure_number MIN_UPTIME 20
ensure_number FAST_FAIL_LIMIT 5

log_info "MINING_MODE   : $MINING_MODE"
log_info "WALLET        : $WALLET"
log_info "WORKER        : $WORKER"
log_info "POOL          : $POOL"
log_info "ALGO          : $ALGO"
log_info "EXTRA_ARGS    : ${EXTRA_ARGS:-(không có)}"
log_info "RGMINER_VER   : $RGMINER_VERSION"
log_debug "URL_DOWNLOAD  : $URL_DOWNLOAD"
log_debug "BIN_PATH      : $BIN_PATH"
log_debug "BACKEND       : ${RGMINER_BACKEND:-(auto)} | CACHE: $RGMINER_BUNDLE_CACHE"
log_debug "DEBUG=$DEBUG FORCE_REINSTALL=$FORCE_REINSTALL RESTART_DELAY=${RESTART_DELAY}s MAX_RETRIES=$MAX_RETRIES MIN_UPTIME=${MIN_UPTIME}s"

if [ -z "$WALLET" ]; then
    die "WALLET đang để trống!"
fi
case "$WALLET" in
    prl*) log_debug "Định dạng ví: tiền tố 'prl' hợp lệ (độ dài ${#WALLET} ký tự)" ;;
    *)    log_warn "Ví '$WALLET' không bắt đầu bằng 'prl' — kiểm tra lại địa chỉ ví Pearl!" ;;
esac

POOL_STRIPPED=${POOL#*://}
POOL_HOST=${POOL_STRIPPED%%:*}
POOL_PORT=${POOL_STRIPPED##*:}
if [ "$POOL_HOST" = "$POOL_PORT" ]; then
    log_warn "POOL '$POOL' thiếu cổng (định dạng đúng: host:port, vd asia.rplant.xyz:17168)"
    POOL_PORT=""
fi

if [ "$MINING_MODE" != "GPU" ]; then
    log_warn "Lưu ý: rgminer là miner GPU (CUDA). Chế độ CPU/DUAL chỉ mang tính thử nghiệm."
fi

# ============================================================================
#  BƯỚC 3: KIỂM TRA CÔNG CỤ HỆ THỐNG (DEPENDENCIES)
# ============================================================================
log_step 3 "Kiểm tra công cụ hệ thống"

MISSING=""
for tool in od sha256sum awk grep tar gzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        log_debug "OK: $tool ($(command -v "$tool"))"
    else
        MISSING="$MISSING $tool"
    fi
done

DOWNLOADER=""
if command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
    log_debug "OK: wget ($(wget --version 2>/dev/null | head -1))"
elif command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    log_debug "OK: curl ($(curl --version 2>/dev/null | head -1))"
else
    MISSING="$MISSING wget/curl"
fi

if [ -n "$MISSING" ]; then
    log_error "Thiếu công cụ:$MISSING"
    die "Cài đặt bằng: apt-get update && apt-get install -y wget tar gzip coreutils ca-certificates"
fi

if [ ! -d /etc/ssl/certs ] || [ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]; then
    log_warn "Không thấy chứng chỉ SSL (/etc/ssl/certs trống) — tải HTTPS có thể lỗi. Cài: apt-get install -y ca-certificates"
fi
for opt_tool in file timeout getent ldd; do
    command -v "$opt_tool" >/dev/null 2>&1 || log_debug "Thiếu tool phụ '$opt_tool' (không bắt buộc, chỉ giảm khả năng chẩn đoán)"
done
log_info "✅ Đủ công cụ cần thiết (trình tải: $DOWNLOADER)"

# ============================================================================
#  BƯỚC 4: KIỂM TRA GPU / DRIVER NVIDIA
# ============================================================================
log_step 4 "Kiểm tra GPU / Driver NVIDIA"

GPU_COUNT=0
if [ "$MINING_MODE" = "CPU" ]; then
    log_info "Chế độ CPU — bỏ qua kiểm tra GPU."
elif ! command -v nvidia-smi >/dev/null 2>&1; then
    log_warn "KHÔNG tìm thấy nvidia-smi! Miner GPU gần như chắc chắn sẽ không chạy được."
    log_warn "  Nếu đang dùng Docker, container PHẢI chạy với: docker run --gpus all ..."
    log_warn "  và máy chủ phải cài nvidia-container-toolkit + driver NVIDIA."
else
    GPU_INFO=$(timeout 15 nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1) || true
    if [ -n "$GPU_INFO" ] && ! echo "$GPU_INFO" | grep -qi "failed\|error"; then
        GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
        log_info "✅ Phát hiện $GPU_COUNT GPU:"
        echo "$GPU_INFO" | while IFS= read -r line; do log_info "   -> $line"; done

        # --- Phân loại backend CUDA theo compute capability + driver ---
        # (logic giống h-run.sh chính chủ: cap >= 12.x tức RTX 50xx/Blackwell
        #  bắt buộc backend CUDA 13, mà CUDA 13 đòi driver >= MIN_CUDA13_DRIVER)
        DRIVER_VER=$(echo "$GPU_INFO" | head -n1 | awk -F',' '{print $2}' | tr -d ' ')
        GPU_CAPS=$(timeout 15 nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null) || true
        MAX_CAP_MAJOR=0
        if [ -n "${GPU_CAPS:-}" ]; then
            while IFS= read -r cap_line; do
                cap=$(echo "$cap_line" | awk -F',' '{print $NF}' | tr -d ' ')
                cap_major=${cap%%.*}
                case "$cap_major" in ''|*[!0-9]*) continue ;; esac
                log_debug "Compute capability: $cap_line (sm_${cap/./})"
                if [ "$cap_major" -gt "$MAX_CAP_MAJOR" ]; then MAX_CAP_MAJOR=$cap_major; fi
            done <<< "$GPU_CAPS"
        fi

        SUGGESTED_BACKEND=""
        if [ "$MAX_CAP_MAJOR" -ge 12 ]; then
            log_info "GPU thế hệ Blackwell/RTX 50xx (compute cap ${MAX_CAP_MAJOR}.x) — BẮT BUỘC backend CUDA 13."
            SUGGESTED_BACKEND="cuda13"
            if [ -n "$DRIVER_VER" ] && version_ge "$DRIVER_VER" "$MIN_CUDA13_DRIVER"; then
                log_info "✅ Driver $DRIVER_VER >= $MIN_CUDA13_DRIVER — đủ điều kiện chạy backend CUDA 13."
            else
                log_error "Driver hiện tại: ${DRIVER_VER:-?} — backend CUDA 13 của rgminer yêu cầu >= $MIN_CUDA13_DRIVER."
                log_error "  Backend CUDA 12 thì KHÔNG hỗ trợ RTX 50xx (chỉ tới sm_90 = RTX 40xx),"
                log_error "  nên rgminer gần như chắc chắn KHÔNG đào được cho tới khi nâng driver."
                log_error "  => Cách sửa: nâng driver NVIDIA >= 595.58.03 TRÊN MÁY HOST (driver là của host,"
                log_error "     không cài được từ trong container). Nếu thuê máy (vast.ai/runpod...),"
                log_error "     hãy chọn host có driver mới hơn hoặc yêu cầu nhà cung cấp nâng cấp."
            fi
        elif [ "$MAX_CAP_MAJOR" -gt 0 ]; then
            log_debug "Compute cap tối đa: ${MAX_CAP_MAJOR}.x — backend CUDA 12/13 đều dùng được, để launcher tự chọn."
        fi

        if [ -z "$RGMINER_BACKEND" ] && [ -n "$SUGGESTED_BACKEND" ]; then
            RGMINER_BACKEND="$SUGGESTED_BACKEND"
            log_info "Tự chọn RGMINER_BACKEND=$RGMINER_BACKEND theo GPU/driver (giống h-run.sh chính chủ)."
        fi
    else
        log_warn "nvidia-smi có nhưng chạy lỗi: $GPU_INFO"
        log_warn "  => Driver chưa được nạp vào container? Kiểm tra lại '--gpus all'."
    fi
fi

if [ -n "$RGMINER_BACKEND" ]; then
    export RGMINER_BACKEND
    log_info "Backend rgminer: RGMINER_BACKEND=$RGMINER_BACKEND (đã export cho miner)"
else
    log_debug "RGMINER_BACKEND để trống — launcher của rgminer sẽ tự chọn (auto)."
fi

# ============================================================================
#  BƯỚC 5: CÀI ĐẶT & KIỂM ĐỊNH BINARY RGMINER
# ============================================================================
log_step 5 "Cài đặt & kiểm định binary rgminer"

# Kiểm định toàn diện 1 binary; trả về 0 nếu dùng được
validate_binary() {
    local p=$1 ok=1
    if [ ! -e "$p" ]; then log_debug "Kiểm định: $p chưa tồn tại"; return 1; fi
    if [ ! -f "$p" ]; then log_error "Kiểm định FAIL: $p không phải file thường (là thư mục/symlink hỏng?)"; return 1; fi
    local size
    size=$(stat -c %s "$p" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000000 ]; then
        log_error "Kiểm định FAIL: file quá nhỏ ($size bytes) — có thể là trang lỗi HTML thay vì binary."
        ok=0
    fi
    if ! is_elf "$p"; then
        log_error "Kiểm định FAIL: magic bytes = '$(magic_of "$p")' — không phải ELF Linux (chuẩn: '7f 45 4c 46')."
        ok=0
    else
        local barch sarch
        barch=$(elf_arch_of "$p"); sarch=$(uname -m)
        if [ "$barch" != "$sarch" ]; then
            log_error "Kiểm định FAIL: binary build cho '$barch' nhưng máy là '$sarch' (=> Exec format error)."
            ok=0
        fi
    fi
    [ "$ok" = "1" ] || return 1
    chmod +x "$p" 2>/dev/null || true
    if [ ! -x "$p" ]; then log_error "Kiểm định FAIL: không gán được quyền thực thi (+x) cho $p"; return 1; fi
    log_debug "Kiểm định OK: ELF $(elf_arch_of "$p"), $size bytes, sha256=$(sha256_of "$p" | head -c 16)..."
    return 0
}

download_file() {
    local url=$1 out=$2 errlog="$TMP_DIR/download.err" rc=0
    log_info "📥 Đang tải: $url"
    if [ "$DOWNLOADER" = "wget" ]; then
        wget --tries=3 --connect-timeout=15 --read-timeout=120 -nv -O "$out" "$url" >"$errlog" 2>&1 || rc=$?
    else
        curl -fSL --retry 3 --connect-timeout 15 -o "$out" "$url" >"$errlog" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        log_error "Tải thất bại (mã lỗi $DOWNLOADER: $rc). Chi tiết:"
        while IFS= read -r line; do log_error "   | $line"; done < <(tail -5 "$errlog")
        if grep -qi "404" "$errlog"; then
            log_error "   => Lỗi 404: URL sai hoặc release đã đổi tên file. Kiểm tra: https://github.com/Printscan/rgminer/releases"
        elif grep -qi "certificate\|ssl" "$errlog"; then
            log_error "   => Lỗi SSL: cài ca-certificates (apt-get install -y ca-certificates)"
        elif grep -qi "resolve\|unknown host" "$errlog"; then
            log_error "   => Lỗi DNS: container không phân giải được github.com — kiểm tra mạng/DNS của Docker."
        fi
        return 1
    fi
    log_debug "Đã tải xong: $(stat -c %s "$out" 2>/dev/null) bytes, sha256=$(sha256_of "$out")"
    return 0
}

install_miner() {
    TMP_DIR=$(mktemp -d /tmp/rgminer.XXXXXX) || die "Không tạo được thư mục tạm trong /tmp (đĩa đầy?)"
    local pkg="$TMP_DIR/pkg"

    download_file "$URL_DOWNLOAD" "$pkg" || die "Không tải được rgminer. Xem chi tiết lỗi phía trên."

    if [ -n "$EXPECTED_SHA256" ]; then
        local actual
        actual=$(sha256_of "$pkg")
        if [ "$actual" != "$EXPECTED_SHA256" ]; then
            log_error "SHA256 thực tế : $actual"
            log_error "SHA256 mong đợi: $EXPECTED_SHA256"
            die "Checksum KHÔNG khớp — file tải về không đúng như mong đợi!"
        fi
        log_info "✅ Checksum SHA256 khớp."
    fi

    local src_bin=""
    case "$URL_DOWNLOAD" in
        *.tar.gz|*.tgz)
            log_info "📂 Gói nén .tar.gz — đang giải nén..."
            mkdir -p "$TMP_DIR/extract"
            tar -xzf "$pkg" -C "$TMP_DIR/extract" 2>"$TMP_DIR/tar.err" || {
                log_error "Giải nén thất bại: $(cat "$TMP_DIR/tar.err")"
                dump_file_info "$pkg"
                die "File tải về không phải gói tar.gz hợp lệ."
            }
            log_debug "Nội dung gói: $(tar -tzf "$pkg" 2>/dev/null | head -10 | tr '\n' ' ')"
            # Chọn file ELF lớn nhất tên rgminer* trong gói (tránh nhầm script phụ)
            local cand
            while IFS= read -r cand; do
                if is_elf "$cand"; then src_bin="$cand"; break; fi
            done < <(find "$TMP_DIR/extract" -type f -name "rgminer*" -exec du -b {} + 2>/dev/null | sort -rn | awk '{print $2}')
            if [ -z "$src_bin" ]; then
                log_error "Không tìm thấy binary ELF nào tên 'rgminer*' trong gói. Danh sách file:"
                find "$TMP_DIR/extract" -type f | head -20 | while IFS= read -r f; do log_error "   | $f"; done
                die "Cấu trúc gói tải về không như mong đợi."
            fi
            log_debug "Đã chọn binary trong gói: $src_bin"
            ;;
        *)
            src_bin="$pkg"   # URL trỏ thẳng vào binary
            ;;
    esac

    if ! validate_binary "$src_bin"; then
        dump_file_info "$src_bin"
        die "File tải về KHÔNG phải binary hợp lệ — xem chẩn đoán phía trên."
    fi

    mv -f "$src_bin" "$BIN_PATH" || die "Không ghi được vào $BIN_PATH (thiếu quyền?)"
    chmod +x "$BIN_PATH"
    rm -rf "$TMP_DIR"; TMP_DIR=""
    log_info "✅ Đã cài rgminer vào: $BIN_PATH"
}

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -w "$INSTALL_DIR" ]; then
    die "Không có quyền ghi vào '$INSTALL_DIR'. Chạy bằng root, hoặc đặt INSTALL_DIR=\$HOME/bin"
fi

if [ "$FORCE_REINSTALL" = "1" ] && [ -e "$BIN_PATH" ]; then
    log_warn "FORCE_REINSTALL=1 — xoá binary cũ tại $BIN_PATH để tải lại."
    rm -rf "$BIN_PATH"
fi

# Dọn binary hỏng do script phiên bản cũ (v1.x) để lại
for old_bin in "$INSTALL_DIR/rgminer-gpu" "$INSTALL_DIR/rgminer-cpu"; do
    if [ -e "$old_bin" ] && ! validate_binary "$old_bin" >/dev/null 2>&1; then
        log_warn "Phát hiện file hỏng do script cũ (v1.x) để lại: $old_bin — đang xoá."
        rm -rf "$old_bin"
    fi
done

if [ -e "$BIN_PATH" ]; then
    log_info "Binary đã tồn tại: $BIN_PATH — kiểm định lại trước khi dùng..."
    if validate_binary "$BIN_PATH"; then
        log_info "✅ Binary cũ hợp lệ, dùng lại (muốn tải mới: chạy với FORCE_REINSTALL=1)"
    else
        log_warn "Binary cũ KHÔNG hợp lệ — đây thường là nguyên nhân lỗi Code=126 lặp vô hạn!"
        dump_file_info "$BIN_PATH"
        rm -rf "$BIN_PATH"
        install_miner
    fi
else
    install_miner
fi

# Chuẩn bị cache cho launcher (rgminer tự giải nén backend vào đây khi chạy)
prepare_bundle_cache
clean_bundle_cache   # dọn payload hỏng từ các lần chạy trước — nguyên nhân Code=126 "câm" phổ biến

# Chạy thử nhẹ (smoke test) để chắc chắn binary + backend thực thi được trên máy này
SMOKE_RUNNER=()
if command -v timeout >/dev/null 2>&1; then SMOKE_RUNNER=(timeout 30); fi

run_smoke() {
    SMOKE_RC=0
    SMOKE_OUT=$("${SMOKE_RUNNER[@]}" "$BIN_PATH" --list-algos 2>&1) || SMOKE_RC=$?
}

# Chạy thử backend TRỰC TIẾP — kế hoạch B khi launcher không exec được backend.
# LD_LIBRARY_PATH trỏ vào thư mục cache để backend nạp libssl.so.1.1 đi kèm.
run_smoke_direct() {
    SMOKE_RC=0
    SMOKE_OUT=$(cd "$BACKEND_DIR" && \
        LD_LIBRARY_PATH="$BACKEND_DIR${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        RGMINER_LAUNCHER_DIR="$BACKEND_DIR" \
        "${SMOKE_RUNNER[@]}" "$BACKEND_BIN" --list-algos 2>&1) || SMOKE_RC=$?
}

log_info "🔬 Chạy thử binary ($BIN_PATH --list-algos)..."
run_smoke

# Launcher trả 126/127 = không exec được backend. Trên một số máy/container,
# launcher GIẢI NÉN thành công nhưng cú exec cuối bị chặn (seccomp/AppArmor).
# => KẾ HOẠCH B: chạy thẳng backend đã giải nén trong cache, bỏ qua launcher.
if [ "$SMOKE_RC" -eq 126 ] || [ "$SMOKE_RC" -eq 127 ]; then
    log_warn "Launcher thất bại Code=$SMOKE_RC — kiểm tra backend đã giải nén trong cache:"
    dump_cache_info
    if locate_backend; then
        log_warn "KẾ HOẠCH B: thử chạy TRỰC TIẾP backend (bỏ qua launcher): $BACKEND_BIN"
        run_smoke_direct
        if [ "$SMOKE_RC" -eq 0 ]; then
            MINER_EXEC_MODE="direct"
            log_info "✅ Backend chạy trực tiếp OK — chuyển sang chế độ DIRECT (không dùng launcher nữa)."
        else
            log_warn "Backend trực tiếp cũng thất bại (Code=$SMOKE_RC). Output: $(echo "$SMOKE_OUT" | head -2 | tr '\n' ' ')"
        fi
    else
        log_warn "Cache chưa có backend hợp lệ để chạy trực tiếp."
    fi
    if [ "$MINER_EXEC_MODE" = "launcher" ]; then
        clean_bundle_cache
        log_info "Dọn cache xong — thử lại launcher (lần 2, launcher sẽ giải nén lại từ đầu)..."
        run_smoke
        if { [ "$SMOKE_RC" -eq 126 ] || [ "$SMOKE_RC" -eq 127 ]; } && locate_backend; then
            log_warn "Launcher vẫn lỗi nhưng đã giải nén backend mới — thử DIRECT với backend mới..."
            run_smoke_direct
            if [ "$SMOKE_RC" -eq 0 ]; then
                MINER_EXEC_MODE="direct"
                log_info "✅ Backend (mới giải nén) chạy trực tiếp OK — chuyển sang chế độ DIRECT."
            fi
        fi
    fi
fi

if [ "$SMOKE_RC" -eq 0 ]; then
    if [ "$MINER_EXEC_MODE" = "direct" ]; then
        log_info "✅ Sẵn sàng đào ở chế độ DIRECT: $BACKEND_BIN"
    else
        log_info "✅ Binary + backend chạy được qua launcher."
    fi
    echo "$SMOKE_OUT" | head -8 | while IFS= read -r line; do log_debug "   | $line"; done
elif [ "$SMOKE_RC" -eq 124 ]; then
    log_warn "Chạy thử bị timeout sau 30s (bất thường nhưng không chặn) — tiếp tục."
elif echo "$SMOKE_OUT" | grep -qi "GLIBC"; then
    log_error "Output: $(echo "$SMOKE_OUT" | head -3)"
    die "Thiếu GLIBC — image/OS quá cũ so với binary. Dùng Ubuntu 22.04/24.04 (vd image nvidia/cuda:12.x-base-ubuntu22.04)."
elif [ "$SMOKE_RC" -eq 126 ] || [ "$SMOKE_RC" -eq 127 ] || [ "$SMOKE_RC" -eq 132 ] || [ "$SMOKE_RC" -eq 139 ]; then
    if [ -n "$SMOKE_OUT" ]; then
        log_error "Chạy thử thất bại (Code=$SMOKE_RC). Output: $(echo "$SMOKE_OUT" | head -3)"
    else
        log_error "Chạy thử thất bại (Code=$SMOKE_RC) — KHÔNG có output (launcher thoát câm: lỗi exec backend)."
    fi
    explain_exit_code "$SMOKE_RC"
    dump_file_info "$BIN_PATH"
    dump_cache_info
    # strace (nếu có) sẽ chỉ ra CHÍNH XÁC syscall exec nào lỗi và errno gì
    if command -v strace >/dev/null 2>&1; then
        STRACE_LOG="/tmp/rgminer-strace.log"
        log_warn "Chạy strace để tìm syscall exec bị lỗi (log đầy đủ: $STRACE_LOG)..."
        "${SMOKE_RUNNER[@]}" strace -f -qq -s 160 -e trace=execve,execveat -o "$STRACE_LOG" "$BIN_PATH" --list-algos >/dev/null 2>&1 || true
        if [ -s "$STRACE_LOG" ]; then
            log_error "Các dòng exec cuối cùng (errno ở cuối dòng = lý do chính xác):"
            grep -E "execve|execveat" "$STRACE_LOG" 2>/dev/null | tail -6 | while IFS= read -r line; do log_error "   | $line"; done
        else
            log_warn "strace không thu được dữ liệu (container có thể chặn ptrace)."
        fi
    else
        log_warn "Mẹo: cài strace (apt-get update && apt-get install -y strace) rồi chạy lại —"
        log_warn "  script sẽ tự dùng strace để chỉ ra chính xác syscall exec bị chặn và errno."
    fi
    # Thử ép từng backend qua launcher để khoanh vùng lỗi
    for try_backend in cuda13 cuda12; do
        TRY_RC=0
        TRY_OUT=$(RGMINER_BACKEND="$try_backend" "${SMOKE_RUNNER[@]}" "$BIN_PATH" --list-algos 2>&1) || TRY_RC=$?
        log_error "  Thử ép RGMINER_BACKEND=$try_backend => Code=$TRY_RC $(echo "$TRY_OUT" | head -1)"
    done
    die "Cả launcher lẫn backend trực tiếp đều không chạy được. Gợi ý: xem errno trong strace ở trên; thử RGMINER_BUNDLE_CACHE=/duong/dan/khac; chạy container không kèm seccomp/AppArmor tuỳ chỉnh (--security-opt seccomp=unconfined) hoặc đổi host."
else
    log_warn "Chạy thử trả về Code=$SMOKE_RC (không chặn). Output đầu:"
    echo "$SMOKE_OUT" | head -5 | while IFS= read -r line; do log_warn "   | $line"; done
fi

# ============================================================================
#  BƯỚC 6: KIỂM TRA KẾT NỐI POOL
# ============================================================================
log_step 6 "Kiểm tra kết nối pool ($POOL_HOST:${POOL_PORT:-?})"

if command -v getent >/dev/null 2>&1; then
    POOL_IPS=$(getent hosts "$POOL_HOST" 2>/dev/null | awk '{print $1}' | tr '\n' ' ') || true
    if [ -n "${POOL_IPS:-}" ]; then
        log_info "✅ DNS OK: $POOL_HOST -> $POOL_IPS"
    else
        log_warn "Không phân giải được DNS '$POOL_HOST' — kiểm tra mạng/DNS container (miner sẽ tự thử lại)."
    fi
fi
if [ -n "$POOL_PORT" ] && command -v timeout >/dev/null 2>&1; then
    if timeout 7 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$POOL_HOST" "$POOL_PORT" 2>/dev/null; then
        log_info "✅ Kết nối TCP tới $POOL_HOST:$POOL_PORT thành công."
    else
        log_warn "KHÔNG kết nối TCP được tới $POOL_HOST:$POOL_PORT (firewall? pool sập? sai port?)"
        log_warn "  Miner vẫn sẽ được khởi chạy và tự thử lại — nhưng nếu miner thoát ngay, đây là nguyên nhân chính."
    fi
fi

# ============================================================================
#  BƯỚC 7: VÒNG LẶP ĐÀO
# ============================================================================
log_step 7 "Bắt đầu vòng lặp đào (mode: $MINING_MODE)"

EXTRA_ARR=()
if [ -n "$EXTRA_ARGS" ]; then read -r -a EXTRA_ARR <<< "$EXTRA_ARGS" || true; fi

launch_miner() {
    local wname=$1
    local bin="$BIN_PATH"
    if [ "$MINER_EXEC_MODE" = "direct" ]; then bin="$BACKEND_BIN"; fi
    local cmd=("$bin" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "$wname")
    if [ ${#EXTRA_ARR[@]} -gt 0 ]; then cmd+=("${EXTRA_ARR[@]}"); fi
    if [ "$MINER_EXEC_MODE" = "direct" ]; then
        log_info "🚀 Lệnh chạy (DIRECT — bỏ qua launcher): ${cmd[*]}"
        # launch_miner luôn được gọi trong subshell nền nên cd ở đây an toàn
        cd "$BACKEND_DIR" 2>/dev/null || true
        LD_LIBRARY_PATH="$BACKEND_DIR${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        RGMINER_LAUNCHER_DIR="$BACKEND_DIR" \
            "${cmd[@]}"
    else
        log_info "🚀 Lệnh chạy: ${RGMINER_BACKEND:+RGMINER_BACKEND=$RGMINER_BACKEND }${cmd[*]}"
        log_debug "Cache backend: $RGMINER_BUNDLE_CACHE"
        "${cmd[@]}"
    fi
}

# Chạy miner ở tiến trình nền rồi 'wait' — nhờ vậy script nhận được SIGTERM
# (docker stop) NGAY LẬP TỨC và tắt miner sạch sẽ thay vì bị SIGKILL sau 10s.
run_fg() {
    local rc=0
    launch_miner "$1" &
    MINER_PID=$!
    wait "$MINER_PID" || rc=$?
    MINER_PID=""
    return "$rc"
}

ATTEMPT=0
FAST_FAILS=0
DEEP_DIAG_DONE=0

while :; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$MAX_RETRIES" -gt 0 ] && [ "$ATTEMPT" -gt "$MAX_RETRIES" ]; then
        die "Đã vượt quá MAX_RETRIES=$MAX_RETRIES lần chạy — dừng hẳn."
    fi

    hr
    log_info "▶️  Lần chạy #$ATTEMPT (script v$SCRIPT_VERSION, chế độ exec: $MINER_EXEC_MODE, $(date '+%H:%M:%S'))"
    if [ ! -x "$BIN_PATH" ]; then
        dump_file_info "$BIN_PATH"
        die "Binary $BIN_PATH biến mất hoặc mất quyền thực thi giữa chừng!"
    fi
    # Chế độ DIRECT: nếu backend trong cache biến mất, chạy launcher 1 lần để
    # nó giải nén lại (kể cả khi exec của launcher lỗi, phần giải nén vẫn chạy)
    if [ "$MINER_EXEC_MODE" = "direct" ] && [ ! -x "$BACKEND_BIN" ]; then
        log_warn "Backend DIRECT biến mất ($BACKEND_BIN) — chạy launcher để giải nén lại..."
        run_smoke
        if ! locate_backend; then
            die "Không khôi phục được backend trong cache — chạy lại script từ đầu."
        fi
        log_info "Đã khôi phục backend: $BACKEND_BIN"
    fi

    START_TS=$(date +%s)
    EXIT_CODE=0

    case "$MINING_MODE" in
        GPU)
            run_fg "${WORKER}-gpu" || EXIT_CODE=$?
            ;;
        CPU)
            run_fg "${WORKER}-cpu" || EXIT_CODE=$?
            ;;
        DUAL)
            log_info "Khởi chạy instance CPU chạy nền (log riêng: $CPU_LOG)"
            echo "===== [$(ts)] DUAL attempt #$ATTEMPT =====" >> "$CPU_LOG"
            launch_miner "${WORKER}-cpu" >> "$CPU_LOG" 2>&1 &
            CPU_PID=$!
            log_info "Instance CPU PID=$CPU_PID (xem log: tail -f $CPU_LOG). Instance GPU chạy chính..."
            run_fg "${WORKER}-gpu" || EXIT_CODE=$?
            if kill -0 "$CPU_PID" 2>/dev/null; then
                log_debug "Dừng instance CPU (PID=$CPU_PID) để restart đồng bộ..."
                kill "$CPU_PID" 2>/dev/null || true
                wait "$CPU_PID" 2>/dev/null || true
            fi
            CPU_PID=""
            ;;
    esac

    DURATION=$(( $(date +%s) - START_TS ))
    log_warn "⚠️  Miner thoát: Code=$EXIT_CODE sau khi chạy được ${DURATION}s (lần #$ATTEMPT)"
    explain_exit_code "$EXIT_CODE"

    # Crash ngay khi vừa chạy (126/127) => chẩn đoán sâu ngay + tự dọn cache
    # backend để lần restart sau launcher giải nén lại sạch sẽ (tự phục hồi).
    # Ở chế độ DIRECT thì KHÔNG dọn cache (sẽ xoá mất chính backend đang dùng).
    if [ "$EXIT_CODE" -eq 126 ] || [ "$EXIT_CODE" -eq 127 ]; then
        if [ "$DEEP_DIAG_DONE" -eq 0 ]; then
            dump_file_info "$BIN_PATH"
            dump_cache_info
            DEEP_DIAG_DONE=1
        fi
        if [ "$MINER_EXEC_MODE" = "launcher" ]; then
            clean_bundle_cache
        fi
    fi

    DELAY=$RESTART_DELAY
    if [ "$DURATION" -lt "$MIN_UPTIME" ]; then
        FAST_FAILS=$((FAST_FAILS + 1))
        log_warn "Crash nhanh (chạy <${MIN_UPTIME}s) lần thứ $FAST_FAILS/$FAST_FAIL_LIMIT liên tiếp."
        if [ "$FAST_FAILS" -ge "$FAST_FAIL_LIMIT" ]; then
            if [ "$DEEP_DIAG_DONE" -eq 0 ]; then
                log_error "Crash liên tục $FAST_FAILS lần — chạy chẩn đoán sâu:"
                dump_file_info "$BIN_PATH"
                DEEP_DIAG_DONE=1
            fi
            DELAY=$LONG_RESTART_DELAY
            log_error "Lỗi có vẻ KHÔNG tự hết (crash $FAST_FAILS lần liên tiếp). Giãn thời gian chờ lên ${DELAY}s."
            log_error "Gợi ý: đọc kỹ log [ERROR] phía trên; thử FORCE_REINSTALL=1; kiểm tra '--gpus all' và driver."
        fi
    else
        FAST_FAILS=0
        DEEP_DIAG_DONE=0
    fi

    log_info "⏳ Khởi động lại sau ${DELAY}s... (Ctrl+C để dừng hẳn)"
    sleep "$DELAY"
done
