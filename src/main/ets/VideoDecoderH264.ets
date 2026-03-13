/**
 * H.264/H.265 硬件视频解码器
 *
 * ## 架构定位
 * - 使用 Rust NAPI H264Decoder (底层调用 OH_VideoDecoder 硬件解码)
 * - 解码直接输出到绑定的 Surface，无需手动渲染
 * - 适用于主流硬件加速场景
 *
 * ## 与 VP8 软件解码器的区别
 * | 特性 | H264 (本文件) | VP8 (VideoDecoderVP8.ets) |
 * |------|---------------|---------------------------|
 * | 解码方式 | 硬件 (OH_VideoDecoder) | 软件 (libvpx) |
 * | 输出目标 | 直接到 Surface | 内存缓冲区 (I420) |
 * | 渲染方式 | 解码即自动渲染 | 需手动 renderToSurface() |
 * | 适用场景 | 主流硬件加速 | 低端设备/软件兼容 |
 *
 * ## 重要说明
 * H264 硬件解码器在 initialize() 时通过 setSurfaceById() 绑定 Surface，
 * 解码后的数据直接输出到 Surface，不需要像 VP8 那样手动调用 renderToSurface()。
 */

import { LogUtil } from './utils/LogUtil';
import { H264Decoder, NapiVideoDecoderConfig } from 'libwebrtc_client.so';
import { VideoDecoderConfig, DecodedFrame } from './MediaCodec';

export class VideoDecoderH264 {
  private config: VideoDecoderConfig;
  private isRunning: boolean = false;
  private h264Decoder: H264Decoder | null = null;
  private surfaceId: string = '';
  private codecType: string = 'H264';

  // 诊断计数
  private decodeAttemptCount: number = 0;
  private decodeSuccessCount: number = 0;
  private lastDiagTime: number = 0;

  public onDecodedFrame?: (frame: DecodedFrame) => void;
  public onError?: (error: string) => void;

  constructor(config: VideoDecoderConfig) {
    this.config = config;
    this.codecType = config.codec ?? 'H264';
  }

  /**
   * 设置输出 Surface（通过 surfaceId）
   *
   * 必须在 initialize() 之前调用，或在 initialize() 之后立即调用。
   * Surface 绑定后，解码输出将直接渲染到该 Surface。
   */
  public setSurfaceById(surfaceId: string): boolean {
    this.surfaceId = surfaceId;

    if (this.h264Decoder !== null) {
      this.h264Decoder.setSurfaceById(surfaceId);
      LogUtil.info(`[VideoDecoderH264] Surface 已设置: ${surfaceId}`);
      return true;
    }

    LogUtil.info(`[VideoDecoderH264] SurfaceId 已保存，将在初始化时设置: ${surfaceId}`);
    return true;
  }

