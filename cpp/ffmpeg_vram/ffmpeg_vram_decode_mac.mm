// VideoToolbox zero-copy decode for macOS: frames never leave GPU memory.
// FFmpeg decodes to AV_PIX_FMT_VIDEOTOOLBOX (data[3] = CVPixelBufferRef);
// the mailbox retains current + previous buffer and hands the IOSurface id
// to the compositor, which imports it via CVPixelBufferCreateWithIOSurface.

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}
#include <CoreVideo/CVPixelBuffer.h>
#include <IOSurface/IOSurface.h>
#include <memory>
#include <stdbool.h>

#include "callback.h"
#include "common.h"

#define LOG_MODULE "FFMPEG_VRAM_DEC_VT"
#include <log.h>
#include <util.h>

extern "C" {
#include "ffmpeg_vram_ffi.h"
}

namespace {

// Biplanar 4:2:0 formats VideoToolbox produces for H264/HEVC.
bool isSupportedPixelFormat(OSType format) {
  return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
         format == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
         format == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange;
}

enum AVPixelFormat get_hw_format(AVCodecContext *c,
                                 const enum AVPixelFormat *formats) {
  (void)c;
  for (const enum AVPixelFormat *f = formats; *f != AV_PIX_FMT_NONE; f++) {
    if (*f == AV_PIX_FMT_VIDEOTOOLBOX) {
      return *f;
    }
  }
  LOG_ERROR(std::string("VIDEOTOOLBOX pixel format not offered"));
  return AV_PIX_FMT_NONE;
}

class FFmpegVRamDecoderMac {
public:
  AVCodecContext *c_ = NULL;
  AVBufferRef *hw_device_ctx_ = NULL;
  AVFrame *frame_ = NULL;
  AVPacket *pkt_ = NULL;
  CVPixelBufferRef mailbox_[2] = {NULL, NULL};
  HWCodecVTFrameInfo info_{};
  std::string name_;
  DataFormat dataFormat_;

  FFmpegVRamDecoderMac(DataFormat dataFormat) : dataFormat_(dataFormat) {
    switch (dataFormat) {
    case H264:
      name_ = "h264";
      break;
    case H265:
      name_ = "hevc";
      break;
    default:
      LOG_ERROR(std::string("unsupported data format"));
      break;
    }
  }

  ~FFmpegVRamDecoderMac() {}

  void releaseMailbox() {
    for (int i = 0; i < 2; i++) {
      if (mailbox_[i]) {
        CVBufferRelease(mailbox_[i]);
        mailbox_[i] = NULL;
      }
    }
  }

  void destroy() {
    if (frame_)
      av_frame_free(&frame_);
    if (pkt_)
      av_packet_free(&pkt_);
    if (c_)
      avcodec_free_context(&c_);
    if (hw_device_ctx_)
      av_buffer_unref(&hw_device_ctx_);
    releaseMailbox();
    frame_ = NULL;
    pkt_ = NULL;
    c_ = NULL;
    hw_device_ctx_ = NULL;
  }

  int reset() {
    const AVCodec *codec = NULL;
    int ret;
    if (!(codec = avcodec_find_decoder_by_name(name_.c_str()))) {
      LOG_ERROR(std::string("avcodec_find_decoder_by_name ") + name_ +
                " failed");
      return -1;
    }
    if (!(c_ = avcodec_alloc_context3(codec))) {
      LOG_ERROR(std::string("Could not allocate video codec context"));
      return -1;
    }
    c_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c_->get_format = get_hw_format;
    ret = av_hwdevice_ctx_create(&hw_device_ctx_, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                 NULL, NULL, 0);
    if (ret < 0) {
      LOG_ERROR(std::string("av_hwdevice_ctx_create failed, ret = ") +
                av_err2str(ret));
      return -1;
    }
    c_->hw_device_ctx = av_buffer_ref(hw_device_ctx_);
    if (!(pkt_ = av_packet_alloc())) {
      LOG_ERROR(std::string("av_packet_alloc failed"));
      return -1;
    }
    if (!(frame_ = av_frame_alloc())) {
      LOG_ERROR(std::string("av_frame_alloc failed"));
      return -1;
    }
    if ((ret = avcodec_open2(c_, codec, NULL)) != 0) {
      LOG_ERROR(std::string("avcodec_open2 failed, ret = ") + av_err2str(ret) +
                ", name=" + name_);
      return -1;
    }
    return 0;
  }

