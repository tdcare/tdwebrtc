/**
 * tdwebrtc 模块入口
 *
 * 导出 WebRTC 音视频通话所需的全部公共 API：
 * - WebRTC 引擎管理 (WebRTCAdapter)
 * - 媒体流管理 (MediaStream)
 * - 信令客户端 (SignalingClient)
 * - 视频渲染组件 (VideoSurface)
 */

// ===== WebRTC 引擎 =====
export {
  WebRTC,
  CallType,
  isUsingMock,
  getWebRTCVersion,
} from './src/main/ets/WebRTCAdapter';

export type {
  MediaTrackConfig,
  WebRTCConfig,
  SignalingData,
  IWebRTCManager,
} from './src/main/ets/WebRTCAdapter';

// ===== 媒体流 =====
export {
  WebRTCMediaStream,
  createMediaStream,
} from './src/main/ets/MediaStream';

export type {
  MediaStreamConfig,
  MediaStreamAudioConfig,
  MediaStreamVideoConfig,
} from './src/main/ets/MediaStream';

// ===== 视频渲染组件 =====
export {
  VideoSurface,
  RemoteVideoSurface,
} from './src/main/ets/VideoSurface';

export type {
  SurfaceInfo,
} from './src/main/ets/VideoSurface';

// ===== 信令客户端 =====
export {
  SignalingClient,
  CmdType,
  CmdAction,
} from './src/main/ets/SignalingClient';

export type {
  SignalingCallback,
} from './src/main/ets/SignalingClient';

// ===== 编解码工具 =====
export {
  VideoDecoder,
  DecodedFrame,
  isCodecSupported,
  detectVideoCodecCapabilities,
} from './src/main/ets/MediaCodec';

export type {
  VideoDecoderConfig,
  VideoCodecCapabilities,
} from './src/main/ets/MediaCodec';
