#!/usr/bin/env python3
"""
Camera diagnostics script for Raspberry Pi.
Tests all video devices and prints status.
"""
import os
import sys

print("=" * 50)
print("  Raspberry Pi Camera Hardware Diagnostics")
print("=" * 50)

# Check video devices
video_devs = [f"/dev/{d}" for d in os.listdir("/dev") if d.startswith("video")]
print(f"Video devices found in /dev: {video_devs}")

try:
    import cv2
    print(f"[✓] OpenCV version: {cv2.__version__}")
    for idx in range(4):
        cap = cv2.VideoCapture(idx)
        if cap.isOpened():
            ret, frame = cap.read()
            if ret and frame is not None:
                h, w = frame.shape[:2]
                print(f"  --> /dev/video{idx}: WORKING ({w}x{h})")
            else:
                print(f"  --> /dev/video{idx}: Opened but cannot read frame")
            cap.release()
        else:
            print(f"  --> /dev/video{idx}: Not available")
except ImportError:
    print("[!] OpenCV (cv2) is not installed. Run: sudo apt install -y python3-opencv")

try:
    import picamera
    print("[✓] Legacy picamera (MMAL) library is available.")
except ImportError:
    print("[i] Legacy picamera library not loaded (using standard USB V4L2).")

print("=" * 50)
