#import "screencap.h"
#import "types.h"
#include <CoreGraphics/CGBitmapContext.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>

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
    // dropped frames!? why does this happen.
    return;
  }

  // Lock the base address of the pixel buffer
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t const bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
  size_t const width = CVPixelBufferGetWidth(pixelBuffer);
  size_t const height = CVPixelBufferGetHeight(pixelBuffer);

  self.frame_processor.process_fn(
      baseAddress, width, height, bytesPerRow, self.frame_processor.other_data
  );

  // Unlock the pixel buffer
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

ScreenCapture *alloc_capture() {
  ScreenCapture *sc = malloc(sizeof(ScreenCapture));
  return sc;
}

void init_capture(ScreenCapture *sc, FrameProcessor frame_processor) {
  sc->region = nil; // capture entire screen by default.
  sc->frame_processor = frame_processor;
  sc->should_stop_capture = false;
  sc->displayID = CGMainDisplayID();
  sc->display = nil;
  sc->error = nil;
  sc->conf = nil;
  sc->stream = nil;
  sc->processor = nil;
  sc->filter = nil;
  sc->capture_done = dispatch_semaphore_create(0);
}

void set_capture_region(ScreenCapture *capture, CaptureRect rect) {
  capture->region = malloc(sizeof(CaptureRect));
  memcpy(capture->region, &rect, sizeof(CaptureRect));
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
  [sc->conf setMinimumFrameInterval:kCMTimeZero];

  // If the user has provided a region to capture, capture only that area.
  const CaptureRect *rect = sc->region;
  if (rect != nil) {
    const CGFloat bottom_left_y = rect->topleft_y + rect->height;
    const CGFloat bottom_left_x = rect->topleft_x;
    CGRect cg_rect =
        CGRectMake(rect->topleft_x, rect->topleft_y, rect->width, rect->height);

    [sc->conf setSourceRect:cg_rect];
    [sc->conf setDestinationRect:cg_rect];
  }

  sc->stream = [[SCStream alloc] initWithFilter:sc->filter
                                  configuration:sc->conf
                                       delegate:nil];

  sc->processor = [[OutputProcessor alloc] init:sc
                                onFrameReceived:sc->frame_processor];
  NSError *err;
  bool ok = [sc->stream addStreamOutput:sc->processor
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
  dispatch_semaphore_t sharable_content_available =
      dispatch_semaphore_create(0);

  __block bool ok = true;
  __block SCShareableContent *content;
  ShareableContentCompletionHandler handler =
      ^(SCShareableContent *shareableContent, NSError *err) {
        ok = err == nil;
        if (!ok) {
          sc->error = err;
        }
        content = shareableContent;
        dispatch_semaphore_signal(sharable_content_available);
      };

  [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                             onScreenWindowsOnly:YES
                                               completionHandler:handler];

  dispatch_semaphore_wait(sharable_content_available, DISPATCH_TIME_FOREVER);

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

/**
 * Adjust `rect` to a coordinate space that has its origin bottom left corner.
 * `rect`: A rectangle with origin at the top left corner.
 * The CGRect that is returned has its origin and coordinate space adjusted to
 * fit MacOS's conventions.
 */
static CGRect transform_to_cg_coord_space(const CaptureRect *const rect) {
  CGFloat const display_height = CGDisplayPixelsHigh(CGMainDisplayID());

  // center x when seem from bottom left as the origin
  CGFloat const center_x = rect->topleft_x + rect->width / 2;
  // center y when seem from top left corner as the origin
  CGFloat const center_y_from_topleft = rect->topleft_y + rect->height / 2;
  CGFloat const center_y = display_height - center_y_from_topleft;

  return CGRectMake(center_x, center_y, rect->width, rect->height);
}

// TODO: add ability to not downscale on HiDPI displays.
Frame capture_frame(ScreenCapture *sc, const CaptureRect *rect) {
  // Determine capture bounds
  CGRect captureBounds;
  if (rect == NULL) {
    if (sc->region) {
      const CaptureRect *const region = sc->region;
      captureBounds = CGRectMake(
          region->topleft_x, region->topleft_y, region->width, region->height
      );
    }

    captureBounds = CGDisplayBounds(sc->displayID);
  } else {
    // Use the provided rect for capture bounds
    captureBounds = transform_to_cg_coord_space(rect);
  }

  // The original image will be scaled up to fit the HiDPI screen.
  CGImageRef bigImage =
      CGDisplayCreateImageForRect(sc->displayID, captureBounds);

  // Prepare to create a bitmap context for converting the image to RGBA, and
  // scaling it down.
  size_t const width = CGImageGetWidth(bigImage);
  size_t const height = CGImageGetHeight(bigImage);
  size_t const bitsPerComponent = 8;
  size_t const bytesPerPixel = 4;

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, CGRectGetWidth(captureBounds), CGRectGetHeight(captureBounds),
      bitsPerComponent, 0, colorSpace, CGImageGetBitmapInfo(bigImage)
  );

  // Draw the image into the bitmap context
  CGContextDrawImage(context, captureBounds, bigImage);

  size_t const finalWidth = CGBitmapContextGetWidth(context);
  size_t const finalHeight = CGBitmapContextGetHeight(context);

  assert(captureBounds.size.width == finalWidth);
  assert(captureBounds.size.height == finalHeight);

  size_t const bytesPerRow = CGBitmapContextGetBytesPerRow(context);
  size_t const bufferLength = bytesPerRow * finalHeight;
  uint8_t *pixelData = CGBitmapContextGetData(context);
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
  Frame frame;
  frame.rgba_buf = outputBuf;
  frame.rgba_buf_size = bufferLength;
  frame.width = finalWidth;
  frame.height = finalHeight;

  CGColorSpaceRelease(colorSpace);
  CGContextRelease(context);
  CGImageRelease(bigImage);

  return frame;
}

// not much to do on MacOS with ARC enabled :)
bool deinit_capture(ScreenCapture *sc) {
  free(sc->region);
  return true;
}