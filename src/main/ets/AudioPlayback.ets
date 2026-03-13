/**
 * 音频播放模块
 *
 * 使用 HarmonyOS AudioRenderer API 播放 PCM 音频数据。
 * 配置: 8000 Hz / 单声道 / 16-bit LE — 与 G.711 PCMU 解码输出对齐。
 * 使用 VoIP 通话流类型以确保正确路由到听筒/扬声器。
 */

import { audio } from '@kit.AudioKit';
import { LogUtil } from './utils/LogUtil';
import { BusinessError } from '@kit.BasicServicesKit';

// ============================================================
// 播放配置接口
// ============================================================

export interface AudioPlaybackConfig {
  sampleRate?: number;   // 默认 8000
  channels?: number;     // 默认 1
}

// ============================================================
// 默认配置
// ============================================================

interface AudioPlaybackDefaults {
  sampleRate: number;
  channels: number;
}

const DEFAULTS: AudioPlaybackDefaults = {
  sampleRate: 8000,
  channels: 1,
};

// ============================================================
// 音频播放器
// ============================================================

export class AudioPlayback {
  private renderer: audio.AudioRenderer | null = null;
  private isRunning: boolean = false;
  private sampleRate: number;
  private channels: number;

  // 待播放 PCM 数据缓冲队列
  private pendingBuffers: ArrayBuffer[] = [];
  // v41: 收紧缓冲上限，降低音频播放时延
  // 50帧×20ms = 1000ms → 10帧×20ms = 200ms，足够平滑网络抖动
  private readonly MAX_PENDING: number = 10;

  public onError?: (error: string) => void;

  constructor(config?: AudioPlaybackConfig) {
    this.sampleRate = config?.sampleRate ?? DEFAULTS.sampleRate;
    this.channels = config?.channels ?? DEFAULTS.channels;
  }

