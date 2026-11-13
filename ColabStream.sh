#!/usr/bin/env bash
# =====================================================================
# ColabStream - Remote Desktop trong container (không systemd):
#   Xvfb + JWM (Joe's Window Manager) + Selkies-GStreamer (WebRTC)
#   + Cloudflare Tunnel + thư viện GPU NVIDIA (Tesla T4) qua EGL / VirtualGL
#   Video được mã hóa bằng NVENC (nvh264enc) nếu có GPU, ngược lại dùng x264enc.
#
# Dùng:  ./ColabStream.sh user | install | install-selkies | install-gpu | start | stop | restart | status | url | gpu | logs [service]
#
# Nếu chạy bằng root, script tự tạo user có quyền sudo (mặc định "remote"),
# rồi tự chuyển sang user đó để chạy lệnh (install, start, ...).
#
# LƯU Ý QUAN TRỌNG VỀ TURN:
#   Selkies-GStreamer truyền hình qua WebRTC (UDP/TCP riêng), còn Cloudflare Tunnel
#   chỉ chuyển được HTTP/WebSocket. Trang web sẽ mở được nhưng video thường KHÔNG
#   kết nối nếu thiếu TURN server. Hãy đặt TURN_HOST/TURN_USER/TURN_PASS (xem bên dưới).
#
# Biến môi trường (tùy chọn):
#   RD_USER          tên user sẽ tạo/chuyển sang (mặc định: remote)
#   RD_USER_PASSWORD mật khẩu của user đó (mặc định: quocanhh)
#   RD_AS_ROOT=1     không chuyển user, chạy thẳng bằng root
#   VERBOSE=1        hiện toàn bộ log cài đặt (mặc định ẩn, ghi vào ~/.colabstream/log/install.log)
#   STREAM_USER      user đăng nhập web Selkies (mặc định: tên user đang chạy)
#   STREAM_PASSWORD  mật khẩu đăng nhập web Selkies (mặc định: quocanhh; nhận cả VNC_PASSWORD cho tương thích)
#   RESOLUTION       độ phân giải (mặc định 1280x720; nhỏ hơn = mượt hơn)
#   DEPTH            độ sâu màu (mặc định 24)
#   CF_TOKEN         token Cloudflare Tunnel đã đặt tên (nếu trống -> quick tunnel *.trycloudflare.com)
#   SELKIES_PORT     cổng web/signaling của Selkies (mặc định 6080)
#   SELKIES_ENCODER  bộ mã hóa: nvh264enc | x264enc | vp8enc ... (mặc định: tự chọn theo GPU)
#   SELKIES_URL      link tải trực tiếp bản portable (ghi đè tự dò)
#   SELKIES_VERSION  ví dụ 1.6.2 -> tải đúng bản đó từ github.com/selkies-project/selkies
#   TURN_HOST / TURN_PORT / TURN_USER / TURN_PASS   thông tin TURN (giao thức TCP)
#   XVFB_GLX=1       bật extension GLX trên Xvfb (mặc định 0: tắt để tránh crash do lib GL của NVIDIA)
#   VGL_VERSION      phiên bản VirtualGL (mặc định 3.1.1)
#
# Chạy ứng dụng bằng GPU:  gpurun <lệnh>      ví dụ:  gpurun glxgears
# =====================================================================
set -u

RESOLUTION="${RESOLUTION:-1280x720}"
DEPTH="${DEPTH:-24}"
DISP_NUM=1
SELKIES_PORT="${SELKIES_PORT:-6080}"
SELKIES_ENCODER="${SELKIES_ENCODER:-}"
SELKIES_URL="${SELKIES_URL:-}"
SELKIES_VERSION="${SELKIES_VERSION:-}"
TURN_HOST="${TURN_HOST:-}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_USER="${TURN_USER:-}"
TURN_PASS="${TURN_PASS:-}"
XVFB_GLX="${XVFB_GLX:-0}"
CF_TOKEN="${CF_TOKEN:-}"
VERBOSE="${VERBOSE:-0}"