  int decode(const uint8_t *data, int length, DecodeCallback callback,
             const void *obj) {
    int ret = -1;
    if (!data || !length) {
      LOG_ERROR(std::string("illegal decode parameter"));
      return -1;
    }
    pkt_->data = (uint8_t *)data;
    pkt_->size = length;
    ret = do_decode(callback, obj);
    av_packet_unref(pkt_);
    return ret;
  }

private:
  int do_decode(DecodeCallback callback, const void *obj) {
    int ret;
    bool decoded = false;

    ret = avcodec_send_packet(c_, pkt_);
    if (ret < 0) {
      LOG_ERROR(std::string("avcodec_send_packet failed, ret = ") +
                av_err2str(ret));
      return ret;
    }

    auto start = util::now();
    while (ret >= 0 && util::elapsed_ms(start) < DECODE_TIMEOUT_MS) {
      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") +
                    av_err2str(ret));
        }
        return decoded ? 0 : -1;
      }
      if (frame_->format != AV_PIX_FMT_VIDEOTOOLBOX) {
        LOG_ERROR(std::string("only AV_PIX_FMT_VIDEOTOOLBOX is supported"));
        return -1;
      }
      CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame_->data[3];
      if (!pixelBuffer ||
          CFGetTypeID(pixelBuffer) != CVPixelBufferGetTypeID()) {
        LOG_ERROR(std::string("frame data[3] is not a CVPixelBuffer"));
        return -1;
      }
      if (!isSupportedPixelFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))) {
        LOG_ERROR(std::string("unsupported CVPixelBuffer format"));
        return -1;
      }
      // 2-deep mailbox: current + previous stay alive so the compositor can
      // still be importing the previous IOSurface when the next frame lands;
      // the plugin side holds its own refs once it wraps the surface.
      if (mailbox_[1]) {
        CVBufferRelease(mailbox_[1]);
      }
      mailbox_[1] = mailbox_[0];
      CVBufferRetain(pixelBuffer);
      mailbox_[0] = pixelBuffer;
      IOSurfaceRef ioSurface = CVPixelBufferGetIOSurface(pixelBuffer);
      if (!ioSurface) {
        LOG_ERROR(std::string("CVImageBufferGetIOSurface failed"));
        return -1;
      }
      info_.io_surface_id = (uint32_t)IOSurfaceGetID(ioSurface);
      info_.width = frame_->width;
      info_.height = frame_->height;
      if (callback) {
        callback((void *)&info_, (void *)obj);
      }
      decoded = true;
    }
    return decoded ? 0 : -1;
  }
};

} // namespace

extern "C" int ffmpeg_vram_destroy_decoder(void *decoder) {
  try {
    if (!decoder)
      return 0;
    FFmpegVRamDecoderMac *d = (FFmpegVRamDecoderMac *)decoder;
    d->destroy();
    delete d;
    return 0;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_vram_destroy_decoder exception:") + e.what());
  }
  return -1;
}

extern "C" void *ffmpeg_vram_new_decoder(void *device, int64_t luid,
                                         int32_t codecID) {
  (void)device;
  (void)luid; // macOS has a single VT device; no adapter selection.
  FFmpegVRamDecoderMac *decoder = NULL;
  try {
    decoder = new FFmpegVRamDecoderMac((DataFormat)codecID);
    if (decoder->reset() == 0) {
      return decoder;
    }
  } catch (std::exception &e) {
    LOG_ERROR(std::string("new decoder exception:") + e.what());
  }
  if (decoder) {
    decoder->destroy();
    delete decoder;
  }
  return NULL;
}

extern "C" int ffmpeg_vram_decode(void *decoder, uint8_t *data, int len,
                                  DecodeCallback callback, void *obj) {
  try {
    FFmpegVRamDecoderMac *d = (FFmpegVRamDecoderMac *)decoder;
    int ret = d->decode(data, len, callback, obj);
    if (d->dataFormat_ == H265 &&
        util_decode::has_flag_could_not_find_ref_with_poc()) {
      return HWCODEC_ERR_HEVC_COULD_NOT_FIND_POC;
    }
    return ret == 0 ? HWCODEC_SUCCESS : HWCODEC_ERR_COMMON;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_vram_decode exception:") + e.what());
  }
  return HWCODEC_ERR_COMMON;
}

extern "C" int ffmpeg_vram_test_decode(int64_t *outLuids, int32_t *outVendors,
                                       int32_t maxDescNum, int32_t *outDescNum,
                                       int32_t dataFormat, uint8_t *data,
                                       int32_t length,
                                       const int64_t *excludedLuids,
                                       const int32_t *excludeFormats,
                                       int32_t excludeCount) {
  try {
    // macOS exposes one VideoToolbox device; the d3d11 adapter-exclusion
    // scheme does not apply.
    (void)excludedLuids;
    (void)excludeFormats;
    (void)excludeCount;
    *outDescNum = 0;
    if (maxDescNum < 1)
      return 0;
    // macOS exposes one VideoToolbox device; luid/vendor stay 0 (the d3d11
    // adapter scheme does not apply).
    FFmpegVRamDecoderMac *p = new FFmpegVRamDecoderMac((DataFormat)dataFormat);
    bool ok = false;
    try {
      if (p->reset() == 0) {
        auto start = util::now();
        ok = p->decode(data, length, nullptr, nullptr) == 0 &&
             util::elapsed_ms(start) < TEST_TIMEOUT_MS;
      }
    } catch (const std::exception &e) {
      LOG_ERROR(std::string("test decode exception:") + e.what());
    }
    p->destroy();
    delete p;
    if (ok) {
      outLuids[0] = 0;
      outVendors[0] = 0;
      *outDescNum = 1;
    }
    return 0;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_vram_test_decode exception:") + e.what());
  }
  return -1;
}
