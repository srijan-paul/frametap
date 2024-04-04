#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Represents a single captured frame.
 */
typedef struct {
  /**
   * Color data for a single frame for the frame in RGBA format.
   */
  uint8_t *rgba_buf;
  /**
   * Size of the `rgba_buf` buffer. Always equal to width * height
   */
  size_t rgba_buf_size;
  size_t width;
  size_t height;
} Frame;

/**
 * Destroy a frame.
 */
void deinit_frame(Frame *frame);

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
 */
void init_capture(ScreenCapture *sc);

/**
 * Set a callback handler to process the captured frames.
 */
void set_on_frame_handler(ScreenCapture *sc, FrameProcessor processor);

/**
 * Set the region of the screen to capture.
 * If this function isn't called, the entire screen is captured by default.
 */
void set_capture_region(ScreenCapture *capture, CaptureRect rect);

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
 * Get an RGBA buffer from the current screen contents.
 */
Frame capture_frame(ScreenCapture *capture, const CaptureRect *rect);

/**
 * free any resources associated with the ScreenCapture object.
 */
void deinit_capture(ScreenCapture *capture);
