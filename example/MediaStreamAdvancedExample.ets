/**
 * 媒体流高级使用示例
 *
 * 演示媒体流的高级功能：
 * 1. 编解码器能力检测
 * 2. 低端设备优化
 * 3. 动态切换编解码器
 * 4. 视频控制（开关、切换摄像头）
 * 5. 音频控制（静音、路由）
 */

import {
  WebRTC,
  WebRTCMediaStream,
  createMediaStream,
  VideoSurface,
  RemoteVideoSurface,
  isCodecSupported,
  detectVideoCodecCapabilities,
} from 'tdwebrtc';
import type { SurfaceInfo, MediaStreamConfig, VideoCodecCapabilities } from 'tdwebrtc';
import common from '@ohos.app.ability.common';

/**
 * 媒体流状态接口
 */
interface MediaStreamState {
  isVideoEnabled: boolean;
  isAudioMuted: boolean;
  isSpeakerOn: boolean;
  codecCapabilities: VideoCodecCapabilities | null;
}

/**
 * 媒体流管理器示例
 */
export class MediaStreamAdvancedExample {
  private context: common.Context;
  private mediaStream: WebRTCMediaStream | null = null;

  // 状态
  private isVideoEnabled: boolean = true;
  private isAudioMuted: boolean = false;
  private isSpeakerOn: boolean = true;

  // 编解码器能力
  private codecCapabilities: VideoCodecCapabilities | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 初始化并检测设备能力
   */
  public async initialize(): Promise<boolean> {
    try {
      // 1. 检测编解码器能力
      this.codecCapabilities = detectVideoCodecCapabilities();
      console.log('[MediaStreamExample] 编解码器能力:');
      console.log(`  硬件编码: ${this.codecCapabilities.hwEncode.join(', ')}`);
      console.log(`  硬件解码: ${this.codecCapabilities.hwDecode.join(', ')}`);
      console.log(`  可用编码: ${this.codecCapabilities.canEncode.join(', ')}`);
      console.log(`  可用解码: ${this.codecCapabilities.canDecode.join(', ')}`);
      console.log(`  最优发送: ${this.codecCapabilities.bestSendCodec}`);
      console.log(`  最优接收: ${this.codecCapabilities.bestRecvCodec}`);

      // 2. 根据设备能力选择最优编解码器
      const preferredCodec = this.codecCapabilities.bestSendCodec;
      console.log(`[MediaStreamExample] 选择编解码器: ${preferredCodec}`);

      // 3. 初始化 WebRTC
      const success = await WebRTC.init({
        stunServers: ['stun:stun.l.google.com:19302'],
        localPort: 0,
        preferredVideoCodec: preferredCodec,
      });

      if (!success) {
        console.error('[MediaStreamExample] WebRTC 初始化失败');
        return false;
      }

      // 4. 创建媒体流（根据设备能力动态配置）
      const config = this.createOptimalConfig(preferredCodec);
      this.mediaStream = createMediaStream(config);
      this.mediaStream.setContext(this.context);

      console.log('[MediaStreamExample] 初始化成功');
      return true;
    } catch (error) {
      console.error(`[MediaStreamExample] 初始化失败: ${(error as Error).message}`);
      return false;
    }
  }

  /**
   * 检查是否支持指定编解码器
   */
  private isCodecAvailable(codec: string): boolean {
    if (!this.codecCapabilities) {
      return codec === 'VP8'; // VP8 始终可用
    }
    return this.codecCapabilities.canEncode.includes(codec);
  }

  /**
   * 创建最优配置
   *
   * 根据设备能力动态调整分辨率、帧率等参数
   */
  private createOptimalConfig(codec: string): MediaStreamConfig {
    const isLowEndDevice = !isCodecSupported('H264');

    if (isLowEndDevice) {
      // 低端设备配置
      console.log('[MediaStreamExample] 检测到低端设备，使用降级配置');
      return {
        video: {
          enabled: true,
          width: 352,   // CIF
          height: 288,
          frameRate: 15,
          codec: 'VP8',
          bitrate: 300000,
        },
        audio: {
          enabled: true,
          sampleRate: 8000,
          channels: 1,
          codec: 'PCMU',
        },
      };
    }

    // 高端设备配置
    return {
      video: {
        enabled: true,
        width: 1280,
        height: 720,
        frameRate: 30,
        codec: codec as 'H264' | 'H265' | 'VP8' | 'VP9',
        bitrate: 2000000,
      },
      audio: {
        enabled: true,
        sampleRate: 8000,
        channels: 1,
        codec: 'PCMU',
      },
    };
  }

