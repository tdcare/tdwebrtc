/**
 * 基本视频通话示例
 *
 * 演示完整的视频通话流程：
 * 1. 初始化 WebRTC
 * 2. 创建媒体流
 * 3. 连接信令服务器
 * 4. 发起/接听呼叫
 * 5. 挂断并释放资源
 */

import { WebRTC, createMediaStream, VideoSurface, RemoteVideoSurface, SignalingClient, CallType, WebRTCMediaStream } from 'tdwebrtc';
import type { SurfaceInfo, MediaStreamConfig, SignalingCallback, SignalingData } from 'tdwebrtc';
import common from '@ohos.app.ability.common';

@Entry
@Component
struct BasicVideoCallExample {
  // Context
  private context: common.Context = getContext(this) as common.Context;

  // WebRTC 相关
  private mediaStream: WebRTCMediaStream | null = null;
  private signaling: SignalingClient | null = null;

  // Surface ID
  @State localSurfaceId: string = '';
  @State remoteSurfaceId: string = '';

  // 状态
  @State callState: string = 'idle'; // idle, calling, connected
  @State localMac: string = 'OHOS-DEVICE-001';
  @State remoteMac: string = '';
  @State roomId: string = '';

  // 配置
  private readonly SIGNALING_URL: string = 'ws://192.168.1.100:8080/ws/';
  private readonly STUN_SERVER: string = 'stun:stun.l.google.com:19302';

  aboutToAppear(): void {
    this.initWebRTC();
  }

  aboutToDisappear(): void {
    this.release();
  }

  /**
   * 初始化 WebRTC
   */
  private async initWebRTC(): Promise<void> {
    try {
      // 1. 初始化 WebRTC 引擎
      const success = await WebRTC.init({
        stunServers: [this.STUN_SERVER],
        localPort: 0, // 随机端口
      });

      if (!success) {
        console.error('[Example] WebRTC 初始化失败');
        return;
      }

      console.log('[Example] WebRTC 初始化成功');

      // 2. 创建媒体流
      const config: MediaStreamConfig = {
        video: {
          enabled: true,
          width: 1280,
          height: 720,
          frameRate: 30,
          codec: 'H264',
          cameraPosition: 'back',
        },
        audio: {
          enabled: true,
          sampleRate: 8000,
          channels: 1,
          codec: 'PCMU',
        },
      };

      this.mediaStream = createMediaStream(config);
      this.mediaStream.setContext(this.context);

      // 设置错误回调
      this.mediaStream.onError = (error: string) => {
        console.error(`[Example] MediaStream 错误: ${error}`);
      };

      console.log('[Example] MediaStream 创建成功');

      // 3. 初始化信令客户端
      this.initSignaling();
    } catch (error) {
      console.error(`[Example] 初始化失败: ${(error as Error).message}`);
    }
  }

  /**
   * 初始化信令客户端
   */
  private initSignaling(): void {
    // 创建回调实现类
    class CallbackImpl implements SignalingCallback {
      private parent: BasicVideoCallExample;
  
      constructor(parent: BasicVideoCallExample) {
        this.parent = parent;
      }
  
      onInitSuccess(): void {
        console.log('[Example] 信令连接成功');
        this.parent.signaling?.sendJoinRoom(this.parent.roomId || 'default-room');
      }
  
      onPeerJoined(fromMac: string, roomId: string): void {
        console.log(`[Example] 对端加入：${fromMac}, room: ${roomId}`);
        this.parent.remoteMac = fromMac;
      }
  
      onPeerLeaved(fromMac: string, roomId: string): void {
        console.log(`[Example] 对端离开：${fromMac}, room: ${roomId}`);
        this.parent.remoteMac = '';
        this.parent.hangup();
      }
  
      onOfferReceived(data: SignalingData): void {
        console.log('[Example] 收到 Offer');
      }
  
      onAnswerReceived(data: SignalingData): void {
        console.log('[Example] 收到 Answer');
      }
  
      onIceCandidateReceived(data: SignalingData): void {
        console.log('[Example] 收到 ICE 候选');
      }
  
      onCall(data: SignalingData): void {
        console.log('[Example] 收到来电');
      }
  
      onDoing(data: SignalingData): void {
        console.log('[Example] 对方已接听');
        this.parent.callState = 'connected';
      }
  
      onHangup(data: SignalingData): void {
        console.log('[Example] 对方已挂断');
        this.parent.hangup();
      }
  
      onVideoCall(data: SignalingData): void {
        console.log('[Example] 收到视频呼叫');
        this.parent.callState = 'calling';
      }
  
      onVideoHangup(data: SignalingData): void {
        console.log('[Example] 视频已挂断');
        this.parent.hangup();
      }
  
      onSosCall(data: SignalingData): void {
        console.log('[Example] 收到 SOS 呼叫');
      }
  
      onSosHangup(data: SignalingData): void {
        console.log('[Example] SOS 已挂断');
      }
  
      onVideoSosCall(data: SignalingData): void {
        console.log('[Example] 收到视频 SOS 呼叫');
      }
  
      onVideoSosHangup(data: SignalingData): void {
        console.log('[Example] 视频 SOS 已挂断');
      }
  
      onTransfer(data: SignalingData): void {
        console.log('[Example] 收到转接');
      }
  
      onIgnore(data: SignalingData): void {
        console.log('[Example] 对方已忽略');
      }
  
      onNotice(data: SignalingData): void {
        console.log('[Example] 收到通知');
      }
    }
  
    const callback = new CallbackImpl(this);
    this.signaling = new SignalingClient();
    this.signaling.init(this.SIGNALING_URL, this.localMac, '{}', callback);
  }

