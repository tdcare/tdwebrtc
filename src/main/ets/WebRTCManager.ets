/**
 * WebRTC 管理器 - ArkTS 封装层
 * 
 * 参考 MQTTManager 实现，封装 Rust WebRTC 客户端
 * 包含 Sans-I/O 网络处理层（UDP Socket）
 */

import { WebRtcClient, getWebrtcVersion } from 'libwebrtc_client.so';
import type { NapiMediaFrame, NapiVideoEncoderConfig } from 'libwebrtc_client.so';
import { detectVideoCodecCapabilities } from './MediaCodec';
import type { VideoCodecCapabilities } from './MediaCodec';
import { LogUtil } from './utils/LogUtil';
import { NetworkUtil } from './utils/NetworkUtil';
// util 不再需要（base64 解码已移至 Rust 层）
import {
  SignalingClient,
  SignalingCallback,
  CallType,
  CmdAction,
} from './SignalingClient';
import type { SignalingData } from './SignalingClient';

// Rust 端暂未导出媒体轨道类型，本地定义
export interface MediaTrackConfig {
  trackId: string;
  streamId: string;
  kind: string;
  codec: string;
  ssrc: number;
  payloadType: number;
  clockRate: number;
}

// WebRTC 事件类型
export enum WebRTCEvent {
  STATE_CHANGE = 'webrtc_state_change',
  CONNECTED = 'webrtc_connected',
  DISCONNECTED = 'webrtc_disconnected',
  ICE_CANDIDATE = 'webrtc_ice_candidate',
  DATA_CHANNEL_MESSAGE = 'webrtc_data_channel_message',
  RTP_PACKET_RECEIVED = 'webrtc_rtp_packet_received',
  OFFER_CREATED = 'webrtc_offer_created',
  ANSWER_CREATED = 'webrtc_answer_created',
  ERROR = 'webrtc_error',
}

// 导出类型已在上方本地定义

// 事件数据接口
export interface WebRTCEventData {
  type: string;
  data?: string;
  error?: string;
}

export interface WebRTCStateChangeData {
  state: string;
  message: string;
}

// 配置接口
export interface WebRTCConfig {
  stunServers?: string[];
  turnServers?: string[];
  localPort?: number; // 本地 UDP 端口
  preferredVideoCodec?: string; // v36: 由 init() 根据设备能力动态设置，控制 SDP 协商优先级
}

// NapiMediaFrame 已从 Rust NAPI 导入，替代旧的 RTP JSON 结构
// 旧的 RtpReceivedJson（base64+JSON）已废弃

// Rust 端返回的 ICE 候选 JSON 结构
interface IceCandidateJson {
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
}

// v42: 缓存的 ICE 候选结构
export interface CachedIceCandidate {
  candidate: string;
  sdpMid: string;
  sdpMLineIndex: number;
}

// 默认配置
const DEFAULT_CONFIG: WebRTCConfig = {
  stunServers: ['stun:stun.l.google.com:19302'],
  turnServers: [],
  localPort: 0, // 0 表示随机端口
  // v36: preferredVideoCodec 不再硬编码，由 init() 根据设备能力动态设置
  // 检测逻辑：H265 > H264 > VP9 > VP8，VP8 软编解码始终兜底
};

// UDP 网络处理已集成到 Rust webrtc_client 内部（零拷贝架构）
// ArkTS 端只需调用 client.startUdp(port, deviceIp) / client.stopUdp()

/**
 * SignalingCallback 实现类 — 将信令事件分发给 WebRTCManager
 */
class SignalingCallbackImpl implements SignalingCallback {
  public mgr: WebRTCManager;

  constructor(mgr: WebRTCManager) {
    this.mgr = mgr;
  }

  onInitSuccess(): void {
    LogUtil.info('[WebRTC] 信令连接成功');
    this.mgr.fireSignalingConnected();
  }

  onPeerJoined(fromMac: string, roomId: string): void {
    LogUtil.info(`[WebRTC] 对端加入: ${fromMac}, room=${roomId}`);
    if (fromMac === this.mgr.getLocalMac()) {
      this.mgr.firePeerJoined(fromMac, roomId);
      return;
    }
    this.mgr.setPeerRoom(fromMac, roomId);
    this.mgr.firePeerJoined(fromMac, roomId);
    // OHOS 主动创建 Offer 发送给对端
    // 信令服务器不会通知新加入者关于已有成员的存在，
    // 导致 Android 的 onPeerJoined 不触发、从而不创建 Offer。
    // 因此 OHOS（已在房间中的一方）必须主动发起 Offer。
    // 如果 Android 也发送了 Offer（SDP Glare），onOfferReceived 中的 polite peer 逻辑会处理。
    LogUtil.info(`[WebRTC] 对端 ${fromMac} 加入，主动创建 Offer`);
    this.mgr.createAndSendOffer(fromMac, roomId);
  }

  onPeerLeaved(fromMac: string, roomId: string): void {
    LogUtil.info(`[WebRTC] 对端离开: ${fromMac}, room=${roomId}`);
    this.mgr.deletePeerRoom(fromMac);
    this.mgr.firePeerLeaved(fromMac, roomId);
  }

  onOfferReceived(data: SignalingData): void {
    const fromMac = data.from_mac;
    const roomId = data.room_id;
    const sdp = data.sdp ?? '';
    LogUtil.info(`[WebRTC] 收到 Offer from: ${fromMac}, sdp长度=${sdp.length}`);
  
    if (data.call_type !== undefined) {
      const callType = data.call_type === 'video' ? CallType.VIDEO : CallType.VOICE;
      this.mgr.updateCallType(callType);
      // 同步更新 SignalingClient 的 currentCallType
      this.mgr.getSignaling()?.setCurrentCallType(callType);
      LogUtil.info(`[WebRTC] 收到 Offer 后更新 callType=${callType}`);
    }
  
    // SDP Glare 处理：如果 OHOS 已经发了 Offer，收到对方 Offer 时回滚自己的
    // 采用 "polite peer" 模式：OHOS 屏幕作为 polite peer，始终接受对方的 Offer
    if (this.mgr.isOfferPending()) {
      LogUtil.warn(`[WebRTC] SDP Glare 检测！已有待处理的 Offer，回滚并接受对方 Offer`);
      // Polite peer: 放弃自己的 offer，接受对方的
      this.mgr.clearOfferPending();
    }
  
    this.mgr.setPeerRoom(fromMac, roomId);
      
    // v43: 先重置状态并添加媒体轨道，再设置远端 SDP 和创建 Answer
    // 这样 Answer SDP 才会包含 a=sendrecv 而不是 a=recvonly
    LogUtil.info(`[WebRTC] v43 被叫：重置状态并添加媒体轨道`);
    this.mgr.resetForNewCall();
    this.mgr.setupMediaTracksForCall(this.mgr.getCurrentCallType() === CallType.VIDEO);
      
    this.mgr.setRemoteDescription(sdp, 'offer');
  
    const answerSdp = this.mgr.createAnswer();
    if (answerSdp !== null) {
      LogUtil.info(`[WebRTC] Answer SDP 创建成功, 长度=${answerSdp.length}`);
      this.mgr.setLocalDescription(answerSdp, 'answer');
      this.mgr.getSignaling()?.sendSessionDescription(answerSdp, 'answer', fromMac, roomId);
      LogUtil.info(`[WebRTC] Answer 已发送给 ${fromMac}`);
    } else {
      LogUtil.error('[WebRTC] Answer SDP 创建失败');
    }
  }