  /**
   * 初始化视频发送端
   */
  public async initVideoSender(surfaceId: string): Promise<boolean> {
    if (!this.mediaStream) {
      return false;
    }
    return await this.mediaStream.initializeVideoSender(surfaceId);
  }

  /**
   * 初始化视频接收端
   */
  public async initVideoReceiver(surfaceId: string): Promise<boolean> {
    if (!this.mediaStream) {
      return false;
    }
    this.mediaStream.setRemoteVideoSurface(surfaceId);
    return await this.mediaStream.initializeVideoReceiver();
  }

  /**
   * 初始化音频
   */
  public async initAudio(): Promise<boolean> {
    if (!this.mediaStream) {
      return false;
    }
    const senderOk = await this.mediaStream.initializeAudioSender();
    const receiverOk = await this.mediaStream.initializeAudioReceiver();
    return senderOk && receiverOk;
  }

  /**
   * 启动媒体流
   */
  public async start(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    await this.mediaStream.startVideoCapture();
    await this.mediaStream.startVideoDecoder();
    await this.mediaStream.startAudioSending();
    await this.mediaStream.startAudioReceiving();
    console.log('[MediaStreamExample] 媒体流已启动');
  }

  // ============================================================
  // 视频控制
  // ============================================================

  /**
   * 切换视频开关
   */
  public async toggleVideo(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    this.isVideoEnabled = !this.isVideoEnabled;
    await this.mediaStream.setVideoEnabled(this.isVideoEnabled);
    console.log(`[MediaStreamExample] 视频 ${this.isVideoEnabled ? '开启' : '关闭'}`);
  }

  /**
   * 切换前后摄像头
   */
  public async switchCamera(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    const success = await this.mediaStream.switchCamera();
    console.log(`[MediaStreamExample] 切换摄像头 ${success ? '成功' : '失败'}`);
  }

  /**
   * 请求关键帧
   */
  public async requestKeyFrame(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    await this.mediaStream.requestKeyFrame();
    console.log('[MediaStreamExample] 已请求关键帧');
  }

  // ============================================================
  // 音频控制
  // ============================================================

  /**
   * 切换静音
   */
  public async toggleMute(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    this.isAudioMuted = !this.isAudioMuted;
    await this.mediaStream.setAudioMute(this.isAudioMuted);
    console.log(`[MediaStreamExample] 麦克风 ${this.isAudioMuted ? '静音' : '开启'}`);
  }

  /**
   * 切换音频路由（听筒/免提）
   */
  public async toggleSpeaker(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    this.isSpeakerOn = !this.isSpeakerOn;
    await this.mediaStream.setAudioRoute(this.isSpeakerOn);
    console.log(`[MediaStreamExample] ${this.isSpeakerOn ? '免提' : '听筒'}模式`);
  }

  // ============================================================
  // 生命周期
  // ============================================================

  /**
   * 停止媒体流
   */
  public async stop(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    await this.mediaStream.stopAll();
    console.log('[MediaStreamExample] 媒体流已停止');
  }

  /**
   * 释放资源
   */
  public async release(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }
    await this.mediaStream.release();
    this.mediaStream = null;
    console.log('[MediaStreamExample] 资源已释放');
  }

  /**
   * 获取当前状态
   */
  public getState(): MediaStreamState {
    const state: MediaStreamState = {
      isVideoEnabled: this.isVideoEnabled,
      isAudioMuted: this.isAudioMuted,
      isSpeakerOn: this.isSpeakerOn,
      codecCapabilities: this.codecCapabilities,
    };
    return state;
  }
}

/**
 * 完整页面示例
 */
