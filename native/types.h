#import "screencap.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface OutputProcessor : NSObject <SCStreamOutput>

@property ScreenCapture *sc;
@property FrameProcessor frame_processor;

@end

struct ScreenCapture {
  CaptureRect region;
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
  FrameProcessor frame_processor;
};
