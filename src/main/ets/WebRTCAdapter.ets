/**
 * WebRTC 适配器
 * 桥接真实的 Rust WebRTC 实现和上层页面
 *
 * 直接从 WebRTCManager 导出所有必要类型和单例
 */

import { LogUtil } from './utils/LogUtil';
// 导入真实的 WebRTC 实现
import {
  WebRTC as RealWebRTC,
  CallType as RealCallType,
} from './WebRTCManager';

import type {
  MediaTrackConfig as RealMediaTrackConfig,
  WebRTCConfig as RealWebRTCConfig,
} from './WebRTCManager';

import type { SignalingData as RealSignalingData } from './SignalingClient';

// ===== 类型定义（重新导出） =====

export type MediaTrackConfig = RealMediaTrackConfig;
export type WebRTCConfig = RealWebRTCConfig;
export type SignalingData = RealSignalingData;

// ===== 重新导出 CallType =====
export { CallType } from './WebRTCManager';

// ===== WebRTC 管理器接口 =====

export interface IWebRTCManager {
  // 初始化
  init(config?: WebRTCConfig): Promise<boolean>;
  close(): Promise<void>;

  // 连接状态
  readonly isConnected: boolean;
  getConnectionState(): string;

  // SDP
  createOffer(): string | null;
  createAnswer(): string | null;
  setLocalDescription(sdp: string, type: 'offer' | 'answer'): boolean;
  setRemoteDescription(sdp: string, type: 'offer' | 'answer'): boolean;

  // ICE
  addIceCandidate(candidate: string, sdpMid?: string, sdpMlineIndex?: number): boolean;

  // 数据通道
  createDataChannel(label: string, ordered?: boolean): boolean;
  sendMessage(channelLabel: string, message: string): boolean;

  // 媒体轨道
  addVideoTrack(trackId: string, codec?: string, ssrc?: number): boolean;
  addAudioTrack(trackId: string, codec?: string, ssrc?: number): boolean;
  getMediaTracks(): MediaTrackConfig[];

  // 回调设置
  setOnStateChange(callback: (state: string) => void): void;
  setOnConnected(callback: () => void): void;
  setOnDisconnected(callback: () => void): void;
  setOnIceCandidate(callback: (candidate: string) => void): void;
  setOnDataChannelMessage(callback: (message: string) => void): void;
  setOnError(callback: (error: string) => void): void;
}

// ===== 使用真实实现 =====

LogUtil.info('[WebRTC Adapter] 使用真实 Rust WebRTC 实现');

// ===== 导出 =====

// 导出单例
export const WebRTC = RealWebRTC;

// 导出信息
export const isUsingMock = false;

// 获取版本信息
export function getWebRTCVersion(): string {
  return 'Rust WebRTC (real)';
}
