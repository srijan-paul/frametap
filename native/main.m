#import "screencap.h"
#import "types.h"
#include <Foundation/Foundation.h>

void process_frame(
    uint8_t *base_addr, size_t width, size_t height, size_t bytes_per_row,
    void *i
) {

  *((int *)i) = *(int *)i + 1;

  if (true)
    return;

  NSLog(@"Processing frame of size %zux%zu", width, height);
  // Create a CGColorSpace
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

  // Create a CGContext using the frame data
  CGContextRef context = CGBitmapContextCreate(
      base_addr, width, height, 8, bytes_per_row, colorSpace,
      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host
  );

  // Create a CGImage from the context
  CGImageRef image = CGBitmapContextCreateImage(context);

  // Create a destination to write the TIFF image to the filesystem
  CFURLRef url = CFURLCreateWithFileSystemPath(
      kCFAllocatorDefault,
      CFSTR("frame.tiff"), // Specify the file path here
      kCFURLPOSIXPathStyle, false
  );
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithURL(url, kUTTypeTIFF, 1, NULL);

  // Add the image to the destination
  CGImageDestinationAddImage(destination, image, NULL);

  // Finalize the destination to write the image to disk
  if (!CGImageDestinationFinalize(destination)) {
    NSLog(@"Failed to write image as TIFF");
  }

  exit(0);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    __block FrameProcessor processor;
    processor.process_fn = process_frame;
    int count = 0;
    processor.other_data = &count;
    __block ScreenCapture sc;
    init_capture(&sc, processor);
    // Dispatch to a background queue
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^{
          start_capture_and_wait(&sc);
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