/**
 * WebRTC 媒体流管理器
 *
 * 整合麦克风采集、音频播放、摄像头采集、编解码器与 WebRTC RTP 传输。
 *
 * 音频链路（完整实现）:
 *   发送: AudioCapture → Rust 层 sendPcmAudio（G.711 编码 + RTP 打包 + 发送，单次 NAPI）
 *   接收: Rust FrameAssembler（RTP 解包 + G.711 解码） → PCM → AudioPlayback
 *
 * 视频链路（完整实现）:
 *   发送: CameraCapture → Rust 层 encodeAndSendVideo（VP8/H264 编码 + RTP 打包 + 发送，单次 NAPI）
 *   接收: RTP → VP8/H264 解码 → Surface 渲染
 */

import { LogUtil } from './utils/LogUtil';
import { PermissionUtil } from './utils/PermissionUtil';
import { BusinessError } from '@kit.BasicServicesKit';
import { WebRTC } from './WebRTCManager';
import { NapiMediaFrame } from 'libwebrtc_client.so';

import {
  VideoDecoder,
  VideoDecoderConfig,
  DecodedFrame,
  isCodecSupported,
} from './MediaCodec';
import { NapiVideoEncoderConfig } from 'libwebrtc_client.so';
import { AudioCapture } from './AudioCapture';
import type { AudioCaptureConfig } from './AudioCapture';
import { AudioPlayback } from './AudioPlayback';
import type { AudioPlaybackConfig } from './AudioPlayback';
import { CameraCapture } from './CameraCapture';
import type { CameraCaptureConfig } from './CameraCapture';
import common from '@ohos.app.ability.common';

// ============================================================
// 媒体流配置
// ============================================================

export interface MediaStreamVideoConfig {
  enabled: boolean;
  width?: number;
  height?: number;
  frameRate?: number;
  codec?: 'H264' | 'H265' | 'VP8' | 'VP9';
  bitrate?: number;
  cameraPosition?: 'back' | 'front';
}

export interface MediaStreamAudioConfig {
  enabled: boolean;
  sampleRate?: number;
  channels?: number;
  codec?: 'PCMU' | 'PCMA' | 'OPUS' | 'AAC';
  bitrate?: number;
}

export interface MediaStreamConfig {
  video?: MediaStreamVideoConfig;
  audio?: MediaStreamAudioConfig;
}

interface DefaultVideoConfig {
  width: number;
  height: number;
  frameRate: number;
  codec: 'H264' | 'H265' | 'VP8' | 'VP9';
  bitrate: number;
}

interface DefaultAudioConfig {
  sampleRate: number;
  channels: number;
  codec: 'PCMU' | 'PCMA' | 'OPUS' | 'AAC';
  bitrate: number;
}

// v31-fix: 默认分辨率与 Android 端对齐 (1280x720)
const DEFAULT_VIDEO_CONFIG: DefaultVideoConfig = {
  width: 1280,
  height: 720,
  frameRate: 30,
  codec: 'VP8',  // v11: 默认 VP8，实际使用时由 WebRTC.getPreferredVideoCodec() 覆盖
  bitrate: 2000000,
};

const DEFAULT_AUDIO_CONFIG: DefaultAudioConfig = {
  sampleRate: 8000,
  channels: 1,
  codec: 'PCMU',
  bitrate: 64000,
};