  public async initialize(): Promise<boolean> {
    try {
      LogUtil.info(`[VideoDecoderH264] 使用 ${this.codecType} 硬件解码器 (Rust NAPI → OH_VideoDecoder)`);

      this.h264Decoder = new H264Decoder();

      if (this.surfaceId !== '') {
        this.h264Decoder.setSurfaceById(this.surfaceId);
      }

      const napiConfig: NapiVideoDecoderConfig = {
        width: this.config.width,
        height: this.config.height,
      };

      const success: boolean = this.h264Decoder.initialize(napiConfig);
      if (!success) {
        LogUtil.error(`[VideoDecoderH264] ${this.codecType} 硬件解码器初始化失败`);
        this.h264Decoder = null;
        return false;
      }
      LogUtil.info(`[VideoDecoderH264] ${this.codecType} 硬件解码器初始化成功: ${this.config.width}x${this.config.height}`);
      return true;
    } catch (error) {
      const msg: string = `${this.codecType} 解码器初始化异常: ${(error as Error).message}`;
      LogUtil.error(`[VideoDecoderH264] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  public async start(): Promise<boolean> {
    if (this.h264Decoder === null) {
      LogUtil.error('[VideoDecoderH264] 解码器未初始化');
      return false;
    }

    const success: boolean = this.h264Decoder.start();
    // v32-fix: 某些设备 start() 返回 false 但实际能正常解码，以解码结果为准
    this.isRunning = true;
    LogUtil.info(`[VideoDecoderH264] ${this.codecType} 硬件解码器启动完成：return=${success} (实际以解码结果为准)`);
    return true;  // 始终返回 true，让解码流程继续
  }

  /**
   * 解码视频帧
   *
   * ## 重要说明
   * H264 硬件解码器直接输出到 Surface，解码即渲染，**不需要**手动调用 renderToSurface()。
   * renderAfterDecode 参数在本实现中被忽略，仅为了保持与 VP8 解码器接口一致。
   *
   * @param encodedData H.264 NALU 数据 (Annex-B 格式)
   * @param timestamp 时间戳（微秒）
   * @param isKeyFrame 是否为关键帧
   * @param renderAfterDecode 此参数被忽略，H264 解码即自动渲染
   */
  public async decodeFrame(
    encodedData: ArrayBuffer,
    timestamp: number,
    isKeyFrame: boolean = false,
    renderAfterDecode: boolean = true
  ): Promise<boolean> {
    if (!this.isRunning || this.h264Decoder === null) {
      return false;
    }

    this.decodeAttemptCount++;

    try {
      const uint8Array: Uint8Array = new Uint8Array(encodedData);
      const ok: boolean = this.h264Decoder.decodeFrame(uint8Array, timestamp, isKeyFrame);

      if (ok) {
        this.decodeSuccessCount++;
        // H264 硬件解码器直接输出到 Surface，解码即渲染
        // 不需要像 VP8 那样手动调用 renderToSurface()
      }

      if (this.decodeAttemptCount <= 3) {
        LogUtil.info(
          `[VideoDecoderH264] ${this.codecType} 解码#${this.decodeAttemptCount}: ${encodedData.byteLength}B, key=${isKeyFrame}, ok=${ok}, surface=${this.surfaceId.length > 0 ? '有' : '无'}`
        );
      }

      this.logDecodeDiag();
      return ok;
    } catch (error) {
      const msg: string = `解码帧异常: ${(error as Error).message}`;
      LogUtil.error(`[VideoDecoderH264] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  /**
   * 手动触发渲染（H264 不需要，此方法仅为了保持接口一致性）
   *
   * H264 硬件解码器解码后直接输出到 Surface，不需要手动渲染。
   * 此方法始终返回 false，仅为了保持与 VideoDecoderVP8 接口一致。
   */
  public renderToSurface(): boolean {
    // H264 硬件解码器不需要手动渲染，解码即自动输出到 Surface
    LogUtil.debug('[VideoDecoderH264] renderToSurface() 被调用，但 H264 硬件解码不需要手动渲染');
    return false;
  }

  /** 每3秒打一次诊断日志 */
  private logDecodeDiag(): void {
    const now: number = Date.now();
    if (now - this.lastDiagTime >= 3000) {
      LogUtil.info(
        `[VideoDecoderH264] 诊断: 尝试=${this.decodeAttemptCount}, 成功=${this.decodeSuccessCount}, surface=${this.surfaceId.length > 0 ? this.surfaceId : '未设置'}`
      );
      this.lastDiagTime = now;
    }
    // 每100帧打印一次，确认解码器持续工作
    if (this.decodeSuccessCount > 0 && this.decodeSuccessCount % 100 === 0) {
      LogUtil.info(`[VideoDecoderH264] 解码进度: 已成功解码 ${this.decodeSuccessCount} 帧`);
    }
  }

  public async release(): Promise<void> {
    this.isRunning = false;

    if (this.h264Decoder !== null) {
      try {
        this.h264Decoder.stop();
        this.h264Decoder.destroy();
      } catch (error) {
        LogUtil.warn(`[VideoDecoderH264] ${this.codecType} 解码器释放异常: ${(error as Error).message}`);
      }
      this.h264Decoder = null;
    }

    LogUtil.info(
      `[VideoDecoderH264] ${this.codecType} 解码器已释放 (尝试=${this.decodeAttemptCount}, 成功=${this.decodeSuccessCount})`
    );
  }
}
