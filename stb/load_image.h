#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint8_t *data;
  size_t width;
  size_t height;
} StbImage;

StbImage *load_image_from_file(const char *filepath);
bool write_image_to_png(
    const char *filepath, uint8_t *image, size_t width, size_t height
);

void free_image(StbImage *image);
