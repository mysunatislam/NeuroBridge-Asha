# Raspberry Pi Model B Setup Guide (Legacy picamera & MMAL)

This guide is specifically tailored for **Raspberry Pi Model B / B+ / 2 / 3** running **Raspberry Pi OS (Buster or Bullseye)** with the classic **`picamera`** stack (not Bookworm / `picamera2`).

---

## 💡 Why This Setup is Special for Pi Model B

| Parameter | Standard (Pi 4 / 5 Bookworm) | Legacy Model B (Buster / Bullseye) |
| :--- | :--- | :--- |
| **CPU & Architecture** | Quad-core ARMv8 (64-bit) | Single-core 700MHz ARMv6 (32-bit) |
| **RAM** | 4GB - 8GB | 512MB RAM |
| **Camera Driver** | `libcamera` + `Picamera2` | Broadcom MMAL GPU + `picamera` |
| **Python Ecosystem** | Python 3.11+ | Python 3.7 / 3.9 |
| **Dependencies** | Requires Rust / heavy builds | **Zero-compile lightweight bridge** |

Because the repository is private and the Pi Model B has 512MB RAM, **you do not need to clone the private repository or compile heavy dependencies on the Pi.** We provide a standalone script `scripts/pi_legacy_bridge.py` that runs cleanly with zero heavy builds.

---

## Step 1: Enable the Camera in raspi-config

1. On your Raspberry Pi, open terminal and run:
   ```bash
   sudo raspi-config
   ```
2. Navigate to **Interface Options** -> **Legacy Camera** (or **Camera** on older Buster releases).
3. Select **Yes** (Enable).
4. Finish and **Reboot** when prompted.

### Verify the Camera Hardware
After reboot, verify the camera with:
```bash
vcgencmd get_camera
```
You should see:
```text
supported=1 detected=1
```

---

## Step 2: Install Pre-Compiled OS Packages

Install the pre-compiled packages directly from the official Raspberry Pi OS repositories (takes ~15 seconds, requires no compilation):

```bash
sudo apt update
sudo apt install -y python3-picamera python3-websockets
```

---

## Step 3: Copy the Bridge Script to Your Pi (No Git Clone Needed)

Since the repo is private, you can simply transfer the self-contained script from your Windows PC to the Pi using `scp`:

### From Windows PowerShell:
```powershell
scp C:\Users\Kotha\OneDrive\Documents\ChatGPT\Fingerspeak\scripts\pi_legacy_bridge.py pi@<YOUR_PI_IP>:~/pi_bridge.py
```
*(Replace `<YOUR_PI_IP>` with your Raspberry Pi's local IP address, e.g., `192.168.1.105`)*

*(Alternatively, you can open `nano ~/pi_bridge.py` on the Pi and paste the contents of `scripts/pi_legacy_bridge.py`.)*

---

## Step 4: Run the Edge Bridge

On your Raspberry Pi:

```bash
python3 ~/pi_bridge.py --pairing-code asha-model-b-connect-2026
```

You will see:
```text
================================================================
  NEUROBRIDGE ASHA — RASPBERRY PI MODEL B EDGE BRIDGE
  Bound Host:     ws://0.0.0.0:8765/v1/device/ws
  Subprotocol:    fingerspeak.device.v1
  Pairing Code:   asha-model-b-connect-2026
================================================================
Initializing legacy picamera (MMAL)...
✓ picamera active @ 640x480 (30 fps)
```

*(Note: To test without a physical camera attached, simply add `--no-camera`)*

---

## Step 5: Connect in the NeuroBridge Asha Mobile App

1. On your phone, open the **NeuroBridge Asha** app.
2. Go to **Setup & Settings** -> **Pair Wheelchair Raspberry Pi** (or tap the **Wheelchair Display** tab).
3. Enter your Pi's connection details:
   - **Pi IP / URL**: `ws://<YOUR_PI_IP>:8765/v1/device/ws`
   - **Pairing Code**: `asha-model-b-connect-2026`
4. Tap **Pair Wheelchair Unit**.
5. Once connected, the app status bar displays:
   - **Pi Power: 100%**
   - **Chair Batt: 98%**
   - **NoIR Cam: Active 30fps**

---

## Step 6: Test Dynamic Wheelchair Display Captions

Type any message in the app (e.g. `"You're not alone. Asha is right here with you."` or tap a quick chip like `"I need some help"`).

The Pi terminal immediately renders the dynamic caption:

```text
================================================================
                  💬 WHEELCHAIR DISPLAY CAPTION                 
        "You're not alone. Asha is right here with you."        
================================================================
```

---

## (Optional) Run Automatically on Boot (systemd service)

To have the bridge start automatically whenever the wheelchair Pi powers on:

Create `/etc/systemd/system/asha-edge.service`:
```bash
sudo nano /etc/systemd/system/asha-edge.service
```

Paste:
```ini
[Unit]
Description=NeuroBridge Asha Legacy Pi Edge Bridge
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi
ExecStart=/usr/bin/python3 /home/pi/pi_bridge.py --pairing-code asha-model-b-connect-2026
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable asha-edge
sudo systemctl start asha-edge
```