  onAnswerReceived(data: SignalingData): void {
    const fromMac = data.from_mac;
    const sdp = data.sdp ?? '';
    LogUtil.info(`[WebRTC] 收到 Answer from: ${fromMac}, sdp长度=${sdp.length}`);

    if (data.call_type !== undefined) {
      this.mgr.updateCallType(data.call_type === 'video' ? CallType.VIDEO : CallType.VOICE);
    }

    this.mgr.setRemoteDescription(sdp, 'answer');
    this.mgr.clearOfferPending();
    LogUtil.info(`[WebRTC] 远端 Answer 已设置`);
  }

  onIceCandidateReceived(data: SignalingData): void {
    const sdp = data.sdp ?? '';
    const sdpMid = data.sdpMid ?? '';
    const sdpMLineIndex = data.sdpMLineIndex ?? 0;
    LogUtil.info(`[WebRTC] 收到 ICE 候选: sdpMid=${sdpMid}, sdpMLineIndex=${sdpMLineIndex}, candidate=${sdp.substring(0, 60)}...`);
    this.mgr.addIceCandidate(sdp, sdpMid, sdpMLineIndex);
  }

  onCall(data: SignalingData): void {
    this.mgr.fireCallReceived(data.from_mac, data.room_id, data.msg ?? '');
  }

  onDoing(data: SignalingData): void {
    this.mgr.fireCallAnswered(data.from_mac, data.to_mac ?? '', data.room_id);
  }

  onHangup(data: SignalingData): void {
    this.mgr.fireCallHangup(data.from_mac, data.room_id);
  }

  onTransfer(data: SignalingData): void {
    this.mgr.fireTransferReceived(data.from_mac, data.room_id);
  }

  onIgnore(data: SignalingData): void {
    this.mgr.fireIgnoreReceived(data.from_mac, data.room_id);
  }

  onNotice(data: SignalingData): void {
    this.mgr.fireNoticeReceived(data.from_mac, data.room_id, data.msg ?? '');
  }

  onSosCall(data: SignalingData): void {
    this.mgr.fireSosCallReceived(data.from_mac, data.room_id, data.msg ?? '');
  }

  onSosHangup(data: SignalingData): void {
    this.mgr.fireSosCallHangup(data.from_mac, data.room_id);
  }

  onVideoCall(data: SignalingData): void {
    const callType = data.call_type === 'video' ? CallType.VIDEO : CallType.VOICE;
    this.mgr.updateCallType(callType);
    // 同步更新 SignalingClient 的 currentCallType
    this.mgr.getSignaling()?.setCurrentCallType(callType);
    this.mgr.fireVideoCallReceived(data.from_mac, data.room_id, data.msg ?? '', callType);
  }

  onVideoHangup(data: SignalingData): void {
    this.mgr.updateCallType(CallType.VOICE);
    this.mgr.fireVideoCallHangup(data.from_mac, data.room_id);
  }

  onVideoSosCall(data: SignalingData): void {
    const callType = data.call_type === 'video' ? CallType.VIDEO : CallType.VOICE;
    this.mgr.updateCallType(callType);
    // 同步更新 SignalingClient 的 currentCallType
    this.mgr.getSignaling()?.setCurrentCallType(callType);
    this.mgr.fireVideoCallReceived(data.from_mac, data.room_id, data.msg ?? '', callType);
  }

  onVideoSosHangup(data: SignalingData): void {
    this.mgr.updateCallType(CallType.VOICE);
    this.mgr.fireVideoCallHangup(data.from_mac, data.room_id);
  }
}

/**
 * WebRTC 管理器单例
 */
class WebRTCManager {
  public client: WebRtcClient | null = null;
  public config: WebRTCConfig = DEFAULT_CONFIG;
  public pollTimer: number | null = null;
  // v20→v41: Phase 1-3 后事件循环极轻量（仅 drain 队列），降低轮询间隔以减少音频时延
  // 100ms 轮询 → G.711 20ms/帧会积压 5 帧 → 平均 50ms 额外延迟
  // 20ms 轮询 → 匹配 G.711 帧率，音频延迟降至 ~10ms
  public readonly POLL_INTERVAL = 20; // 20ms 轮询间隔，匹配 G.711 音频帧率
  public readonly TICK_MAX_MS = 500; // 单次 tick 最大执行时间（ms）
  public eventLoopRunning: boolean = false; // 事件循环是否运行中

  // ---- 信令客户端 ----
  public signaling: SignalingClient | null = null;
  public localMac: string = '';
  public currentCallType: CallType = CallType.VOICE;
  // 对端连接映射 (fromMac -> roomId)
  public peerRoomMap: Map<string, string> = new Map();
  // SDP 协商状态，用于处理 SDP Glare
  public offerPending: boolean = false; // 是否已发送 Offer 尚未收到 Answer
  // v42: 缓存已收集的本地 ICE 候选，在 peerRoomMap 更新后发送
  public cachedIceCandidates: CachedIceCandidate[] = [];
  // v24: SDP 协商后的视频编解码器 — 从远端 SDP 中解析，覆盖 preferredVideoCodec
  // 解决：OHOS 偏好 H264 但 Android 不支持 → SDP 协商选 VP8 → OHOS 应该也用 VP8 编码
  public negotiatedVideoCodec: string | null = null;

  // v36: 设备编解码能力缓存 — 在 init() 时检测，后续复用
  public codecCapabilities: VideoCodecCapabilities | null = null;

  // 事件回调
  public onStateChange?: (state: string) => void;
  public onConnected?: () => void;
  public onDisconnected?: () => void;
  public onIceCandidate?: (candidate: string) => void;
  public onDataChannelMessage?: (message: string) => void;
  public onMediaFrameReceived?: (frame: NapiMediaFrame) => void;
  public onError?: (error: string) => void;

  // 呼叫事件回调
  public onCallReceived?: (fromMac: string, roomId: string, msg: string) => void;
  public onCallAnswered?: (fromMac: string, toMac: string, roomId: string) => void;
  public onCallHangup?: (fromMac: string, roomId: string) => void;
  public onVideoCallReceived?: (fromMac: string, roomId: string, msg: string, callType: CallType) => void;
  public onVideoCallHangup?: (fromMac: string, roomId: string) => void;
  public onSosCallReceived?: (fromMac: string, roomId: string, msg: string) => void;
  public onSosCallHangup?: (fromMac: string, roomId: string) => void;
  public onTransferReceived?: (fromMac: string, roomId: string) => void;
  public onIgnoreReceived?: (fromMac: string, roomId: string) => void;
  public onNoticeReceived?: (fromMac: string, roomId: string, msg: string) => void;
  public onSignalingConnected?: () => void;
  public onPeerJoined?: (fromMac: string, roomId: string) => void;
  public onPeerLeaved?: (fromMac: string, roomId: string) => void;

  // ---- SignalingCallbackImpl 所需的访问器和事件触发方法 ----

  public getLocalMac(): string {
    return this.localMac;
  }

  public getSignaling(): SignalingClient | null {
    return this.signaling;
  }

  public setPeerRoom(mac: string, roomId: string): void {
    this.peerRoomMap.set(mac, roomId);
    LogUtil.info(`[WebRTC] setPeerRoom: ${mac} -> ${roomId}`);
    // v42: 对端映射更新后，发送缓存的 ICE 候选
    this.sendCachedIceCandidates();
  }

  public deletePeerRoom(mac: string): void {
    this.peerRoomMap.delete(mac);
    LogUtil.info(`[WebRTC] deletePeerRoom: ${mac}`);
  }

