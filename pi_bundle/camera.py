#!/usr/bin/env python3
"""
Camera test & capture tool for Raspberry Pi
Auto-detects USB webcam (/dev/video1 or /dev/video0) or NoIR CSI camera.
"""
import cv2
import sys
import os

def find_working_camera():
    for index in [1, 0, 2]:
        cap = cv2.VideoCapture(index)
        if cap.isOpened():
            ret, frame = cap.read()
            if ret and frame is not None and frame.size > 0:
                print(f"[✓] Successfully opened camera at index /dev/video{index}")
                return cap, index
            cap.release()
    return None, None

def main():
    target_idx = 1
    if len(sys.argv) > 1:
        try:
            target_idx = int(sys.argv[1])
        except ValueError:
            pass

    print(f"Trying camera index {target_idx}...")
    cap = cv2.VideoCapture(target_idx)
    if not cap.isOpened() or not cap.read()[0]:
        print(f"[!] Index {target_idx} failed, scanning for available cameras...")
        cap, target_idx = find_working_camera()

    if cap is None:
        print("[ERROR] No working camera found. Check connections with 'ls /dev/video*'.")
        sys.exit(1)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    print(f"\n--- Camera Running (/dev/video{target_idx}) ---")
    print("Keys: [S] = Save capture.jpg | [Q] = Quit\n")

    has_gui = bool(os.environ.get("DISPLAY"))
    count = 0

    while True:
        ret, frame = cap.read()
        if not ret or frame is None:
            print("[!] Failed to grab frame.")
            break

        count += 1
        if has_gui:
            cv2.imshow("NeuroBridge Camera", frame)
            key = cv2.waitKey(1) & 0xFF
            if key == ord('s'):
                cv2.imwrite("capture.jpg", frame)
                print("[✓] Saved capture.jpg")
            elif key == ord('q'):
                break
        else:
            if count % 30 == 0:
                cv2.imwrite("capture.jpg", frame)
                print(f"[✓] Frame {count} captured (saved capture.jpg)")
                print("Press Ctrl+C to stop.")

    cap.release()
    if has_gui:
        cv2.destroyAllWindows()
    print("Camera released.")

if __name__ == "__main__":
    main()