RD_USER="${RD_USER:-remote}"
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
  dst="$home/ColabStream.sh"
  self="$(readlink -f "$0")"
  if [ "$self" != "$dst" ]; then
    install -o "$RD_USER" -g "$(id -gn "$RD_USER")" -m 0755 "$self" "$dst"
  fi

  # Giữ lại các biến cấu hình và PATH (Colab có nvidia-smi ở thư mục riêng)
  envs="export PATH=$(printf '%q' "$PATH"):\$PATH; "
  for v in STREAM_USER STREAM_PASSWORD VNC_PASSWORD RESOLUTION DEPTH CF_TOKEN \
           SELKIES_PORT SELKIES_ENCODER SELKIES_URL SELKIES_VERSION \
           TURN_HOST TURN_PORT TURN_USER TURN_PASS XVFB_GLX VGL_VERSION VERBOSE; do
    if [ -n "${!v-}" ]; then envs+="export $v=$(printf '%q' "${!v}"); "; fi
  done

  log "Chuyển sang user '$RD_USER'..."
  exec su - "$RD_USER" -c "${envs}bash $(printf '%q' "$dst") $(printf '%q ' "$@")"
}

# Chạy bằng root -> tự tạo user và chuyển sang (trừ lệnh 'user' và khi RD_AS_ROOT=1)
case "${1:-}" in
  install|install-selkies|install-gpu|start|stop|restart|status|url|gpu|logs)
    if [ "$(id -u)" -eq 0 ] && [ "${RD_AS_ROOT:-0}" != "1" ]; then
      reexec_as_user "$@"
    fi
    ;;
esac

# ---------------------------------------------------------------------
BASE="${HOME}/.colabstream"
RUN="$BASE/run"; LOG="$BASE/log"; BIN="$BASE/bin"
SELKIES_DIR="$BASE/selkies"
mkdir -p "$RUN" "$LOG" "$BIN" "$SELKIES_DIR"
INSTALL_LOG="$LOG/install.log"

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"
APT="env DEBIAN_FRONTEND=noninteractive apt-get"

STREAM_USER="${STREAM_USER:-$(id -un)}"
STREAM_PASSWORD="${STREAM_PASSWORD:-${VNC_PASSWORD:-quocanhh}}"

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

  run "[1/5] Cập nhật danh sách gói" $SUDO $APT update -qq || exit 1
  run "[2/5] Cài Xvfb, JWM và thư viện cho Selkies" $SUDO $APT install -y --no-install-recommends \
    xvfb jwm xterm lxterminal pcmanfm lxtask dbus-x11 \
    x11-xserver-utils x11-utils x11-xkb-utils xkb-data xauth xserver-xorg-core \
    libpulse0 pulseaudio wayland-protocols libwayland-dev libwayland-egl1 \
    libx11-xcb1 libxcb-dri3-0 libxdamage1 libxfixes3 libxv1 libxtst6 libxext6 \
    jq tar gzip fonts-dejavu-core fonts-noto-core \
    curl wget ca-certificates procps psmisc || exit 1

  if ! command -v cloudflared >/dev/null; then
    local a
    case "$(uname -m)" in
      x86_64) a=amd64 ;; aarch64|arm64) a=arm64 ;; armv7l) a=arm ;; *) err "Arch không hỗ trợ"; exit 1 ;;
    esac
    run "[3/5] Tải cloudflared" curl -fsSL \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" \
      -o /tmp/cloudflared || exit 1
    run "      Cài cloudflared" $SUDO install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared || exit 1
    rm -f /tmp/cloudflared
  else
    log "[3/5] cloudflared đã có."
  fi

  log "[4/5] Selkies-GStreamer"
  install_selkies || exit 1

  log "[5/5] GPU NVIDIA"
  install_gpu
  log "Cài xong. Chạy: $0 start"
}

# ---------------------------------------------------------------------
# Tìm file chạy của Selkies sau khi giải nén (tên thư mục có thể khác theo bản phát hành)
selkies_run_path() {
  find "$SELKIES_DIR" -maxdepth 3 -type f -name 'selkies-gstreamer-run' 2>/dev/null | head -n1
}

