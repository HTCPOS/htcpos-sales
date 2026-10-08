#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  HTC POS - Camera bridge setup (Android machine / Termux)
#  Run once with:
#    curl -sL https://raw.githubusercontent.com/HTCPOS/htcpos-sales/main/setup.sh | bash
#  Safe to re-run: it overwrites the server + boot files cleanly.
# ============================================================
set -e

CAM_DIR="$HOME/cam"
BOOT_DIR="$HOME/.termux/boot"
CONF="$CAM_DIR/camsrv.conf"
PY="$CAM_DIR/camsrv.py"
RUN="$CAM_DIR/run.sh"
PREFIX_BIN="$PREFIX/bin"

echo "==================================================="
echo "   HTC POS - Camera bridge installer"
echo "==================================================="
mkdir -p "$CAM_DIR" "$BOOT_DIR"

# ---------- 1) packages ----------
echo
echo ">> [1/6] Checking packages (python, ffmpeg, curl)..."
pkg install -y python ffmpeg curl >/dev/null 2>&1 || true
pip install --quiet requests >/dev/null 2>&1 || pip install requests || true

# ---------- 2) cloudflared ----------
echo ">> [2/6] Installing cloudflared..."
if [ ! -x "$PREFIX_BIN/cloudflared" ]; then
  # armeabi-v7a machine -> 32-bit arm build
  curl -sL -o "$PREFIX_BIN/cloudflared" \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm
  chmod +x "$PREFIX_BIN/cloudflared"
fi
echo "   cloudflared ready."

# ---------- 3) secrets (asked once, kept only on this machine) ----------
echo
echo ">> [3/6] Settings (stored ONLY on this machine, not on GitHub)."
if [ -f "$CONF" ]; then
  echo "   Found existing settings at $CONF - keeping them."
  echo "   (delete that file and re-run if you want to change them)"
else
  # defaults
  DEF_DVR_IP="192.168.0.100"
  DEF_DVR_USER="htcpos"
  DEF_TZ_OFFSET="2"     # Libya = UTC+2
  DEF_FB="https://htcpos-6f17b-default-rtdb.europe-west1.firebasedatabase.app"
  DEF_APIKEY="AIzaSyBVvW-gB2p0MR85iXgyE35flEfbusrgn0Y"
  DEF_EMAIL="htcstore100@gmail.com"

  read -p "   DVR IP [$DEF_DVR_IP]: " DVR_IP;        DVR_IP=${DVR_IP:-$DEF_DVR_IP}
  read -p "   DVR username [$DEF_DVR_USER]: " DVR_USER; DVR_USER=${DVR_USER:-$DEF_DVR_USER}
  read -p "   DVR password for '$DVR_USER': " DVR_PASS
  while [ -z "$DVR_PASS" ]; do read -p "   DVR password (required): " DVR_PASS; done

  read -p "   Camera access code for the app [htc-cam-k7m2]: " CAM_CODE
  CAM_CODE=${CAM_CODE:-htc-cam-k7m2}

  read -p "   Firebase email [$DEF_EMAIL]: " FB_EMAIL; FB_EMAIL=${FB_EMAIL:-$DEF_EMAIL}
  read -p "   Firebase password for '$FB_EMAIL': " FB_PASS
  while [ -z "$FB_PASS" ]; do read -p "   Firebase password (required): " FB_PASS; done

  umask 077
  cat > "$CONF" <<EOF
DVR_IP=$DVR_IP
DVR_USER=$DVR_USER
DVR_PASS=$DVR_PASS
CAM_CODE=$CAM_CODE
TZ_OFFSET=$DEF_TZ_OFFSET
FB_URL=$DEF_FB
FB_APIKEY=$DEF_APIKEY
FB_EMAIL=$FB_EMAIL
FB_PASS=$FB_PASS
PORT=8787
EOF
  chmod 600 "$CONF"
  echo "   Saved settings (permissions 600)."
fi

# ---------- 4) the server ----------
echo ">> [4/6] Writing camera server..."
cat > "$PY" <<'PYEOF'
#!/data/data/com.termux/files/usr/bin/python
# HTC POS camera bridge: serves a short HLS clip of the DVR archive,
# starting at the minute of an invoice. One ffmpeg job at a time.
import os, sys, time, json, signal, shutil, subprocess, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
CAMDIR = os.path.join(HOME, "cam")
CONF = os.path.join(CAMDIR, "camsrv.conf")
HLS = os.path.join(CAMDIR, "hls")

def load_conf():
    c = {}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1); c[k] = v
    return c

