#!/bin/bash
clang \
  -fobjc-arc -framework AVFoundation \
  -framework Foundation -framework CoreVideo -framework CoreMedia  \
  -framework CoreGraphics -framework ImageIO -framework CoreServices \
  -framework AppKit -framework CoreImage -framework ScreenCaptureKit \
  screencap.m  main.m -o hello