@Entry
@Component
struct MediaStreamAdvancedPage {
  private context: common.Context = getContext(this) as common.Context;
  private manager: MediaStreamAdvancedExample | null = null;

  @State localSurfaceId: string = '';
  @State remoteSurfaceId: string = '';
  @State isInitialized: boolean = false;
  @State isCallActive: boolean = false;

  // 控制状态
  @State isVideoEnabled: boolean = true;
  @State isAudioMuted: boolean = false;
  @State isSpeakerOn: boolean = true;

  aboutToAppear(): void {
    this.manager = new MediaStreamAdvancedExample(this.context);
  }

  aboutToDisappear(): void {
    this.release();
  }

  private async initialize(): Promise<void> {
    if (!this.manager) {
      return;
    }

    const success = await this.manager.initialize();
    if (success) {
      this.isInitialized = true;
      const state = this.manager.getState();
      this.isVideoEnabled = state.isVideoEnabled;
      this.isAudioMuted = state.isAudioMuted;
      this.isSpeakerOn = state.isSpeakerOn;
    }
  }

  private async startCall(): Promise<void> {
    if (!this.manager || !this.localSurfaceId || !this.remoteSurfaceId) {
      return;
    }

    await this.manager.initVideoSender(this.localSurfaceId);
    await this.manager.initVideoReceiver(this.remoteSurfaceId);
    await this.manager.initAudio();
    await this.manager.start();
    this.isCallActive = true;
  }

  private async release(): Promise<void> {
    if (this.manager) {
      await this.manager.release();
    }
  }

  build() {
    Column() {
      Text('媒体流高级示例')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      // 初始化状态
      if (!this.isInitialized) {
        Button('初始化')
          .onClick(() => this.initialize())
          .margin({ bottom: 20 })
      } else {
        // 视频区域
        Row() {
          // 本地预览
          Column() {
            Text('本地预览')
              .fontSize(12)
              .fontColor('#FFFFFF')
            VideoSurface({
              componentId: 'local-preview',
              surfaceWidth: 160,
              surfaceHeight: 120,
              onSurfaceReady: (info: SurfaceInfo) => {
                this.localSurfaceId = info.surfaceId;
              },
            })
              .width(160)
              .height(120)
              .backgroundColor('#000000')
          }

          Blank()

          // 远端视频
          Column() {
            Text('远端视频')
              .fontSize(12)
              .fontColor('#FFFFFF')
            RemoteVideoSurface({
              componentId: 'remote-video',
              surfaceWidth: 160,
              surfaceHeight: 120,
              onSurfaceReady: (info: SurfaceInfo) => {
                this.remoteSurfaceId = info.surfaceId;
              },
            })
              .width(160)
              .height(120)
              .backgroundColor('#000000')
          }
        }
        .width('100%')
        .margin({ bottom: 20 })

        // 开始呼叫
        if (!this.isCallActive) {
          Button('开始呼叫')
            .enabled(this.localSurfaceId !== '' && this.remoteSurfaceId !== '')
            .onClick(() => this.startCall())
            .margin({ bottom: 20 })
        } else {
          // 视频控制
          Row() {
            Button(this.isVideoEnabled ? '关闭视频' : '开启视频')
              .onClick(async () => {
                await this.manager?.toggleVideo();
                this.isVideoEnabled = !this.isVideoEnabled;
              })
              .margin({ right: 10 })

            Button('切换摄像头')
              .onClick(() => this.manager?.switchCamera())
          }
          .margin({ bottom: 10 })

          // 音频控制
          Row() {
            Button(this.isAudioMuted ? '取消静音' : '静音')
              .onClick(async () => {
                await this.manager?.toggleMute();
                this.isAudioMuted = !this.isAudioMuted;
              })
              .margin({ right: 10 })

            Button(this.isSpeakerOn ? '切听筒' : '切免提')
              .onClick(async () => {
                await this.manager?.toggleSpeaker();
                this.isSpeakerOn = !this.isSpeakerOn;
              })
          }
          .margin({ bottom: 20 })

          // 请求关键帧
          Button('请求关键帧')
            .onClick(() => this.manager?.requestKeyFrame())
            .margin({ bottom: 20 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