// ============================================================
// 5×7 位图字体 — 用于摄像头关闭时的占位画面时间渲染
// 每个字符用7个数字表示，每个数字的5个低位对应一行的像素
// ============================================================
const PLACEHOLDER_FONT: Record<string, number[]> = {
  '0': [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
  '1': [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
  '2': [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
  '3': [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],
  '4': [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
  '5': [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
  '6': [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
  '7': [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
  '8': [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
  '9': [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
  ':': [0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000],
  '-': [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000],
  ' ': [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000],
};

// ============================================================
// WebRTC 媒体流管理器
// ============================================================

export class WebRTCMediaStream {
  private config: MediaStreamConfig;
  private context: common.Context | null = null;

  // v26: 低端设备检测标志
  private isLowEndDevice: boolean = false;

  // 音频相关
  private audioCapture: AudioCapture | null = null;
  private audioPlayback: AudioPlayback | null = null;
  // 轨道 ID 必须与 SDP 协商中 setupMediaTracksForCall() 使用的 ID 一致
  private audioTrackId: string = 'ARDAMSa0';
  private audioTimestamp: number = 0;
  private audioClockRate: number = 8000;

  // 视频相关
  private cameraCapture: CameraCapture | null = null;
  // Phase 3: 视频编码器移入 Rust 层（WebRTC.createVideoEncoder / encodeAndSendVideo）
  // videoEncoder: VideoEncoder 已移除，编码由 Rust InternalVideoEncoder 完成
  private videoEncoderCreated: boolean = false; // Rust 层视频编码器是否已创建
  private videoDecoder: VideoDecoder | null = null;
  // 轨道 ID 必须与 SDP 协商中 setupMediaTracksForCall() 使用的 ID 一致
  private videoTrackId: string = 'ARDAMSv0';
  private videoTimestamp: number = 0;
  private videoClockRate: number = 90000;

  // 视频发送诊断计数
  private videoSendFrameCount: number = 0;
  private videoCaptureCount: number = 0;
  private videoRtpSendCount: number = 0;
  private videoRtpRecvCount: number = 0;
  private audioRtpRecvCount: number = 0;
  private lastStreamDiagTime: number = 0;

  // v16: 墙钟 RTP 时间戳 — 避免相机时间戳与真实时间漂移
  private videoRtpStartMs: number = 0;

  // v17: 帧丢弃机制 — 避免事件队列中旧帧堆积
  // 相机 30fps 回调通过异步链(imageArrival→readNextImage→getComponent)在事件循环中级联排队
  // VP8 软编码 ~100ms/帧阻塞主线程，导致多个回调堆积，编码内容越来越旧
  // 用 single-slot buffer + setTimeout(0) 让所有堆积回调先跑完，只编码最新帧
  private latestCameraFrame: ArrayBuffer | null = null;
  private latestCameraTimestampUs: number = 0;
  private videoEncodeScheduled: boolean = false;
  private videoFrameDropCount: number = 0;
  // v22: 移除 v20 解码限速 — VP8 时域预测编码不允许丢帧
  // 丢帧会破坏参考帧链，导致后续所有 P 帧花屏直到下一关键帧
  // VP8 软件解码 ~15ms/帧，不是主线程瓶颈（编码 ~100ms 才是）
  private lastDecodeProcessTime: number = 0;
  // v20: 编码间隔控制 — 给主线程充足喘息空间
  // v20: 编码间隔 100ms — VP8 编码 ~100ms + 100ms 间隔 = 200ms/帧 ≈ 5fps
  // 确保主线程有 50% 时间处理定时器 (VP8 poll/WebRTC poll) 和相机回调
  // v26: 低端设备动态调整：延长到 150ms，进一步降低 CPU 负载
  // v27: 进一步优化：增加到 200ms，优先保证流畅性而非帧率
  private readonly ENCODE_GAP_MS: number = 50;  // v27: 从 200ms 降到 50ms，提升帧率到 ~15fps
  
  // v26: 低端设备视频配置降级参数
  private readonly LOW_END_DEVICE_WIDTH: number = 176;  // QCIF 分辨率 (176x144)
  private readonly LOW_END_DEVICE_HEIGHT: number = 144;
  private readonly LOW_END_DEVICE_FRAMERATE: number = 5;  // 进一步降低到 5fps
  private readonly LOW_END_DEVICE_ENCODE_GAP: number = 300; // 300ms 间隔 ≈ 3fps，进一步降低 CPU 负载

  // 当前视频编解码类型 (发送端使用)
  private videoCodecType: string = 'H264';

  // v28-fix: PLI 发送限流控制
  private lastPliTimeMs: number = 0;
  private readonly PLI_INTERVAL_MS: number = 100;  // v28-fix4: 进一步缩短到 100ms，持续施压 Android 端
  private pliRequestCount: number = 0;
  private keyframeReceivedAfterPli: boolean = false;  // 标记 PLI 后是否收到关键帧

  // v30: PLI 定时器已移除（Android 不响应 PLI）
  // 保留属性以避免编译错误
  private pliTimerId: number = -1;

  // 远端实际编解码器自动检测 (v08)
  // 根据收到的第一个视频 RTP 包的 payloadType 自动检测远端编解码器
  // 如果与当前解码器不匹配，动态切换解码器
  private remoteVideoCodec: 'H264' | 'VP8' | null = null;
  private decoderSwitchInProgress: boolean = false;

  // 视频帧异步解码 FIFO 队列 — 将视频解码从 RTP 处理循环中移出
  // 解码 + 渲染耗时 20-50ms/帧，若同步执行会阻塞主线程导致 THREAD_BLOCK_6S (ANR)
  // 使用队列而非单槽：防止关键帧在 setTimeout 回调前被 P 帧覆盖
  // v22: 队列上限恢复为 10 — VP8 不能丢帧（会花屏）
  // 队列只起缓冲作用：RTP 回调入队 → setTimeout(0) 出队解码
  // 正常情况下队列深度 0-2，只有主线程暂时繁忙时才会积累
  private pendingVideoFrames: Array<ArrayBuffer> = [];
  private pendingVideoTimestamps: Array<number> = [];
  private pendingVideoKeyFrames: Array<boolean> = [];
  private MAX_PENDING_VIDEO_FRAMES: number = 10; // v29-opt: 改为普通属性，支持动态调整
  private decodeScheduled: boolean = false;
    
  // v27: 延迟监控 — 追踪端到端延迟
  private lastDecodeLatencyMs: number = 0;
  private totalDecodeLatencyMs: number = 0;
  private decodeLatencyCount: number = 0;

  // 远端视频 Surface
  private remoteSurfaceId: string = '';

  // 本地预览 Surface ID（用于摄像头重启）
  private localPreviewSurfaceId: string = '';

  // 视频发送开关标志 — 控制是否将采集帧送入编码器
  // 关闭时仅丢弃帧，不触碰摄像头/编码器生命周期，避免 release 后无法恢复
  private videoSendEnabled: boolean = true;

  // 摄像头关闭时的占位画面定时器
  private placeholderTimerId: number = -1;

  // 接收回调
  public onVideoFrameDecoded?: (frame: DecodedFrame) => void;
  public onAudioFrameDecoded?: (frame: DecodedFrame) => void;
  public onError?: (error: string) => void;

  constructor(config: MediaStreamConfig = {}) {
    this.config = config;
    
    // v26: 方案 B - 检测低端设备并动态调整配置
    this.isLowEndDevice = this.detectLowEndDevice();
    if (this.isLowEndDevice) {
      LogUtil.warn('[MediaStream] 检测到低端设备，将降低视频配置以优化性能');
      this.applyLowEndDeviceOptimizations();
    }
  }

  /**
   * v26: 低端设备检测逻辑
   * 支持 H264 硬件编解码的设备视为高端设备，无需降级
   * 仅不支持硬件编解码（只能用 VP8 软编码）的设备才降级
   */
  private detectLowEndDevice(): boolean {
    try {
      const h264Supported: boolean = isCodecSupported('H264');
      LogUtil.info(`[MediaStream] 设备检测：H264硬件编解码=${h264Supported}, 低端=${!h264Supported}`);
      // 支持 H264 硬件编解码 → 高端设备，不降级
      // 不支持 → 只能用 VP8 软编码，视为低端设备，需要降级
      return !h264Supported;
    } catch (error) {
      // 检测失败时默认不降级
      LogUtil.warn('[MediaStream] 设备检测失败，使用默认配置');
      return false;
    }
  }

  /**
   * v26: 应用低端设备优化策略
   */
  private applyLowEndDeviceOptimizations(): void {
    // 1. 降低视频分辨率
    if (this.config.video) {
      const oldWidth = this.config.video.width;
      const oldHeight = this.config.video.height;
      const oldFrameRate = this.config.video.frameRate;
      
      this.config.video.width = this.LOW_END_DEVICE_WIDTH;
      this.config.video.height = this.LOW_END_DEVICE_HEIGHT;
      this.config.video.frameRate = this.LOW_END_DEVICE_FRAMERATE;
      
      LogUtil.info(
        `[MediaStream] 视频配置降级：${oldWidth}x${oldHeight}@${oldFrameRate}fps -> ` +
        `${this.LOW_END_DEVICE_WIDTH}x${this.LOW_END_DEVICE_HEIGHT}@${this.LOW_END_DEVICE_FRAMERATE}fps`
      );
    }
    
    // 2. 延长编码间隔，减少主线程压力
    // 注意：ENCODE_GAP_MS 是 readonly，需要在 CameraCapture 中动态调整
    LogUtil.info(`[MediaStream] 编码间隔调整：100ms -> ${this.LOW_END_DEVICE_ENCODE_GAP}ms`);
    
    // 3. 增加解码队列保护阈值
    this.MAX_PENDING_VIDEO_FRAMES = 5; // 从默认 10 降到 5，减少队列延迟
    
    LogUtil.warn('[MediaStream] 低端设备优化：降低分辨率、帧率和队列大小以提升实时性');
  }

  /**
   * 设置上下文（需要在 initialize 前调用）
   */
  public setContext(context: common.Context): void {
    this.context = context;
  }

  /**
   * 设置远端视频渲染 Surface
   */
  public setRemoteVideoSurface(surfaceId: string): void {
    this.remoteSurfaceId = surfaceId;
    if (this.videoDecoder !== null) {
      LogUtil.info(`[MediaStream] 设置远端 Surface 到解码器: ${surfaceId}`);
      this.videoDecoder.setSurfaceById(surfaceId);
    } else {
      LogUtil.info(`[MediaStream] 保存远端 SurfaceId，待解码器初始化后设置: ${surfaceId}`);
    }
  }

  // ============================================================
  // 音频 — 完整发送链路
  // ============================================================

  /**
   * 初始化音频发送端
   * AudioCapture → Rust 层一体化（G.711 编码 + RTP 打包 + 发送）
   */
  public async initializeAudioSender(): Promise<boolean> {
    try {
      const sampleRate: number = this.config.audio?.sampleRate ?? DEFAULT_AUDIO_CONFIG.sampleRate;
      const channels: number = this.config.audio?.channels ?? DEFAULT_AUDIO_CONFIG.channels;
      const codec: string = this.config.audio?.codec ?? DEFAULT_AUDIO_CONFIG.codec;

      this.audioClockRate = sampleRate;

      // 0. 请求麦克风权限
      const micGranted: boolean = await PermissionUtil.checkRequestPermissions('ohos.permission.MICROPHONE');
      if (!micGranted) {
        LogUtil.error('[MediaStream] 麦克风权限被拒绝');
        this.onError?.('麦克风权限被拒绝');
        return false;
      }
      LogUtil.info('[MediaStream] 麦克风权限已授权');

      // 1. 初始化麦克风采集（AudioEncoder 已移除，G.711 编码由 Rust 层 sendPcmAudio 一体完成）
      const captureConfig: AudioCaptureConfig = {
        sampleRate: sampleRate,
        channels: channels,
      };
      this.audioCapture = new AudioCapture(captureConfig);
      this.audioCapture.onAudioData = (pcmData: ArrayBuffer) => {
        this.handleCapturedAudio(pcmData);
      };
      this.audioCapture.onError = (err: string) => this.onError?.(`麦克风错误: ${err}`);

      if (!await this.audioCapture.initialize()) {
        LogUtil.error('[MediaStream] 麦克风初始化失败');
        return false;
      }

      // 注意：不在此处添加 WebRTC 音频轨道。
      // 轨道由 SDP 协商流程（createAndSendOffer → setupMediaTracksForCall）统一添加，
      // 本类仅使用相同的 trackId 发送 RTP 数据。

      LogUtil.info(`[MediaStream] 音频发送已初始化: ${sampleRate}Hz ${codec}, trackId=${this.audioTrackId}`);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] 音频发送初始化失败: ${err.message}`);
      return false;
    }
  }

  /**
   * 初始化音频接收端
   * WebRTC RTP → Rust 层 G.711 解码（FrameAssembler 内部自动解码） → AudioPlayback
   */
  public async initializeAudioReceiver(): Promise<boolean> {
    try {
      const sampleRate: number = this.config.audio?.sampleRate ?? DEFAULT_AUDIO_CONFIG.sampleRate;
      const channels: number = this.config.audio?.channels ?? DEFAULT_AUDIO_CONFIG.channels;

      // 1. 初始化音频播放器（AudioDecoder 已移除，G.711 解码由 Rust FrameAssembler 内部完成）
      const playbackConfig: AudioPlaybackConfig = {
        sampleRate: sampleRate,
        channels: channels,
      };
      this.audioPlayback = new AudioPlayback(playbackConfig);
      this.audioPlayback.onError = (err: string) => this.onError?.(`音频播放错误: ${err}`);

      if (!await this.audioPlayback.initialize()) {
        LogUtil.error('[MediaStream] 音频播放器初始化失败');
        return false;
      }

      // 2. 注册完整媒体帧接收回调（Rust 层 RTP 解包 + 帧重组 + G.711 解码，消除 JSON/base64 开销）
      WebRTC.setOnMediaFrameReceived((frame: NapiMediaFrame) => {
        this.handleReceivedMediaFrame(frame);
      });

      LogUtil.info('[MediaStream] 音频接收已初始化');
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] 音频接收初始化失败: ${err.message}`);
      return false;
    }
  }

  // ============================================================
  // 视频 — 完整发送链路
  // ============================================================

  /**
   * 初始化视频发送端
   * CameraCapture → H.264 编码 → RTP
   * @param previewSurfaceId XComponent surfaceId 用于本地预览
   */
  public async initializeVideoSender(previewSurfaceId: string): Promise<boolean> {
    if (this.context === null) {
      LogUtil.error('[MediaStream] 上下文未设置，请先调用 setContext()');
      return false;
    }

    try {
      // 0. 请求摄像头权限
      const cameraGranted: boolean = await PermissionUtil.checkRequestPermissions('ohos.permission.CAMERA');
      if (!cameraGranted) {
        LogUtil.error('[MediaStream] 摄像头权限被拒绝');
        this.onError?.('摄像头权限被拒绝');
        return false;
      }
      LogUtil.info('[MediaStream] 摄像头权限已授权');

      const width: number = this.config.video?.width ?? DEFAULT_VIDEO_CONFIG.width;
      const height: number = this.config.video?.height ?? DEFAULT_VIDEO_CONFIG.height;
      const frameRate: number = this.config.video?.frameRate ?? DEFAULT_VIDEO_CONFIG.frameRate;
      // v36: 根据设备编码能力动态选择发送编解码器
      // getSendVideoCodec() 返回设备最优编码器（H265>H264>VP9>VP8），不再硬编码
      const codec: string = WebRTC.getSendVideoCodec();
      const bitrate: number = this.config.video?.bitrate ?? DEFAULT_VIDEO_CONFIG.bitrate;

      // 记录当前视频编解码类型
      this.videoCodecType = codec;

      // 1. 先初始化摄像头采集（获取实际分辨率）
      const captureConfig: CameraCaptureConfig = {
        width: width,
        height: height,
        frameRate: frameRate,
        cameraPosition: this.config.video?.cameraPosition ?? 'back',
        // v26: 传递低端设备标志，让 CameraCapture 动态调整帧率
        isLowEndDevice: this.isLowEndDevice,
      };
      this.cameraCapture = new CameraCapture(this.context, captureConfig);
      this.cameraCapture.onVideoFrame = (nv12Data: ArrayBuffer, w: number, h: number, timestampUs: number) => {
        this.handleCapturedVideoFrame(nv12Data, w, h, timestampUs);
      };
      this.cameraCapture.onError = (err: string) => this.onError?.(`摄像头错误: ${err}`);

      // 如果提供了预览 Surface ID，则用于本地预览
      LogUtil.info(`[MediaStream] 开始初始化摄像头，预览SurfaceId长度: ${previewSurfaceId.length}`);
      if (!await this.cameraCapture.initialize(previewSurfaceId)) {
        LogUtil.error('[MediaStream] 摄像头初始化失败');
        return false;
      }
      // 保存本地预览Surface ID，以便摄像头重启时使用
      this.localPreviewSurfaceId = previewSurfaceId;
      LogUtil.info('[MediaStream] 摄像头初始化完成');

      // 2. 用摄像头实际分辨率创建 Rust 层内部视频编码器
      //    Phase 3: 编码器移入 Rust 层，消除 pollOutput NAPI 往返
      const actualWidth: number = this.cameraCapture.getActualWidth();
      const actualHeight: number = this.cameraCapture.getActualHeight();
      if (actualWidth !== width || actualHeight !== height) {
        LogUtil.warn(`[MediaStream] 摄像头实际分辨率 ${actualWidth}x${actualHeight} 与请求 ${width}x${height} 不同，编码器将使用实际分辨率`);
      }

      const encoderConfig: NapiVideoEncoderConfig = {
        width: actualWidth,
        height: actualHeight,
        frameRate: frameRate,
        bitRate: this.isLowEndDevice ? 300000 : bitrate,
        pixelFormat: 'NV12',
        iFrameInterval: this.isLowEndDevice ? 500 : 2000,
      };
      const actualCodec: string = WebRTC.createVideoEncoder(encoderConfig, codec);
      if (actualCodec === '') {
        LogUtil.error('[MediaStream] Rust 层视频编码器创建失败');
        return false;
      }
      this.videoEncoderCreated = true;

      // 检查编码器是否回退了（例如 H264 硬编码失败回退到 VP8）
      if (actualCodec !== codec) {
        LogUtil.warn(`[MediaStream] v36 编码器回退: ${codec} → ${actualCodec}`);
        this.videoCodecType = actualCodec;
        WebRTC.updateVideoTrackCodec(actualCodec);
      }

      // 3. 视频轨道由 setupMediaTracksForCall() 在 SDP 协商时统一添加
      // 不在此处重复添加，避免产生不同 SSRC 导致 Android 丢弃 RTP 包
      // WebRTC.addVideoTrack(this.videoTrackId, codec);

      LogUtil.info(`[MediaStream] v25 视频发送初始化: codec=${codec}, videoCodecType=${this.videoCodecType}, 实际分辨率=${actualWidth}x${actualHeight} @ ${frameRate}fps`);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] 视频发送初始化失败: ${err.message}`);
      return false;
    }
  }

  /**
   * 启动视频编码器（Rust 层内部编码器）
   */
  public async startVideoEncoder(): Promise<boolean> {
    if (this.videoEncoderCreated) {
      const ok: boolean = WebRTC.startVideoEncoder();
      LogUtil.info(`[MediaStream] Rust 视频编码器启动: ${ok}`);
      return ok;
    }
    return false;
  }

  // ============================================================
  // 视频 — 完整接收链路
  // ============================================================

  /**
   * 初始化视频接收端
   * RTP → H.264 解码 → Surface 渲染
   */
  public async initializeVideoReceiver(): Promise<boolean> {
    try {
      // v32-fix: 解码器分辨率必须与编码器输出一致 (1280x720)，不能使用 config.video 可能被低端设备逻辑覆盖的值
      // 实际显示分辨率由解码器输出的 Surface 决定，这里只需要保证编解码器参数匹配
      const width: number = 1280;  // 固定与 Android 端对齐
      const height: number = 720;
      // v36: 根据设备解码能力动态选择接收编解码器
      // getPreferredVideoCodec() 返回 SDP 协商结果或设备最优解码器
      // 如果硬解码器初始化/启动失败，自动回退到 VP8 软解码
      let codec: string = WebRTC.getPreferredVideoCodec();
  
      // 1. 初始化视频解码器（根据配置自动选择 H264 或 VP8）
      const decoderConfig: VideoDecoderConfig = {
        codec: codec as 'H264' | 'VP8',
        width: width,
        height: height,
      };
      this.videoDecoder = new VideoDecoder(decoderConfig);
      this.videoDecoder.onDecodedFrame = (frame: DecodedFrame) => {
        this.onVideoFrameDecoded?.(frame);
      };
      this.videoDecoder.onError = (err: string) => this.onError?.(`视频解码错误：${err}`);
  
      // 2. 设置 Surface（如果已有）
      if (this.remoteSurfaceId !== '') {
        this.videoDecoder.setSurfaceById(this.remoteSurfaceId);
      }
  
      const initResult = await this.videoDecoder.initialize();
      if (!initResult) {
        // v36: 硬解码器初始化失败时回退到 VP8 软解码
        if (codec !== 'VP8') {
          LogUtil.warn(`[MediaStream] ${codec} 解码器初始化失败，回退到 VP8 软解码`);
          await this.videoDecoder.release();
          codec = 'VP8';
          const fallbackConfig: VideoDecoderConfig = { codec: 'VP8', width: width, height: height };
          this.videoDecoder = new VideoDecoder(fallbackConfig);
          this.videoDecoder.onDecodedFrame = (frame: DecodedFrame) => { this.onVideoFrameDecoded?.(frame); };
          this.videoDecoder.onError = (err: string) => this.onError?.(`视频解码错误：${err}`);
          if (this.remoteSurfaceId !== '') { this.videoDecoder.setSurfaceById(this.remoteSurfaceId); }
          const fallbackInit = await this.videoDecoder.initialize();
          if (!fallbackInit) {
            LogUtil.error('[MediaStream] VP8 解码器也初始化失败');
            return false;
          }
        } else {
          LogUtil.error('[MediaStream] 视频解码器初始化失败');
          return false;
        }
      }
  
      LogUtil.info(`[MediaStream] v36 视频接收初始化：codec=${codec}, 分辨率=${width}x${height}`);
        
      // v32-fix: 启动解码器并添加诊断日志
      const startResult = await this.videoDecoder.start();
      if (!startResult) {
        // v36: 硬解码器启动失败时回退到 VP8
        if (codec !== 'VP8') {
          LogUtil.warn(`[MediaStream] ${codec} 解码器启动失败，回退到 VP8 软解码`);
          await this.videoDecoder.release();
          codec = 'VP8';
          const fallbackConfig2: VideoDecoderConfig = { codec: 'VP8', width: width, height: height };
          this.videoDecoder = new VideoDecoder(fallbackConfig2);
          this.videoDecoder.onDecodedFrame = (frame: DecodedFrame) => { this.onVideoFrameDecoded?.(frame); };
          this.videoDecoder.onError = (err: string) => this.onError?.(`视频解码错误：${err}`);
          if (this.remoteSurfaceId !== '') { this.videoDecoder.setSurfaceById(this.remoteSurfaceId); }
          if (!await this.videoDecoder.initialize()) {
            LogUtil.error('[MediaStream] VP8 解码器回退初始化失败');
            return false;
          }
          const startOk = await this.videoDecoder.start();
          if (!startOk) {
            LogUtil.error('[MediaStream] VP8 解码器回退启动失败');
            return false;
          }
        } else {
          LogUtil.error('[MediaStream] 视频解码器启动失败');
          return false;
        }
      }
        
      LogUtil.info(`[MediaStream] v32-fix 视频解码器已启动：codec=${codec}`);

      // v36: 如果硬解码回退到了 VP8，同步更新 config，保证自动检测机制一致性
      if (codec === 'VP8' && this.config.video) {
        this.config.video.codec = 'VP8';
        LogUtil.info('[MediaStream] v36 解码器回退后同步 config.video.codec=VP8');
      }

      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] 视频接收初始化失败：${err.message}`);
      return false;
    }
  }

  // ============================================================
  // 启停控制
  // ============================================================

  /**
   * 启动音频发送
   */
  public async startAudioSending(): Promise<boolean> {
    if (this.audioCapture !== null) {
      await this.audioCapture.start();
    }
    LogUtil.info('[MediaStream] 音频发送已启动');
    return true;
  }

  /**
   * 启动音频接收
   */
  public async startAudioReceiving(): Promise<boolean> {
    if (this.audioPlayback !== null) {
      await this.audioPlayback.start();
    }
    LogUtil.info('[MediaStream] 音频接收已启动');
    return true;
  }

  /**
   * 启动视频采集
   */
  public async startVideoCapture(): Promise<boolean> {
    LogUtil.info('[MediaStream] 开始启动视频采集');
    
    // 先启动 Rust 层内部编码器
    if (this.videoEncoderCreated) {
      const ok: boolean = WebRTC.startVideoEncoder();
      LogUtil.info(`[MediaStream] Rust 视频编码器启动: ${ok}`);
      // H264 OH_AVCodec 是异步的，需要等待 Buffer 队列就绪
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));
    }
    
    // 再启动摄像头采集
    if (this.cameraCapture !== null) {
      LogUtil.info('[MediaStream] 开始启动摄像头采集');
      const startResult = await this.cameraCapture.start();
      LogUtil.info(`[MediaStream] 摄像头采集启动结果: ${startResult}`);
      
      // 检查摄像头是否真的在运行
      if (!this.cameraCapture.getIsRunning()) {
        LogUtil.warn('[MediaStream] 摄像头未运行，可能使用了模拟帧模式');
      }
    }
    
    LogUtil.info('[MediaStream] 视频采集已启动');
    return true;
  }

  /**
   * 启动视频解码器
   */
  public async startVideoDecoder(): Promise<boolean> {
    if (this.videoDecoder !== null) {
      await this.videoDecoder.start();
      LogUtil.info('[MediaStream] 视频解码器已启动');
      // OH_AVCodec 是异步的，需要等待 on_need_input_buffer 回调
      // 等待 100ms 让 Buffer 队列就绪
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));
      
      // v27-fix3: 解码器启动后主动请求关键帧，确保第一个画面清晰
      LogUtil.info('[MediaStream] 请求远端发送关键帧...');
      await this.requestKeyFrame();
      
      return true;
    }
    return false;
  }

  /**
   * v30b: PLI 定时请求已移除（确认 Android 不响应 PLI）
   * 保留空方法避免其他代码调用报错
   */
  private startPeriodicPliRequests(): void {
    // no-op: Android 不响应 PLI
  }

  private stopPeriodicPliRequests(): void {
    if (this.pliTimerId !== -1) {
      clearInterval(this.pliTimerId);
      this.pliTimerId = -1;
    }
  }

  /**
   * 停止所有
   */
  public async stopAll(): Promise<void> {
    // v30: 停止定时 PLI 请求
    this.stopPeriodicPliRequests();

    // 清除待解码的视频帧队列
    this.pendingVideoFrames = [];
    this.pendingVideoTimestamps = [];
    this.pendingVideoKeyFrames = [];
    this.decodeScheduled = false;

    // 重置远端编解码器检测状态 (v08)
    this.remoteVideoCodec = null;
    this.decoderSwitchInProgress = false;

    if (this.audioCapture !== null) {
      await this.audioCapture.stop();
    }
    if (this.audioPlayback !== null) {
      await this.audioPlayback.stop();
    }
    if (this.cameraCapture !== null) {
      await this.cameraCapture.stop();
    }
    // Phase 3: Rust 层视频编码器停止 + 销毁
    if (this.videoEncoderCreated) {
      WebRTC.stopVideoEncoder();
      WebRTC.destroyVideoEncoder();
      this.videoEncoderCreated = false;
    }
    if (this.videoDecoder !== null) {
      await this.videoDecoder.release();
    }
    LogUtil.info('[MediaStream] 所有媒体已停止');
  }

  // ============================================================
  // 内部数据流处理
  // ============================================================

  /**
   * 处理麦克风采集的 PCM 数据 → Rust 层一体化发送（G.711 编码 + RTP 打包 + 发送）
   *
   * 旧路径：ETS AudioEncoder.encodeSamples() → onEncodedFrame → sendEncodedAudioFrame（2次 NAPI）
   * 新路径：单次 sendPcmAudio NAPI 调用，Rust 内部完成 G.711 + RTP + send
   */
  private handleCapturedAudio(pcmData: ArrayBuffer): void {
    const timestamp: number = this.audioTimestamp;
    // 每次采集一帧: sampleRate * 0.02 = 采样数 (20ms)
    this.audioTimestamp += Math.floor(this.audioClockRate * 0.02);
    WebRTC.sendPcmAudio(this.audioTrackId, new Uint8Array(pcmData), timestamp);
  }

  /**
   * 处理摄像头采集的 NV12 数据 → 编码
   *
   * v17: 使用 single-slot buffer + setTimeout(0) 帧丢弃机制
   * 相机 30fps 回调通过异步链在事件循环中级联排队，VP8 编码 ~80ms/帧阻塞主线程
   * 导致多个回调堆积。每次回调只保存最新帧，用 setTimeout(0) 延迟编码
   * 让所有堆积的回调先跑完，然后只编码最新那一帧。
   */
  private handleCapturedVideoFrame(nv12Data: ArrayBuffer, width: number, height: number, timestampUs: number): void {
    // 视频开关：关闭时静默丢弃帧，摄像头和编码器保持运行
    if (!this.videoSendEnabled) {
      return;
    }
    this.videoCaptureCount++;

    // v17: 只保留最新帧，丢弃旧帧
    if (this.latestCameraFrame !== null) {
      this.videoFrameDropCount++;
    }
    this.latestCameraFrame = nv12Data;
    this.latestCameraTimestampUs = timestampUs;

    // 用 setTimeout(0) 延迟编码到下一个事件循环迭代
    // 让所有已排队的相机回调先跑完，更新 latestCameraFrame 为最新帧
    if (!this.videoEncodeScheduled) {
      this.videoEncodeScheduled = true;
      setTimeout(() => this.encodeLatestCameraFrame(), 0);
    }
  }

  /**
   * v17: 编码最新的相机帧
   *
   * Phase 3: 单次 encodeAndSendVideo NAPI 调用，Rust 内部完成编码 + RTP 打包 + 发送
   * 旧路径：ETS encodeFrame + pollOutput + sendEncodedVideoFrame（3+ 次 NAPI）
   */
  private async encodeLatestCameraFrame(): Promise<void> {
    this.videoEncodeScheduled = false;

    if (this.latestCameraFrame === null || !this.videoEncoderCreated) {
      return;
    }

    // 取出最新帧并清空槽位
    const frameData: ArrayBuffer = this.latestCameraFrame;
    const timestampUs: number = this.latestCameraTimestampUs;
    this.latestCameraFrame = null;

    // v16: 用墙钟时间生成 RTP 时间戳 (90kHz)
    const nowMs: number = Date.now();
    if (this.videoRtpStartMs === 0) {
      this.videoRtpStartMs = nowMs;
    }
    this.videoTimestamp = Math.floor((nowMs - this.videoRtpStartMs) * 90);

    // Phase 3: 单次 NAPI 调用 — Rust 内部完成 YUV 编码 + drain 输出 + RTP 打包 + handle_write
    const rtpCount: number = WebRTC.encodeAndSendVideo(
      this.videoTrackId,
      new Uint8Array(frameData),
      timestampUs,
      this.videoTimestamp
    );

    this.videoSendFrameCount++;
    this.videoRtpSendCount += Math.max(rtpCount, 0);

    this.logStreamDiag();

    // v19: 编码完成后，给主线程 ENCODE_GAP_MS 的喘息空间
    this.videoEncodeScheduled = true;
    setTimeout(() => this.encodeLatestCameraFrame(), this.ENCODE_GAP_MS);
  }

  // handleEncodedVideoFrame 已移除 — Phase 3: 编码输出留在 Rust 层内部
  // encodeAndSendVideo 单次 NAPI 调用完成编码 + RTP + 发送

  /**
   * 处理 Rust 层 RTP 解包 + 帧重组后的完整媒体帧
   *
   * NapiMediaFrame 字段:
   *   trackId: string, data: ArrayBuffer, timestamp: number,
   *   isKeyFrame: boolean, isAudio: boolean, payloadType: number, ssrc: number
   *
   * 旧路径：ETS 层逐 RTP 包解析 → VP8/H264 帧重组 → 入队解码（~700 行代码）
   * 新路径：Rust FrameAssembler 输出完整帧 → 直接入队解码
   */
  private handleReceivedMediaFrame(frame: NapiMediaFrame): void {
    if (frame.isAudio) {
      // 音频 PCM 数据（Rust FrameAssembler 已自动完成 G.711 解码）→ 直接播放
      this.audioRtpRecvCount++;
      this.audioPlayback?.write(frame.data);
      this.onAudioFrameDecoded?.(new DecodedFrame(frame.data, frame.timestamp));
    } else {
      // 视频完整帧 → 直接入队解码
      this.videoRtpRecvCount++;

      // 自动检测远端编解码器并按需切换解码器
      if (this.remoteVideoCodec === null) {
        const detectedCodec: 'H264' | 'VP8' = (frame.payloadType === 96) ? 'VP8' : 'H264';
        this.remoteVideoCodec = detectedCodec;
        const currentCodec: string = this.config.video?.codec ?? WebRTC.getPreferredVideoCodec() as string;
        LogUtil.info(`[MediaStream] 检测到远端视频编解码：${detectedCodec} (PT=${frame.payloadType}), 当前解码器：${currentCodec}`);

        if (detectedCodec !== currentCodec && !this.decoderSwitchInProgress) {
          LogUtil.info(`[MediaStream] 编解码器不匹配! 远端=${detectedCodec}, 本端=${currentCodec}, 自动切换解码器`);
          this.switchVideoDecoder(detectedCodec);
        }
      }

      // 诊断日志
      if (this.videoRtpRecvCount <= 5 || this.videoRtpRecvCount % 100 === 0 || frame.isKeyFrame) {
        LogUtil.info(`[MediaStream] 视频帧(${this.videoRtpRecvCount}): ${frame.data.byteLength}B, key=${frame.isKeyFrame}, pt=${frame.payloadType}, ts=${frame.timestamp}`);
      }

      this.scheduleVideoDecode(frame.data, frame.timestamp, frame.isKeyFrame);
    }
  }

  /**
   * 调度视频帧异步解码
   *
   * 将视频解码从 RTP 处理循环中移出到独立的事件循环迭代，
   * 避免解码阻塞主线程造成 THREAD_BLOCK_6S (ANR)。
   */
  private scheduleVideoDecode(frameData: ArrayBuffer, timestamp: number, isKeyFrame: boolean = false): void {
    // 关键帧到达：清空队列，从关键帧开始新的解码序列
    if (isKeyFrame) {
      this.pendingVideoFrames = [frameData];
      this.pendingVideoTimestamps = [timestamp];
      this.pendingVideoKeyFrames = [true];
      
      LogUtil.info('[MediaStream] 收到关键帧，刷新队列');
      
      if (!this.decodeScheduled) {
        this.decodeScheduled = true;
        setTimeout(() => {
          this.processNextVideoFrame();
        }, 0);
      }
      return;
    }
    
    // v30b: 低端设备队列满时，丢弃最旧的非关键帧（保留参考帧链的最新部分）
    if (this.pendingVideoFrames.length >= this.MAX_PENDING_VIDEO_FRAMES) {
      let dropped: boolean = false;
      for (let i = 0; i < this.pendingVideoFrames.length; i++) {
        if (!this.pendingVideoKeyFrames[i]) {
          this.pendingVideoFrames.splice(i, 1);
          this.pendingVideoTimestamps.splice(i, 1);
          this.pendingVideoKeyFrames.splice(i, 1);
          dropped = true;
          break;
        }
      }
      if (!dropped) {
        this.pendingVideoFrames.shift();
        this.pendingVideoTimestamps.shift();
        this.pendingVideoKeyFrames.shift();
      }
    }
    this.pendingVideoFrames.push(frameData);
    this.pendingVideoTimestamps.push(timestamp);
    this.pendingVideoKeyFrames.push(isKeyFrame);

    // 调度异步解码
    if (!this.decodeScheduled) {
      this.decodeScheduled = true;
      setTimeout(() => {
        this.processNextVideoFrame();
      }, 0);
    }
  }

  /**
   * v27: 清空待解码队列中的旧帧，只保留最新关键帧
   * 防止缓冲区累积导致延迟过高
   */
  private clearStaleVideoFrames(): void {
    if (this.pendingVideoFrames.length > 3) {
      // 队列超过 3 帧，丢弃所有旧帧，只保留最后 3 帧
      const keepCount: number = Math.min(3, this.pendingVideoFrames.length);
      const dropCount: number = this.pendingVideoFrames.length - keepCount;
        
      this.pendingVideoFrames.splice(0, dropCount);
      this.pendingVideoTimestamps.splice(0, dropCount);
      this.pendingVideoKeyFrames.splice(0, dropCount);
        
      LogUtil.warn(`[MediaStream] 清空待解码队列：丢弃${dropCount}帧，保留${keepCount}帧`);
    }
  }
  
  /**
   * v27-fix3: 强制请求关键帧（用于初始化和花屏恢复）
   * v28: 通过 WebRTC.sendRtcpPLI 发送 RTCP PLI 包
   */
  public async requestKeyFrame(): Promise<void> {
    LogUtil.info('[MediaStream] 请求关键帧...');
    
    // v28: 通过 WebRTCManager 发送 RTCP PLI 包
    try {
      const success: boolean = await WebRTC.sendRtcpPli(this.videoTrackId);
      if (success) {
        LogUtil.info('[MediaStream] PLI 已发送，等待关键帧...');
        return;
      } else {
        LogUtil.warn('[MediaStream] PLI 发送失败，回退到本地编码器请求');
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] PLI 发送异常：${err.message}`);
    }
    
    // 回退方案：通过 Rust 层内部视频编码器请求关键帧
    if (this.videoEncoderCreated) {
      WebRTC.requestVideoKeyFrame();
      LogUtil.info('[MediaStream] 已向 Rust 编码器请求关键帧');
    }
  }
  
  /**
   * v30b: 处理待解码的视频帧
   *
   * 低端设备策略：批量解码队列中所有帧（保持参考帧链完整），只渲染最后一帧
   * VP8 解码只需 5-9ms/帧，不花屏的关键是不丢 P 帧、保持参考帧链连续
   * 渲染（I420→RGBA）才是性能瓶颈，所以每批只渲染一次
   */
  private async processNextVideoFrame(): Promise<void> {
    // 解码器切换中，丢弃所有帧
    if (this.decoderSwitchInProgress) {
      this.pendingVideoFrames = [];
      this.pendingVideoTimestamps = [];
      this.pendingVideoKeyFrames = [];
      this.decodeScheduled = false;
      return;
    }

    if (this.videoDecoder === null || this.pendingVideoFrames.length === 0) {
      this.decodeScheduled = false;
      return;
    }

    // v30b: 低端设备批量解码 — 一次性解码队列中所有帧，只渲染最后一帧
    if (this.isLowEndDevice) {
      const batchSize: number = this.pendingVideoFrames.length;
      let decodedCount: number = 0;
    
      // 逐帧解码（不渲染），保持 libvpx 参考帧链完整
      while (this.pendingVideoFrames.length > 0) {
        const frameData: ArrayBuffer = this.pendingVideoFrames.shift() as ArrayBuffer;
        const timestamp: number = this.pendingVideoTimestamps.shift() as number;
        const isKeyFrame: boolean = this.pendingVideoKeyFrames.shift() as boolean;
        const isLastFrame: boolean = this.pendingVideoFrames.length === 0;
    
        this.decodeLatencyCount++;
        if (isKeyFrame) {
          LogUtil.info(`[MediaStream] ★ 解码关键帧：batch=${batchSize}`);
        }
    
        // v31-fix: H264 硬件解码需要 await
        await this.videoDecoder.decodeFrame(frameData, timestamp, isKeyFrame, isLastFrame);
        decodedCount++;
      }
    
      // v32-fix: H264 硬件解码器直接输出到 Surface，不需要手动渲染；VP8 软件解码器需要手动渲染
      // 只有 VP8 且批量解码时才需要在批量后统一渲染
      if (decodedCount > 1 && this.config.video?.codec === 'VP8') {
        this.videoDecoder.renderToSurface();
      }
    
      if (decodedCount > 1) {
        LogUtil.info(`[MediaStream] v30b: 批量解码${decodedCount}帧，只渲染最后 1 帧`);
      }
    } else {
      // 非低端设备：每次解码一帧（原始逻辑）
      const frameData: ArrayBuffer | undefined = this.pendingVideoFrames.shift();
      const timestamp: number | undefined = this.pendingVideoTimestamps.shift();
      const isKeyFrame: boolean | undefined = this.pendingVideoKeyFrames.shift();

      if (frameData !== undefined) {
        this.decodeLatencyCount++;
        if ((isKeyFrame ?? false)) {
          LogUtil.info(`[MediaStream] ★ 解码关键帧：队列深度=${this.pendingVideoFrames.length}`);
        }
        // v31-fix: H264 硬件解码需要 await
        await this.videoDecoder.decodeFrame(frameData, timestamp as number, isKeyFrame ?? false);
      }
    }

    // 队列中还有帧，继续调度
    if (this.pendingVideoFrames.length > 0) {
      setTimeout(() => {
        this.processNextVideoFrame();
      }, 0);
    } else {
      this.decodeScheduled = false;
    }
  }

  /**
   * v08: 动态切换视频解码器
   *
   * 当检测到远端实际编解码器与当前解码器不匹配时调用。
   * 释放旧解码器，创建并启动新的正确类型解码器。
   */
  private async switchVideoDecoder(codec: 'H264' | 'VP8'): Promise<void> {
    this.decoderSwitchInProgress = true;
    LogUtil.info(`[MediaStream] v08 开始切换解码器 → ${codec}`);

    // 1. 释放旧解码器
    if (this.videoDecoder !== null) {
      try {
        await this.videoDecoder.release();
      } catch (e) {
        LogUtil.warn(`[MediaStream] 释放旧解码器异常: ${(e as Error).message}`);
      }
      this.videoDecoder = null;
    }

    // 2. 清空待解码队列（旧编解码器格式的数据）
    this.pendingVideoFrames = [];
    this.pendingVideoTimestamps = [];
    this.pendingVideoKeyFrames = [];
    this.decodeScheduled = false;

    // 3. 创建新解码器
    // v34-fix: 解码器分辨率必须固定为 1280x720（与 Android 端对齐），
    // 不能使用 config.video（可能被低端设备逻辑降级到 176x144）
    const width: number = 1280;
    const height: number = 720;
    const decoderConfig: VideoDecoderConfig = {
      codec: codec,
      width: width,
      height: height,
    };
    this.videoDecoder = new VideoDecoder(decoderConfig);
    this.videoDecoder.onDecodedFrame = (frame: DecodedFrame) => {
      this.onVideoFrameDecoded?.(frame);
    };
    this.videoDecoder.onError = (err: string) => this.onError?.(`视频解码错误: ${err}`);

    // 4. 设置 Surface
    if (this.remoteSurfaceId !== '') {
      this.videoDecoder.setSurfaceById(this.remoteSurfaceId);
    }

    // 5. 初始化
    if (!await this.videoDecoder.initialize()) {
      LogUtil.error(`[MediaStream] v08 ${codec} 解码器初始化失败`);
      this.decoderSwitchInProgress = false;
      return;
    }

    // 6. 启动
    await this.videoDecoder.start();
    // 等待 Buffer 队列就绪
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));

    this.decoderSwitchInProgress = false;
    LogUtil.info(`[MediaStream] v08 视频解码器已成功切换到 ${codec}`);
  }

  /** 每3秒打一次流管线诊断日志 */
  private logStreamDiag(): void {
    const now: number = Date.now();
    if (now - this.lastStreamDiagTime >= 3000) {
      LogUtil.info(`[MediaStream] 管线诊断: 采集=${this.videoCaptureCount}, 丢弃=${this.videoFrameDropCount}, 编码发送=${this.videoSendFrameCount}, RTP发送=${this.videoRtpSendCount}, 视频RTP收=${this.videoRtpRecvCount}, 音频RTP收=${this.audioRtpRecvCount}`);
      this.lastStreamDiagTime = now;
    }
  }

  // ============================================================
  // 资源释放
  // ============================================================

  /**
   * 释放所有资源
   */
  public async release(): Promise<void> {
    // 停止占位画面定时器
    this.stopPlaceholderTimer();

    // v30: 停止定时 PLI 请求
    this.stopPeriodicPliRequests();

    // 清除待解码的视频帧队列
    this.pendingVideoFrames = [];
    this.pendingVideoTimestamps = [];
    this.pendingVideoKeyFrames = [];
    this.decodeScheduled = false;

    // 重置远端编解码器检测状态 (v08)
    this.remoteVideoCodec = null;
    this.decoderSwitchInProgress = false;

    // v16: 重置墙钟 RTP 时间戳基准
    this.videoRtpStartMs = 0;

    // v17: 重置帧丢弃状态
    this.latestCameraFrame = null;
    this.latestCameraTimestampUs = 0;
    this.videoEncodeScheduled = false;
    this.videoFrameDropCount = 0;

    await this.audioCapture?.release();
    await this.audioPlayback?.release();
    await this.cameraCapture?.release();
    // Phase 3: Rust 层视频编码器销毁
    if (this.videoEncoderCreated) {
      WebRTC.stopVideoEncoder();
      WebRTC.destroyVideoEncoder();
      this.videoEncoderCreated = false;
    }
    await this.videoDecoder?.release();

    this.audioCapture = null;
    this.audioPlayback = null;
    this.cameraCapture = null;
    this.videoDecoder = null;

    LogUtil.info('[MediaStream] 已释放');
  }

  /**
   * 切换前后摄像头
   *
   * CameraCapture.switchCamera() 只切换 config，需要完整的 release → re-initialize 流程：
   * 1. 暂停帧发送
   * 2. 释放旧摄像头资源
   * 3. 切换摄像头方向
   * 4. 用保存的 localPreviewSurfaceId 重新初始化
   * 5. 启动摄像头采集
   * 6. 恢复帧发送 + 请求关键帧
   */
  public async switchCamera(): Promise<boolean> {
    if (this.cameraCapture === null || this.localPreviewSurfaceId.length === 0) {
      LogUtil.error('[MediaStream] 无法切换摄像头：摄像头或预览Surface未就绪');
      return false;
    }

    try {
      // 1. 暂停帧发送，避免切换过程中编码残留帧
      this.videoSendEnabled = false;

      // 2. 释放旧摄像头
      await this.cameraCapture.release();
      LogUtil.info('[MediaStream] 旧摄像头已释放');

      // 3. 切换方向（只更新 config.cameraPosition）
      await this.cameraCapture.switchCamera();

      // 4. 重新初始化（使用新方向 + 原 surfaceId）
      const initOk: boolean = await this.cameraCapture.initialize(this.localPreviewSurfaceId);
      if (!initOk) {
        LogUtil.error('[MediaStream] 切换后摄像头初始化失败');
        return false;
      }
      LogUtil.info('[MediaStream] 新摄像头初始化成功');

      // 5. 启动摄像头采集
      await this.cameraCapture.start();

      // 6. 恢复帧发送 + 延迟请求关键帧
      this.videoSendEnabled = true;
      setTimeout(() => {
        this.requestVideoKeyFrame();
      }, 200);

      LogUtil.info('[MediaStream] 摄像头切换完成');
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[MediaStream] 摄像头切换失败: ${err.message}`);
      // 恢复帧发送，防止永久卡死
      this.videoSendEnabled = true;
      return false;
    }
  }

  /**
   * 设置音频静音状态
   */
  public async setAudioMute(muted: boolean): Promise<void> {
    if (this.audioCapture !== null) {
      if (muted) {
        // 停止音频采集，相当于静音
        await this.audioCapture.stop();
        LogUtil.info('[MediaStream] 音频已静音');
      } else {
        // 重新开始音频采集
        await this.audioCapture.start();
        LogUtil.info('[MediaStream] 音频静音已取消');
      }
    }
  }

  /**
   * 设置音频路由（听筒/免提）
   */
  public async setAudioRoute(isSpeakerOn: boolean): Promise<void> {
    if (this.audioPlayback !== null) {
      await this.audioPlayback.setAudioRoute(isSpeakerOn);
    }
  }

  /**
   * 设置视频开关状态
   *
   * 仅通过标志位控制帧是否送入编码器，不触碰摄像头/编码器生命周期。
   * 关闭时：摄像头继续采集但帧在 handleCapturedVideoFrame 入口被丢弃，
   *         同时启动定时器每秒生成带时间戳的占位画面发送给远端
   * 打开时：停止占位画面，恢复帧传递，延迟请求关键帧让远端重新同步
   */
  public async setVideoEnabled(enabled: boolean): Promise<void> {
    this.videoSendEnabled = enabled;
    if (enabled) {
      this.stopPlaceholderTimer();
      LogUtil.info('[MediaStream] 视频发送已恢复');
      // 恢复后请求关键帧，确保远端能立即解码
      setTimeout(() => {
        this.requestVideoKeyFrame();
      }, 200);
    } else {
      LogUtil.info('[MediaStream] 视频发送已暂停，启动占位画面');
      this.startPlaceholderTimer();
    }
  }

  // ============================================================
  // 摄像头关闭时 — 占位画面（显示当前时间）
  // ============================================================

  /**
   * 启动占位画面定时器，每秒生成一帧带时间戳的黑色画面发送给远端
   */
  private startPlaceholderTimer(): void {
    this.stopPlaceholderTimer();
    // 立即发送一帧
    this.generateAndEncodePlaceholder();
    // 每秒更新一次（时间精确到秒）
    this.placeholderTimerId = setInterval(() => {
      this.generateAndEncodePlaceholder();
    }, 1000);
  }

  /**
   * 停止占位画面定时器
   */
  private stopPlaceholderTimer(): void {
    if (this.placeholderTimerId !== -1) {
      clearInterval(this.placeholderTimerId);
      this.placeholderTimerId = -1;
    }
  }

  /**
   * 生成占位画面 NV12 帧并通过 Rust 层编码发送
   */
  private generateAndEncodePlaceholder(): void {
    if (!this.videoEncoderCreated || this.cameraCapture === null) return;

    const w: number = this.cameraCapture.getActualWidth();
    const h: number = this.cameraCapture.getActualHeight();
    if (w === 0 || h === 0) return;

    // 生成 NV12 帧
    const nv12: ArrayBuffer = this.renderTimePlaceholder(w, h);

    // RTP 时间戳
    const nowMs: number = Date.now();
    if (this.videoRtpStartMs === 0) {
      this.videoRtpStartMs = nowMs;
    }
    this.videoTimestamp = Math.floor((nowMs - this.videoRtpStartMs) * 90);

    const timestampUs: number = Math.floor(nowMs * 1000);
    WebRTC.encodeAndSendVideo(this.videoTrackId, new Uint8Array(nv12), timestampUs, this.videoTimestamp);
  }

  /**
   * 生成带当前时间的占位 NV12 帧
   *
   * 深灰背景 + 白色时间文字，格式 "YYYY-MM-DD HH:MM:SS"
   * 使用 5×7 位图字体放大4倍渲染
   */
  private renderTimePlaceholder(w: number, h: number): ArrayBuffer {
    const ySize: number = w * h;
    const uvSize: number = Math.floor(w * h / 2);
    const buf: ArrayBuffer = new ArrayBuffer(ySize + uvSize);
    const view: Uint8Array = new Uint8Array(buf);

    // 填充深灰背景：Y=32 深灰, U=128, V=128
    view.fill(32, 0, ySize);
    view.fill(128, ySize, ySize + uvSize);

    // 时间字符串
    const now: Date = new Date();
    const timeStr: string = this.padNum(now.getFullYear(), 4) + '-'
      + this.padNum(now.getMonth() + 1, 2) + '-'
      + this.padNum(now.getDate(), 2) + ' '
      + this.padNum(now.getHours(), 2) + ':'
      + this.padNum(now.getMinutes(), 2) + ':'
      + this.padNum(now.getSeconds(), 2);

    // 字体参数
    const FONT_W: number = 5;
    const FONT_H: number = 7;
    const SCALE: number = 4;
    const CHAR_W: number = FONT_W * SCALE;  // 20
    const CHAR_H: number = FONT_H * SCALE;  // 28
    const GAP: number = 4;  // 字符间距

    const totalW: number = timeStr.length * (CHAR_W + GAP) - GAP;
    const startX: number = Math.floor((w - totalW) / 2);
    const startY: number = Math.floor((h - CHAR_H) / 2);

    // 渲染每个字符
    for (let ci: number = 0; ci < timeStr.length; ci++) {
      const ch: string = timeStr[ci];
      const glyph: number[] | undefined = PLACEHOLDER_FONT[ch];
      if (glyph === undefined) continue;

      const cx: number = startX + ci * (CHAR_W + GAP);
      for (let row: number = 0; row < FONT_H; row++) {
        const bits: number = glyph[row];
        for (let col: number = 0; col < FONT_W; col++) {
          if ((bits >> (FONT_W - 1 - col)) & 1) {
            // 放大像素块
            for (let sy: number = 0; sy < SCALE; sy++) {
              const py: number = startY + row * SCALE + sy;
              if (py < 0 || py >= h) continue;
              for (let sx: number = 0; sx < SCALE; sx++) {
                const px: number = cx + col * SCALE + sx;
                if (px < 0 || px >= w) continue;
                view[py * w + px] = 235; // 白色 Y
              }
            }
          }
        }
      }
    }

    return buf;
  }

  /** 数字补零 */
  private padNum(n: number, len: number): string {
    let s: string = n.toString();
    while (s.length < len) {
      s = '0' + s;
    }
    return s;
  }

  /**
   * 请求视频关键帧（通过 Rust 层内部编码器）
   */
  public async requestVideoKeyFrame(): Promise<void> {
    if (this.videoEncoderCreated) {
      WebRTC.requestVideoKeyFrame();
    }
  }
}

// ============================================================
// 便捷工厂方法
// ============================================================

export function createMediaStream(config?: MediaStreamConfig): WebRTCMediaStream {
  return new WebRTCMediaStream(config);
}