  /**
   * v42: 发送缓存的 ICE 候选给所有已知对端
   * 在 peerRoomMap 更新后调用，确保 ICE 候选能发送给对端
   */
  public sendCachedIceCandidates(): void {
    if (this.cachedIceCandidates.length === 0) {
      return;
    }
    if (this.peerRoomMap.size === 0) {
      LogUtil.debug(`[WebRTC] v42 peerRoomMap 为空，暂不发送 ICE 候选`);
      return;
    }
    if (!this.signaling) {
      LogUtil.warn(`[WebRTC] v42 信令未初始化，无法发送 ICE 候选`);
      return;
    }

    LogUtil.info(`[WebRTC] v42 发送缓存的 ICE 候选: ${this.cachedIceCandidates.length} 个, 对端数: ${this.peerRoomMap.size}`);
    
    // 遍历所有缓存候选，发送给所有对端
    for (let i = 0; i < this.cachedIceCandidates.length; i++) {
      const ice = this.cachedIceCandidates[i];
      this.peerRoomMap.forEach((roomId: string, peerMac: string) => {
        this.signaling?.sendIceCandidate(ice.candidate, ice.sdpMid, ice.sdpMLineIndex, peerMac, roomId);
      });
    }
    
    // 发送后清空缓存
    this.cachedIceCandidates = [];
    LogUtil.info(`[WebRTC] v42 ICE 候选已发送并清空缓存`);
  }

  public updateCallType(callType: CallType): void {
    this.currentCallType = callType;
  }

  public isOfferPending(): boolean {
    return this.offerPending;
  }

  public clearOfferPending(): void {
    this.offerPending = false;
  }

  public fireSignalingConnected(): void {
    this.onSignalingConnected?.();
  }

  public firePeerJoined(fromMac: string, roomId: string): void {
    this.onPeerJoined?.(fromMac, roomId);
  }

  public firePeerLeaved(fromMac: string, roomId: string): void {
    this.onPeerLeaved?.(fromMac, roomId);
  }

  public fireCallReceived(fromMac: string, roomId: string, msg: string): void {
    this.onCallReceived?.(fromMac, roomId, msg);
  }

  public fireCallAnswered(fromMac: string, toMac: string, roomId: string): void {
    this.onCallAnswered?.(fromMac, toMac, roomId);
  }

  public fireCallHangup(fromMac: string, roomId: string): void {
    this.onCallHangup?.(fromMac, roomId);
  }

  public fireTransferReceived(fromMac: string, roomId: string): void {
    this.onTransferReceived?.(fromMac, roomId);
  }

  public fireIgnoreReceived(fromMac: string, roomId: string): void {
    this.onIgnoreReceived?.(fromMac, roomId);
  }

  public fireNoticeReceived(fromMac: string, roomId: string, msg: string): void {
    this.onNoticeReceived?.(fromMac, roomId, msg);
  }

  public fireSosCallReceived(fromMac: string, roomId: string, msg: string): void {
    this.onSosCallReceived?.(fromMac, roomId, msg);
  }

  public fireSosCallHangup(fromMac: string, roomId: string): void {
    this.onSosCallHangup?.(fromMac, roomId);
  }

  public fireVideoCallReceived(fromMac: string, roomId: string, msg: string, callType: CallType): void {
    this.onVideoCallReceived?.(fromMac, roomId, msg, callType);
  }

  public fireVideoCallHangup(fromMac: string, roomId: string): void {
    this.onVideoCallHangup?.(fromMac, roomId);
  }

  /**
   * 初始化 WebRTC（异步）
   */
  public async init(config?: WebRTCConfig): Promise<boolean> {
    const merged: WebRTCConfig = {
      stunServers: config?.stunServers ?? DEFAULT_CONFIG.stunServers,
      turnServers: config?.turnServers ?? DEFAULT_CONFIG.turnServers,
      localPort: config?.localPort ?? DEFAULT_CONFIG.localPort,
      preferredVideoCodec: config?.preferredVideoCodec ?? DEFAULT_CONFIG.preferredVideoCodec,
    };
    this.config = merged;
    
    // 清空之前的轨道状态，确保从干净状态开始
    this.localTracks = [];
    
    try {
      LogUtil.info(`[WebRTC] 初始化, 版本: ${getWebrtcVersion()}`);
    } catch (_e) {
      LogUtil.warn('[WebRTC] 初始化 (getWebrtcVersion 不可用，跳过版本打印)');
    }
    LogUtil.info(`[WebRTC] STUN 服务器: ${JSON.stringify(this.config.stunServers)}`);

    // v36: 检测设备编解码能力，动态选择最优编解码器
    try {
      this.codecCapabilities = detectVideoCodecCapabilities();
      LogUtil.info(`[WebRTC] v36 设备编解码能力: 硬件编码=${JSON.stringify(this.codecCapabilities.hwEncode)}, 硬件解码=${JSON.stringify(this.codecCapabilities.hwDecode)}`);
      LogUtil.info(`[WebRTC] v36 可用编码=${JSON.stringify(this.codecCapabilities.canEncode)}, 可用解码=${JSON.stringify(this.codecCapabilities.canDecode)}`);
      LogUtil.info(`[WebRTC] v36 最优发送=${this.codecCapabilities.bestSendCodec}, 最优接收=${this.codecCapabilities.bestRecvCodec}`);
      // 根据设备解码能力设置 preferredVideoCodec（控制 Rust MediaEngine 注册顺序 → SDP 优先级）
      this.config.preferredVideoCodec = this.codecCapabilities.bestRecvCodec;
    } catch (e) {
      LogUtil.warn(`[WebRTC] v36 编解码能力检测失败，使用 VP8 兜底: ${e}`);
      this.config.preferredVideoCodec = 'VP8';
    }

    // 初始化 Rust WebRTC 客户端（传递 preferredVideoCodec 控制 SDP 编解码器优先级）
    this.client = new WebRtcClient(
      this.config.stunServers,
      this.config.turnServers,
      this.config.preferredVideoCodec ?? 'VP8'
    );

    // v27: UDP 网络层集成到 Rust 内部（零拷贝）
    // 获取设备 IP 传给 Rust，用于 ICE candidate 注册
    let deviceIp: string | undefined = undefined;
    try {
      deviceIp = NetworkUtil.getIpAddress();
      LogUtil.info(`[WebRTC] 设备 IP: ${deviceIp}`);
    } catch (e) {
      LogUtil.warn('[WebRTC] 获取设备 IP 失败，Rust 层将自动探测');
    }

    const localAddr: string | null = this.client.startUdp(
      this.config.localPort ?? 0,
      deviceIp
    );
    if (localAddr === null) {
      LogUtil.error('[WebRTC] Rust UDP 绑定失败');
      return false;
    }
    LogUtil.info(`[WebRTC] Rust UDP 已启动: ${localAddr}`);

    // 启动 ArkTS 事件轮询（仅轮询事件队列，网络 I/O 由 Rust 后台线程处理）
    this.startEventLoop();

    LogUtil.info('[WebRTC] 初始化完成');
    return true;
  }

  // v27: handleIncomingData 和 sendOutgoingPackets 已移除
  // UDP 收发现在在 Rust 后台线程内完成（零拷贝）

  /**
   * 创建 Offer
   */
  public createOffer(): string | null {
    if (!this.client) {
      LogUtil.error('[WebRTC] 客户端未初始化');
      return null;
    }
    return this.client.createOffer();
  }

  /**
   * 创建 Answer
   */
  public createAnswer(): string | null {
    if (!this.client) {
      LogUtil.error('[WebRTC] 客户端未初始化');
      return null;
    }
    return this.client.createAnswer();
  }

