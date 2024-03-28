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
   * This buffer is (width * height * 4) bytes long.
   */
  uint8_t *rgba_buf;
  // Width of the in pixels.
  size_t width;
  // Height in pixels.
  size_t height;
} ImageData;

/**
 * Destroy a frame.
 */
void deinit_imagedata(ImageData *frame);

/**
 * A frame in video format.
 */
typedef struct {
  ImageData image;
  float duration_in_ms;
} Frame;

/**
 * De-initialize a new frame.
 * Releases all internally held references in the frame.
 */
void deinit_frame(Frame *frame);

/**
 * Dellocate a frame.  The frame pointer will be set to NULL.
 */
void free_frame(Frame **frame);

// Represents a screen region to be captured.
typedef struct CaptureRect {
  double topleft_x;
  double topleft_y;
  double width;
  double height;
} CaptureRect;

typedef struct ScreenCapture ScreenCapture;

// A callback function to process a captured frame.
typedef void (*ProcessFrameFn)(Frame frame, void *other_data);

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
ImageData grab_screen(ScreenCapture *capture, const CaptureRect *rect);

/**
 * free any resources associated with the ScreenCapture object.
 */
void deinit_capture(ScreenCapture *capture);
