#import "screencap.h"
#import "types.h"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>

void process_frame(
    uint8_t *base_addr, size_t width, size_t height, size_t bytes_per_row,
    void *i
) {

  int *count = (int *)i;
  *count = *(int *)i + 1;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    __block FrameProcessor processor;
    processor.process_fn = process_frame;
    int count = 0;
    processor.other_data = &count;
    __block ScreenCapture sc;
    init_capture(&sc);
    set_on_frame_handler(&sc, processor);
    // Dispatch to a background queue
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^{
          if (!start_capture_and_wait(&sc)) {
            NSLog(@"Failed to start capture");
          }
        }
    );

    // Keep the main thread alive long enough to see our logs
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    stop_capture(&sc);
    NSLog(@"Captured %d frames", count);
  }
  return 0;
}
