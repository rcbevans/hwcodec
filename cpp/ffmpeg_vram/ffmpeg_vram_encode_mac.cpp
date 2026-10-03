// macOS stubs for the vram encode FFI. VideoToolbox zero-copy encode input
// is not implemented yet; the symbols must exist because the bindgen'd vram
// ffi module references them on every target. The ffi header is bindgen-only
// and is deliberately not included here (the d3d11 impls follow the same
// pattern).
#include "../common/callback.h"

extern "C" {

void *ffmpeg_vram_new_encoder(void *handle, int64_t luid, int32_t dataFormat,
                              int32_t width, int32_t height, int32_t kbs,
                              int32_t framerate, int32_t gop) {
  (void)handle;
  (void)luid;
  (void)dataFormat;
  (void)width;
  (void)height;
  (void)kbs;
  (void)framerate;
  (void)gop;
  return nullptr;
}

int ffmpeg_vram_encode(void *encoder, void *tex, EncodeCallback callback,
                       void *obj, int64_t ms) {
  (void)encoder;
  (void)tex;
  (void)callback;
  (void)obj;
  (void)ms;
  return -1;
}

int ffmpeg_vram_destroy_encoder(void *encoder) {
  (void)encoder;
  return -1;
}

int ffmpeg_vram_test_encode(int64_t *outLuids, int32_t *outVendors,
                            int32_t maxDescNum, int32_t *outDescNum,
                            int32_t dataFormat, int32_t width, int32_t height,
                            int32_t kbs, int32_t framerate, int32_t gop,
                            const int64_t *excludedLuids,
                            const int32_t *excludeFormats,
                            int32_t excludeCount) {
  (void)outLuids;
  (void)outVendors;
  (void)maxDescNum;
  (void)dataFormat;
  (void)width;
  (void)height;
  (void)kbs;
  (void)framerate;
  (void)gop;
  (void)excludedLuids;
  (void)excludeFormats;
  (void)excludeCount;
  *outDescNum = 0;
  return 0;
}

int ffmpeg_vram_set_bitrate(void *encoder, int32_t kbs) {
  (void)encoder;
  (void)kbs;
  return -1;
}

int ffmpeg_vram_set_framerate(void *encoder, int32_t framerate) {
  (void)encoder;
  (void)framerate;
  return -1;
}
}
