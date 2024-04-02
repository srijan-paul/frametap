#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// Represents a screen region to be captured.
typedef struct CaptureRect {
  double topleft_x;
  double topleft_y;
  double width;
  double height;
} CaptureRect;

typedef struct ScreenCapture ScreenCapture;

// A callback function to process a captured frame.
typedef void (*ProcessFrameFn)(
    uint8_t *base_addr, size_t width, size_t height, size_t bytes_per_row,
    void *other_data
);

// A frame processor function along with any context it may need.
typedef struct FrameProcessor {
  ProcessFrameFn process_fn;
  // This data will be platform specific.
  void *other_data;
} FrameProcessor;

/**
 * Allocates a new ScreenCapture object.
 */
ScreenCapture *alloc_capture();

/**
 * Initializes the screen capture object.
 * `capture`: Pointer to an uninitialized ScreenCapture object.
 * `rect`: The region of the screen to capture. NULL if entire screen.
 * `on_frame`: The function to call when a frame is captured.
 */
void init_capture(
    ScreenCapture *capture, CaptureRect rect, FrameProcessor on_frame
);

/**
 * Starts capturing the screen.
 * `capture`: the ScreenCapture object to start capturing.
 */
bool start_capture(ScreenCapture *capture);

/**
 * Starts capturing the screen and waits for the capture to finish.
 * `capture`: the ScreenCapture object to start capturing.
 */
bool start_capture_and_wait(ScreenCapture *capture);

/**
 * `capture`: The screen capture object.
 */
void stop_capture(ScreenCapture *capture);

/**
 * free any resources associated with the ScreenCapture object.
 */
bool deinit_capture(ScreenCapture *capture);
