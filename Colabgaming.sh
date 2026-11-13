#!/usr/bin/env bash
# =====================================================================
# Remote Desktop trong container (không systemd):
#   Selkies (AppImage, stream qua trình duyệt) + Xvfb + JWM + Cloudflare Tunnel
#   + thư viện GPU NVIDIA (Tesla T4) qua EGL / VirtualGL
#   (đã bỏ TigerVNC / noVNC)
#
# Dùng:  ./remote-desktop.sh user | install | install-selkies | install-gpu | install-apps
#                            | start | stop | restart | status | url | gpu | logs [service]
#
# Nếu chạy bằng root, script tự tạo user có quyền sudo (mặc định "remote"),
# rồi tự chuyển sang user đó để chạy lệnh (install, start, ...).
#
# Biến môi trường (tùy chọn):
#   RD_USER          tên user sẽ tạo/chuyển sang (mặc định: remote)
#   RD_USER_PASSWORD mật khẩu của user đó (mặc định: quocanhh)
#   RD_AS_ROOT=1     không chuyển user, chạy thẳng bằng root
#   VERBOSE=1        hiện toàn bộ log cài đặt (mặc định ẩn, ghi vào ~/.remote-desktop/log/install.log)
#   WEB_PORT         cổng Selkies nghe trên localhost (mặc định 6080; tránh 8080 vì Colab dùng)
#   WEB_USER         tên đăng nhập trang web Selkies (mặc định: user)
#   WEB_PASSWORD     mật khẩu trang web Selkies (mặc định: quocanhh; nên đổi vì URL ra Internet)
#   FRAMERATE        FPS stream khởi đầu (mặc định 30; máy ít CPU như Colab nên để 30)
#   RESOLUTION       khóa độ phân giải, ví dụ 1280x720 (mặc định: tự theo cửa sổ trình duyệt)
#   SELKIES_VERSION  phiên bản Selkies (mặc định 2.2.1)
#   CF_TOKEN         token Cloudflare Tunnel đã đặt tên (nếu trống -> quick tunnel *.trycloudflare.com)
#   VGL_VERSION      phiên bản VirtualGL (mặc định 3.1.1)
#   POLYMC_VERSION   phiên bản PolyMC (mặc định 7.0)
#   SKIP_APPS=1      khi 'install' thì bỏ qua Chromium + Java 25 + PolyMC
#
# Chạy ứng dụng bằng GPU:  gpurun <lệnh>      ví dụ:  gpurun glxgears
# Ứng dụng:  chromium-rd (Chromium) | polymc | gpurun polymc   (cũng có trong menu chuột phải)
# =====================================================================
set -u

DISP_NUM=20            # Selkies dùng màn hình :20
WEB_PORT="${WEB_PORT:-6080}"   # cổng Selkies (chỉ lắng nghe localhost; KHÔNG dùng 8080 vì Colab chiếm sẵn)
WEB_USER="${WEB_USER:-user}"
WEB_PASSWORD="${WEB_PASSWORD:-${VNC_PASSWORD:-quocanhh}}"
FRAMERATE="${FRAMERATE:-30}"
RESOLUTION="${RESOLUTION:-}"   # ví dụ 1280x720 (khóa độ phân giải, nhẹ CPU hơn); trống = theo cửa sổ trình duyệt
SELKIES_VERSION="${SELKIES_VERSION:-2.2.1}"
CF_TOKEN="${CF_TOKEN:-}"
VERBOSE="${VERBOSE:-0}"

RD_USER="${RD_USER:-QuocAnk}"
RD_USER_PASSWORD="${RD_USER_PASSWORD:-quocanhh}"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------
# Tạo user có quyền sudo (cần chạy bằng root)
ensure_user() {
  if [ "$(id -u)" -ne 0 ]; then err "Cần chạy bằng root để tạo user."; return 1; fi

  if ! command -v sudo >/dev/null 2>&1; then
    log "Cài sudo..."
    env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null 2>&1 \
      || { err "Không cài được sudo."; return 1; }
  fi

  if id "$RD_USER" >/dev/null 2>&1; then
    log "User '$RD_USER' đã tồn tại."
  else
    log "Tạo user '$RD_USER'..."
    useradd -m -s /bin/bash "$RD_USER" || { err "useradd lỗi."; return 1; }
    echo "$RD_USER:$RD_USER_PASSWORD" | chpasswd
  fi

  usermod -aG sudo "$RD_USER" 2>/dev/null
  for g in video render audio; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$RD_USER" 2>/dev/null
  done

  # Không hỏi mật khẩu khi dùng sudo (script cần chạy apt tự động)
  mkdir -p /etc/sudoers.d
  echo "$RD_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$RD_USER"
  chmod 440 "/etc/sudoers.d/90-$RD_USER"
}