CF = load_conf()
PORT = int(CF.get("PORT", "8787"))
TZ = int(CF.get("TZ_OFFSET", "2"))
CLIP_SECONDS = int(CF.get("CLIP_SECONDS", "180"))   # طول المقطع المسجّل لكل مشاهدة (ثانية)
CODE = CF.get("CAM_CODE", "")
DVR_IP = CF["DVR_IP"]; DVR_USER = CF["DVR_USER"]; DVR_PASS = CF["DVR_PASS"]

# channel map: app sends cam=1..4 -> DVR channel 101/201/301/401 (main stream)
def channel(cam):
    cam = int(cam)
    if cam < 1 or cam > 4: raise ValueError("cam 1..4")
    return cam * 100 + 1

_lock = threading.Lock()
_proc = {"p": None, "started": 0, "key": None}

def rtsp_url(ch, start_utc):
    # start_utc: "YYYYMMDDTHHMMSSZ"
    auth = "%s:%s" % (urllib.parse.quote(DVR_USER), urllib.parse.quote(DVR_PASS))
    return ("rtsp://%s@%s:554/Streaming/tracks/%d?starttime=%s"
            % (auth, DVR_IP, ch, start_utc))

def stop_ffmpeg():
    p = _proc["p"]
    if p and p.poll() is None:
        try: p.send_signal(signal.SIGINT); p.wait(timeout=5)
        except Exception:
            try: p.kill()
            except Exception: pass
    _proc["p"] = None; _proc["key"] = None

def start_ffmpeg(ch, start_utc, key):
    stop_ffmpeg()
    if os.path.isdir(HLS): shutil.rmtree(HLS, ignore_errors=True)
    os.makedirs(HLS, exist_ok=True)
    url = rtsp_url(ch, start_utc)
    # نسجّل مقطع محدود (CLIP_SECONDS) من الأرشيف كـ VOD HLS كامل (ما يحذف مقاطع) -> الآيفون
    # يحمّله ويشغّله بسلاسة مع شريط تقديم، وما يعلّق حتى لو النفق أبطأ من الشبكة المحلية.
    # نسخ مباشر (copy) لـ HEVC بدون تحويل - المعالج الضعيف ما يتعب.
    cmd = [
        "ffmpeg", "-nostdin", "-loglevel", "error",
        "-rtsp_transport", "tcp", "-i", url,
        "-t", str(CLIP_SECONDS),
        "-c", "copy", "-an",
        "-f", "hls", "-hls_time", "4", "-hls_list_size", "0",
        "-hls_playlist_type", "event",
        "-hls_flags", "append_list+independent_segments",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", os.path.join(HLS, "seg%d.m4s"),
        os.path.join(HLS, "index.m3u8"),
    ]
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _proc.update(p=p, started=time.time(), key=key)

# auto-stop watchdog: kill ffmpeg if no playlist request for 90s
_last_touch = {"t": time.time()}
def watchdog():
    while True:
        time.sleep(20)
        if _proc["p"] and (time.time() - _last_touch["t"] > 90):
            with _lock: stop_ffmpeg()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = u.path

        if path == "/health":
            self.send_response(200); self._cors()
            self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(b'{"ok":true}'); return

        # /play?code=..&cam=2&t=YYYYMMDDHHMMSS  (t = LOCAL time of the invoice)
        if path == "/play":
            if q.get("code",[""])[0] != CODE:
                self.send_response(403); self._cors(); self.end_headers()
                self.wfile.write(b"bad code"); return
            try:
                cam = q.get("cam",["2"])[0]; ch = channel(cam)
                t = q.get("t",[""])[0]
                if len(t) != 14: raise ValueError("t=YYYYMMDDHHMMSS")
                # نرسل الوقت المحلي زي ما هو + Z - نفس طريقة VLC اللي اتأكد إنها تشتغل 100%
                # على هذا الـ DVR (يتعامل مع وقت tracks كـ محلي، مش UTC). ما نطرح أي ساعات.
                import datetime
                datetime.datetime.strptime(t, "%Y%m%d%H%M%S")   # تحقق من الصيغة فقط
                start_utc = t[0:8] + "T" + t[8:14] + "Z"
                key = "%s-%s" % (ch, start_utc)
            except Exception as e:
                self.send_response(400); self._cors(); self.end_headers()
                self.wfile.write(str(e).encode()); return
            with _lock:
                if _proc["key"] != key or not _proc["p"] or _proc["p"].poll() is not None:
                    start_ffmpeg(ch, start_utc, key)
            _last_touch["t"] = time.time()
            self.send_response(200); self._cors()
            self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(b'{"hls":"/hls/index.m3u8"}'); return

        # serve HLS files
        if path.startswith("/hls/"):
            _last_touch["t"] = time.time()
            fn = os.path.join(HLS, os.path.basename(path))
            if not os.path.isfile(fn):
                # playlist may need a moment to appear
                for _ in range(25):
                    if os.path.isfile(fn): break
                    time.sleep(0.2)
            if not os.path.isfile(fn):
                self.send_response(404); self._cors(); self.end_headers(); return
            ct = "application/vnd.apple.mpegurl" if fn.endswith(".m3u8") else "video/mp4"
            data = open(fn,"rb").read()
            self.send_response(200); self._cors()
            self.send_header("Content-Type",ct)
            self.send_header("Content-Length",str(len(data))); self.end_headers()
            self.wfile.write(data); return

        self.send_response(404); self._cors(); self.end_headers()