# Tải bản portable (tarball chạy được trên mọi distro glibc >= 2.17, không cần root để chạy)
install_selkies() {
  if [ -n "$(selkies_run_path)" ]; then
    log "      Selkies đã có: $(selkies_run_path)"
    return 0
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    err "Bản portable của Selkies chỉ hỗ trợ x86_64 trong script này."
    return 1
  fi

  local url="$SELKIES_URL"
  if [ -z "$url" ] && [ -n "$SELKIES_VERSION" ]; then
    url="https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/selkies-gstreamer-portable-v${SELKIES_VERSION}_amd64.tar.gz"
  fi
  if [ -z "$url" ]; then
    log "      Dò bản Selkies-GStreamer portable mới nhất trên GitHub..."
    url="$(curl -fsSL 'https://api.github.com/repos/selkies-project/selkies/releases?per_page=20' 2>>"$INSTALL_LOG" \
      | jq -r '[.[].assets[]?.browser_download_url | select(test("selkies-gstreamer-portable.*amd64\\.tar\\.gz$"))][0]' 2>>"$INSTALL_LOG")"
  fi
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    err "Không dò được link tải Selkies. Hãy đặt SELKIES_VERSION=<số phiên bản> hoặc SELKIES_URL=<link .tar.gz>."
    return 1
  fi

  local tgz="/tmp/selkies-portable.tar.gz"
  run "      Tải Selkies: $url" curl -fL --retry 3 -o "$tgz" "$url" || return 1
  run "      Giải nén Selkies" tar -xzf "$tgz" -C "$SELKIES_DIR" || { rm -f "$tgz"; return 1; }
  rm -f "$tgz"

  if [ -z "$(selkies_run_path)" ]; then
    err "Giải nén xong nhưng không thấy selkies-gstreamer-run trong $SELKIES_DIR. Kiểm tra: ls -R $SELKIES_DIR | head"
    return 1
  fi
  log "      Đã cài Selkies: $(selkies_run_path)"
}

# ---------------------------------------------------------------------
# GPU: Tesla T4 là card compute (không có cổng xuất hình), nên không chạy Xorg
# với driver NVIDIA. Thay vào đó: dùng driver kernel của host, cài thêm thư viện
# userspace (OpenGL/EGL/Vulkan) đúng phiên bản, rồi render bằng EGL + VirtualGL.
# Desktop (JWM) vẫn vẽ bằng CPU (Xvfb); ứng dụng 3D chạy bằng:  gpurun <lệnh>
# Việc mã hóa video Selkies dùng NVENC của GPU (nếu có).
make_gpurun() {
  cat > "$BIN/gpurun" <<'EOF'
#!/bin/bash
# Chạy ứng dụng OpenGL bằng GPU NVIDIA (EGL headless qua VirtualGL)
unset LIBGL_ALWAYS_SOFTWARE
export DISPLAY="${DISPLAY:-:1}"
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
}

install_gpu() {
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    err "Không phát hiện GPU NVIDIA (nvidia-smi không chạy được) - bỏ qua phần GPU."
    err "Nếu dùng Colab: Runtime > Change runtime type > chọn T4 GPU."
    make_gpurun
    return 0
  fi

  local ver name major
  ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
  name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
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

  # 3) VirtualGL (đẩy hình từ GPU sang màn hình Xvfb)
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
  nvidia-smi 2>&1 | head -n 15 || err "nvidia-smi lỗi"
  echo
  echo "=== Thư viện NVIDIA ==="
  ldconfig -p | grep -E 'libEGL_nvidia|libGLX_nvidia|libcuda\.so|libnvidia-encode' || echo "(không thấy)"
  echo
  echo "=== OpenGL qua gpurun (cần desktop đang chạy) ==="
  if command -v glxinfo >/dev/null; then
    DISPLAY=":${DISP_NUM}" "$BIN/gpurun" glxinfo -B 2>&1 | grep -E 'OpenGL (vendor|renderer|version)' \
      || echo "Không đọc được. Hãy chạy '$0 start' trước."
  else
    echo "Chưa có glxinfo (cài mesa-utils)."
  fi
}

# Chọn bộ mã hóa: có NVENC (libnvidia-encode) thì dùng nvh264enc, ngược lại x264enc
pick_encoder() {
  if [ -n "$SELKIES_ENCODER" ]; then echo "$SELKIES_ENCODER"; return; fi
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 \
     && ldconfig -p | grep -q 'libnvidia-encode'; then
    echo "nvh264enc"
  else
    echo "x264enc"
  fi
}