# Chuyển sang user rồi chạy lại chính script này với cùng tham số
reexec_as_user() {
  ensure_user || exit 1
  local home dst self envs v
  home="$(getent passwd "$RD_USER" | cut -d: -f6)"
  dst="$home/remote-desktop.sh"
  self="$(readlink -f "$0")"
  if [ "$self" != "$dst" ]; then
    install -o "$RD_USER" -g "$(id -gn "$RD_USER")" -m 0755 "$self" "$dst"
  fi

  # Giữ lại các biến cấu hình và PATH (Colab có nvidia-smi ở thư mục riêng)
  envs="export PATH=$(printf '%q' "$PATH"):\$PATH; "
  for v in WEB_PORT WEB_USER WEB_PASSWORD VNC_PASSWORD FRAMERATE RESOLUTION SELKIES_VERSION CF_TOKEN VGL_VERSION POLYMC_VERSION SKIP_APPS VERBOSE; do
    if [ -n "${!v-}" ]; then envs+="export $v=$(printf '%q' "${!v}"); "; fi
  done

  # Ghi lại vị trí nvidia-smi thật (user thường có thể không có thư mục này trong PATH)
  command -v nvidia-smi >/dev/null 2>&1 && command -v nvidia-smi > /etc/remote-desktop-nvidia-smi.path
  [ -n "${LD_LIBRARY_PATH:-}" ] && printf '%s\n' "$LD_LIBRARY_PATH" > /etc/remote-desktop-ld.path

  log "Chuyển sang user '$RD_USER'..."
  exec su - "$RD_USER" -c "${envs}bash $(printf '%q' "$dst") $(printf '%q ' "$@")"
}

# Chạy bằng root -> tự tạo user và chuyển sang (trừ lệnh 'user' và khi RD_AS_ROOT=1)
case "${1:-}" in
  install|install-selkies|install-gpu|install-apps|start|stop|restart|status|url|gpu|logs)
    if [ "$(id -u)" -eq 0 ] && [ "${RD_AS_ROOT:-0}" != "1" ]; then
      reexec_as_user "$@"
    fi
    ;;
esac

# ---------------------------------------------------------------------
BASE="${HOME}/.remote-desktop"
RUN="$BASE/run"; LOG="$BASE/log"; BIN="$BASE/bin"
mkdir -p "$RUN" "$LOG" "$BIN"
INSTALL_LOG="$LOG/install.log"

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"
APT="env DEBIAN_FRONTEND=noninteractive apt-get"

# run "<mô tả>" <lệnh...>  -> ẩn output, ghi vào install.log; lỗi thì in đoạn cuối log
run() {
  local msg="$1"; shift
  log "$msg"
  if [ "$VERBOSE" = "1" ]; then "$@"; return $?; fi
  echo "=== $msg: $* ===" >> "$INSTALL_LOG"
  "$@" >> "$INSTALL_LOG" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    err "Lỗi khi: $msg (mã $rc). Chi tiết: $INSTALL_LOG"
    tail -n 15 "$INSTALL_LOG" >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------------
install_all() {
  : > "$INSTALL_LOG"
  log "Log cài đặt: $INSTALL_LOG (đặt VERBOSE=1 nếu muốn xem trực tiếp)"

  run "[1/6] Cập nhật danh sách gói" $SUDO $APT update -qq || exit 1
  run "[2/6] Cài Xvfb, JWM và công cụ" $SUDO $APT install -y --no-install-recommends \
    xvfb jwm xterm lxterminal pcmanfm lxtask dbus-x11 xclip \
    x11-xserver-utils x11-xkb-utils xkb-data xauth \
    fonts-dejavu-core fonts-noto-core \
    curl wget ca-certificates procps psmisc || exit 1

  if ! command -v cloudflared >/dev/null; then
    local a
    case "$(uname -m)" in
      x86_64) a=amd64 ;; aarch64|arm64) a=arm64 ;; armv7l) a=arm ;; *) err "Arch không hỗ trợ"; exit 1 ;;
    esac
    run "[3/6] Tải cloudflared" curl -fsSL \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" \
      -o /tmp/cloudflared || exit 1
    run "      Cài cloudflared" $SUDO install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared || exit 1
    rm -f /tmp/cloudflared
  else
    log "[3/6] cloudflared đã có."
  fi

  log "[4/6] Selkies"
  install_selkies || exit 1

  log "[5/6] GPU NVIDIA"
  install_gpu

  if [ "${SKIP_APPS:-0}" = "1" ]; then
    log "[6/6] Bỏ qua Chromium/Java/PolyMC (SKIP_APPS=1). Cài sau bằng: $0 install-apps"
  else
    log "[6/6] Chromium + Java 25 + PolyMC"
    install_apps
  fi
  log "Cài xong. Chạy: $0 start"
}

