# Frametap 

> frametap is *very* early in development. Definitely do not use it just yet. 

A cross platform screen capture library for MacOS, Windows, and Linux.

Frametap can:
  - Deliver live frame information from your screen.
  - Capture GIFs.
  - Export frames as PNGs.

## Why?

I wanted a screen capture app that lets me control the compression, quantization, dithering, etc.
Surprisingly, there's nothing that can do all that on all three major OSes (well, except for FFMPEG – but that's a command line tool).

Hopefully, once the library is mature, I'll be able to use it to build such an app.
While I'm still figuring thngs out, you can try [LICECap](https://www.cockos.com/licecap/) — it's pretty solid!

## Goals

- Cross platform
  - **MacOS**: ScreenCaptureKit and CoreGraphics (AVFoundation at some point).
  - **Windows**: Win32 API.
  - **Linux**:  Figure something out with Wayland / dbus.
- Fast. Drop as few frames as possible.
- Control over parameters such as FPS, Quantization algorithm, dithering, etc.
