#import "screencap.h"
#import "types.h"

@implementation OutputProcessor

- (instancetype)init:(struct ScreenCapture *)sc
     onFrameReceived:(ProcessFrameFn)processFn {
  self = [super init];
  self.sc = sc;
  self.processFrameFn = processFn;
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

  self.processFrameFn(baseAddress, width, height, bytesPerRow);

  // Unlock the pixel buffer
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

void init_capture(ScreenCapture *sc, ProcessFrameFn onFrameReceived) {
  sc->processFrameFn = onFrameReceived;
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

  sc->stream = [[SCStream alloc] initWithFilter:sc->filter
                                  configuration:sc->conf
                                       delegate:nil];

  sc->processor = [[OutputProcessor alloc] init:sc
                                onFrameReceived:sc->processFrameFn];
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

// not much to do on MacOS with ARC enabled :)
bool deinit_capture(ScreenCapture *sc) { return true; }