# ---------------------------------------------------------------------
# Selkies: stream desktop qua trình duyệt. AppImage cần FUSE nên giải nén rồi chạy AppRun.
install_selkies() {
  local arch dir ver
  arch="$(uname -m)"; dir="$BASE/selkies"; ver="$SELKIES_VERSION"
  case "$arch" in x86_64|aarch64) ;; *) err "Selkies chỉ có cho x86_64/aarch64."; return 1 ;; esac
  mkdir -p "$dir"
  if [ -x "$dir/squashfs-root/AppRun" ]; then
    log "      Selkies đã có."; return 0
  fi
  run "      Tải Selkies $ver" curl -fsSL -o "$dir/selkies.AppImage" \
    "https://github.com/selkies-project/selkies/releases/download/$ver/selkies-$ver-$arch.AppImage" || return 1
  chmod +x "$dir/selkies.AppImage"
  ( cd "$dir" && run "      Giải nén Selkies" ./selkies.AppImage --appimage-extract ) || return 1
  rm -f "$dir/selkies.AppImage"
}

# ---------------------------------------------------------------------
# Ứng dụng: Chromium (không snap) + OpenJDK 25 + PolyMC
make_app_wrappers() {
  # Chromium trong container cần --no-sandbox (không có user namespace)
  cat > "$BIN/chromium-rd" <<'EOF'
#!/bin/bash
exec chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --password-store=basic "$@"
EOF
  # PolyMC (AppImage đã giải nén) + chọn sẵn Java 25
  cat > "$BIN/polymc" <<'EOF'
#!/bin/bash
for d in /opt/jdk-25 /usr/lib/jvm/java-25-openjdk-*; do
  if [ -x "$d/bin/java" ]; then export JAVA_HOME="$d"; export PATH="$d/bin:$PATH"; break; fi
done
export QT_QPA_PLATFORM=xcb
unset LIBGL_ALWAYS_SOFTWARE
# PolyMC 7.0 dùng Qt build với OpenSSL 1.1; Ubuntu 24.04 chỉ có OpenSSL 3 nên Qt báo
# "TLS initialization failed". Cho Qt thấy đúng libssl/libcrypto 1.1 đi kèm AppImage
# (chỉ 2 file này, không thêm cả thư mục lib để khỏi ảnh hưởng Java/Minecraft).
P="$HOME/.remote-desktop/polymc"
mkdir -p "$P/ssl11"
ln -sf "$P/squashfs-root/usr/lib/libssl.so.1.1" "$P/ssl11/libssl.so.1.1"
ln -sf "$P/squashfs-root/usr/lib/libcrypto.so.1.1" "$P/ssl11/libcrypto.so.1.1"
export LD_LIBRARY_PATH="$P/ssl11${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$P/squashfs-root/AppRun" "$@"
EOF
  chmod +x "$BIN/chromium-rd" "$BIN/polymc"
  $SUDO ln -sf "$BIN/chromium-rd" /usr/local/bin/chromium-rd 2>/dev/null || true
  $SUDO ln -sf "$BIN/polymc" /usr/local/bin/polymc 2>/dev/null || true
}

install_java() {
  if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q '"25'; then
    log "      Java 25 đã có."; return 0
  fi
  if run "      Cài OpenJDK 25 (apt)" $SUDO $APT install -y --no-install-recommends openjdk-25-jdk; then
    local j; j="$(ls -d /usr/lib/jvm/java-25-openjdk-*/ 2>/dev/null | head -n1)"
    if [ -n "$j" ]; then   # đặt Java 25 làm mặc định
      $SUDO update-alternatives --set java "${j}bin/java" >/dev/null 2>&1
      $SUDO update-alternatives --set javac "${j}bin/javac" >/dev/null 2>&1
    fi
    return 0
  fi

  err "Không cài được openjdk-25 bằng apt, thử Eclipse Temurin 25..."
  local arch
  case "$(uname -m)" in x86_64) arch=x64 ;; aarch64|arm64) arch=aarch64 ;; *) err "Arch không hỗ trợ"; return 1 ;; esac
  run "      Tải Temurin JDK 25" curl -fsSL \
    "https://api.adoptium.net/v3/binary/latest/25/ga/linux/$arch/jdk/hotspot/normal/eclipse" \
    -o /tmp/jdk25.tar.gz || return 1
  $SUDO mkdir -p /opt/jdk-25
  run "      Giải nén Temurin vào /opt/jdk-25" $SUDO tar -xzf /tmp/jdk25.tar.gz -C /opt/jdk-25 --strip-components=1 || return 1
  rm -f /tmp/jdk25.tar.gz
  $SUDO ln -sf /opt/jdk-25/bin/java /usr/local/bin/java
  $SUDO ln -sf /opt/jdk-25/bin/javac /usr/local/bin/javac
}