  /**
   * 设置本地 SDP
   */
  public setLocalDescription(sdp: string, type: 'offer' | 'answer'): boolean {
    if (!this.client) return false;
    return this.client.setLocalDescription(sdp, type);
  }

  /**
   * 设置远端 SDP
   *
   * v24: 从 SDP 中提取协商后的视频编解码器
   * - 收到 answer: 对端从 offer 中选择了它支持的编解码器
   * - 收到 offer: 对端的编解码器偏好
   * 第一个视频 payload type 就是协商后的首选编解码器
   * 
   * v29: H264 profile-level-id 统一替换（对齐 Android v26）
   * - 根因：OHOS 注册 H264 profile-level-id=42e01f，Android 硬件编码器可能返回 42001f/42c01f 等
   * - rtc-patched 的 fmtp 匹配要求前 2 字节完全相同，否则降级为 VP8
   * - 需在 SDP 协商前统一为 OHOS 自己的值，确保 exact match
   */
  public setRemoteDescription(sdp: string, type: 'offer' | 'answer'): boolean {
    if (!this.client) return false;
    
    // v29: H264 profile-level-id 统一替换（类似 Android v26）
    let processedSdp = sdp;
    if (type === 'answer' || type === 'offer') {
      // 提取 OHOS Rust 端注册的 H264 profile-level-id（从本地 Offer/Answer 中获取）
      // 由于无法直接访问 Rust 侧的值，这里使用 OHOS 注册的固定值 42e01f
      const OHOS_H264_PROFILE_LEVEL_ID = '42e01f';
      
      // 替换所有 H264 的 profile-level-id 为 OHOS 的值
      const replaced = processedSdp.replace(
        /profile-level-id=[0-9a-fA-F]{6}/g,
        `profile-level-id=${OHOS_H264_PROFILE_LEVEL_ID}`
      );
      
      if (replaced !== processedSdp) {
        LogUtil.info(`[WebRTC] v29 统一 ${type} SDP profile-level-id -> ${OHOS_H264_PROFILE_LEVEL_ID}`);
        processedSdp = replaced;
      }
    }
    
    const result: boolean = this.client.setRemoteDescription(processedSdp, type);
    if (result) {
      this.extractNegotiatedVideoCodec(processedSdp, type);
    }
    return result;
  }

  /**
   * v24: 从 SDP 中提取协商后的视频编解码器
   *
   * 解析流程:
   * 1. 找到 m=video 行，提取 payload type 列表（第一个 PT 优先级最高）
   * 2. 找到对应的 a=rtpmap:PT codec/clockRate 行
   * 3. 映射编解码器名称: VP8/H264/VP9
   */
  public extractNegotiatedVideoCodec(sdp: string, type: string): void {
    try {
      const lines: string[] = sdp.split('\n');
      let videoPayloadTypes: string[] = [];
      const rtpMap: Map<string, string> = new Map();

      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        // m=video 9 UDP/TLS/RTP/SAVPF 96 102
        if (line.startsWith('m=video')) {
          const parts: string[] = line.split(' ');
          // PT 列表从第4个开始
          for (let j = 3; j < parts.length; j++) {
            videoPayloadTypes.push(parts[j]);
          }
        }
        // a=rtpmap:96 VP8/90000
        if (line.startsWith('a=rtpmap:')) {
          const match: RegExpMatchArray | null = line.match(/a=rtpmap:(\d+)\s+([\w\-]+)\//);
          if (match !== null && match.length >= 3) {
            rtpMap.set(match[1], match[2]);
          }
        }
      }

      if (videoPayloadTypes.length > 0) {
        // v34: 当处理远端 Offer 时，优先选择本端可编码的 preferredVideoCodec
        // 场景：Android Offer H264 优先，但 OHOS 只能 H264 硬解码，不能硬编码
        //       此时应选择 VP8（OHOS 有 libvpx 软编码），而非盲目跟随 Offer 第一位
        const localPreferred: string = this.config.preferredVideoCodec ?? 'VP8';
        let selectedCodec: string = '';
        let selectedPT: string = '';

        // 第一轮：在远端 SDP 中查找本端偏好的编解码器
        for (let k = 0; k < videoPayloadTypes.length; k++) {
          let rawName: string = rtpMap.get(videoPayloadTypes[k]) ?? '';
          if (rawName.toUpperCase() === 'VP8') rawName = 'VP8';
          else if (rawName.toUpperCase() === 'H264') rawName = 'H264';
          else if (rawName.toUpperCase() === 'VP9') rawName = 'VP9';
          else if (rawName.toUpperCase() === 'H265') rawName = 'H265';
          if (rawName === localPreferred) {
            selectedCodec = rawName;
            selectedPT = videoPayloadTypes[k];
            break;
          }
        }

        // 第二轮回退：如果偏好编解码器不在远端 SDP 中，使用远端第一个
        if (selectedCodec === '') {
          const firstPT: string = videoPayloadTypes[0];
          let codecName: string = rtpMap.get(firstPT) ?? '';
          if (codecName.toUpperCase() === 'VP8') codecName = 'VP8';
          else if (codecName.toUpperCase() === 'H264') codecName = 'H264';
          else if (codecName.toUpperCase() === 'VP9') codecName = 'VP9';
          else if (codecName.toUpperCase() === 'H265') codecName = 'H265';
          selectedCodec = codecName;
          selectedPT = firstPT;
        }

        if (selectedCodec !== '') {
          const oldCodec: string = this.negotiatedVideoCodec ?? this.config.preferredVideoCodec ?? 'H264';
          this.negotiatedVideoCodec = selectedCodec;
          LogUtil.info(`[WebRTC] v35 SDP[${type}] 协商视频编解码(接收): ${selectedCodec} (PT=${selectedPT}), 本端偏好=${localPreferred}, 之前=${oldCodec}`);
          // v35: 非对称编解码 — negotiatedVideoCodec 仅用于接收端解码器选择
          // 发送端固定 VP8，不根据协商结果更新发送轨道的 codec/PT
        } else {
          LogUtil.warn(`[WebRTC] v24 SDP[${type}] 无法解析视频编解码器, PTs=${JSON.stringify(videoPayloadTypes)}, rtpmap=${JSON.stringify(Array.from(rtpMap.entries()))}`);
        }
      } else {
        LogUtil.info(`[WebRTC] v24 SDP[${type}] 无视频媒体段`);
      }
    } catch (e) {
      LogUtil.warn(`[WebRTC] v24 SDP 解析异常: ${(e as Error).message}`);
    }
  }

  /**
   * 添加 ICE 候选
   */
  public addIceCandidate(candidate: string, sdpMid?: string, sdpMlineIndex?: number): boolean {
    if (!this.client) return false;
    return this.client.addIceCandidate(candidate, sdpMid, sdpMlineIndex);
  }

  /**
   * 创建数据通道
   */
  public createDataChannel(label: string, ordered: boolean = true): boolean {
    if (!this.client) return false;
    return this.client.createDataChannel(label, ordered);
  }

  /**
   * 发送数据通道消息
   */
  public sendMessage(channelLabel: string, message: string): boolean {
    if (!this.client) return false;
    return this.client.sendMessage(channelLabel, message);
  }

  // ---- 音视频轨道处理（对接 Rust rtc 引擎） ----

  public localTracks: MediaTrackConfig[] = [];

