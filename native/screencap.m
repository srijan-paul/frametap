#import "screencap.h"
#import "types.h"
#include <CoreMedia/CoreMedia.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>

void add_frame(ScreenCapture *sc, CMTime time, ImageData image);

@implementation OutputProcessor

- (instancetype)init:(struct ScreenCapture *)sc
     onFrameReceived:(FrameProcessor)processFn {
  self = [super init];
  self.sc = sc;
  self.frame_processor = processFn;
  return self;
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {

  assert(sampleBuffer != nil);

  CFRetain(sampleBuffer);
  if (type != SCStreamOutputTypeScreen) {
    CFRelease(sampleBuffer);
    return;
  }

  if (self.sc->should_stop_capture) {
    CFRelease(sampleBuffer);
    dispatch_semaphore_signal(self.sc->capture_done);
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

  if (pixelBuffer == NULL) {
    CFRelease(sampleBuffer);
    // dropped frames!? why does this happen.
    return;
  }

    // Lock the base address of the pixel buffer
  CVReturn const ok =
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  if (ok != kCVReturnSuccess) {
    CFRelease(sampleBuffer);
    return;
  }

  uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t const bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
  size_t const width = CVPixelBufferGetWidth(pixelBuffer);
  size_t const height = CVPixelBufferGetHeight(pixelBuffer);

  // copy the bytes within the bounds of sc->region.
  size_t outWidth = width, outHeight = height;
  size_t x = 0, y = 0;
  if (self.sc->region != nil) {
    CaptureRect const *rect = self.sc->region;
    x = rect->topleft_x;
    y = rect->topleft_y;
    outWidth = rect->width;
    outHeight = rect->height;
  } else {
    outWidth = width;
    outHeight = height;
  }

  uint8_t *outputBuf = malloc(outWidth * outHeight * 4);
  assert(outputBuf != nil);

  for (size_t i = 0; i < outHeight; i++) {
    for (size_t j = 0; j < outWidth; j++) {
      size_t const inIdx = ((i + y) * width + (j + x)) * 4;
      size_t const outIdx = (i * outWidth + j) * 4;
      memcpy(outputBuf + outIdx, baseAddress + inIdx, 4);
    }
  }

  // If the user provided a callback function to process the frame, call it.
  if (self.sc->has_frame_processor) {
    ImageData image = {
        .rgba_buf = outputBuf,
        .width = outWidth,
        .height = outHeight,
    };
    CMTime timeOfCapture = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    add_frame(self.sc, timeOfCapture, image);
  } else {
    free(outputBuf);
  }

  // Unlock the pixel buffer
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  CFRelease(sampleBuffer);
}
@end

ScreenCapture *alloc_capture() {
  ScreenCapture *sc = malloc(sizeof(ScreenCapture));
  return sc;
}

void init_capture(ScreenCapture *sc) {
  sc->region = nil; // capture entire screen by default.
  sc->has_frame_processor = false;
  sc->should_stop_capture = false;
  sc->displayID = CGMainDisplayID();
  sc->display = nil;
  sc->error = nil;
  sc->conf = nil;
  sc->stream = nil;
  sc->processor = nil;
  sc->filter = nil;
  sc->capture_done = dispatch_semaphore_create(0);
  sc->capture_time = kCMTimeZero;
}

void add_frame(ScreenCapture *sc, CMTime time, ImageData image) {
  // In the first call to `add_frame`, capture_time is kCMTimeZero.
  // For all subsequent calls, it will be the time at which the previous frame
  // was captured. So we can calculate the duration of the current frame by
  // subtracting `sc->capture_time` from `time`.
  if (CMTimeCompare(sc->capture_time, kCMTimeZero) != 0) {
    CMTime duration = CMTimeSubtract(time, sc->capture_time);
    Frame frame = {
        .image = sc->current_frame_image,
        .duration_in_ms = CMTimeGetSeconds(duration) * 1000,
    };
    sc->frame_processor.process_fn(frame, sc->frame_processor.other_data);
    deinit_imagedata(&frame.image);
  }

  sc->capture_time = time;
  sc->current_frame_image = image;
}

void set_on_frame_handler(ScreenCapture *sc, FrameProcessor processor) {
  sc->frame_processor = processor;
  sc->has_frame_processor = true;
}

void set_capture_region(ScreenCapture *sc, CaptureRect rect) {
  sc->region = malloc(sizeof(CaptureRect));
  memcpy(sc->region, &rect, sizeof(CaptureRect));
}

bool setup_screen_capture(ScreenCapture *sc, SCShareableContent *content) {
  sc->displayID = CGMainDisplayID();
  sc->displays = [content displays];

  for (SCDisplay *d in sc->displays) {
    if ([d displayID] == sc->displayID) {
      sc->display = d;
    }
  }

  if (sc->display == nil) {
    sc->error =
        [NSError errorWithDomain:@"ScreenCapture"
                            code:1
                        userInfo:@{
                          NSLocalizedDescriptionKey : @"Main display not found."
                        }];
    return false;
  }

  NSArray<SCWindow *> *windows = [content windows];
  sc->filter = [[SCContentFilter alloc] initWithDisplay:sc->display
                                       includingWindows:windows];

  sc->conf = [[SCStreamConfiguration alloc] init];
  [sc->conf setPixelFormat:'BGRA'];
  [sc->conf setCapturesAudio:NO];
  [sc->conf setShowsCursor:YES];
  [sc->conf setMinimumFrameInterval:CMTimeMake(1, 60)];

  // If the user has provided a region to capture, capture only that area.
  if (sc->region != nil) {
    const CaptureRect *rect = sc->region;
    // const CGFloat bottom_left_y = rect->topleft_y + rect->height;
    // const CGFloat bottom_left_x = rect->topleft_x;
    CGRect cg_rect =
        CGRectMake(rect->topleft_x, rect->topleft_y, rect->width, rect->height);
  }

  sc->stream = [[SCStream alloc] initWithFilter:sc->filter
                                  configuration:sc->conf
                                       delegate:nil];

  sc->processor = [[OutputProcessor alloc] init:sc
                                onFrameReceived:sc->frame_processor];
  NSError *err = nil;
  bool const ok = [sc->stream addStreamOutput:sc->processor
                                         type:SCStreamOutputTypeScreen
                           sampleHandlerQueue:nil
                                        error:&err];

  if (!ok) {
    sc->error = err;
    return false;
  }

  sc->capture_done = dispatch_semaphore_create(0);
  return true;
}

static bool start_screen_capture(ScreenCapture *sc) {
  dispatch_semaphore_t capture_started = dispatch_semaphore_create(0);
  [sc->stream startCaptureWithCompletionHandler:^(NSError *_Nullable error) {
    if (error != nil) {
      sc->error = error;
      dispatch_semaphore_signal(capture_started);
      return;
    }

    dispatch_semaphore_signal(capture_started);
  }];

  if (sc->error != nil) {
    return false;
  }

  dispatch_semaphore_wait(capture_started, DISPATCH_TIME_FOREVER);
  return true;
}

typedef void (^ShareableContentCompletionHandler)(
    SCShareableContent *content, NSError *error
);

bool start_capture(ScreenCapture *sc) {
  // If the user hasn't provided a callback function to process frames,
  // there isn't any point in starting a live screen capture.
  if (!sc->has_frame_processor) {
    return false;
  }

  dispatch_semaphore_t sharable_content_available =
      dispatch_semaphore_create(0);

  __block bool ok = true;
  __block SCShareableContent *content = nil;
  ShareableContentCompletionHandler handler =
      ^(SCShareableContent *shareableContent, NSError *err) {
        ok = err == nil;
        if (!ok) {
          sc->error = err;
        }

        content = shareableContent;
        [content retain];
        dispatch_semaphore_signal(sharable_content_available);
      };

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:YES
                                               completionHandler:handler];

  dispatch_semaphore_wait(sharable_content_available, DISPATCH_TIME_FOREVER);
  dispatch_release(sharable_content_available);

  if (!ok) {
    return false;
  }

  if (!(ok = setup_screen_capture(sc, content))) {
    dispatch_semaphore_signal(sc->capture_done);
    return false;
  }

  if (!(ok = start_screen_capture(sc))) {
    dispatch_semaphore_signal(sc->capture_done);
    return false;
  }

  return ok;
}

bool start_capture_and_wait(ScreenCapture *capture) {
  if (!start_capture(capture)) {
    return false;
  }
  dispatch_semaphore_wait(capture->capture_done, DISPATCH_TIME_FOREVER);
  return true;
}

void stop_capture(ScreenCapture *sc) {
  dispatch_semaphore_signal(sc->capture_done);
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  [sc->stream stopCaptureWithCompletionHandler:^(NSError *_Nullable error) {
    if (error != nil) {
      sc->error = error;
    }
    dispatch_semaphore_signal(finished);
  }];
  sc->should_stop_capture = true;
  dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
}

ImageData grab_screen(ScreenCapture *sc, const CaptureRect *rect) {
  // Determine capture bounds
  CGRect captureBounds;
  if (rect == NULL) {
    if (sc->region) {
      const CaptureRect *const region = sc->region;
      captureBounds = CGRectMake(
          region->topleft_x, region->topleft_y, region->width, region->height
      );
    } else {
      captureBounds = CGDisplayBounds(sc->displayID);
    }
  } else {
    // Use the provided rect for capture bounds
    captureBounds =
        CGRectMake(rect->topleft_x, rect->topleft_y, rect->width, rect->height);
  }

  CGImageRef image = CGDisplayCreateImageForRect(sc->displayID, captureBounds);
  // TODO: handle this case. Image can be NULL, when displayID is invalid.
  assert(image != nil);

  // Prepare to create a bitmap context to draw the image on.
  size_t const width = CGImageGetWidth(image);
  size_t const height = CGImageGetHeight(image);
  size_t const bytesPerRow = CGImageGetBytesPerRow(image);
  size_t const bitsPerComponent = 8; // 8-bit per color channel.
  size_t const bytesPerPixel = 4;    // 4 bytes per pixel (RGBA)

  // Intuition says that bytes per row = width in pixels * bytes per pixel.
  // This isn't always true, however.
  // Sometimes, bytesPerRow =/= width * bytesPerPixel.
  // This is because the macOS might add padding bytes to each row.
  size_t const expectedBytesPerRow = width * bytesPerPixel;
  size_t const paddingPerRow = bytesPerRow - (width * bytesPerPixel);
  size_t const bufferLength = (bytesPerRow - paddingPerRow) * height;
  assert(bytesPerRow - paddingPerRow == width * bytesPerPixel);

  uint8_t *pixelData = (uint8_t *)malloc(bufferLength);
  CGContextRef context = CGBitmapContextCreate(
      pixelData, width, height, bitsPerComponent, expectedBytesPerRow,
      CGImageGetColorSpace(image), CGImageGetBitmapInfo(image)
  );

  CGRect const dstRect = CGRectMake(0, 0, width, height);
  // Draw the image into the bitmap context
  CGContextDrawImage(context, dstRect, image);

  // TODO: handle this case.
  assert(pixelData != NULL);

  // TODO: is it possible to directly get RGBA data?
  // The format will be BGRA, but we want RGBA.
  uint8_t *outputBuf = malloc(bufferLength);
  for (size_t i = 0; i < bufferLength; i += bytesPerPixel) {
    uint8_t b = pixelData[i];
    uint8_t g = pixelData[i + 1];
    uint8_t r = pixelData[i + 2];
    uint8_t a = pixelData[i + 3];

    outputBuf[i] = r;
    outputBuf[i + 1] = g;
    outputBuf[i + 2] = b;
    outputBuf[i + 3] = a;
  }

  // Now, bitmapData contains the image in RGBA format
  // Construct the Frame object
  ImageData frame;
  frame.rgba_buf = outputBuf;
  frame.width = width;
  frame.height = height;

  CGContextRelease(context);
  CGImageRelease(image);
  free(pixelData);

  return frame;
}

void deinit_imagedata(ImageData *frame) {
  assert(frame != nil);

  if (frame->rgba_buf != nil) {
    free(frame->rgba_buf);
  }

  frame->rgba_buf = nil;
}

void deinit_frame(Frame *frame) {
  if (frame->image.rgba_buf != nil) {
    free(frame->image.rgba_buf);
  }
}

void free_frame(Frame **frame_p) {
  if (frame_p == nil)
    return;

  Frame *frame = *frame_p;
  if (frame == nil)
    return;

  if (frame->image.rgba_buf != nil) {
    free(frame->image.rgba_buf);
  }

  free(frame);
  *frame_p = nil;
}

// not much to do on MacOS with ARC enabled :)
void deinit_capture(ScreenCapture *sc) {
  if (sc == nil) {
    return;
  }

  if (sc->region != nil) {
    free(sc->region);
  }
}