if __name__ == "__main__":
    threading.Thread(target=watchdog, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print("camsrv on 127.0.0.1:%d" % PORT, flush=True)
    srv.serve_forever()
PYEOF
echo "   server written."

# ---------- 5) runner (server + tunnel + publish url to Firebase) ----------
echo ">> [5/6] Writing runner + boot autostart..."
cat > "$RUN" <<'RUNEOF'
#!/data/data/com.termux/files/usr/bin/bash
# keep awake, start server, open tunnel, push tunnel url to Firebase, keep alive.
CAM_DIR="$HOME/cam"
CONF="$CAM_DIR/camsrv.conf"
LOG="$CAM_DIR/run.log"
exec >>"$LOG" 2>&1
echo "=== boot $(date) ==="

termux-wake-lock || true

# load conf
set -a; . "$CONF"; set +a
PORT=${PORT:-8787}

# start the python server
pkill -f camsrv.py 2>/dev/null || true
python "$CAM_DIR/camsrv.py" &
sleep 3

get_token() {
  FB_EMAIL="$FB_EMAIL" FB_PASS="$FB_PASS" FB_APIKEY="$FB_APIKEY" python - <<'PY'
import os,json,urllib.request
d=json.dumps({"email":os.environ["FB_EMAIL"],"password":os.environ["FB_PASS"],"returnSecureToken":True}).encode()
u="https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key="+os.environ["FB_APIKEY"]
try:
  r=urllib.request.urlopen(urllib.request.Request(u,d,{"Content-Type":"application/json"}),timeout=20)
  print(json.load(r)["idToken"])
except Exception as e:
  print("")
PY
}

publish_url() {
  local URL="$1"
  local TOK; TOK=$(get_token)
  [ -z "$TOK" ] && { echo "no firebase token"; return; }
  FB_URL="$FB_URL" CAM_CODE="$CAM_CODE" python - "$URL" "$TOK" <<'PY'
import os,sys,json,time,urllib.request
url,tok=sys.argv[1],sys.argv[2]
body=json.dumps({"url":url,"code":os.environ["CAM_CODE"],"ts":time.time()}).encode()
u=os.environ["FB_URL"]+"/data/cameraBridge.json?auth="+tok
try:
  req=urllib.request.Request(u,body,{"Content-Type":"application/json"},method="PUT")
  urllib.request.urlopen(req,timeout=20); print("published:",url)
except Exception as e:
  print("publish failed:",e)
PY
}

# tunnel loop: if cloudflared dies or url changes, re-publish
while true; do
  # start a quick tunnel; capture its url from logs
  TUNLOG="$CAM_DIR/cf.log"; : > "$TUNLOG"
  cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" >"$TUNLOG" 2>&1 &
  CFPID=$!
  URL=""
  for i in $(seq 1 30); do
    URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNLOG" | head -n1)
    [ -n "$URL" ] && break
    sleep 2
  done
  if [ -n "$URL" ]; then publish_url "$URL"; else echo "no tunnel url"; fi
  # wait until cloudflared exits, then loop to get a fresh url
  wait $CFPID
  echo "tunnel died $(date), restarting in 5s"
  sleep 5
done
RUNEOF
chmod +x "$RUN"

# --- remote-control watcher: يراقب أوامر التطبيق في Firebase وينفّذ تحديث/إعادة تشغيل عن بُعد ---
cat > "$CAM_DIR/bridgectl.py" <<'CTLEOF'
#!/data/data/com.termux/files/usr/bin/python
# يراقب commands/bridgeUpdate كل 15 ثانية. action=restart يعيد تشغيل الجسر،
# action=update يحمّل آخر setup.sh ويشغّله (مع فحص سلامة). يكتب الحالة في data/bridgeStatus.
import os, time, json, subprocess, urllib.request
HOME = os.path.expanduser("~"); CAMDIR = os.path.join(HOME, "cam")
CONF = os.path.join(CAMDIR, "camsrv.conf")
SETUP_URL = "https://raw.githubusercontent.com/HTCPOS/htcpos-sales/main/setup.sh"
def conf():
    c = {}
    for line in open(CONF):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1); c[k] = v
    return c
