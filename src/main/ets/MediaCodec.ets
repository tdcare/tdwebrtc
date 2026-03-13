/**
 * 音视频编解码器
 *
 * ## 架构定位
 *
 * 本模块是 WebRTC 媒体处理的 **解码管理层 + 编解码能力检测**，负责：
 * - 视频解码器生命周期管理（H.264 硬解 / VP8 软解）
 * - 设备编解码能力检测（detectVideoCodecCapabilities）
 *
 * ## 编解码实现策略
 *
 * | 功能     | 实现方式                   | 说明 |
 * |----------|--------------------------|------|
 * | 视频解码 | Rust NAPI H264Decoder/Vp8Decoder | H.264 硬解码 + VP8 软解码 |
 * | 视频编码 | Rust InternalVideoEncoder      | 已移入 Rust 层，通过 encodeAndSendVideo 一体化调用 |
 * | 音频编解码 | Rust 层 sendPcmAudio / FrameAssembler | G.711 编解码已完全内置在 Rust 层 |
 *
 * ## 数据流
 *
 * 解码: NALU/VP8 数据 → Uint8Array 直传 → Rust Decoder → Surface 渲染
 */

import { LogUtil } from './utils/LogUtil';
import {
  NapiVideoDecoderConfig,
  checkSupportedVideoCodecs,
} from 'libwebrtc_client.so';
import { VideoDecoderVP8 } from './VideoDecoderVP8';
import { VideoDecoderH264 } from './VideoDecoderH264';

// ============================================================
// 编解码器配置接口
// ============================================================

export interface VideoDecoderConfig {
  codec: 'H264' | 'H265' | 'VP8' | 'VP9';
  width: number;
  height: number;
}

// 编码帧数据
export class EncodedFrame {
  data: ArrayBuffer;
  timestamp: number;
  isKeyFrame: boolean;

  constructor(data: ArrayBuffer, timestamp: number, isKeyFrame: boolean) {
    this.data = data;
    this.timestamp = timestamp;
    this.isKeyFrame = isKeyFrame;
  }
}

// 解码帧数据
export class DecodedFrame {
  data: ArrayBuffer;
  timestamp: number;
  width: number;
  height: number;

  constructor(data: ArrayBuffer, timestamp: number, width: number = 0, height: number = 0) {
    this.data = data;
    this.timestamp = timestamp;
    this.width = width;
    this.height = height;
  }
}

// ============================================================
// 视频解码器 — 按编解码器类型分离实现
//
// VP8:  VideoDecoderVP8  → 软件解码 (libvpx)，需手动 renderToSurface
// H264: VideoDecoderH264 → 硬件解码 (OH_VideoDecoder)，解码即渲染
//
// 为了保持向后兼容，这里重新导出两个类，并保留 VideoDecoder 作为统一接口
// ============================================================

export { VideoDecoderVP8, VideoDecoderH264 };

/**
 * 视频解码器统一接口（工厂类）
 *
 * 根据 codec 类型自动选择 VP8 或 H264 解码器实现。
 * 两个实现的差异：
 * - VP8:  软件解码，输出到内存缓冲区，需要手动 renderToSurface()
 * - H264: 硬件解码，直接输出到 Surface，解码即自动渲染
 */
export class VideoDecoder {
  private impl: VideoDecoderVP8 | VideoDecoderH264;

  public onDecodedFrame?: (frame: DecodedFrame) => void;
  public onError?: (error: string) => void;

  constructor(config: VideoDecoderConfig) {
    if (config.codec === 'VP8') {
      this.impl = new VideoDecoderVP8(config);
    } else {
      this.impl = new VideoDecoderH264(config);
    }

    // 转发事件
    this.impl.onDecodedFrame = (frame: DecodedFrame) => {
      this.onDecodedFrame?.(frame);
    };
    this.impl.onError = (error: string) => {
      this.onError?.(error);
    };
  }

  public setSurfaceById(surfaceId: string): boolean {
    return this.impl.setSurfaceById(surfaceId);
  }

  public async initialize(): Promise<boolean> {
    const result = await this.impl.initialize();
    LogUtil.info(`[VideoDecoder] ${this.impl.constructor.name} 初始化完成：result=${result}`);
    return result;
  }

  public async start(): Promise<boolean> {
    const result = await this.impl.start();
    LogUtil.info(`[VideoDecoder] ${this.impl.constructor.name} 启动完成：result=${result}`);
    return result;
  }

  public async decodeFrame(
    encodedData: ArrayBuffer,
    timestamp: number,
    isKeyFrame: boolean = false,
    renderAfterDecode: boolean = true
  ): Promise<boolean> {
    const result = await this.impl.decodeFrame(encodedData, timestamp, isKeyFrame, renderAfterDecode);
    if (!result) {
      LogUtil.error(`[VideoDecoder] ${this.impl.constructor.name} 解码失败：timestamp=${timestamp}, size=${encodedData.byteLength}`);
    }
    return result;
  }

  public renderToSurface(): boolean {
    return this.impl.renderToSurface();
  }

  public async release(): Promise<void> {
    return this.impl.release();
  }
}

// ============================================================
// 编解码器能力检查
// ============================================================