  /**
   * 初始化播放器
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
  
      const rendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION,
        rendererFlags: 0,
      };
  
      const rendererOptions: audio.AudioRendererOptions = {
        streamInfo: streamInfo,
        rendererInfo: rendererInfo,
      };
  
      this.renderer = await audio.createAudioRenderer(rendererOptions);
  
      // v23: 降低播放音量以减轻声学回声（扬声器 → 麦克风 辅合）
      // 视频通话场景下用户手持设备，扬声器音量过大会被麦克风采集到并回传给对方
      await this.renderer.setVolume(0.3);
  
      // 注册 writeData 回调：AudioRenderer 需要数据时调用
      this.renderer.on('writeData', (buffer: ArrayBuffer) => {
        this.fillBuffer(buffer);
      });
  
      LogUtil.info(`[AudioPlayback] 初始化成功：${this.sampleRate}Hz ${this.channels}ch`);
  
      // v26: 延迟音频路由切换，避免在低端设备上阻塞初始化
      // 默认切换到扬声器（免提）模式，但不在此处立即执行
      // 由上层 CallPage 在 UI 渲染完成后主动调用 setAudioRoute()
      LogUtil.info('[AudioPlayback] 初始化完成，音频路由待设置');
  
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      const msg: string = `初始化失败：${err.message} (code: ${err.code})`;
      LogUtil.error(`[AudioPlayback] ${msg}`);
      this.onError?.(msg);
      return false;
    }
  }

  /**
   * 开始播放
   */
  public async start(): Promise<boolean> {
    if (this.renderer === null) {
      LogUtil.error('[AudioPlayback] 未初始化');
      return false;
    }

    try {
      await this.renderer.start();
      this.isRunning = true;
      LogUtil.info('[AudioPlayback] 播放已开始');
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[AudioPlayback] 启动失败: ${err.message}`);
      this.onError?.(`启动失败: ${err.message}`);
      return false;
    }
  }

  /**
   * 写入 PCM 数据到播放缓冲区
   * @param pcmData PCM 16-bit LE 数据
   */
  public write(pcmData: ArrayBuffer): void {
    if (!this.isRunning) return;

    if (this.pendingBuffers.length >= this.MAX_PENDING) {
      // 丢弃最旧的数据，防止延迟积累
      this.pendingBuffers.shift();
    }
    this.pendingBuffers.push(pcmData);
  }

  /**
   * 停止播放
   */
  public async stop(): Promise<void> {
    this.isRunning = false;
    this.pendingBuffers = [];
    if (this.renderer === null) return;

    try {
      await this.renderer.stop();
      LogUtil.info('[AudioPlayback] 播放已停止');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.warn(`[AudioPlayback] 停止异常: ${err.message}`);
    }
  }

  /**
   * 释放资源
   */
  public async release(): Promise<void> {
    this.isRunning = false;
    this.pendingBuffers = [];
    if (this.renderer === null) return;

    try {
      await this.renderer.release();
      this.renderer = null;
      LogUtil.info('[AudioPlayback] 已释放');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.warn(`[AudioPlayback] 释放异常: ${err.message}`);
      this.renderer = null;
    }
  }

  /**
   * 是否正在播放
   */
  public getIsRunning(): boolean {
    return this.isRunning;
  }

  /**
   * 获取缓冲区待播放帧数
   */
  public getPendingCount(): number {
    return this.pendingBuffers.length;
  }

  /**
   * 设置音频路由（听筒/扬声器）
   * 使用 AudioRoutingManager.setCommunicationDevice 进行真正的输出设备切换
   * @param isSpeakerOn true为扬声器（免提），false为听筒
   */
  public async setAudioRoute(isSpeakerOn: boolean): Promise<void> {
    if (this.renderer === null) {
      LogUtil.warn('[AudioPlayback] 未初始化，无法设置音频路由');
      return;
    }
      
    try {
      const startTime: number = Date.now();
      const audioManager: audio.AudioManager = audio.getAudioManager();
      const routingManager: audio.AudioRoutingManager = audioManager.getRoutingManager();
      // setCommunicationDevice 专为 VoIP 通话设计
      // SPEAKER + true  → 切换到扬声器
      // SPEAKER + false → 切换到听筒（默认）
      await routingManager.setCommunicationDevice(audio.CommunicationDeviceType.SPEAKER, isSpeakerOn);
      const elapsed: number = Date.now() - startTime;
      LogUtil.info(`[AudioPlayback] 音频路由已切换：${isSpeakerOn ? '扬声器（免提）' : '听筒'}，耗时${elapsed}ms`);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[AudioPlayback] 设置音频路由失败：${err.message}`);
      this.onError?.(`设置音频路由失败：${err.message}`);
    }
  }

  /**
   * AudioRenderer writeData 回调：将缓冲队列中的数据填入播放缓冲区
   */
  private fillBuffer(targetBuffer: ArrayBuffer): void {
    const targetView: Uint8Array = new Uint8Array(targetBuffer);
    let offset: number = 0;
    const targetLen: number = targetBuffer.byteLength;

    while (offset < targetLen && this.pendingBuffers.length > 0) {
      const srcBuf: ArrayBuffer | undefined = this.pendingBuffers[0];
      if (srcBuf === undefined) break;
      const srcView: Uint8Array = new Uint8Array(srcBuf);
      const remain: number = targetLen - offset;

      if (srcView.byteLength <= remain) {
        // 整块拷贝
        targetView.set(srcView, offset);
        offset += srcView.byteLength;
        this.pendingBuffers.shift();
      } else {
        // 部分拷贝
        targetView.set(srcView.subarray(0, remain), offset);
        // 保留剩余部分
        const leftover: ArrayBuffer = new ArrayBuffer(srcView.byteLength - remain);
        new Uint8Array(leftover).set(srcView.subarray(remain));
        this.pendingBuffers[0] = leftover;
        offset = targetLen;
      }
    }

    // 如果没有足够数据，填充静音
    if (offset < targetLen) {
      targetView.fill(0, offset, targetLen);
    }
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
    return audio.AudioSamplingRate.SAMPLE_RATE_8000;
  }
}
