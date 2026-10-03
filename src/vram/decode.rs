use crate::{
    common::{DataFormat::*, Driver::*},
    ffmpeg::init_av_log,
    vram::{ffmpeg, inner::DecodeCalls, DecodeContext},
};
// The vendor SDK drivers are windows-only; macOS has the ffmpeg
// (VideoToolbox) driver only.
#[cfg(windows)]
use crate::vram::{amf, mfx, nv};
use log::trace;
use std::ffi::c_void;

pub struct Decoder {
    calls: DecodeCalls,
    codec: *mut c_void,
    frames: *mut Vec<DecodeFrame>,
    pub ctx: DecodeContext,
}

unsafe impl Send for Decoder {}
unsafe impl Sync for Decoder {}

extern "C" {
    #[cfg(not(target_os = "macos"))]
    fn hwcodec_get_d3d11_texture_width_height(
        texture: *mut c_void,
        width: *mut i32,
        height: *mut i32,
    );
}

impl Decoder {
    pub fn new(ctx: DecodeContext) -> Result<Self, ()> {
        init_av_log();
        let calls = match ctx.driver {
            #[cfg(windows)]
            NV => nv::decode_calls(),
            #[cfg(windows)]
            AMF => amf::decode_calls(),
            #[cfg(windows)]
            MFX => mfx::decode_calls(),
            FFMPEG => ffmpeg::decode_calls(),
            // macOS has only the ffmpeg (VideoToolbox) driver.
            #[cfg(target_os = "macos")]
            _ => ffmpeg::decode_calls(),
        };
        unsafe {
            let codec = (calls.new)(
                ctx.device.unwrap_or(std::ptr::null_mut()),
                ctx.luid,
                ctx.data_format as i32,
            );
            if codec.is_null() {
                return Err(());
            }
            Ok(Self {
                calls,
                codec,
                frames: Box::into_raw(Box::new(Vec::<DecodeFrame>::new())),
                ctx,
            })
        }
    }

    pub fn decode(&mut self, packet: &[u8]) -> Result<&mut Vec<DecodeFrame>, i32> {
        unsafe {
            (&mut *self.frames).clear();
            let ret = (self.calls.decode)(
                self.codec,
                packet.as_ptr() as _,
                packet.len() as _,
                Some(Self::callback),
                self.frames as *mut _ as *mut c_void,
            );

            if ret != 0 {
                Err(ret)
            } else {
                Ok(&mut *self.frames)
            }
        }
    }

    unsafe extern "C" fn callback(texture: *mut c_void, obj: *const c_void) {
        let frames = &mut *(obj as *mut Vec<DecodeFrame>);
        #[cfg(target_os = "macos")]
        {
            // macOS passes the HWCodecVTFrameInfo mailbox; the shared handle
            // is the IOSurface id.
            let info = &*(texture as *const ffmpeg::HWCodecVTFrameInfo);
            frames.push(DecodeFrame {
                texture: info.io_surface_id as *mut c_void,
                width: info.width,
                height: info.height,
            });
        }
        #[cfg(not(target_os = "macos"))]
        {
            let mut width = 0;
            let mut height = 0;
            hwcodec_get_d3d11_texture_width_height(texture, &mut width, &mut height);

            let frame = DecodeFrame {
                texture,
                width,
                height,
            };
            frames.push(frame);
        }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe {
            (self.calls.destroy)(self.codec);
            self.codec = std::ptr::null_mut();
            let _ = Box::from_raw(self.frames);
            trace!("Decoder dropped");
        }
    }
}

pub struct DecodeFrame {
    pub texture: *mut c_void,
    pub width: i32,
    pub height: i32,
}

