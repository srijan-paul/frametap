#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct ScreenCapture ScreenCapture;
typedef void (*ProcessFrameFn)(
    uint8_t *base_addr, size_t width, size_t height, size_t bytes_per_row
);

void init_capture(ScreenCapture *capture, ProcessFrameFn on_frame);
bool start_capture(ScreenCapture *capture);
bool start_capture_and_wait(ScreenCapture *capture);
void stop_capture(ScreenCapture *capture);
bool deinit_capture(ScreenCapture *capture);
