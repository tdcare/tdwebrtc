/**
 * 麦克风采集模块
 *
 * 使用 HarmonyOS AudioCapturer API 采集 PCM 音频数据。
 * 配置: 8000 Hz / 单声道 / 16-bit LE — 与 G.711 PCMU 编码对齐。
 * 每 20ms 采集一帧（160 samples = 320 bytes）。
 */

import { audio } from '@kit.AudioKit';
import { LogUtil } from './utils/LogUtil';
import { BusinessError } from '@kit.BasicServicesKit';

// ============================================================
// 采集配置接口
// ============================================================

export interface AudioCaptureConfig {
  sampleRate?: number;   // 默认 8000
  channels?: number;     // 默认 1
  frameDurationMs?: number; // 默认 20
}

// ============================================================
// 默认配置
// ============================================================

interface AudioCaptureDefaults {
  sampleRate: number;
  channels: number;
  frameDurationMs: number;
}

const DEFAULTS: AudioCaptureDefaults = {
  sampleRate: 8000,
  channels: 1,
  frameDurationMs: 20,
};

// ============================================================
// 麦克风采集器
// ============================================================

export class AudioCapture {
  private capturer: audio.AudioCapturer | null = null;
  private isRunning: boolean = false;
  private sampleRate: number;
  private channels: number;
  private frameDurationMs: number;

  /** 音频数据回调：每帧 PCM 16-bit LE 数据 */
  public onAudioData?: (pcmData: ArrayBuffer) => void;
  public onError?: (error: string) => void;

  constructor(config?: AudioCaptureConfig) {
    this.sampleRate = config?.sampleRate ?? DEFAULTS.sampleRate;
    this.channels = config?.channels ?? DEFAULTS.channels;
    this.frameDurationMs = config?.frameDurationMs ?? DEFAULTS.frameDurationMs;
  }

  /**
   * 初始化采集器
   */
  public async initialize(): Promise<boolean> {
    try {
      const channelCount: audio.AudioChannel = this.channels === 2
        ? audio.AudioChannel.CHANNEL_2
        : audio.AudioChannel.CHANNEL_1;

      const sampleRateEnum: audio.AudioSamplingRate = this.getSampleRateEnum(this.sampleRate);

      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: sampleRateEnum,
        channels: channelCount,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      };

      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
        capturerFlags: 0,
      };

      const capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: streamInfo,
        capturerInfo: capturerInfo,
      };

      this.capturer = await audio.createAudioCapturer(capturerOptions);

      // 注册数据回调
      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        if (this.isRunning) {
          this.onAudioData?.(buffer);
        }
      });

      LogUtil.info(`[AudioCapture] 初始化成功: ${this.sampleRate}Hz ${this.channels}ch`);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      const msg: string = `初始化失败: ${err.message} (code: ${err.code})`;
      LogUtil.error(`[AudioCapture] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  /**
   * 开始采集
   */
  public async start(): Promise<boolean> {
    if (this.capturer === null) {
      LogUtil.error('[AudioCapture] 未初始化');
      return false;
    }

    try {
      await this.capturer.start();
      this.isRunning = true;
      LogUtil.info('[AudioCapture] 采集已开始');
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[AudioCapture] 启动失败: ${err.message}`);
      this.onError?.(`启动失败: ${err.message}`);
      return false;
    }
  }

  /**
   * 停止采集
   */
  public async stop(): Promise<void> {
    this.isRunning = false;
    if (this.capturer === null) return;

    try {
      await this.capturer.stop();
      LogUtil.info('[AudioCapture] 采集已停止');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.warn(`[AudioCapture] 停止异常: ${err.message}`);
    }
  }

  /**
   * 释放资源
   */
  public async release(): Promise<void> {
    this.isRunning = false;
    if (this.capturer === null) return;

    try {
      await this.capturer.release();
      this.capturer = null;
      LogUtil.info('[AudioCapture] 已释放');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.warn(`[AudioCapture] 释放异常: ${err.message}`);
      this.capturer = null;
    }
  }

  /**
   * 是否正在采集
   */
  public getIsRunning(): boolean {
    return this.isRunning;
  }

  /**
   * 获取每帧字节数
   * 16-bit PCM: sampleRate * channels * 2 bytes * frameDurationMs / 1000
   */
  public getFrameByteSize(): number {
    return Math.floor(this.sampleRate * this.channels * 2 * this.frameDurationMs / 1000);
  }

  /**
   * 将数字采样率映射到枚举值
   */
  private getSampleRateEnum(rate: number): audio.AudioSamplingRate {
    if (rate === 8000) return audio.AudioSamplingRate.SAMPLE_RATE_8000;
    if (rate === 11025) return audio.AudioSamplingRate.SAMPLE_RATE_11025;
    if (rate === 12000) return audio.AudioSamplingRate.SAMPLE_RATE_12000;
    if (rate === 16000) return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    if (rate === 22050) return audio.AudioSamplingRate.SAMPLE_RATE_22050;
    if (rate === 24000) return audio.AudioSamplingRate.SAMPLE_RATE_24000;
    if (rate === 32000) return audio.AudioSamplingRate.SAMPLE_RATE_32000;
    if (rate === 44100) return audio.AudioSamplingRate.SAMPLE_RATE_44100;
    if (rate === 48000) return audio.AudioSamplingRate.SAMPLE_RATE_48000;
    // 默认 8000 Hz
    return audio.AudioSamplingRate.SAMPLE_RATE_8000;
  }
}