  /**
   * 发起视频呼叫
   */
  private async startVideoCall(): Promise<void> {
    if (!this.mediaStream || !this.signaling) {
      console.error('[Example] 未初始化');
      return;
    }

    try {
      this.callState = 'calling';

      // 1. 初始化视频发送端（本地预览）
      if (this.localSurfaceId) {
        await this.mediaStream.initializeVideoSender(this.localSurfaceId);
      }

      // 2. 初始化视频接收端
      if (this.remoteSurfaceId) {
        this.mediaStream.setRemoteVideoSurface(this.remoteSurfaceId);
      }
      await this.mediaStream.initializeVideoReceiver();

      // 3. 初始化音频
      await this.mediaStream.initializeAudioSender();
      await this.mediaStream.initializeAudioReceiver();

      // 4. 启动媒体流
      await this.mediaStream.startVideoCapture();
      await this.mediaStream.startVideoDecoder();
      await this.mediaStream.startAudioSending();
      await this.mediaStream.startAudioReceiving();

      // 5. 发送视频呼叫信令
      this.signaling.sendCall(this.remoteMac, this.roomId, CallType.VIDEO);

      console.log('[Example] 视频呼叫已发起');
    } catch (error) {
      console.error(`[Example] 发起呼叫失败: ${(error as Error).message}`);
      this.callState = 'idle';
    }
  }

  /**
   * 挂断
   */
  private async hangup(): Promise<void> {
    if (!this.mediaStream) {
      return;
    }

    try {
      // 1. 发送挂断信令
      if (this.signaling && this.remoteMac) {
        this.signaling.sendHangup(this.remoteMac, this.roomId);
      }

      // 2. 停止媒体流
      await this.mediaStream.stopAll();

      // 3. 重置状态
      this.callState = 'idle';

      console.log('[Example] 已挂断');
    } catch (error) {
      console.error(`[Example] 挂断失败: ${(error as Error).message}`);
    }
  }

  /**
   * 释放资源
   */
  private async release(): Promise<void> {
    try {
      await this.hangup();

      if (this.mediaStream) {
        await this.mediaStream.release();
        this.mediaStream = null;
      }

      if (this.signaling) {
        this.signaling.destroy();
        this.signaling = null;
      }

      await WebRTC.close();

      console.log('[Example] 资源已释放');
    } catch (error) {
      console.error(`[Example] 释放资源失败: ${(error as Error).message}`);
    }
  }

  build() {
    Column() {
      // 标题
      Text('视频通话示例')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      // 状态显示
      Text(`状态: ${this.callState}`)
        .fontSize(16)
        .margin({ bottom: 10 })

      // 远端视频（大画面）
      RemoteVideoSurface({
        componentId: 'remote-video',
        surfaceWidth: 320,
        surfaceHeight: 240,
        onSurfaceReady: (info: SurfaceInfo) => {
          this.remoteSurfaceId = info.surfaceId;
          if (this.mediaStream) {
            this.mediaStream.setRemoteVideoSurface(info.surfaceId);
          }
        },
      })
        .width(320)
        .height(240)
        .backgroundColor('#000000')
        .margin({ bottom: 10 })

      // 本地预览（小画面）
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
        .backgroundColor('#333333')
        .margin({ bottom: 20 })

      // 控制按钮
      Row() {
        Button('发起呼叫')
          .enabled(this.callState === 'idle' && this.remoteSurfaceId !== '' && this.localSurfaceId !== '')
          .onClick(() => this.startVideoCall())
          .margin({ right: 10 })

        Button('挂断')
          .enabled(this.callState !== 'idle')
          .onClick(() => this.hangup())
          .backgroundColor('#FF0000')
      }
      .margin({ bottom: 20 })

      // 设备控制
      Row() {
        Button('切换摄像头')
          .enabled(this.callState === 'connected')
          .onClick(async () => {
            await this.mediaStream?.switchCamera();
          })
          .margin({ right: 10 })

        Button('静音')
          .enabled(this.callState === 'connected')
          .onClick(async () => {
            await this.mediaStream?.setAudioMute(true);
          })
          .margin({ right: 10 })

        Button('免提')
          .enabled(this.callState === 'connected')
          .onClick(async () => {
            await this.mediaStream?.setAudioRoute(true);
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