// v36: 编解码器优先级（从高到低）
// 当设备支持多种编解码器时，按此顺序选择最优的
const VIDEO_CODEC_PRIORITY: string[] = ['H265', 'H264', 'VP9', 'VP8'];

// v36: 当前代码库中已实现的编解码器
// H264: Rust NAPI → OH_VideoEncoder/Decoder（硬件编解码）
// VP8:  Rust libvpx（软件编解码）
// H265/VP9: 框架预留，待 RTP 打包/解包实现后启用
const IMPLEMENTED_ENCODE_CODECS: string[] = ['H264', 'VP8'];
const IMPLEMENTED_DECODE_CODECS: string[] = ['H264', 'VP8'];

// v36: MIME 类型与编解码器名称映射
const MIME_TO_CODEC: Array<[string, string]> = [
  ['video/hevc', 'H265'],
  ['video/avc', 'H264'],
  ['video/x-vnd.on2.vp9', 'VP9'],
  ['video/x-vnd.on2.vp8', 'VP8'],
];

/**
 * v36: 设备视频编解码能力检测结果
 */
export interface VideoCodecCapabilities {
  hwEncode: string[];     // 设备硬件编码能力列表
  hwDecode: string[];     // 设备硬件解码能力列表
  canEncode: string[];    // 实际可用编码列表（硬件 + VP8 软编码，按优先级排序）
  canDecode: string[];    // 实际可用解码列表（硬件 + VP8 软解码，按优先级排序）
  bestSendCodec: string;  // 最优发送编解码器
  bestRecvCodec: string;  // 最优接收编解码器
}

/**
 * v36: 检测设备视频编解码能力，自动选择最优编解码器
 *
 * 原则：
 * 1. 按 H265 > H264 > VP9 > VP8 优先级选择
 * 2. 编码和解码分别检测，支持非对称选择
 * 3. VP8 软编解码作为兜底（libvpx 始终可用）
 * 4. 只选择代码库中已实现的编解码器
 */
export function detectVideoCodecCapabilities(): VideoCodecCapabilities {
  const hwEncode: string[] = [];
  const hwDecode: string[] = [];

  try {
    const supported: Array<string> = checkSupportedVideoCodecs();
    for (let i = 0; i < supported.length; i++) {
      const entry: string = supported[i];
      for (let j = 0; j < MIME_TO_CODEC.length; j++) {
        const mime: string = MIME_TO_CODEC[j][0];
        const codec: string = MIME_TO_CODEC[j][1];
        if (entry.includes(mime)) {
          if (entry.includes('编码+解码') || entry.includes('仅编码')) {
            hwEncode.push(codec);
          }
          if (entry.includes('编码+解码') || entry.includes('仅解码')) {
            hwDecode.push(codec);
          }
        }
      }
    }
  } catch {
    // 检测失败，后续会用 VP8 兜底
  }

  // 构建实际可用列表：按优先级遍历，取设备支持 ∩ 已实现
  const canEncode: string[] = [];
  const canDecode: string[] = [];

  for (let k = 0; k < VIDEO_CODEC_PRIORITY.length; k++) {
    const codec: string = VIDEO_CODEC_PRIORITY[k];
    const hasHwEnc: boolean = hwEncode.includes(codec);
    const hasSwEnc: boolean = codec === 'VP8'; // libvpx 软编码
    const implEnc: boolean = IMPLEMENTED_ENCODE_CODECS.includes(codec);
    if ((hasHwEnc || hasSwEnc) && implEnc) {
      canEncode.push(codec);
    }
  }

  for (let k = 0; k < VIDEO_CODEC_PRIORITY.length; k++) {
    const codec: string = VIDEO_CODEC_PRIORITY[k];
    const hasHwDec: boolean = hwDecode.includes(codec);
    const hasSwDec: boolean = codec === 'VP8'; // libvpx 软解码
    const implDec: boolean = IMPLEMENTED_DECODE_CODECS.includes(codec);
    if ((hasHwDec || hasSwDec) && implDec) {
      canDecode.push(codec);
    }
  }

  // VP8 始终兜底
  if (!canEncode.includes('VP8')) {
    canEncode.push('VP8');
  }
  if (!canDecode.includes('VP8')) {
    canDecode.push('VP8');
  }

  const result: VideoCodecCapabilities = {
    hwEncode: hwEncode,
    hwDecode: hwDecode,
    canEncode: canEncode,
    canDecode: canDecode,
    bestSendCodec: canEncode.length > 0 ? canEncode[0] : 'VP8',
    bestRecvCodec: canDecode.length > 0 ? canDecode[0] : 'VP8',
  };

  return result;
}

/**
 * 检查设备是否支持指定的编解码器（向后兼容）
 */
export function isCodecSupported(codec: 'H264' | 'H265'): boolean {
  try {
    const supported: Array<string> = checkSupportedVideoCodecs();
    const mimeType: string = codec === 'H265' ? 'video/hevc' : 'video/avc';
    // v34-fix: checkSupportedVideoCodecs 返回格式为 "H.264 (AVC) (video/avc) - 仅解码"
    // 之前用 s === mimeType 精确比较永远为 false，改用 includes 匹配
    return supported.some((s: string) => s.includes(mimeType));
  } catch {
    return false;
  }
}
