# TD WebRTC for HarmonyOS

基于 [webrtc-rs/rtc](https://github.com/webrtc-rs/rtc) 的鸿蒙 WebRTC 模块。

## 安装

### 通过 OHPM 安装

```bash
ohpm install tdwebrtc
# 或简写
ohpm i tdwebrtc
```

### 在项目中引用

在 `oh-package.json5` 中添加依赖：

```json5
{
  "dependencies": {
    "tdwebrtc": "file:./tdwebrtc"
  }
}
```

## 快速开始

### 基本使用

```typescript
import { WebRTC, createMediaStream, VideoSurface, RemoteVideoSurface } from 'tdwebrtc';
import type { SurfaceInfo } from 'tdwebrtc';

// 1. 初始化 WebRTC
const success = await WebRTC.init({
  stunServers: ['stun:stun.l.google.com:19302'],
  localPort: 0, // 0 表示随机端口
});

// 2. 创建媒体流
const mediaStream = createMediaStream({
  video: { 
    enabled: true, 
    width: 1280, 
    height: 720, 
    frameRate: 30,
    codec: 'H264', // 或 'VP8', 'H265', 'VP9'
  },
  audio: { 
    enabled: true, 
    sampleRate: 8000, 
    channels: 1,
    codec: 'PCMU', // 或 'OPUS', 'AAC'
  },
}, context);

// 3. 设置视频 Surface
mediaStream.setLocalVideoSurface(localSurfaceId);
mediaStream.setRemoteVideoSurface(remoteSurfaceId);

// 4. 启动媒体流
await mediaStream.startSending();
await mediaStream.startReceiving();
```

## 核心功能

- ✅ **WebRTC 协议**：SDP 协商、ICE 交换、DTLS 握手、RTP/RTCP 传输
- ✅ **数据通道**：SCTP 可靠/非可靠传输
- ✅ **视频编解码**：H.264/H.265 硬件加速、VP8 软件解码
- ✅ **音频编解码**：G.711 (PCMU/PCMA)、OPUS 软件编解码
- ✅ **媒体流管理**：采集、编解码、RTP 传输全链路封装
- ✅ **视频渲染**：XComponent 本地预览与远端渲染组件
- ✅ **设备控制**：摄像头切换、音频路由切换、静音控制

## API 参考

### WebRTC 管理器

```typescript
import { WebRTC } from 'tdwebrtc';

// 初始化
const success = await WebRTC.init({ 
  stunServers: ['stun:stun.l.google.com:19302'],
  localPort: 0,
});

// 创建 Offer/Answer（返回 string | null）
const offer = WebRTC.createOffer();
const answer = WebRTC.createAnswer();

// 设置描述
WebRTC.setLocalDescription(offer, 'offer');
WebRTC.setRemoteDescription(sdp, 'answer');

// ICE 候选
WebRTC.addIceCandidate(candidate, sdpMid, sdpMLineIndex);

// 数据通道
WebRTC.createDataChannel('chat', true);
WebRTC.sendMessage('chat', 'Hello');

// 媒体轨道
WebRTC.addVideoTrack('video-0', 'H264');
WebRTC.addAudioTrack('audio-0', 'PCMU');
const tracks = WebRTC.getMediaTracks();

// 回调设置
WebRTC.setOnStateChange((state) => {
  console.log('状态变化:', state);
});
WebRTC.setOnConnected(() => {
  console.log('已连接');
});
WebRTC.setOnIceCandidate((candidate) => {
  console.log('ICE 候选:', candidate);
});
```

### MediaStream

```typescript
import { createMediaStream, WebRTCMediaStream } from 'tdwebrtc';
import type { MediaStreamConfig } from 'tdwebrtc';

// 创建
const config: MediaStreamConfig = {
  video: { enabled: true, width: 1280, height: 720, codec: 'H264' },
  audio: { enabled: true, sampleRate: 8000, codec: 'PCMU' },
};
const mediaStream = createMediaStream(config, context);

// 设置 Surface
mediaStream.setLocalVideoSurface(surfaceId);
mediaStream.setRemoteVideoSurface(surfaceId);

// 启停
await mediaStream.startSending();
await mediaStream.startReceiving();
await mediaStream.stopAll();

// 控制
await mediaStream.setVideoEnabled(false);
await mediaStream.switchCamera();
mediaStream.setAudioMute(true);

// 发送数据
mediaStream.sendVideoFrame(yuvData);
mediaStream.sendAudioSamples(pcmData);

// 释放
mediaStream.release();
```

### 视频编解码器支持

| 编解码器 | 类型 | 说明 |
|---------|------|------|
| H264 | 视频 | 硬件加速，推荐使用 |
| H265 | 视频 | 硬件加速 |
| VP8 | 视频 | 软件解码 |
| VP9 | 视频 | 软件解码 |
| PCMU | 音频 | G.711 µ-law |
| PCMA | 音频 | G.711 A-law |
| OPUS | 音频 | 高质量音频编解码 |
| AAC | 音频 | 通用音频格式 |

## 依赖说明

本模块依赖以下 ArkTS 系统能力：

- `@kit.AbilityKit`: common.Context
- `@kit.ArkTS`: 基础类型
- `@ohos.multimedia.media`: 音视频编解码
- `@ohos.multimedia.audioRenderer`: 音频播放
- `@ohos.multimedia.audioCapturer`: 音频采集
- `@ohos.multimedia.camera`: 摄像头采集
- `@ohos.netconnection`: UDP 网络

## 权限配置

在使用前，请确保已在 `module.json5` 中配置以下权限：

```json5
{
  "requestPermissions": [
    { "name": "ohos.permission.CAMERA" },
    { "name": "ohos.permission.MICROPHONE" },
    { "name": "ohos.permission.INTERNET" }
  ]
}
```

## 常见问题

### Q: 看不到远端视频？

A: 检查以下几点：
1. PeerConnection 状态是否为 'connected'
2. 确认已收到远端 RTP 包
3. 检查视频解码器是否已初始化
4. 确认 Surface 已连接到解码器

```typescript
WebRTC.setOnStateChange((state) => {
  if (state === 'connected') {
    console.log('可以启动媒体流了');
  }
});
```

### Q: 本地预览黑屏？

A: 确保按顺序正确初始化：

```typescript
// 1. 创建 XComponent 获取 surfaceId
XComponent({
  componentId: 'local-preview',
  type: 'surface',
  onSurfaceReady: (info) => {
    // 2. 将 surfaceId 传递给 MediaStream
    mediaStream.setLocalVideoSurface(info.surfaceId);
  }
})
```

同时需要申请相机权限。

### Q: 音频有杂音？

A: 检查以下配置：
1. 采样率匹配（推荐 8kHz 或 48kHz）
2. 声道数配置正确（通常单声道）
3. 音频缓冲区大小合适
4. 确认编解码器匹配（PCMU/PCMA/OPUS）

### Q: 连接失败？

A: 检查以下配置：
1. STUN/TURN 服务器地址是否正确
2. 网络是否可达
3. 防火墙是否开放 UDP 端口

## License

MIT License