  /**
   * 添加媒体轨道（音频或视频）
   * @param config 轨道配置
   */
  public addMediaTrack(config: MediaTrackConfig): boolean {
    if (!this.client) {
      LogUtil.error('[WebRTC] addMediaTrack: 客户端未初始化');
      return false;
    }

    // 将 codec 映射为 MIME 类型
    const codecMime = this.codecToMime(config.kind, config.codec);
    // PCMU/PCMA 是单声道(channels=0表示默认)，opus 是双声道，视频为 0
    // 必须与 MediaEngine 中注册的值一致，否则 codec 匹配失败
    let channels: number = 0;
    if (config.kind === 'audio' && config.codec === 'opus') {
      channels = 2;
    }

    const result: boolean = this.client.addMediaTrack(
      config.streamId,
      config.trackId,
      config.kind,
      codecMime,
      config.clockRate,
      channels,
      config.ssrc,
      config.payloadType
    );

    if (result) {
      this.localTracks.push(config);
      LogUtil.info(`[WebRTC] 轨道已添加: ${config.trackId} (${config.kind}/${config.codec})`);
    } else {
      LogUtil.error(`[WebRTC] 添加轨道失败: ${config.trackId}`);
    }
    return result;
  }

  /**
   * 移除媒体轨道
   */
  public removeMediaTrack(trackId: string): boolean {
    if (!this.client) return false;

    const result: boolean = this.client.removeMediaTrack(trackId);
    if (result) {
      this.localTracks = this.localTracks.filter((t: MediaTrackConfig) => t.trackId !== trackId);
      LogUtil.info(`[WebRTC] 轨道已移除: ${trackId}`);
    }
    return result;
  }

  /**
   * 获取所有媒体轨道
   */
  public getMediaTracks(): MediaTrackConfig[] {
    return this.localTracks;
  }

  /**
   * 获取 Rust 端的轨道 ID 列表
   */
  public getRemoteMediaTrackIds(): string[] {
    if (!this.client) return [];
    return this.client.getMediaTracks();
  }

  /**
   * 发送 PCM 音频数据（一体化：G.711 编码 + RTP 打包 + 发送，单次 NAPI 调用）
   * 一体化：G.711 编码 + RTP 打包 + 发送，单次 NAPI 调用
   * @param trackId 音频轨道 ID
   * @param pcmData PCM 16-bit LE 数据
   * @param timestamp RTP 时间戳
   */
  public sendPcmAudio(trackId: string, pcmData: Uint8Array, timestamp: number): boolean {
    if (!this.client) return false;
    return this.client.sendPcmAudio(trackId, pcmData, timestamp);
  }

  // ---- Phase 3: 视频编码器管理 + 一体化发送 ----

  /**
   * 创建 Rust 层内部视频编码器
   * H264 硬编码失败时自动回退到 VP8 软编码
   * @returns 实际使用的编解码器名称（"H264" 或 "VP8"），失败返回空字符串
   */
  public createVideoEncoder(config: NapiVideoEncoderConfig, codec: string): string {
    if (!this.client) return '';
    return this.client.createVideoEncoder(config, codec);
  }

  /** 启动 Rust 层内部视频编码器 */
  public startVideoEncoder(): boolean {
    if (!this.client) return false;
    return this.client.startVideoEncoder();
  }

  /** 停止 Rust 层内部视频编码器 */
  public stopVideoEncoder(): boolean {
    if (!this.client) return false;
    return this.client.stopVideoEncoder();
  }

  /** 销毁 Rust 层内部视频编码器 */
  public destroyVideoEncoder(): void {
    if (!this.client) return;
    this.client.destroyVideoEncoder();
  }

  /** 请求视频关键帧（通过 Rust 层内部编码器） */
  public requestVideoKeyFrame(): boolean {
    if (!this.client) return false;
    return this.client.requestVideoKeyFrame();
  }

  /** 获取 Rust 层内部视频编码器实际使用的编解码器 */
  public getVideoEncoderCodec(): string {
    if (!this.client) return '';
    return this.client.getVideoEncoderCodec();
  }

  /**
   * 视频编码 + RTP 打包 + 发送（一体化，单次 NAPI 调用）
   * 一体化：编码 + RTP 打包 + 发送，单次 NAPI 调用
   * @returns 发送的 RTP 包总数，-1 表示失败
   */
  public encodeAndSendVideo(trackId: string, yuvData: Uint8Array, timestampUs: number, rtpTimestamp: number): number {
    if (!this.client) return -1;
    return this.client.encodeAndSendVideo(trackId, yuvData, timestampUs, rtpTimestamp);
  }

  /**
   * 接收完整媒体帧（Rust 层 RTP 解包 + 帧重组，消除 JSON/base64 开销）
   * @returns 完整媒体帧列表
   */
  public receiveMediaFrames(): NapiMediaFrame[] {
    if (!this.client) return [];
    return this.client.pollMediaFrames();
  }
  
  /**
   * v28: 发送 RTCP PLI（Picture Loss Indication）请求关键帧
   * 
   * 当解码器检测到花屏或丢包时，通过此方法通知发送端立即发送关键帧
   * 
   * @param trackId 轨道 ID
   * @return 是否成功发送
   */
  public sendRtcpPli(trackId: string): boolean {
    if (!this.client) {
      LogUtil.warn('[WebRTC] sendRtcpPli: 客户端未初始化');
      return false;
    }
      
    LogUtil.info(`[WebRTC] 发送 PLI: trackId=${trackId}`);
    return this.client.sendRtcpPli(trackId);
  }

  /**
   * 添加视频轨道（便捷方法）
   * @param trackId 轨道 ID
   * @param codec 编解码器 (H264, VP8, VP9)
   * @param ssrc SSRC
   */
  public addVideoTrack(trackId: string, codec: string = 'H264', ssrc: number = 0): boolean {
    const config: MediaTrackConfig = {
      trackId: trackId,
      streamId: 'ARDAMS',
      kind: 'video',
      codec: codec,
      ssrc: ssrc || Math.floor(Math.random() * 0xFFFFFFFF),
      payloadType: codec === 'VP8' ? 96 : (codec === 'VP9' ? 98 : 102),
      clockRate: 90000, // 视频标准时钟频率
    };
    return this.addMediaTrack(config);
  }

  /**
   * 添加音频轨道（便捷方法）
   * @param trackId 轨道 ID
   * @param codec 编解码器 (opus, PCMU, PCMA)
   * @param ssrc SSRC
   */
  public addAudioTrack(trackId: string, codec: string = 'opus', ssrc: number = 0): boolean {
    const clockRate = codec === 'opus' ? 48000 : 8000;
    const payloadType = codec === 'opus' ? 111 : (codec === 'PCMU' ? 0 : 8);
    
    const config: MediaTrackConfig = {
      trackId: trackId,
      streamId: 'ARDAMS',
      kind: 'audio',
      codec: codec,
      ssrc: ssrc || Math.floor(Math.random() * 0xFFFFFFFF),
      payloadType: payloadType,
      clockRate: clockRate,
    };
    return this.addMediaTrack(config);
  }

  /**
   * 获取连接状态
   */
  public getConnectionState(): string {
    if (!this.client) return 'unknown';
    return this.client.getConnectionState();
  }

  /**
   * 是否已连接
   */
  public get isConnected(): boolean {
    return this.client?.isConnected() ?? false;
  }

  /**
   * 获取本地 UDP 地址
   */
  public getLocalUdpAddress(): string | null {
    return this.client?.getLocalUdpAddress() ?? null;
  }