pub fn available() -> Vec<DecodeContext> {
    use log::debug;

    let mut codecs: Vec<_> = vec![];
    // disable nv sdk decode
    // codecs.append(
    //     &mut nv::possible_support_decoders()
    //         .drain(..)
    //         .map(|n| (NV, n))
    //         .collect(),
    // );
    codecs.append(
        &mut ffmpeg::possible_support_decoders()
            .drain(..)
            .map(|n| (FFMPEG, n))
            .collect(),
    );
    #[cfg(windows)]
    {
        codecs.append(
            &mut amf::possible_support_decoders()
                .drain(..)
                .map(|n| (AMF, n))
                .collect(),
        );
        codecs.append(
            &mut mfx::possible_support_decoders()
                .drain(..)
                .map(|n| (MFX, n))
                .collect(),
        );
    }

    let inputs: Vec<DecodeContext> = codecs
        .drain(..)
        .map(|(driver, n)| DecodeContext {
            device: None,
            driver: driver.clone(),
            vendor: driver, // Initially set vendor same as driver, will be updated by test results
            data_format: n.data_format,
            luid: 0,
        })
        .collect();

    let mut outputs = Vec::<DecodeContext>::new();
    let mut exclude_luid_formats = Vec::<(i64, i32)>::new();
    let buf264 = &crate::common::DATA_H264_720P[..];
    let buf265 = &crate::common::DATA_H265_720P[..];

    for input in inputs {
        debug!(
            "Testing vram decoder: driver={:?}, format={:?}",
            input.driver, input.data_format
        );

        let test = match input.driver {
            #[cfg(windows)]
            NV => nv::decode_calls().test,
            #[cfg(windows)]
            AMF => amf::decode_calls().test,
            #[cfg(windows)]
            MFX => mfx::decode_calls().test,
            FFMPEG => ffmpeg::decode_calls().test,
            #[cfg(target_os = "macos")]
            _ => ffmpeg::decode_calls().test,
        };

        let mut luids: Vec<i64> = vec![0; crate::vram::MAX_ADATERS];
        let mut vendors: Vec<i32> = vec![0; crate::vram::MAX_ADATERS];
        let mut desc_count: i32 = 0;

        let data = match input.data_format {
            H264 => buf264,
            H265 => buf265,
            _ => {
                debug!("Unsupported data format: {:?}, skipping", input.data_format);
                continue;
            }
        };

        let (excluded_luids, exclude_formats): (Vec<i64>, Vec<i32>) = exclude_luid_formats
            .iter()
            .map(|(luid, format)| (*luid, *format))
            .unzip();

        let result = unsafe {
            test(
                luids.as_mut_ptr(),
                vendors.as_mut_ptr(),
                luids.len() as _,
                &mut desc_count,
                input.data_format as i32,
                data.as_ptr() as *mut u8,
                data.len() as _,
                excluded_luids.as_ptr(),
                exclude_formats.as_ptr(),
                exclude_luid_formats.len() as i32,
            )
        };

        if result == 0 {
            if desc_count as usize <= luids.len() {
                debug!(
                    "vram decoder test passed: driver={:?}, adapters={}",
                    input.driver, desc_count
                );
                for i in 0..desc_count as usize {
                    let mut input = input.clone();
                    input.luid = luids[i];
                    input.vendor = match vendors[i] {
                        #[cfg(target_os = "macos")]
                        _ => FFMPEG, // no adapter vendors; the test writes 0
                        #[cfg(not(target_os = "macos"))]
                        0 => NV,
                        #[cfg(not(target_os = "macos"))]
                        1 => AMF,
                        #[cfg(not(target_os = "macos"))]
                        2 => MFX,
                        #[cfg(not(target_os = "macos"))]
                        _ => {
                            log::error!(
                                "Unexpected vendor value encountered: {}. Skipping.",
                                vendors[i]
                            );
                            continue;
                        }
                    };
                    exclude_luid_formats.push((luids[i], input.data_format as i32));
                    outputs.push(input);
                }
            }
        } else {
            debug!(
                "vram decoder test failed: driver={:?}, error={}",
                input.driver, result
            );
        }
    }

    outputs
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use crate::common::DATA_H264_720P;

    #[test]
    fn videotoolbox_zero_copy_round_trip() {
        let outputs = available();
        assert!(
            outputs.iter().any(|c| c.data_format == H264),
            "videotoolbox vram h264 decoder not available: {:?}",
            outputs
        );
        let ctx = outputs
            .iter()
            .find(|c| c.data_format == H264)
            .unwrap()
            .clone();
        let mut decoder = Decoder::new(ctx).unwrap();
        let frames = decoder.decode(DATA_H264_720P).unwrap();
        assert!(!frames.is_empty(), "no frames decoded");
        assert_ne!(frames[0].texture, std::ptr::null_mut(), "no IOSurface id");
        assert!(frames[0].width > 0 && frames[0].height > 0);
    }
}