# ---------------------------------------------------------------------
# Cấu hình JWM + session (nhẹ, không compositor)
prepare_config() {
  # Mật khẩu đăng nhập web Selkies (HTTP basic auth)
  echo "$STREAM_PASSWORD" > "$BASE/password.txt"; chmod 600 "$BASE/password.txt"
  echo "$STREAM_USER"     > "$BASE/user.txt";     chmod 600 "$BASE/user.txt"

  [ -x "$BIN/gpurun" ] || make_gpurun

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

  # Script khởi động session desktop
  cat > "$BASE/xstartup" <<'EOF'
#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
export NO_AT_BRIDGE=1 GTK_OVERLAY_SCROLLING=0
export PATH="$HOME/.colabstream/bin:$PATH"
xset s off -dpms s noblank 2>/dev/null
xsetroot -solid "#2e3440" 2>/dev/null
exec dbus-launch --exit-with-session jwm
EOF
  chmod +x "$BASE/xstartup"
}

# Tạo các wrapper chạy từng dịch vụ (mỗi lần restart đều chạy lại wrapper => dọn lock cũ)
make_wrappers() {
  # --- Xvfb ---
  local glx_arg="-extension GLX"
  [ "$XVFB_GLX" = "1" ] && glx_arg="+extension GLX"
  cat > "$BIN/run-xvfb" <<EOF
#!/bin/bash
# Dọn lock/socket cũ trước MỖI lần (re)start để tránh chết liên tục
rm -f /tmp/.X${DISP_NUM}-lock /tmp/.X11-unix/X${DISP_NUM} 2>/dev/null
# Tránh nạp nhầm EGL/GL của NVIDIA vào X server (gây segfault)
unset LD_LIBRARY_PATH LD_PRELOAD
export LIBGL_ALWAYS_SOFTWARE=1
ulimit -c 0
exec Xvfb :${DISP_NUM} -screen 0 ${RESOLUTION}x${DEPTH} -dpi 96 \\
  +extension RANDR +extension MIT-SHM +extension XTEST ${glx_arg} \\
  -nolisten tcp -noreset
EOF
  chmod +x "$BIN/run-xvfb"

  # --- Desktop (JWM) ---
  cat > "$BIN/run-desktop" <<EOF
#!/bin/bash
for i in \$(seq 1 30); do [ -S /tmp/.X11-unix/X${DISP_NUM} ] && break; sleep 1; done
export DISPLAY=:${DISP_NUM}
exec "$BASE/xstartup"
EOF
  chmod +x "$BIN/run-desktop"

  # --- Selkies-GStreamer ---
  local srun sdir enc q_user q_pass turn_args=""
  srun="$(selkies_run_path)"
  sdir="$(dirname "$srun")"
  enc="$(pick_encoder)"
  q_user="$(printf '%q' "$STREAM_USER")"
  q_pass="$(printf '%q' "$STREAM_PASSWORD")"
  if [ -n "$TURN_HOST" ]; then
    turn_args="$(printf '%q ' \
      "--turn_host=$TURN_HOST" "--turn_port=$TURN_PORT" "--turn_protocol=tcp" \
      "--turn_username=$TURN_USER" "--turn_password=$TURN_PASS")"
  fi
  cat > "$BIN/run-selkies" <<EOF
#!/bin/bash
export DISPLAY=:${DISP_NUM}
export XDG_RUNTIME_DIR="/tmp/runtime-\$(id -u)"
mkdir -p "\$XDG_RUNTIME_DIR"; chmod 700 "\$XDG_RUNTIME_DIR"
export PULSE_SERVER="unix:\$XDG_RUNTIME_DIR/pulse/native"
# Âm thanh (không bắt buộc; lỗi thì bỏ qua)
pulseaudio --daemonize=yes --exit-idle-time=-1 >/dev/null 2>&1 || true
for i in \$(seq 1 30); do [ -S /tmp/.X11-unix/X${DISP_NUM} ] && break; sleep 1; done
cd "$sdir" || exit 1
exec "$srun" --addr=0.0.0.0 --port=${SELKIES_PORT} \\
  --enable_https=false --encoder=${enc} \\
  --enable_basic_auth=true --basic_auth_user=${q_user} --basic_auth_password=${q_pass} \\
  ${turn_args}
EOF
  chmod 700 "$BIN/run-selkies"   # chứa mật khẩu => chỉ user này đọc được
}