  /**
   * 关闭连接
   */
  public async close(): Promise<void> {
    this.stopEventLoop();
    
    // 销毁信令客户端
    if (this.signaling) {
      this.signaling.destroy();
      this.signaling = null;
    }
    this.peerRoomMap.clear();
    this.cachedIceCandidates = []; // v42: 清空缓存的 ICE 候选

    // 关闭 WebRTC 客户端（内部会自动停止 UDP 后台线程）
    this.client?.close();
    this.client = null;
    
    // 清空本地轨道状态，确保下次 init() 时从零开始
    this.localTracks = [];
    
    LogUtil.info('[WebRTC] 连接已关闭');
  }

  /**
   * 重置状态以准备新的呼叫
   * 关闭旧连接并重新初始化，确保 SDP 生成正确
   */
  public resetForNewCall(): void {
    // 清空轨道状态
    this.localTracks = [];
    this.peerRoomMap.clear();
    this.offerPending = false;
    this.negotiatedVideoCodec = null; // v24: 清除上次的协商结果
    this.cachedIceCandidates = []; // v42: 清空缓存的 ICE 候选
    
    // 如果已有客户端，关闭并重新创建
    if (this.client !== null) {
      LogUtil.info('[WebRTC] resetForNewCall: 关闭旧客户端并重新创建');
      this.stopEventLoop();
      this.client.close(); // 内部会停止 UDP
      this.client = null;
      
      // 同步创建新客户端
      this.init();
    }
  }

  // ---- 事件回调设置 ----

  public setOnStateChange(callback: (state: string) => void): void {
    this.onStateChange = callback;
  }

  public setOnConnected(callback: () => void): void {
    this.onConnected = callback;
  }

  public setOnDisconnected(callback: () => void): void {
    this.onDisconnected = callback;
  }

  public setOnIceCandidate(callback: (candidate: string) => void): void {
    this.onIceCandidate = callback;
  }

  public setOnDataChannelMessage(callback: (message: string) => void): void {
    this.onDataChannelMessage = callback;
  }

  /**
   * 设置媒体帧接收回调（Rust 层 RTP 解包 + 帧重组后的完整帧）
   */
  public setOnMediaFrameReceived(callback: (frame: NapiMediaFrame) => void): void {
    this.onMediaFrameReceived = callback;
  }

  public setOnError(callback: (error: string) => void): void {
    this.onError = callback;
  }

  // ---- 事件循环 ----

  /**
   * 启动事件循环（使用 setTimeout 递归调度，避免 setInterval 回调积压导致 ANR）
   *
   * setInterval 在 tick 执行超时后，会立即执行所有已积压的回调，
   * 导致主线程被连续占用数秒。改用 setTimeout 递归可保证：
   * 每个 tick 完成后至少等 POLL_INTERVAL 再执行下一个，给 UI 和其他任务留出执行窗口。
   */
  public startEventLoop(): void {
    if (this.eventLoopRunning) return;
    this.eventLoopRunning = true;
    this.scheduleNextTick();
    LogUtil.info('[WebRTC] 事件循环已启动 (setTimeout 模式)');
  }

  public scheduleNextTick(): void {
    if (!this.eventLoopRunning) return;
    this.pollTimer = setTimeout(() => {
      this.eventLoopTick();
      // tick 完成后再调度下一个，确保不会积压
      this.scheduleNextTick();
    }, this.POLL_INTERVAL);
  }

  public stopEventLoop(): void {
    this.eventLoopRunning = false;
    if (this.pollTimer !== null) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
    LogUtil.info('[WebRTC] 事件循环已停止');
  }

  /**
   * 事件循环单次执行
   *
   * v27: 网络 I/O 已移至 Rust 后台线程，此处仅轮询事件队列
   * v28: RTP 包直接轮询，不再依赖事件通知（避免事件队列洪泛）
   */
  public eventLoopTick(): void {
    if (!this.client) return;

    // v27: handle_timeout 和 sendOutgoingPackets 已由 Rust 后台线程处理
    // ArkTS 仅轮询事件队列（状态变化、ICE 候选等）
    this.pollEvents();

    // 轮询完整媒体帧（Rust 层 RTP 解包 + 帧重组）
    if (this.onMediaFrameReceived) {
      const frames: NapiMediaFrame[] = this.receiveMediaFrames();
      for (let f = 0; f < frames.length; f++) {
        this.onMediaFrameReceived(frames[f]);
      }
    }
  }

  public pollEvents(): void {
    if (!this.client) return;
    const start: number = Date.now();

    const events: string[] = this.client.pollAllEvents();
    for (let i = 0; i < events.length; i++) {
      this.handleEvent(events[i]);
      // 宽松时间防护：正常运行不触发，仅在积压时截断防止阻塞主线程数秒
      if (Date.now() - start > this.TICK_MAX_MS) {
        LogUtil.warn(`[WebRTC] pollEvents 截断: 已处理 ${i + 1}/${events.length} 事件, 耗时 ${Date.now() - start}ms`);
        break;
      }
    }
  }

  public handleEvent(eventJson: string): void {
    try {
      const event = JSON.parse(eventJson) as WebRTCEventData;
      LogUtil.debug(`[WebRTC] 事件: ${event.type}`);

      switch (event.type) {
        case 'state_change':
          this.onStateChange?.(event.data ?? 'unknown');
          break;

        case 'connected':
          this.onConnected?.();
          break;

        case 'disconnected':
        case 'closed':
          this.onDisconnected?.();
          break;

        case 'ice_candidate':
          if (event.data) {
            this.onIceCandidate?.(event.data);
          }
          break;

        case 'data_channel_message':
          if (event.data) {
            this.onDataChannelMessage?.(event.data);
          }
          break;

        case 'rtp_packet_received':
          if (this.onMediaFrameReceived) {
            const frames2: NapiMediaFrame[] = this.receiveMediaFrames();
            for (let f2 = 0; f2 < frames2.length; f2++) {
              this.onMediaFrameReceived(frames2[f2]);
            }
          }
          break;

        case 'error':
          LogUtil.error(`[WebRTC] 错误: ${event.error}`);
          this.onError?.(event.error ?? 'Unknown error');
          break;

        default:
          LogUtil.debug(`[WebRTC] 未知事件: ${event.type}`);
      }
    } catch (e) {
      LogUtil.error(`[WebRTC] 解析事件失败: ${eventJson}`);
    }
  }

  /**
   * 将编解码器名称转换为 MIME 类型
   */
  public codecToMime(kind: string, codec: string): string {
    if (kind === 'video') {
      if (codec === 'VP8') return 'video/VP8';
      if (codec === 'VP9') return 'video/VP9';
      if (codec === 'H264') return 'video/H264';
      if (codec === 'H265') return 'video/H265';
      return `video/${codec}`;
    }
    // audio
    if (codec === 'opus') return 'audio/opus';
    if (codec === 'PCMU') return 'audio/PCMU';
    if (codec === 'PCMA') return 'audio/PCMA';
    if (codec === 'AAC') return 'audio/AAC';
    return `audio/${codec}`;
  }

  // ============================================================
  // 信令集成 — 对齐 Android WebRtcManager
  // ============================================================

