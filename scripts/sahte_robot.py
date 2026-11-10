#!/usr/bin/env python3
"""HDRG100 sahte robot: gerçek robot yokken mobil uygulamayı denemek için.

Robotun gönderdiği JSON telemetrinin aynısını UDP ile yollar ve uygulamadan
gelen HELLO / RESET:<n> mesajlarını işler.

Kullanım:
    python3 scripts/sahte_robot.py            # 4211 portunu dinler
    python3 scripts/sahte_robot.py --port 4210

Telemetri uygulamanın dinlediği 4210 portuna gider: istemci HELLO gönderdiyse doğrudan
ona, göndermediyse 127.0.0.1'e ve yayın adresine. Ana uygulama iOS Simulator'da aynı Mac'te
çalışırken ek ayar gerekmez; uygulama komutlarını 192.168.4.1'e gönderdiği için RESET bu
betiğe ulaşmaz ve sıfırlama uygulama tarafında yapılır. Robot adresi girilebilen bir
istemcide adres 127.0.0.1, port 4211 olmalı (4210'u uygulamanın kendisi dinler).

Klavye (harfi yazıp Enter'a bas):
    w ileri   s geri   a sola   d sağa   x dur
    k kutu düştü/yerine kondu   c istasyona kenetlen/ayrıl
    f devril/kalk   q çıkış
"""
import argparse
import json
import math
import random
import socket
import threading
import time

APP_PORT = 4210


class SahteRobot:
    def __init__(self):
        self.lock = threading.Lock()
        self.seq = 0
        self.cmd = "STOP"
        self.pitch = 0.0
        self.dist = 0.0
        self.yaw = 0.0
        self.bat = 92.0
        self.box = 1
        self.dock = 0
        self.dock_time = 0.0
        self.fallen = False
        self.rst = 0
        self.client = None
        self.client_seen = 0.0

    def step(self, dt):
        with self.lock:
            speed = {"FWD": 0.20, "BWD": -0.20}.get(self.cmd, 0.0)
            turn = {"RIGHT": 60.0, "LEFT": -60.0}.get(self.cmd, 0.0)
            if self.fallen:
                self.pitch = 62.0
                return
            if self.dock:
                speed, turn = 0.0, 0.0
            self.dist += speed * dt
            self.yaw += turn * dt
            lean = 2.5 if speed > 0 else (-2.5 if speed < 0 else 0.0)
            wobble = 0.8 * math.sin(time.time() * 3.1) + random.uniform(-0.3, 0.3)
            self.pitch = lean + wobble
            charging = self.dock and time.time() - self.dock_time > 1.5
            self.bat = min(100.0, self.bat + 0.05) if charging else max(0.0, self.bat - 0.002)

    def packet(self):
        with self.lock:
            self.seq += 1
            charging = 1 if self.dock and time.time() - self.dock_time > 1.5 else 0
            cmd = "DOCK" if self.dock else self.cmd
            return json.dumps({
                "seq": self.seq, "pitch": round(self.pitch, 1), "bat": int(self.bat),
                "chg": charging, "dock": self.dock, "box": self.box,
                "dist": round(self.dist, 3), "yaw": round(self.yaw, 1),
                "rst": self.rst, "cmd": cmd,
            }, separators=(",", ":"))


def listen(sock, robot):
    while True:
        try:
            data, addr = sock.recvfrom(256)
        except OSError:
            return
        text = data.decode(errors="ignore").strip()
        with robot.lock:
            robot.client = addr[0]
            robot.client_seen = time.time()
            if text.startswith("RESET"):
                token = int(text.split(":")[1]) if ":" in text else 0
                if token != robot.rst:
                    robot.dist = 0.0
                    robot.yaw = 0.0
                    robot.rst = token
                    print(f"  <- RESET:{token} (mesafe ve dönüş sıfırlandı)")


def send_loop(sock, robot):
    while True:
        robot.step(0.5)
        msg = robot.packet().encode()
        with robot.lock:
            client = robot.client if time.time() - robot.client_seen < 5 else None
        targets = [(client, APP_PORT)] if client else [("127.0.0.1", APP_PORT), ("255.255.255.255", APP_PORT)]
        for t in targets:
            try:
                sock.sendto(msg, t)
            except OSError:
                pass
        time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser(description="HDRG100 sahte robot")
    ap.add_argument("--port", type=int, default=4211, help="robotun dinlediği port (varsayılan 4211)")
    args = ap.parse_args()

    robot = SahteRobot()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", args.port))

    threading.Thread(target=listen, args=(sock, robot), daemon=True).start()
    threading.Thread(target=send_loop, args=(sock, robot), daemon=True).start()

    print(f"Sahte robot hazır: {args.port} portunu dinliyor, telemetriyi {APP_PORT} portuna 2 Hz gönderiyor.")
    print("Komutlar: w/s/a/d/x hareket, k kutu, c istasyon, f devril, q çıkış")
    keys = {"w": "FWD", "s": "BWD", "a": "LEFT", "d": "RIGHT", "x": "STOP"}
    while True:
        try:
            key = input().strip().lower()
        except EOFError:
            break
        with robot.lock:
            if key in keys:
                robot.cmd = keys[key]
                print(f"  komut: {robot.cmd}")
            elif key == "k":
                robot.box = 0 if robot.box else 1
                print(f"  kutu: {'yerinde' if robot.box else 'DÜŞTÜ'}")
            elif key == "c":
                robot.dock = 0 if robot.dock else 1
                robot.dock_time = time.time()
                robot.cmd = "STOP"
                print(f"  istasyon: {'kenetlendi (şarj 1,5 sn sonra başlar)' if robot.dock else 'ayrıldı'}")
            elif key == "f":
                robot.fallen = not robot.fallen
                print(f"  robot: {'DEVRİLDİ' if robot.fallen else 'dik'}")
            elif key == "q":
                break
            else:
                print(f"  bilinmeyen tuş, son paket: {robot.packet()}")


if __name__ == "__main__":
    main()
