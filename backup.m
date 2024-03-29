
#include <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

struct ScreenCapture;

@interface OutputProcessor : NSObject <SCStreamOutput>

@property size_t msToCapture;
@property struct ScreenCapture *sc;

@end

typedef struct ScreenCapture {
  SCStream *stream;
  SCStreamConfiguration *conf;
  SCContentFilter *filter;
  OutputProcessor *processor;
  SCDisplay *display;
  SCShareableContent *content;
  NSError *error;

  CGDirectDisplayID displayID;
  NSArray<SCDisplay *> *displays;
  NSArray<SCWindow *> *windows;

  dispatch_semaphore_t capture_done;
  bool should_stop_capture;
} ScreenCapture;

@implementation OutputProcessor

- (instancetype)init:(struct ScreenCapture *)sc {
  self = [super init];
  self.msToCapture = 3 * 1000;
  self.sc = sc;
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
    NSLog(@"Failed to get image buffer from sample buffer. %p",
          CMSampleBufferGetDataBuffer(sampleBuffer));
    return;
  }

  // Lock the base address of the pixel buffer
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t const bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
  size_t const width = CVPixelBufferGetWidth(pixelBuffer);
  size_t const height = CVPixelBufferGetHeight(pixelBuffer);

  NSLog(@"(%zu x %zu)", width, height);

  // TODO: do further processing on the pixel buffer.

  // Unlock the pixel buffer
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

static bool init_screen_capture(ScreenCapture *sc,
                                SCShareableContent *content) {

  sc->should_stop_capture = false;
  sc->displayID = CGMainDisplayID();

  sc->displays = [content displays];
  sc->display = nil;

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
  [sc->conf setQueueDepth:8];
  [sc->conf setCapturesAudio:NO];
  [sc->conf setShowsCursor:YES];
  [sc->conf setWidth:100];
  [sc->conf setHeight:100];

  sc->stream = [[SCStream alloc] initWithFilter:sc->filter
                                  configuration:sc->conf
                                       delegate:nil];

  sc->processor = [[OutputProcessor alloc] init:sc];
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

typedef void (^ShareableContentCompletionHandler)(SCShareableContent *content,
                                                  NSError *error);

int main() {
  dispatch_semaphore_t content_received = dispatch_semaphore_create(0);

  __block SCShareableContent *content;
  ShareableContentCompletionHandler handler =
      ^(SCShareableContent *shareableContent, NSError *err) {
        if (err != nil) {
          NSLog(@"Error retrieving shareable content: %@",
                err.localizedDescription);
          exit(1);
        }

        content = shareableContent;
        dispatch_semaphore_signal(content_received);
      };

  [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                             onScreenWindowsOnly:YES
                                               completionHandler:handler];

  dispatch_semaphore_wait(content_received, DISPATCH_TIME_FOREVER);

  ScreenCapture sc;
  if (!init_screen_capture(&sc, content)) {
    NSLog(@"Error initializing screen capture: %@",
          sc.error.localizedDescription);
    exit(1);
  }

  if (!start_screen_capture(&sc)) {
    NSLog(@"Error starting screen capture: %@", sc.error.localizedDescription);
    exit(1);
  }

  dispatch_semaphore_wait(sc.capture_done, DISPATCH_TIME_FOREVER);

  return 0;
}
