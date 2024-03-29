#import "screencap.h"
#import "types.h"
#include <Foundation/Foundation.h>

void process_frame(
    uint8_t *base_addr, size_t width, size_t height, size_t bytes_per_row
) {}

int main() {
  ScreenCapture sc;
  init_capture(&sc, process_frame);
  start_capture(&sc);
  stop_capture(&sc);
  return 0;
}
