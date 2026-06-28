#!/usr/bin/env python3
"""
Minimal UART boot-console logger for the Banana Pi BPI-M4 (works for any board with
a serial debug header). Reads the serial port and tees raw bytes to BOTH stdout and a
log file, so you can watch the boot live AND keep a transcript to grep afterwards.

Banana Pi BPI-M4 debug console settings: 115200 8N1 (8 data bits, no parity, 1 stop).
There is no "try other bauds" dance on this board -- it is always 115200.

Usage:
    python3 uart-logger.py [device] [baud] [logfile]

Defaults:
    device  = first /dev/cu.usbserial-* (macOS) or /dev/ttyUSB0 (Linux), autodetected
    baud    = 115200
    logfile = ./uart.log

Examples:
    python3 uart-logger.py                                  # autodetect, 115200
    python3 uart-logger.py /dev/cu.usbserial-A50285BI       # explicit device
    python3 uart-logger.py /dev/ttyUSB0 115200 boot.log

Requires pyserial:  pip install pyserial

NOTE: garbage at EVERY baud rate is almost always a loose GND, not a wrong baud. Check
the common ground wire FIRST, then that TX<->RX aren't swapped, then baud (115200 here).
"""
import sys
import glob

try:
    import serial  # pyserial
except ImportError:
    sys.exit("pyserial not installed. Run: pip install pyserial")


def autodetect():
    for pat in ("/dev/cu.usbserial-*", "/dev/tty.usbserial-*",
                "/dev/ttyUSB*", "/dev/ttyACM*"):
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]
    sys.exit("No serial adapter found. Pass the device explicitly: "
             "uart-logger.py /dev/cu.usbserial-XXXX")


def main():
    dev = sys.argv[1] if len(sys.argv) > 1 else autodetect()
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
    logpath = sys.argv[3] if len(sys.argv) > 3 else "uart.log"

    print(f"[uart-logger] {dev} @ {baud} 8N1 -> {logpath}  (Ctrl-C to stop)",
          file=sys.stderr)
    ser = serial.Serial(dev, baud, timeout=1)
    with open(logpath, "ab", buffering=0) as f:
        while True:
            data = ser.read(4096)
            if data:
                f.write(data)
                sys.stdout.buffer.write(data)
                sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