  /**
   * 初始化信令连接（对齐 Android WebRtcManager.init）
   *
   * 如果 WebRTC 客户端尚未初始化，会自动调用 init() 创建 Rust WebRtcClient 和 UDP Socket。
   *
   * @param socketUrl 信令服务器 WebSocket URL（不含 MAC 后缀）
   * @param snNum 本机设备标识（MAC / SN）
   * @param jsonStr 扩展信息
   */
  public initSignaling(socketUrl: string, snNum: string, jsonStr: string): void {
    LogUtil.info(`[WebRTC] initSignaling: socketUrl=${socketUrl}, snNum=${snNum}, jsonStr=${jsonStr}`);
    this.localMac = snNum;

    // 如果已有客户端，先关闭再重新初始化（确保每次呼叫都从干净状态开始）
    if (this.client !== null) {
      LogUtil.info('[WebRTC] 检测到已有客户端，先关闭再重新初始化');
      this.stopEventLoop();
      this.client.close(); // 内部会停止 UDP
      this.client = null;
      this.localTracks = [];
      this.peerRoomMap.clear();
      this.cachedIceCandidates = []; // v42: 清空缓存的 ICE 候选
    }

    // 初始化 WebRTC 客户端（Rust PeerConnection + UDP Socket）
    LogUtil.info('[WebRTC] 初始化 WebRTC 客户端');
    this.init().then((success: boolean) => {
      if (success) {
        LogUtil.info('[WebRTC] WebRTC 客户端初始化成功');
      } else {
        LogUtil.error('[WebRTC] WebRTC 客户端初始化失败！SDP/ICE 将无法工作');
      }
    }).catch((e: Error) => {
      LogUtil.error(`[WebRTC] WebRTC 客户端初始化异常: ${e.message}`);
    });

    this.signaling = new SignalingClient();

    const sigCallback = new SignalingCallbackImpl(this);
    this.signaling.init(socketUrl, snNum, jsonStr, sigCallback);
    LogUtil.info(`[WebRTC] initSignaling 完成，等待连接...`);

    // 当收到 ICE 候选时自动通过信令转发
    // v42: 缓存 ICE 候选，并在 peerRoomMap 非空时发送
    this.setOnIceCandidate((candidateData: string) => {
      // Rust 端现在推送完整 ICE 候选 JSON: {candidate, sdpMid, sdpMLineIndex}
      let candidateStr: string = candidateData;
      let sdpMid: string = 'audio';
      let sdpMLineIndex: number = 0;

      try {
        const parsed = JSON.parse(candidateData) as IceCandidateJson;
        candidateStr = parsed.candidate;
        sdpMid = parsed.sdpMid ?? 'audio';
        sdpMLineIndex = parsed.sdpMLineIndex ?? 0;
      } catch (_e) {
        // 降级兼容：如果不是 JSON，直接当作候选字符串使用
        LogUtil.warn(`[WebRTC] ICE 候选非 JSON 格式，降级处理: ${candidateData}`);
      }

      // v42: 缓存 ICE 候选
      const iceCandidate: CachedIceCandidate = {
        candidate: candidateStr,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex
      };
      this.cachedIceCandidates.push(iceCandidate);
      LogUtil.info(`[WebRTC] v42 ICE 候选已缓存: ${candidateStr.substring(0, 50)}..., 缓存数=${this.cachedIceCandidates.length}`);

      // 将 ICE 候选发送给所有已知对端
      this.sendCachedIceCandidates();
    });
  }

  /**
   * 创建 Offer 并通过信令发送
   */
  public createAndSendOffer(toMac: string, roomId: string): void {
    LogUtil.info(`[WebRTC] createAndSendOffer: toMac=${toMac}, roomId=${roomId}`);
    // 先添加媒体轨道
    this.setupMediaTracksForCall(this.currentCallType === CallType.VIDEO);

    const offerSdp = this.createOffer();
    if (offerSdp !== null) {
      LogUtil.info(`[WebRTC] Offer SDP 创建成功, 长度=${offerSdp.length}`);
      this.setLocalDescription(offerSdp, 'offer');
      this.offerPending = true; // 标记已发送 Offer，等待 Answer
      this.signaling?.sendSessionDescription(offerSdp, 'offer', toMac, roomId);
      LogUtil.info(`[WebRTC] Offer 已发送给 ${toMac}`);
    } else {
      LogUtil.error('[WebRTC] Offer SDP 创建失败');
    }
  }

  /**
   * 根据通话类型设置媒体轨道
   */
  public setupMediaTracksForCall(enableVideo: boolean): void {
    // 始终添加音频轨道（使用 PCMU 编码，payload type 0）
    if (!this.hasTrackOfKind('audio')) {
      this.addAudioTrack('ARDAMSa0', 'PCMU');
    }

    // v36: 根据设备编码能力动态选择发送编解码器
    // SDP 的 codec 顺序由 Rust MediaEngine 注册顺序决定（bestRecvCodec 优先），与本地发送轨道无关
    const videoCodec: string = this.getSendVideoCodec();
    if (enableVideo && !this.hasTrackOfKind('video')) {
      this.addVideoTrack('ARDAMSv0', videoCodec);
      LogUtil.info(`[WebRTC] v25 setupMediaTracks: videoCodec=${videoCodec}, negotiated=${this.negotiatedVideoCodec}, preferred=${this.config.preferredVideoCodec}`);
    }
  }

  public hasTrackOfKind(kind: string): boolean {
    for (let i = 0; i < this.localTracks.length; i++) {
      if (this.localTracks[i].kind === kind) return true;
    }
    return false;
  }

  /**
   * v25/v36: 更新已注册的视频轨道的 codec 和 payloadType
   *
   * SDP 协商后，实际使用的编解码器可能与初始添加轨道时不同。
   * 例如: 偏好 H264(PT=102) 但协商后选择 VP8(PT=96)
   * 必须同步更新 localTracks，否则 RTP 发送会用错误的 PT。
   * v36: 开放为 public，供 MediaStream 在编码器回退时同步轨道信息
   */
  public updateVideoTrackCodec(newCodec: string): void {
    const newPT: number = newCodec === 'VP8' ? 96 : (newCodec === 'VP9' ? 98 : 102);
    for (let i = 0; i < this.localTracks.length; i++) {
      if (this.localTracks[i].kind === 'video') {
        const oldCodec: string = this.localTracks[i].codec;
        const oldPT: number = this.localTracks[i].payloadType;
        if (oldPT !== newPT) {
          this.localTracks[i].codec = newCodec;
          this.localTracks[i].payloadType = newPT;
          LogUtil.warn(`[WebRTC] v25 视频轨道PT已更新: ${oldCodec}(PT=${oldPT}) → ${newCodec}(PT=${newPT})`);
        }
        break;
      }
    }
  }

  // ---- 房间管理（对齐 Android WebRtcManager） ----

  /** 加入房间 */
  public joinRoom(roomId: string): void {
    this.signaling?.sendJoinRoom(roomId);
  }

  /** 离开房间 */
  public leaveRoom(roomId: string): void {
    this.signaling?.sendLeaveRoom(roomId);
  }

  // ---- 呼叫控制（对齐 Android WebRtcManager） ----

  /** 发起语音呼叫 */
  public call(toMacList: string[], roomId: string, msg: string): void {
    LogUtil.info(`[WebRTC] call: toMacList=${JSON.stringify(toMacList)}, roomId=${roomId}, msg=${msg}`);
    LogUtil.info(`[WebRTC] call: signaling=${this.signaling !== null ? 'ok' : 'null'}, isConnected=${this.signaling?.getIsConnected()}`);
    this.currentCallType = CallType.VOICE;
    this.signaling?.setCurrentCallType(CallType.VOICE);
    
    // 确保每次呼叫都从干净状态开始
    this.resetForNewCall();
    
    for (let i = 0; i < toMacList.length; i++) {
      LogUtil.info(`[WebRTC] call[${i}]: toMac=${toMacList[i]}`);
      this.signaling?.sendCall(toMacList[i], roomId, msg);
    }
  }