CF = conf()
def token():
    try:
        d = json.dumps({"email": CF["FB_EMAIL"], "password": CF["FB_PASS"], "returnSecureToken": True}).encode()
        u = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" + CF["FB_APIKEY"]
        r = urllib.request.urlopen(urllib.request.Request(u, d, {"Content-Type": "application/json"}), timeout=20)
        return json.load(r)["idToken"]
    except Exception:
        return ""
def fb_get(path, tok):
    try: return json.load(urllib.request.urlopen(CF["FB_URL"] + "/" + path + ".json?auth=" + tok, timeout=20))
    except Exception: return None
def fb_put(path, obj, tok):
    try:
        body = json.dumps(obj).encode()
        req = urllib.request.Request(CF["FB_URL"] + "/" + path + ".json?auth=" + tok, body, {"Content-Type": "application/json"}, method="PUT")
        urllib.request.urlopen(req, timeout=20)
    except Exception: pass
def fb_del(path, tok):
    try:
        req = urllib.request.Request(CF["FB_URL"] + "/" + path + ".json?auth=" + tok, method="DELETE")
        urllib.request.urlopen(req, timeout=20)
    except Exception: pass
def status(tok, state, msg=""):
    fb_put("data/bridgeStatus", {"state": state, "msg": msg, "at": time.time()}, tok)
def do_restart(tok):
    status(tok, "working", "restart")
    subprocess.call("pkill -f 'cloudflared tunnel'; pkill -f camsrv.py; pkill -f cam/run.sh", shell=True)
    time.sleep(2)
    subprocess.Popen("setsid bash " + os.path.join(CAMDIR, "run.sh") + " >/dev/null 2>&1", shell=True)
    time.sleep(1); status(tok, "done", "restart")
def do_update(tok):
    status(tok, "working", "update")
    setup = os.path.join(HOME, "setup.sh")
    rc = subprocess.call("curl -sL " + SETUP_URL + " -o " + setup, shell=True)
    if rc != 0 or not os.path.exists(setup) or os.path.getsize(setup) < 500:
        status(tok, "error", "download failed"); return
    if subprocess.call("bash -n " + setup, shell=True) != 0:
        status(tok, "error", "bad script"); return
    status(tok, "done", "update started")
    # setsid عشان يكمل setup.sh حتى لو انقتل هذا المراقب أثناء إعادة التشغيل
    subprocess.Popen("setsid bash " + setup + " >/dev/null 2>&1", shell=True)
def main():
    seen = None
    while True:
        try:
            tok = token()
            if tok:
                cmd = fb_get("commands/bridgeUpdate", tok)
                if isinstance(cmd, dict) and cmd.get("id") and cmd.get("id") != seen:
                    seen = cmd.get("id"); action = cmd.get("action", "")
                    fb_del("commands/bridgeUpdate", tok)
                    if action == "restart": do_restart(tok)
                    elif action == "update": do_update(tok)
        except Exception: pass
        time.sleep(15)
if __name__ == "__main__":
    main()
CTLEOF

# boot entry (runs at device boot via Termux:Boot) - runner + watcher
cat > "$BOOT_DIR/10-camsrv.sh" <<BOOTEOF
#!/data/data/com.termux/files/usr/bin/bash
sleep 10
bash "\$HOME/cam/run.sh" >/dev/null 2>&1 &
python "\$HOME/cam/bridgectl.py" >/dev/null 2>&1 &
BOOTEOF
chmod +x "$BOOT_DIR/10-camsrv.sh"
echo "   runner + watcher + boot entry written."

# ---------- 6) start now ----------
echo ">> [6/6] Starting now..."
pkill -f "cloudflared tunnel" 2>/dev/null || true
pkill -f camsrv.py 2>/dev/null || true
pkill -f bridgectl.py 2>/dev/null || true
pkill -f "cam/run.sh" 2>/dev/null || true
sleep 1
nohup bash "$RUN" >/dev/null 2>&1 &
nohup python "$CAM_DIR/bridgectl.py" >/dev/null 2>&1 &
echo
echo "==================================================="
echo "   Done. The bridge is starting."
echo "   In ~30s the tunnel URL is written to Firebase at:"
echo "      data/cameraBridge"
echo "   Watch log:   tail -f ~/cam/run.log"
echo "==================================================="
