# Jif

> jif is a work in progress, and does not support all platforms just yet. Expect more in the days to come.

A cross platform screen capture library focused on performance, control, and image quality. 

## Why?

I want an app that'll let me capture my screen and control the compression, quantization, dithering, etc. of the resulting image/video content.
Surprisingly, there's nothing that can do all that on all three major OSes (well, except for FFMPEG – but that's a command line tool).

Hopefully, once the library is mature is mature enough, I'll be able to use it to build one that just works.
While I'm still figuring thngs out, you can try [LICECap](https://www.cockos.com/licecap/) — it's pretty solid!

## Goals

- Cross platform
  - **MacOS**: ScreenCaptureKit and CoreGraphics (AVFoundation at some point).
  - **Windows**: Win32 API.
  - **Linux**:  Figure something out with Wayland / dbus.
- Fast. Drop as few frames as possible.
- Control over parameters such as FPS, Quantization algorithm, dithering, etc.