install_chromium() {
  if command -v chromium >/dev/null 2>&1 && ! chromium --version 2>&1 | grep -qi snap; then
    log "      Chromium đã có."; return 0
  fi
  run "      Cài công cụ thêm PPA" $SUDO $APT install -y --no-install-recommends software-properties-common gnupg || return 1
  # Ubuntu chỉ có Chromium dạng snap (không chạy được trong container) -> dùng PPA xtradeb (gói .deb)
  run "      Thêm PPA xtradeb/apps" $SUDO env PATH=/usr/sbin:/usr/bin:/sbin:/bin add-apt-repository -y ppa:xtradeb/apps || return 1
  printf 'Package: chromium*\nPin: release o=LP-PPA-xtradeb-apps\nPin-Priority: 700\n' \
    | $SUDO tee /etc/apt/preferences.d/chromium-xtradeb >/dev/null
  run "      Cập nhật danh sách gói" $SUDO $APT update -qq || return 1
  run "      Cài Chromium" $SUDO $APT install -y --no-install-recommends chromium fonts-liberation || return 1
}

install_polymc() {
  if [ "$(uname -m)" != "x86_64" ]; then err "PolyMC AppImage chỉ có cho x86_64."; return 1; fi
  run "      Cài thư viện cho Qt/Minecraft" $SUDO $APT install -y --no-install-recommends \
    libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
    libxcb-render-util0 libxcb-xinerama0 libxcb-shape0 libxcb-xkb1 libxcb-randr0 \
    libxrandr2 libxcursor1 libxxf86vm1 libxi6 libxrender1 libxtst6 libopenal1 libnss3 \
    || return 1

  local dir="$BASE/polymc" ver="${POLYMC_VERSION:-7.0}"
  mkdir -p "$dir"
  if [ -x "$dir/squashfs-root/AppRun" ]; then
    log "      PolyMC đã có."
  else
    run "      Tải PolyMC $ver" wget -q -O "$dir/PolyMC.AppImage" \
      "https://github.com/PolyMC/PolyMC/releases/download/$ver/PolyMC-Linux-$ver-x86_64.AppImage" || return 1
    chmod +x "$dir/PolyMC.AppImage"
    # Container không có FUSE -> giải nén AppImage ra thư mục rồi chạy AppRun
    ( cd "$dir" && run "      Giải nén PolyMC" ./PolyMC.AppImage --appimage-extract ) || return 1
    rm -f "$dir/PolyMC.AppImage"
  fi
}

install_apps() {
  install_java     || err "Java 25: lỗi (xem $INSTALL_LOG)"
  install_chromium || err "Chromium: lỗi (xem $INSTALL_LOG)"
  install_polymc   || err "PolyMC: lỗi (xem $INSTALL_LOG)"
  make_app_wrappers
  log "      Xong. Mở từ menu chuột phải trên desktop, hoặc gõ: chromium-rd | polymc | gpurun polymc"
}

# ---------------------------------------------------------------------
# GPU: Tesla T4 là card compute (không có cổng xuất hình), nên không chạy Xorg
# với driver NVIDIA. Thay vào đó: dùng driver kernel của host, cài thêm thư viện
# userspace (OpenGL/EGL/Vulkan) đúng phiên bản, rồi render bằng EGL + VirtualGL.
# Desktop (JWM) vẫn vẽ bằng CPU; ứng dụng 3D chạy bằng:  gpurun <lệnh>
make_gpurun() {
  cat > "$BIN/gpurun" <<'EOF'
#!/bin/bash
# Chạy ứng dụng OpenGL bằng GPU NVIDIA (EGL headless qua VirtualGL)
unset LIBGL_ALWAYS_SOFTWARE
export DISPLAY="${DISPLAY:-:20}"
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
if command -v vglrun >/dev/null 2>&1; then
  exec vglrun -d egl "$@"
else
  exec "$@"
fi
EOF
  chmod +x "$BIN/gpurun"
  $SUDO ln -sf "$BIN/gpurun" /usr/local/bin/gpurun 2>/dev/null || true

  # nvidia-smi: tự thêm thư mục thư viện NVIDIA của host (Colab: /usr/lib64-nvidia)
  # chỉ cho riêng lệnh này, không đụng LD_LIBRARY_PATH toàn hệ thống (tránh crash Xvfb/swrast)
  cat > "$BIN/nvidia-smi" <<'EOF'
#!/bin/bash
L=""
[ -r /etc/remote-desktop-ld.path ] && read -r SAVED_LD < /etc/remote-desktop-ld.path && L=":$SAVED_LD"
for d in /usr/lib64-nvidia /usr/local/nvidia/lib64 /usr/local/nvidia/lib /usr/lib/x86_64-linux-gnu /usr/lib64; do
  [ -d "$d" ] && L="$L:$d"
done
export LD_LIBRARY_PATH="${L#:}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -r /etc/remote-desktop-nvidia-smi.path ] && read -r SAVED < /etc/remote-desktop-nvidia-smi.path
for b in "${SAVED:-}" /opt/bin/nvidia-smi /usr/local/nvidia/bin/nvidia-smi /usr/bin/nvidia-smi /usr/lib64-nvidia/bin/nvidia-smi; do
  [ -x "$b" ] && exec "$b" "$@"
done
echo "Không tìm thấy nvidia-smi" >&2; exit 1
EOF
  chmod +x "$BIN/nvidia-smi"
}