  /** 发起视频呼叫 */
  public videoCall(toMacList: string[], roomId: string, msg: string, callType: CallType): void {
    LogUtil.info(`[WebRTC] videoCall: toMacList=${JSON.stringify(toMacList)}, roomId=${roomId}, msg=${msg}, callType=${callType}`);
    LogUtil.info(`[WebRTC] videoCall: signaling=${this.signaling !== null ? 'ok' : 'null'}, isConnected=${this.signaling?.getIsConnected()}`);
    this.currentCallType = callType;
    this.signaling?.setCurrentCallType(callType);
    
    // 确保每次呼叫都从干净状态开始
    this.resetForNewCall();
    
    for (let i = 0; i < toMacList.length; i++) {
      LogUtil.info(`[WebRTC] videoCall[${i}]: toMac=${toMacList[i]}`);
      this.signaling?.sendVideoCall(toMacList[i], roomId, msg, callType);
    }
  }

  /**
   * 接听呼叫
   * 
   * 关键流程：
   * 1. 发送 doing 信令通知呼叫方
   * 2. 加入房间（触发服务器发送 client_joined）
   * 3. 设置 peerRoomMap 以便接收 ICE 候选
   * 4. 等待呼叫方发送 Offer（标准 WebRTC 流程：呼叫方创建 Offer）
   * 
   * 注意：被叫方不主动创建 Offer，而是等待呼叫方的 Offer 后创建 Answer
   */
  public answer(allMacList: string[], roomId: string): void {
    LogUtil.info(`[WebRTC] answer: allMacList=${JSON.stringify(allMacList)}, roomId=${roomId}`);
    
    // 1. 设置对端映射（用于接收 ICE 候选）
    for (let i = 0; i < allMacList.length; i++) {
      this.setPeerRoom(allMacList[i], roomId);
    }
    
    // 2. 发送 doing 信令通知呼叫方
    for (let i = 0; i < allMacList.length; i++) {
      this.signaling?.sendAnswer(allMacList[i], roomId);
    }
    
    LogUtil.info(`[WebRTC] answer 完成，等待呼叫方发送 Offer`);
  }

  /** 挂断 */
  public hangup(toMacList: string[], roomId: string): void {
    for (let i = 0; i < toMacList.length; i++) {
      this.signaling?.sendHangup(toMacList[i], roomId);
    }
    this.currentCallType = CallType.VOICE;
  }

  /** 视频挂断 */
  public videoHangup(toMacList: string[], roomId: string): void {
    for (let i = 0; i < toMacList.length; i++) {
      this.signaling?.sendVideoHangup(toMacList[i], roomId);
    }
    this.currentCallType = CallType.VOICE;
  }

  /** SOS 呼叫 */
  public sosCall(toMacList: string[], roomId: string, msg: string): void {
    LogUtil.info(`[WebRTC] sosCall: toMacList=${JSON.stringify(toMacList)}, roomId=${roomId}, msg=${msg}`);
    LogUtil.info(`[WebRTC] sosCall: signaling=${this.signaling !== null ? 'ok' : 'null'}, isConnected=${this.signaling?.getIsConnected()}`);
    
    // 确保每次呼叫都从干净状态开始
    this.resetForNewCall();
    
    for (let i = 0; i < toMacList.length; i++) {
      LogUtil.info(`[WebRTC] sosCall[${i}]: toMac=${toMacList[i]}`);
      this.signaling?.sendSosCall(toMacList[i], roomId, msg);
    }
  }

  /** SOS 挂断 */
  public sosHangup(toMacList: string[], roomId: string): void {
    for (let i = 0; i < toMacList.length; i++) {
      this.signaling?.sendSosHangup(toMacList[i], roomId);
    }
  }

  /** 转接 */
  public transfer(toMac: string, roomId: string): void {
    this.signaling?.sendTransfer(toMac, roomId);
  }

  /** 忽略 */
  public ignore(toMac: string, roomId: string): void {
    this.signaling?.sendIgnore(toMac, roomId);
  }

  /** 发送通知 */
  public sendNotice(toMacList: string[], roomId: string, msg: string): void {
    for (let i = 0; i < toMacList.length; i++) {
      this.signaling?.sendNotice(toMacList[i], roomId, msg);
    }
  }

  /** 获取当前通话类型 */
  public getCurrentCallType(): CallType {
    return this.currentCallType;
  }

  /**
   * v36: 获取接收端视频编解码器（用于解码器选择）
   *
   * 优先级: negotiatedVideoCodec (SDP协商结果) > 设备检测 bestRecvCodec > VP8 兜底
   * 非对称编解码场景：设备只有 H264 解码 → bestRecvCodec=H264 → Android 发 H264 → OHOS 硬解码
   */
  public getPreferredVideoCodec(): string {
    if (this.negotiatedVideoCodec !== null) {
      return this.negotiatedVideoCodec;
    }
    return this.codecCapabilities?.bestRecvCodec ?? this.config.preferredVideoCodec ?? 'VP8';
  }

  /**
   * v36: 获取发送端视频编解码器（用于编码器选择）
   *
   * 根据设备编码能力自动选择，不再硬编码 VP8
   * 优先级: H265 > H264 > VP9 > VP8（取决于设备硬件能力 + 已实现的编解码器）
   * VP8 软编码（libvpx）始终兜底
   */
  public getSendVideoCodec(): string {
    return this.codecCapabilities?.bestSendCodec ?? 'VP8';
  }

  /**
   * v36: 获取设备编解码能力（供外部诊断使用）
   */
  public getCodecCapabilities(): VideoCodecCapabilities | null {
    return this.codecCapabilities;
  }

  /** 获取信令连接状态 */
  public getSignalingConnected(): boolean {
    return this.signaling?.getIsConnected() ?? false;
  }

  // ---- 呼叫事件回调设置 ----

  public setOnCallReceived(callback: (fromMac: string, roomId: string, msg: string) => void): void {
    this.onCallReceived = callback;
  }

  public setOnCallAnswered(callback: (fromMac: string, toMac: string, roomId: string) => void): void {
    this.onCallAnswered = callback;
  }

  public setOnCallHangup(callback: (fromMac: string, roomId: string) => void): void {
    this.onCallHangup = callback;
  }

  public setOnVideoCallReceived(callback: (fromMac: string, roomId: string, msg: string, callType: CallType) => void): void {
    this.onVideoCallReceived = callback;
  }

  public setOnVideoCallHangup(callback: (fromMac: string, roomId: string) => void): void {
    this.onVideoCallHangup = callback;
  }

  public setOnSosCallReceived(callback: (fromMac: string, roomId: string, msg: string) => void): void {
    this.onSosCallReceived = callback;
  }

  public setOnSosCallHangup(callback: (fromMac: string, roomId: string) => void): void {
    this.onSosCallHangup = callback;
  }

  public setOnTransferReceived(callback: (fromMac: string, roomId: string) => void): void {
    this.onTransferReceived = callback;
  }

  public setOnIgnoreReceived(callback: (fromMac: string, roomId: string) => void): void {
    this.onIgnoreReceived = callback;
  }

  public setOnNoticeReceived(callback: (fromMac: string, roomId: string, msg: string) => void): void {
    this.onNoticeReceived = callback;
  }

  public setOnSignalingConnected(callback: () => void): void {
    this.onSignalingConnected = callback;
  }

  public setOnPeerJoined(callback: (fromMac: string, roomId: string) => void): void {
    this.onPeerJoined = callback;
  }

  public setOnPeerLeaved(callback: (fromMac: string, roomId: string) => void): void {
    this.onPeerLeaved = callback;
  }
}

// 导出单例
export const WebRTC = new WebRTCManager();

// 重新导出信令相关类型
export { CallType } from './SignalingClient';
export type { SignalingData } from './SignalingClient';
