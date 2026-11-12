#!/usr/bin/env bash
# =====================================================================
# Remote Desktop trong container (không systemd):
#   TigerVNC + JWM (Joe's Window Manager) + noVNC + Cloudflare Tunnel
#   + thư viện GPU NVIDIA (Tesla T4) qua EGL / VirtualGL
#
# Dùng:  ./remote-desktop.sh install | install-gpu | start | stop | restart | status | url | gpu | logs [service]
#
# Biến môi trường (tùy chọn):
#   VNC_PASSWORD   mật khẩu VNC (mặc định: quocanhh)
#   RESOLUTION     độ phân giải (mặc định 1280x720; nhỏ hơn = mượt hơn)
#   DEPTH          độ sâu màu (mặc định 24; dùng 16 nếu mạng yếu)
#   CF_TOKEN       token Cloudflare Tunnel đã đặt tên (nếu trống -> quick tunnel *.trycloudflare.com)
#   NOVNC_QUALITY  0-9 (mặc định 6)   NOVNC_COMPRESSION 0-9 (mặc định 4)
#   VGL_VERSION    phiên bản VirtualGL (mặc định 3.1.1)
#
# Chạy ứng dụng bằng GPU:  gpurun <lệnh>      ví dụ:  gpurun glxgears
# =====================================================================
set -u

RESOLUTION="${RESOLUTION:-1280x720}"
DEPTH="${DEPTH:-24}"
DISP_NUM=1
VNC_PORT=$((5900 + DISP_NUM))
NOVNC_PORT=6080
NOVNC_QUALITY="${NOVNC_QUALITY:-6}"
NOVNC_COMPRESSION="${NOVNC_COMPRESSION:-4}"
CF_TOKEN="${CF_TOKEN:-}"

BASE="${HOME}/.remote-desktop"
RUN="$BASE/run"; LOG="$BASE/log"; BIN="$BASE/bin"
mkdir -p "$RUN" "$LOG" "$BIN" "$HOME/.vnc"

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------
install_all() {
  log "Cài gói cần thiết..."
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    tigervnc-standalone-server tigervnc-common tigervnc-tools \
    jwm xterm lxterminal pcmanfm lxtask dbus-x11 \
    x11-xserver-utils x11-xkb-utils xkb-data xauth \
    novnc websockify python3-numpy \
    fonts-dejavu-core fonts-noto-core \
    curl wget ca-certificates procps psmisc

  # Bỏ screensaver nếu có
  $SUDO apt-get remove -y --purge xscreensaver light-locker 2>/dev/null || true

  if ! command -v cloudflared >/dev/null; then
    log "Cài cloudflared..."
    case "$(uname -m)" in
      x86_64) a=amd64 ;; aarch64|arm64) a=arm64 ;; armv7l) a=arm ;; *) err "Arch không hỗ trợ"; exit 1 ;;
    esac
    curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" -o /tmp/cloudflared
    $SUDO install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared && rm -f /tmp/cloudflared
  fi

  [ -e /usr/share/novnc/index.html ] || $SUDO ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

  install_gpu
  log "Cài xong. Chạy: $0 start"
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

  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get install -y --no-install-recommends \
    libglvnd0 libegl1 libgl1 libglx0 libgles2 libopengl0 \
    libvulkan1 vulkan-tools mesa-utils wget kmod

  # 1) Thư viện userspace NVIDIA khớp đúng phiên bản driver của host (không cài kernel module)
  if ldconfig -p | grep -q 'libEGL_nvidia.so.0' && ldconfig -p | grep -q 'libGLX_nvidia.so.0'; then
    log "Đã có thư viện OpenGL/EGL của NVIDIA."
  else
    log "Cài thư viện userspace NVIDIA $ver (bỏ qua kernel module, dùng driver host)..."
    local run="/tmp/NVIDIA-Linux-x86_64-$ver.run"
    if wget -q --show-progress -O "$run" \
         "https://download.nvidia.com/XFree86/Linux-x86_64/$ver/NVIDIA-Linux-x86_64-$ver.run" \
       && $SUDO sh "$run" --silent --no-kernel-module --no-kernel-module-source \
            --no-nouveau-check --no-nvidia-modprobe --no-x-check --no-drm \
            --no-check-for-alternate-installs --no-install-libglvnd; then
      log "Cài bản .run thành công."
    else
      err "Cài bản .run lỗi, thử gói apt libnvidia-gl-$major (có thể lệch minor version)..."
      $SUDO apt-get install -y --no-install-recommends "libnvidia-gl-$major" \
        || $SUDO apt-get install -y --no-install-recommends "libnvidia-gl-$major-server" \
        || err "Không cài được thư viện GL của NVIDIA."
    fi
    rm -f "$run"
    $SUDO ldconfig
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

  # 3) VirtualGL (đẩy hình từ GPU sang màn hình VNC)
  if ! command -v vglrun >/dev/null 2>&1; then
    if [ "$(uname -m)" = "x86_64" ]; then
      local v="${VGL_VERSION:-3.1.1}" deb="/tmp/virtualgl.deb"
      log "Cài VirtualGL $v..."
      if wget -q -O "$deb" "https://github.com/VirtualGL/virtualgl/releases/download/$v/virtualgl_${v}_amd64.deb" \
         && $SUDO apt-get install -y "$deb"; then
        log "Đã cài VirtualGL."
      else
        err "Không cài được VirtualGL (gpurun sẽ chạy app trực tiếp, không qua vglrun)."
      fi
      rm -f "$deb"
    fi
  fi

  make_gpurun
  log "GPU xong. Kiểm tra sau khi start: $0 gpu"
}

