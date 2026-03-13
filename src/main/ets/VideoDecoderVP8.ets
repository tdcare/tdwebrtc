/**
 * VP8 软件视频解码器
 *
 * ## 架构定位
 * - 使用 Rust NAPI VP8Decoder (libvpx 软件解码)
 * - 解码输出到内存缓冲区 (I420 格式)
 * - 需要手动调用 renderToSurface() 将 I420 渲染到 Surface
 *
 * ## 与 H264 硬件解码器的区别
 * | 特性 | VP8 (本文件) | H264 (VideoDecoderH264.ets) |
 * |------|--------------|------------------------------|
 * | 解码方式 | 软件 (libvpx) | 硬件 (OH_VideoDecoder) |
 * | 输出目标 | 内存缓冲区 (I420) | 直接到 Surface |
 * | 渲染方式 | 手动 renderToSurface() | 解码即自动渲染 |
 * | 适用场景 | 低端设备/软件兼容 | 主流硬件加速 |
 */

import { LogUtil } from './utils/LogUtil';
import { Vp8Decoder, NapiVideoDecoderConfig } from 'libwebrtc_client.so';
import { VideoDecoderConfig, DecodedFrame } from './MediaCodec';

export class VideoDecoderVP8 {
  private config: VideoDecoderConfig;
  private isRunning: boolean = false;
  private vp8Decoder: Vp8Decoder | null = null;
  private surfaceId: string = '';

  // 诊断计数
  private decodeAttemptCount: number = 0;
  private decodeSuccessCount: number = 0;
  private lastDiagTime: number = 0;

  public onDecodedFrame?: (frame: DecodedFrame) => void;
  public onError?: (error: string) => void;

  constructor(config: VideoDecoderConfig) {
    this.config = config;
  }

  /**
   * 设置输出 Surface（通过 surfaceId）
   */
  public setSurfaceById(surfaceId: string): boolean {
    this.surfaceId = surfaceId;

    if (this.vp8Decoder !== null) {
      this.vp8Decoder.setSurface(surfaceId);
      LogUtil.info(`[VideoDecoderVP8] Surface 已设置: ${surfaceId}`);
      return true;
    }

    LogUtil.info(`[VideoDecoderVP8] SurfaceId 已保存，将在初始化时设置: ${surfaceId}`);
    return true;
  }

  public async initialize(): Promise<boolean> {
    try {
      this.vp8Decoder = new Vp8Decoder();
      LogUtil.info('[VideoDecoderVP8] 使用 VP8 软件解码器 (Rust/libvpx)');

      const napiConfig: NapiVideoDecoderConfig = {
        width: this.config.width,
        height: this.config.height,
      };

      if (this.surfaceId !== '') {
        this.vp8Decoder.setSurface(this.surfaceId);
      }

      const success: boolean = this.vp8Decoder.initialize(napiConfig);
      if (!success) {
        LogUtil.error('[VideoDecoderVP8] VP8 解码器初始化失败');
        this.vp8Decoder = null;
        return false;
      }
      LogUtil.info(`[VideoDecoderVP8] VP8 软件解码器初始化成功: ${this.config.width}x${this.config.height}`);
      return true;
    } catch (error) {
      const msg: string = `VP8 解码器初始化异常: ${(error as Error).message}`;
      LogUtil.error(`[VideoDecoderVP8] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  public async start(): Promise<boolean> {
    if (this.vp8Decoder === null) {
      LogUtil.error('[VideoDecoderVP8] 解码器未初始化');
      return false;
    }

    const success: boolean = this.vp8Decoder.start();
    if (!success) {
      LogUtil.error('[VideoDecoderVP8] VP8 解码器启动失败');
      return false;
    }
    this.isRunning = true;
    LogUtil.info('[VideoDecoderVP8] VP8 软件解码器已启动');
    return true;
  }

  /**
   * 解码视频帧
   *
   * @param encodedData VP8 帧数据
   * @param timestamp 时间戳（微秒）
   * @param isKeyFrame 是否为关键帧
   * @param renderAfterDecode 解码后是否立即渲染到 Surface（默认 true）
   *                          批量解码时只最后一帧设为 true，前面帧设为 false
   */
  public async decodeFrame(
    encodedData: ArrayBuffer,
    timestamp: number,
    isKeyFrame: boolean = false,
    renderAfterDecode: boolean = true
  ): Promise<boolean> {
    if (!this.isRunning || this.vp8Decoder === null) {
      return false;
    }

    this.decodeAttemptCount++;

    try {
      const uint8Array: Uint8Array = new Uint8Array(encodedData);

      const success: boolean = this.vp8Decoder.decodeFrame(uint8Array, timestamp, isKeyFrame);
      if (success) {
        this.decodeSuccessCount++;
        // VP8 需要手动渲染：批量解码时只最后一帧需要渲染，前面的帧只更新参考帧
        if (renderAfterDecode) {
          this.vp8Decoder.renderToSurface();
        }
        if (this.onDecodedFrame !== undefined) {
          const frame: DecodedFrame = new DecodedFrame(
            new ArrayBuffer(0),
            timestamp,
            this.config.width,
            this.config.height
          );
          this.onDecodedFrame(frame);
        }
      }
      this.logDecodeDiag();
      return success;
    } catch (error) {
      const msg: string = `解码帧异常: ${(error as Error).message}`;
      LogUtil.error(`[VideoDecoderVP8] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  /**
   * 手动触发渲染（用于批量解码后统一渲染）
   */
  public renderToSurface(): boolean {
    if (this.vp8Decoder !== null) {
      return this.vp8Decoder.renderToSurface();
    }
    return false;
  }

  /** 每3秒打一次诊断日志 */
  private logDecodeDiag(): void {
    const now: number = Date.now();
    if (now - this.lastDiagTime >= 3000) {
      LogUtil.info(
        `[VideoDecoderVP8] 诊断: 尝试=${this.decodeAttemptCount}, 成功=${this.decodeSuccessCount}, surface=${this.surfaceId.length > 0 ? this.surfaceId : '未设置'}`
      );
      this.lastDiagTime = now;
    }
    // 每100帧打印一次，确认解码器持续工作
    if (this.decodeSuccessCount > 0 && this.decodeSuccessCount % 100 === 0) {
      LogUtil.info(`[VideoDecoderVP8] 解码进度: 已成功解码 ${this.decodeSuccessCount} 帧`);
    }
  }

  public async release(): Promise<void> {
    this.isRunning = false;

    if (this.vp8Decoder !== null) {
      this.vp8Decoder.stop();
      this.vp8Decoder = null;
    }

    LogUtil.info(
      `[VideoDecoderVP8] VP8 解码器已释放 (尝试=${this.decodeAttemptCount}, 成功=${this.decodeSuccessCount})`
    );
  }
}
