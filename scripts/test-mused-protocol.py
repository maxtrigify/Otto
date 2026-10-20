#!/usr/bin/env python3
"""Compatibility wrapper: this script was renamed to test-ottod-protocol.py."""

import os
import sys

target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-ottod-protocol.py")
os.execv(sys.executable, [sys.executable, target, *sys.argv[1:]])
