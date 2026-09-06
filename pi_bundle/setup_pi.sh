#!/bin/bash
# Turnkey setup script for Raspberry Pi
set -e

echo "======================================================="
echo "  NeuroBridge Asha — Raspberry Pi Setup Script"
echo "======================================================="

echo "[1/3] Updating system package lists..."
sudo apt update

echo "[2/3] Installing Python dependencies (OpenCV, WebSockets)..."
sudo apt install -y python3-opencv python3-websockets python3-numpy python3-pip

echo "[3/3] Testing camera detection..."
python3 camera_test.py

echo ""
echo "======================================================="
echo "  Setup Complete! To start the server, run:"
echo "      python3 neurobridge_pi_server.py"
echo "======================================================="
