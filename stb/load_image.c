#include "load_image.h"
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"

StbImage *load_image_from_file(const char *filepath) {
  int width, height, nchannels;
  uint8_t *data = stbi_load(filepath, &width, &height, &nchannels, 3);
  if (data == NULL)
    return NULL;

  StbImage *image = malloc(sizeof(StbImage));
  image->width = width;
  image->height = height;
  image->data = data;

  return image;
}

bool write_image_to_png(
    const char *filepath, uint8_t *image, size_t width, size_t height
) {
  return stbi_write_png(filepath, width, height, 3, image, 0) == 1;
}

void free_image(StbImage *image) {
  free(image->data);
  free(image);
}