install_gpu() {
  make_gpurun
  local NVSMI="$BIN/nvidia-smi"
  if ! "$NVSMI" -L >/dev/null 2>&1; then
    err "Không phát hiện GPU NVIDIA (nvidia-smi không chạy được) - bỏ qua phần GPU."
    err "Nếu dùng Colab: Runtime > Change runtime type > chọn T4 GPU."
    return 0
  fi

  local ver name major
  ver="$("$NVSMI" --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
  name="$("$NVSMI" --query-gpu=name --format=csv,noheader | head -n1)"
  major="${ver%%.*}"
  log "GPU: $name | driver của host: $ver"

  run "      Cài thư viện OpenGL/EGL/Vulkan nền" $SUDO $APT install -y --no-install-recommends \
    libglvnd0 libegl1 libgl1 libglx0 libgles2 libopengl0 \
    libvulkan1 vulkan-tools mesa-utils wget kmod

  # 1) Thư viện userspace NVIDIA khớp đúng phiên bản driver của host (không cài kernel module)
  if ldconfig -p | grep -q 'libEGL_nvidia.so.0' && ldconfig -p | grep -q 'libGLX_nvidia.so.0'; then
    log "      Đã có thư viện OpenGL/EGL của NVIDIA."
  else
    local runf="/tmp/NVIDIA-Linux-x86_64-$ver.run"
    if run "      Tải thư viện NVIDIA $ver" wget -q -O "$runf" \
         "https://download.nvidia.com/XFree86/Linux-x86_64/$ver/NVIDIA-Linux-x86_64-$ver.run" \
       && run "      Cài thư viện NVIDIA (bỏ qua kernel module)" $SUDO sh "$runf" --silent \
            --no-kernel-module --no-kernel-module-source \
            --no-nouveau-check --no-nvidia-modprobe --no-x-check --no-drm \
            --no-check-for-alternate-installs --no-install-libglvnd; then
      :
    else
      err "Cài bản .run lỗi, thử gói apt libnvidia-gl-$major (có thể lệch minor version)..."
      run "      Cài libnvidia-gl-$major" $SUDO $APT install -y --no-install-recommends "libnvidia-gl-$major" \
        || run "      Cài libnvidia-gl-$major-server" $SUDO $APT install -y --no-install-recommends "libnvidia-gl-$major-server" \
        || err "Không cài được thư viện GL của NVIDIA."
    fi
    rm -f "$runf"
    $SUDO ldconfig >/dev/null 2>&1
  fi

  # 2) Đảm bảo glvnd/Vulkan nhận ra NVIDIA
  if [ ! -e /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
    $SUDO mkdir -p /usr/share/glvnd/egl_vendor.d
    echo '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}' \
      | $SUDO tee /usr/share/glvnd/egl_vendor.d/10_nvidia.json >/dev/null
  fi
  if [ ! -e /usr/share/vulkan/icd.d/nvidia_icd.json ] && [ ! -e /etc/vulkan/icd.d/nvidia_icd.json ]; then
    $SUDO mkdir -p /usr/share/vulkan/icd.d
    echo '{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3"}}' \
      | $SUDO tee /usr/share/vulkan/icd.d/nvidia_icd.json >/dev/null
  fi

  # 3) VirtualGL (đẩy hình từ GPU sang màn hình ảo Xvfb)
  if ! command -v vglrun >/dev/null 2>&1 && [ "$(uname -m)" = "x86_64" ]; then
    local v="${VGL_VERSION:-3.1.1}" deb="/tmp/virtualgl.deb"
    if run "      Tải VirtualGL $v" wget -q -O "$deb" \
         "https://github.com/VirtualGL/virtualgl/releases/download/$v/virtualgl_${v}_amd64.deb" \
       && run "      Cài VirtualGL" $SUDO $APT install -y "$deb"; then
      :
    else
      err "Không cài được VirtualGL (gpurun sẽ chạy app trực tiếp, không qua vglrun)."
    fi
    rm -f "$deb"
  fi

  make_gpurun
  log "      GPU xong. Kiểm tra sau khi start: $0 gpu"
}

gpu_check() {
  echo "=== nvidia-smi ==="
  "$BIN/nvidia-smi" 2>&1 | head -n 15
  echo
  echo "=== Thư viện NVIDIA ==="
  ldconfig -p | grep -E 'libEGL_nvidia|libGLX_nvidia|libcuda\.so' || echo "(không thấy)"
  echo
  echo "=== OpenGL qua gpurun (cần desktop đang chạy) ==="
  if command -v glxinfo >/dev/null; then
    DISPLAY=":${DISP_NUM}" "$BIN/gpurun" glxinfo -B 2>&1 | grep -E 'OpenGL (vendor|renderer|version)' \
      || echo "Không đọc được. Hãy chạy '$0 start' trước."
  else
    echo "Chưa có glxinfo (cài mesa-utils)."
  fi
}

# ---------------------------------------------------------------------
# Cấu hình JWM + session (nhẹ, không compositor)
prepare_config() {
  make_gpurun
  make_app_wrappers

  # Cấu hình JWM (chỉ tạo nếu chưa có; xóa ~/.jwmrc để tạo lại mặc định)
  if [ ! -f "$HOME/.jwmrc" ]; then
    cat > "$HOME/.jwmrc" <<'EOF'
<?xml version="1.0"?>
<JWM>
  <RootMenu onroot="12">
    <Program label="Terminal">lxterminal</Program>
    <Program label="Trình quản lý tệp">pcmanfm</Program>
    <Program label="Task Manager">lxtask</Program>
    <Program label="nvidia-smi">xterm -hold -e nvidia-smi</Program>
    <Separator/>
    <Restart label="Restart JWM"/>
    <Exit label="Exit" confirm="false"/>
  </RootMenu>

  <Tray x="0" y="-1" height="32" autohide="off" layout="horizontal">
    <TrayButton label="Menu">root:1</TrayButton>
    <TrayButton label="Term">exec:lxterminal</TrayButton>
    <TrayButton label="Files">exec:pcmanfm</TrayButton>
    <Spacer width="4"/>
    <TaskList maxwidth="220"/>
    <Dock/>
    <Clock format="%H:%M %d/%m"/>
  </Tray>

  <Desktops width="1" height="1">
    <Background type="solid">#2e3440</Background>
  </Desktops>

  <FocusModel>click</FocusModel>
  <SnapMode distance="10">border</SnapMode>
  <MoveMode>outline</MoveMode>
  <ResizeMode>outline</ResizeMode>
  <DoubleClickSpeed>400</DoubleClickSpeed>
  <DoubleClickDelta>4</DoubleClickDelta>
</JWM>
EOF
  fi

  # Thêm Chromium/PolyMC vào menu JWM (kể cả khi ~/.jwmrc đã có từ trước)
  if ! grep -q 'label="PolyMC"' "$HOME/.jwmrc"; then
    sed -i '/<Program label="Task Manager">/a\    <Program label="Chromium">chromium-rd</Program>\n    <Program label="PolyMC">polymc</Program>\n    <Program label="PolyMC (GPU)">gpurun polymc</Program>' "$HOME/.jwmrc"
  fi

  # Wrapper chạy Xvfb + Selkies, tự giám sát:
  #  - tự chạy Xvfb (để biết chính xác nó thoát vì lý do gì: mã 139 = segfault, 137 = bị kill...)
  #  - Xvfb chết/treo hoặc Selkies thoát => ghi sự kiện vào xvfb-events.log, dọn sạch, để vòng lặp chạy lại
  cat > "$BIN/selkies-run" <<'EOF'
#!/bin/bash
# selkies-run <màn hình> <lệnh chạy Selkies...>      (RD_LOG = thư mục log)
D="$1"; shift
L="${RD_LOG:-/tmp}"
SOCK="/tmp/.X11-unix/X$D"
EV="$L/xvfb-events.log"

alive() {  # tiến trình còn sống và không phải zombie
  local st; st="$(awk '/^State:/{print $2}' "/proc/$1/status" 2>/dev/null)"
  [ -n "$st" ] && [ "$st" != "Z" ]
}
cleanup_x() {
  pkill -f "Xvfb :$D " 2>/dev/null
  pkill -f "pulseaudio_selkies.log" 2>/dev/null
  rm -f "/tmp/.X$D-lock" "$SOCK"
}
cleanup_x   # bắt đầu từ trạng thái sạch

Xvfb ":$D" -screen 0 4096x2304x24 -s 0 -dpms +extension COMPOSITE +extension DAMAGE \
  +extension GLX +extension RANDR +extension RENDER +extension MIT-SHM +extension XFIXES \
  +extension XTEST +iglx +render -nolisten tcp -ac -noreset -shmem >> "$L/xvfb.log" 2>&1 &
xpid=$!
for i in $(seq 1 60); do
  [ -S "$SOCK" ] && break
  alive "$xpid" || break
  sleep 0.5
done
if [ ! -S "$SOCK" ]; then
  echo "[$(date '+%F %T')] Xvfb không khởi động được (xem $L/xvfb.log)" | tee -a "$EV"
  cleanup_x; exit 1
fi

"$@" &
spid=$!
trap 'kill "$spid" "$xpid" 2>/dev/null' TERM INT

why=""; up=0; fails=0
while :; do
  sleep 1
  if ! alive "$xpid"; then
    wait "$xpid" 2>/dev/null; code=$?
    why="Xvfb đã thoát, mã $code (134=X server tự abort sau lỗi nghiêm trọng, 139=segfault, 137=SIGKILL/OOM, 135=SIGBUS)"
    break
  fi
  if ! alive "$spid"; then
    wait "$spid" 2>/dev/null; code=$?
    why="Selkies đã thoát, mã $code"
    break
  fi
  if DISPLAY=":$D" timeout 5 xset q >/dev/null 2>&1; then
    up=1; fails=0
  elif [ "$up" = 1 ]; then
    fails=$((fails+1))
    if [ "$fails" -ge 20 ]; then why="Xvfb treo, không phản hồi ~100s"; break; fi
  fi
done

{
  echo "=== [$(date '+%F %T')] $why"
  free -m | head -2
  df -h /dev/shm | tail -n 1
  ps aux --sort=-%mem | head -5 | cut -c1-140
} >> "$EV"
echo "[selkies-run] $why"

kill "$spid" 2>/dev/null; sleep 2; kill -9 "$spid" 2>/dev/null
cleanup_x
exit 1
EOF
  chmod +x "$BIN/selkies-run"

  # Script khởi động session (chạy trên màn hình :20 do Selkies/Xvfb tạo)
  cat > "$BASE/xstartup" <<'EOF'
#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
export NO_AT_BRIDGE=1 GTK_OVERLAY_SCROLLING=0
export PULSE_SERVER="unix:/tmp/pulse/native"      # âm thanh do Selkies cung cấp
export PATH="$HOME/.remote-desktop/bin:$PATH"
xset s off -dpms s noblank 2>/dev/null
xsetroot -solid "#2e3440" 2>/dev/null
exec dbus-launch --exit-with-session jwm
EOF
  chmod +x "$BASE/xstartup"
}

# ---------------------------------------------------------------------
# Thay thế systemd: vòng lặp tự restart service khi chết
# svc_start <name> <command...>
svc_start() {
  local name="$1"; shift
  local pidf="$RUN/$name.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    log "$name đã chạy (pid $(cat "$pidf"))"; return
  fi
  local cmd; cmd="$(printf '%q ' "$@")"
  setsid nohup bash -c "
    while true; do
      $cmd >> '$LOG/$name.log' 2>&1
      echo \"[\$(date '+%F %T')] $name thoát, restart sau 2s\" >> '$LOG/$name.log'
      sleep 2
    done" >/dev/null 2>&1 &
  echo $! > "$pidf"
  log "Đã chạy $name (pid $!)"
}

svc_stop() {
  local name="$1" pidf="$RUN/$1.pid"
  if [ -f "$pidf" ]; then
    local p; p="$(cat "$pidf")"
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    rm -f "$pidf"
  fi
}

# ---------------------------------------------------------------------
start_all() {
  local SK="$BASE/selkies/squashfs-root/AppRun"
  [ -x "$SK" ] || { err "Chưa cài Selkies. Chạy: $0 install"; exit 1; }
  command -v Xvfb >/dev/null || { err "Chưa cài Xvfb. Chạy: $0 install"; exit 1; }
  command -v jwm  >/dev/null || { err "Chưa cài JWM. Chạy: $0 install"; exit 1; }
  prepare_config

  # Thư mục socket X phải cho phép mọi user tạo file; dọn lock cũ (kể cả của root)
  $SUDO mkdir -p /tmp/.X11-unix && $SUDO chmod 1777 /tmp/.X11-unix
  $SUDO rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"

  # 1) Selkies: AppRun tự bật Xvfb (:20) + PulseAudio rồi stream màn hình qua web.
  #    Mặc định chỉ lắng nghe localhost; Cloudflare Tunnel trỏ vào đây.
  #    - env -u LD_LIBRARY_PATH + EGL của Mesa: tránh nạp nhầm EGL của NVIDIA (làm Xvfb/swrast crash)
  #    - mật khẩu truyền qua biến môi trường để không lộ trong 'ps'
  local egl_env="__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json"
  [ -e /usr/share/glvnd/egl_vendor.d/50_mesa.json ] || egl_env="__EGL_VENDOR_LIBRARY_DIRS=/nonexistent"
  local extra=()
  [ -n "$FRAMERATE" ] && extra+=("--framerate=$FRAMERATE")
  if [[ "$RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    extra+=("--manual-width=${BASH_REMATCH[1]}" "--manual-height=${BASH_REMATCH[2]}")
  fi
  export DISPLAY=":${DISP_NUM}" SELKIES_BASIC_AUTH_USER="$WEB_USER" SELKIES_BASIC_AUTH_PASSWORD="$WEB_PASSWORD"
  svc_start selkies env -u LD_LIBRARY_PATH "$egl_env" "RD_LOG=$LOG" "$BIN/selkies-run" "$DISP_NUM" "$SK" --port="$WEB_PORT" ${extra[@]+"${extra[@]}"}
  unset SELKIES_BASIC_AUTH_USER SELKIES_BASIC_AUTH_PASSWORD

  # 2) Desktop session JWM (chờ Xvfb sẵn sàng rồi mới chạy)
  svc_start desktop bash -c "
    for i in \$(seq 1 90); do [ -S /tmp/.X11-unix/X${DISP_NUM} ] && break; sleep 1; done
    export DISPLAY=:${DISP_NUM}
    '$BASE/xstartup'
    # xstartup thoát => chờ để vòng lặp restart
  "

  # 3) Cloudflare tunnel
  if [ -n "$CF_TOKEN" ]; then
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 run --token "$CF_TOKEN"
    log "Dùng named tunnel: trỏ Public Hostname tới http://localhost:${WEB_PORT} trong Cloudflare Zero Trust."
  else
    : > "$LOG/cloudflared.log"
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 --url "http://localhost:${WEB_PORT}"
    log "Đợi URL từ Cloudflare..."
    for i in $(seq 1 30); do
      grep -qo 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" && break; sleep 1
    done
  fi
  show_url
}

stop_all() {
  for s in cloudflared desktop selkies; do svc_stop "$s"; done
  pkill -f "$BASE/selkies/squashfs-root" 2>/dev/null
  pkill -f "Xvfb :${DISP_NUM}" 2>/dev/null
  pkill -f "pulseaudio_selkies.log" 2>/dev/null
  pkill -x jwm 2>/dev/null
  pkill -f "cloudflared tunnel" 2>/dev/null
  $SUDO rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"
  log "Đã dừng tất cả."
}

show_url() {
  local u
  u="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" 2>/dev/null | tail -1)"
  echo "------------------------------------------------------------"
  if [ -n "$u" ]; then
    echo "URL : $u"
  elif [ -n "$CF_TOKEN" ]; then
    echo "URL : https://<hostname-của-bạn>"
  else
    echo "URL : (chưa có - xem: $0 logs cloudflared)"
  fi
  echo "Đăng nhập (trình duyệt sẽ hỏi): user = $WEB_USER | mật khẩu = $WEB_PASSWORD"
  echo "------------------------------------------------------------"
}

status() {
  for s in selkies desktop cloudflared; do
    if [ -f "$RUN/$s.pid" ] && kill -0 "$(cat "$RUN/$s.pid")" 2>/dev/null; then
      printf '%-12s \033[32mRUNNING\033[0m\n' "$s"
    else
      printf '%-12s \033[31mSTOPPED\033[0m\n' "$s"
    fi
  done
  show_url
}

case "${1:-}" in
  user)            ensure_user && log "Xong. Chuyển user thủ công bằng: su - $RD_USER" ;;
  install)         install_all ;;
  install-selkies) install_selkies ;;
  install-gpu)     install_gpu ;;
  install-apps)    install_apps ;;
  start)           start_all ;;
  stop)            stop_all ;;
  restart)         stop_all; sleep 1; start_all ;;
  status)          status ;;
  url)             show_url ;;
  gpu)             gpu_check ;;
  logs)            tail -n 50 -f "$LOG/${2:-selkies}.log" ;;
  *) echo "Dùng: $0 {user|install|install-selkies|install-gpu|install-apps|start|stop|restart|status|url|gpu|logs [selkies|desktop|cloudflared|xvfb|xvfb-events]}"; exit 1 ;;
esac
