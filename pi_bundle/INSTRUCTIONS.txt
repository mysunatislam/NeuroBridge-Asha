# NeuroBridge Asha — Raspberry Pi Setup Bundle

This package contains everything needed to run the NeuroBridge Asha edge server and camera bridge on your Raspberry Pi (Model B, B+, 2, 3, 4, 5).

## Quick Start in 3 Steps:

### Step 1: Install Dependencies
Run the setup script:
```bash
chmod +x setup_pi.sh
./setup_pi.sh
```
*(Or install manually: `sudo apt install -y python3-opencv python3-websockets python3-numpy`)*

### Step 2: Test Camera
```bash
python3 camera_test.py
```
To test live window:
```bash
python3 camera.py
```

### Step 3: Start NeuroBridge Server
```bash
python3 neurobridge_pi_server.py
```

### Step 4: Connect from Phone / App
- **WebSocket URL**: `ws://<YOUR_PI_IP>:8765`
- **Pairing Code**: `123456` (or `asha-model-b-connect-2026`)