gpu_check() {
  echo "=== nvidia-smi ==="
  nvidia-smi 2>&1 | head -n 15 || err "nvidia-smi lỗi"
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
  # Mật khẩu VNC
  # Mật khẩu cố định (có thể ghi đè bằng biến môi trường VNC_PASSWORD).
  # Lưu ý: giao thức VNC chỉ dùng 8 ký tự đầu của mật khẩu.
  VNC_PASSWORD="${VNC_PASSWORD:-quocanhh}"
  echo "$VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
  chmod 600 "$HOME/.vnc/passwd"
  echo "$VNC_PASSWORD" > "$BASE/password.txt"; chmod 600 "$BASE/password.txt"

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

  # Script khởi động session
  cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
export NO_AT_BRIDGE=1 GTK_OVERLAY_SCROLLING=0
export PATH="$HOME/.remote-desktop/bin:$PATH"
xset s off -dpms s noblank 2>/dev/null
xsetroot -solid "#2e3440" 2>/dev/null
vncconfig -nowin >/dev/null 2>&1 &   # đồng bộ clipboard với trình duyệt
exec dbus-launch --exit-with-session jwm
EOF
  chmod +x "$HOME/.vnc/xstartup"
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
  command -v Xtigervnc >/dev/null || { err "Chưa cài. Chạy: $0 install"; exit 1; }
  command -v jwm >/dev/null || { err "Chưa cài JWM. Chạy: $0 install"; exit 1; }
  prepare_config

  # Dọn lock cũ (thường gặp khi container restart)
  rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"

  # 1) X server (TigerVNC) - chỉ lắng nghe localhost, tối ưu cập nhật khung hình
  svc_start xvnc Xtigervnc ":${DISP_NUM}" \
    -geometry "$RESOLUTION" -depth "$DEPTH" \
    -rfbport "$VNC_PORT" -localhost yes \
    -rfbauth "$HOME/.vnc/passwd" -SecurityTypes VncAuth \
    -AlwaysShared -AcceptSetDesktopSize \
    -FrameRate 30 -CompareFB 1 -dpi 96

  # 2) Desktop session JWM (chờ X sẵn sàng rồi mới chạy)
  svc_start desktop bash -c "
    for i in \$(seq 1 30); do [ -S /tmp/.X11-unix/X${DISP_NUM} ] && break; sleep 1; done
    export DISPLAY=:${DISP_NUM}
    '$HOME/.vnc/xstartup'
    # xstartup thoát => chờ để vòng lặp restart
  "

  # 3) noVNC (websockify)
  svc_start novnc websockify --web /usr/share/novnc "$NOVNC_PORT" "localhost:${VNC_PORT}"

  # 4) Cloudflare tunnel
  if [ -n "$CF_TOKEN" ]; then
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 run --token "$CF_TOKEN"
    log "Dùng named tunnel: trỏ Public Hostname tới http://localhost:${NOVNC_PORT} trong Cloudflare Zero Trust."
  else
    : > "$LOG/cloudflared.log"
    svc_start cloudflared cloudflared tunnel --no-autoupdate --protocol http2 --url "http://localhost:${NOVNC_PORT}"
    log "Đợi URL từ Cloudflare..."
    for i in $(seq 1 30); do
      grep -qo 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" && break; sleep 1
    done
  fi
  show_url
}

stop_all() {
  for s in cloudflared novnc desktop xvnc; do svc_stop "$s"; done
  pkill -f "Xtigervnc :${DISP_NUM}" 2>/dev/null
  pkill -x jwm 2>/dev/null
  pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null
  pkill -f "cloudflared tunnel" 2>/dev/null
  rm -f "/tmp/.X${DISP_NUM}-lock" "/tmp/.X11-unix/X${DISP_NUM}"
  log "Đã dừng tất cả."
}

show_url() {
  local params="autoconnect=true&resize=remote&quality=${NOVNC_QUALITY}&compression=${NOVNC_COMPRESSION}&reconnect=true"
  local u
  u="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/cloudflared.log" 2>/dev/null | tail -1)"
  echo "------------------------------------------------------------"
  if [ -n "$u" ]; then
    echo "URL : $u/vnc.html?$params"
  elif [ -n "$CF_TOKEN" ]; then
    echo "URL : https://<hostname-của-bạn>/vnc.html?$params"
  else
    echo "URL : (chưa có - xem: $0 logs cloudflared)"
  fi
  echo "Pass: $(cat "$BASE/password.txt" 2>/dev/null || echo '<đã đặt trước đó>')"
  echo "------------------------------------------------------------"
}

status() {
  for s in xvnc desktop novnc cloudflared; do
    if [ -f "$RUN/$s.pid" ] && kill -0 "$(cat "$RUN/$s.pid")" 2>/dev/null; then
      printf '%-12s \033[32mRUNNING\033[0m\n' "$s"
    else
      printf '%-12s \033[31mSTOPPED\033[0m\n' "$s"
    fi
  done
  show_url
}

case "${1:-}" in
  install)     install_all ;;
  install-gpu) install_gpu ;;
  start)       start_all ;;
  stop)        stop_all ;;
  restart)     stop_all; sleep 1; start_all ;;
  status)      status ;;
  url)         show_url ;;
  gpu)         gpu_check ;;
  logs)        tail -n 50 -f "$LOG/${2:-cloudflared}.log" ;;
  *) echo "Dùng: $0 {install|install-gpu|start|stop|restart|status|url|gpu|logs [xvnc|desktop|novnc|cloudflared]}"; exit 1 ;;
esac