# ---------------------------------------------------------------------
# Thay thế systemd: vòng lặp tự restart service khi chết (ghi mã thoát vào log)
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
      rc=\$?
      echo \"[\$(date '+%F %T')] $name thoát (mã \$rc), restart sau 2s\" >> '$LOG/$name.log'
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
  command -v Xvfb >/dev/null || { err "Chưa cài Xvfb. Chạy: $0 install"; exit 1; }
  command -v jwm  >/dev/null || { err "Chưa cài JWM. Chạy: $0 install"; exit 1; }
  [ -n "$(selkies_run_path)" ] || { err "Chưa cài Selkies. Chạy: $0 install-selkies"; exit 1; }
  prepare_config
  make_wrappers

  # Thư mục socket X phải cho phép mọi user tạo file; dọn lock cũ (kể cả của root)
  $SUDO mkdir -p /tmp/.X11-unix && $SUDO chmod 1777 /tmp/.X11-unix
  $SUDO rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"

  # 1) X server ảo (Xvfb)
  svc_start xvfb "$BIN/run-xvfb"

  # 2) Desktop session JWM (chờ X sẵn sàng rồi mới chạy)
  svc_start desktop "$BIN/run-desktop"

  # 3) Selkies-GStreamer (chụp màn hình :1, mã hóa, phát qua WebRTC)
  svc_start selkies "$BIN/run-selkies"
  log "Bộ mã hóa video: $(pick_encoder)"
  if [ -z "$TURN_HOST" ]; then
    err "Chưa đặt TURN_HOST: qua Cloudflare Tunnel video có thể không kết nối (chỉ thấy trang đăng nhập/đen)."
  fi

  # 4) Cloudflare tunnel
  if [ -n "$CF_TOKEN" ]; then
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 run --token "$CF_TOKEN"
    log "Dùng named tunnel: trỏ Public Hostname tới http://localhost:${SELKIES_PORT} trong Cloudflare Zero Trust."
  else
    : > "$LOG/cloudflared.log"
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 --url "http://localhost:${SELKIES_PORT}"
    log "Đợi URL từ Cloudflare..."
    for i in $(seq 1 30); do
      grep -qo 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" && break; sleep 1
    done
  fi
  show_url
}

stop_all() {
  for s in cloudflared selkies desktop xvfb; do svc_stop "$s"; done
  pkill -u "$(id -u)" -f "Xvfb :${DISP_NUM}" 2>/dev/null
  pkill -u "$(id -u)" -x jwm 2>/dev/null
  pkill -u "$(id -u)" -f "selkies-gstreamer" 2>/dev/null
  pkill -u "$(id -u)" -f "cloudflared tunnel" 2>/dev/null
  pulseaudio --kill >/dev/null 2>&1
  $SUDO rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"
  log "Đã dừng tất cả."
}

show_url() {
  local u
  u="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" 2>/dev/null | tail -1)"
  echo "------------------------------------------------------------"
  if [ -n "$u" ]; then
    echo "URL : $u/"
  elif [ -n "$CF_TOKEN" ]; then
    echo "URL : https://<hostname-của-bạn>/"
  else
    echo "URL : (chưa có - xem: $0 logs cloudflared)"
  fi
  echo "User: $(cat "$BASE/user.txt" 2>/dev/null || echo "$STREAM_USER")"
  echo "Pass: $(cat "$BASE/password.txt" 2>/dev/null || echo '<đã đặt trước đó>')"
  echo "------------------------------------------------------------"
}

status() {
  for s in xvfb desktop selkies cloudflared; do
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
  install-selkies) : > "$INSTALL_LOG"; install_selkies ;;
  install-gpu)     install_gpu ;;
  start)           start_all ;;
  stop)            stop_all ;;
  restart)         stop_all; sleep 1; start_all ;;
  status)          status ;;
  url)             show_url ;;
  gpu)             gpu_check ;;
  logs)            tail -n 50 -f "$LOG/${2:-selkies}.log" ;;
  *) echo "Dùng: $0 {user|install|install-selkies|install-gpu|start|stop|restart|status|url|gpu|logs [xvfb|desktop|selkies|cloudflared]}"; exit 1 ;;
esac
