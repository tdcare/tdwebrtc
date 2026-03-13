# TD WebRTC 模块集成指南

## 模块说明

`tdwebrtc` 是一个独立的 HarmonyOS WebRTC 模块，封装了完整的音视频通话功能。

## 集成步骤

### 方式一：作为本地依赖（推荐）

1. **复制模块到项目根目录**

```bash
# 将 td-webrtc 目录复制到你的项目根目录
cp -r /path/to/td-webrtc ./your-project/
```

2. **编译 Rust 原生库**

```powershell
cd td-webrtc
.\build-rust.ps1
```

这会自动：
- 定位 `webrtc/webrtc_client` 目录
- 使用 ohrs 编译 Rust 库
- 将生成的 `.so` 文件复制到 `td-webrtc/libs/` 目录
- 生成类型定义文件到 `td-webrtc/src/types/`

3. **在项目的 oh-package.json5 中添加依赖**

```json5
{
  "dependencies": {
    "tdwebrtc": "file:./tdwebrtc"
  }
}
```

4. **在代码中导入**

```typescript
import { WebRTC, createMediaStream, VideoSurface, RemoteVideoSurface } from 'tdwebrtc';
import type { SurfaceInfo, MediaStreamConfig } from 'tdwebrtc';
```

### 方式二：作为 Git 子模块

```bash
# 添加子模块
git submodule add <repository-url> td-webrtc

# 初始化子模块
git submodule update --init
```

然后在 `entry/oh-package.json5` 中添加依赖：

```json5
{
  "dependencies": {
    "tdwebrtc": "file:../tdwebrtc"
  }
}
```

## 使用示例

### 基础视频通话

```typescript
import { WebRTC, createMediaStream, VideoSurface, RemoteVideoSurface } from 'tdwebrtc';
import type { SurfaceInfo } from 'tdwebrtc';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct CallPage {
  @State callState: string = 'idle';
  private mediaStream: WebRTCMediaStream | null = null;
  @State localSurfaceId: string = '';
  @State remoteSurfaceId: string = '';
  
  aboutToAppear() {
    // 初始化 WebRTC
    WebRTC.init({
      stunServers: ['stun:stun.l.google.com:19302'],
      localPort: 0,
    });
    
    // 设置回调
    WebRTC.setOnConnected(() => {
      this.callState = 'connected';
    });
  }
  
  build() {
    Stack() {
      // 远端视频（全屏）
      Column() {
        RemoteVideoSurface({
          componentId: 'remote-video',
          surfaceWidth: -1,
          surfaceHeight: -1,
          onSurfaceReady: (info: SurfaceInfo) => {
            this.remoteSurfaceId = info.surfaceId;
            this.mediaStream?.setRemoteVideoSurface(info.surfaceId);
          },
        })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      
      // 本地预览（小窗）
      Column() {
        VideoSurface({
          componentId: 'local-preview',
          surfaceWidth: -1,
          surfaceHeight: -1,
          onSurfaceReady: (info: SurfaceInfo) => {
            this.localSurfaceId = info.surfaceId;
            this.tryInitializeVideoSender();
          },
        })
        .width('100%')
        .height('100%')
      }
      .width(160)
      .height(214)
      .position({ x: '70%', y: 90 })
    }
  }
  
  private async startCall(targetMac: string, roomId: string) {
    // 创建媒体流
    this.mediaStream = createMediaStream({
      video: {
        enabled: true,
        width: 1280,
        height: 720,
        frameRate: 30,
        codec: 'H264', // 或 'VP8'
      },
      audio: {
        enabled: true,
        sampleRate: 8000,
        channels: 1,
        codec: 'PCMU', // G.711
      },
    }, getContext(this));
    
    // 设置 Surface
    this.mediaStream.setLocalVideoSurface(this.localSurfaceId);
    this.mediaStream.setRemoteVideoSurface(this.remoteSurfaceId);
    
    // 启动媒体流
    await this.mediaStream.startSending();
    await this.mediaStream.startReceiving();
    
    // 发起呼叫
    await WebRTC.call(targetMac, roomId, CallType.VIDEO);
  }
}
```

### 摄像头控制

```typescript
import { CameraCapture } from 'tdwebrtc';
import type { CameraCaptureConfig } from 'tdwebrtc';

const config: CameraCaptureConfig = {
  cameraPosition: 'front',
  previewWidth: 1280,
  previewHeight: 720,
  frameRate: 30,
};

const camera = new CameraCapture(config);

// 初始化（需传入 surfaceId）
await camera.initialize(surfaceId);
await camera.start();

// 切换摄像头
await camera.switchCamera();

// 停止并释放
await camera.stop();
await camera.release();
```

### 音频路由切换

```typescript
import { AudioPlayback } from 'tdwebrtc';

const audio = new AudioPlayback();
await audio.initialize();

// 切换到扬声器（免提）
audio.setAudioRoute(true);

// 切换到听筒
audio.setAudioRoute(false);

// 静音
audio.setMute(true);
```

## 完整 API 列表

### WebRTC 核心

```typescript
import { WebRTC, CallType } from 'tdwebrtc';

// 初始化（返回 Promise<boolean>）
const success = await WebRTC.init({ 
  stunServers: ['stun:stun.l.google.com:19302'],
  turnServers: [], // 可选
  localPort: 0,
});

// 信令回调
WebRTC.setOnConnected(() => { /* 连接成功 */ });
WebRTC.setOnStateChange((state) => { /* 状态变化 */ });
WebRTC.setOnDisconnected(() => { /* 断开连接 */ });
WebRTC.setOnIceCandidate((candidate) => { /* ICE 候选 */ });
WebRTC.setOnDataChannelMessage((msg) => { /* 数据通道消息 */ });

// SDP 协商（返回 string | null，非 Promise）
const offer = WebRTC.createOffer();
const answer = WebRTC.createAnswer();
WebRTC.setLocalDescription(offer, 'offer');
WebRTC.setRemoteDescription(sdp, 'answer');

// ICE
WebRTC.addIceCandidate(candidate, sdpMid, sdpMLineIndex);

// 数据通道
WebRTC.createDataChannel('chat', true); // ordered
WebRTC.sendMessage('chat', 'Hello');

// 媒体轨道
WebRTC.addVideoTrack('video-0', 'H264');
WebRTC.addAudioTrack('audio-0', 'PCMU');
const tracks = WebRTC.getMediaTracks();

// 呼叫控制
await WebRTC.call(targetMac, roomId, CallType.VIDEO);
await WebRTC.answer();
await WebRTC.hangup();

// 生命周期
await WebRTC.close();
```

### MediaStream

```typescript
import { createMediaStream, WebRTCMediaStream } from 'tdwebrtc';
import type { MediaStreamConfig, SurfaceInfo } from 'tdwebrtc';

// 创建（需要传入 context）
const config: MediaStreamConfig = {
  video: { enabled: true, width: 1280, height: 720, codec: 'H264' },
  audio: { enabled: true, sampleRate: 8000, codec: 'PCMU' },
};
const mediaStream = createMediaStream(config, context);

// 设置 Surface（必须在 startSending/Receiving 之前）
mediaStream.setLocalVideoSurface(localSurfaceId);
mediaStream.setRemoteVideoSurface(remoteSurfaceId);

// 启动（不再需要 initializeSender/Receiver）
await mediaStream.startSending();
await mediaStream.startReceiving();

// 停止
await mediaStream.stopAll();

// 视频控制
await mediaStream.setVideoEnabled(false);
const switched = await mediaStream.switchCamera();

// 音频控制
mediaStream.setAudioMute(true);
mediaStream.setAudioRoute(true); // 免提

// 发送数据
mediaStream.sendVideoFrame(yuvData);
mediaStream.sendAudioSamples(pcmData);

// 回调
mediaStream.onVideoFrameDecoded = (frame) => { /* 处理解码帧 */ };
mediaStream.onAudioFrameDecoded = (frame) => { /* 处理音频帧 */ };
mediaStream.onError = (error) => { console.error(error); };

// 释放
mediaStream.release();
```

### 编解码器

```typescript
import { VideoDecoder, isCodecSupported } from 'tdwebrtc';
import type { VideoDecoderConfig } from 'tdwebrtc';

// 检测设备支持的编解码器
const capabilities = await detectVideoCodecCapabilities();
if (isCodecSupported('H264')) {
  console.log('支持 H264');
}

// 视频解码器
const config: VideoDecoderConfig = {
  codec: 'H264',
  width: 1280,
  height: 720,
};

const decoder = new VideoDecoder(config);
decoder.onDecodedFrame = (frame) => { 
  // frame.data: Uint8Array
  // frame.timestamp: number
};
await decoder.initialize();
await decoder.decodeFrame(encodedData, timestamp, isKeyFrame);
await decoder.release();

// 注意：视频编码器已移至 Rust 层
// 应用层只需调用 mediaStream.sendVideoFrame() 即可
```

## 故障排查

### 问题 1：看不到远端视频

**检查清单：**
1. ✅ PeerConnection 是否达到 'connected' 状态
2. ✅ 是否收到远端的 RTP 包（查看日志）
3. ✅ 视频解码器是否已初始化
4. ✅ Surface 是否已连接到解码器
5. ✅ 编解码器是否匹配（H264/VP8）

**调试代码：**
```typescript
WebRTC.setOnStateChange((state) => {
  console.log('连接状态:', state);
  if (state === 'connected') {
    console.log('现在可以启动媒体流');
  }
});

// 检查编解码器能力
const caps = await detectVideoCodecCapabilities();
console.log('支持的编解码器:', caps);
```

### 问题 2：本地预览黑屏

**可能原因：**
- XComponent 未正确创建
- Surface ID 传递错误或时机不对
- 相机权限未申请
- MediaStream 未在 Surface ready 后设置

**解决方法：**
```typescript
// 确保在 onSurfaceReady 回调中设置 Surface
VideoSurface({
  componentId: 'local-preview',
  surfaceWidth: -1,
  surfaceHeight: -1,
  onSurfaceReady: (info: SurfaceInfo) => {
    // 此时 surfaceId 才有效
    mediaStream.setLocalVideoSurface(info.surfaceId);
  }
})

// 同时需要在 module.json5 中申请相机权限
"requestPermissions": [
  { "name": "ohos.permission.CAMERA" },
  { "name": "ohos.permission.MICROPHONE" }
]
```

### 问题 3：音频有杂音

**检查项：**
1. 采样率是否匹配（推荐 8kHz 或 48kHz）
2. 声道数配置是否正确（通常单声道）
3. 音频缓冲区大小是否合适
4. 确认编解码器类型（PCMU/PCMA/OPUS）
5. 检查是否有权限访问麦克风

**建议配置：**
```typescript
audio: {
  enabled: true,
  sampleRate: 8000, // 或 48000
  channels: 1,      // 单声道
  codec: 'PCMU',    // G.711 μ-law
}
```

## 性能优化建议

### 1. 选择合适的编解码器

- **优先 H.264**：硬件加速，性能好
- **VP8 备用**：软件编码，兼容性好但性能较差

### 2. 调整分辨率和码率

```typescript
const config = {
  video: {
    width: 640,      // VGA 足够清晰
    height: 480,
    frameRate: 30,   // 流畅度足够
    bitrate: 2000000, // 2Mbps
  },
};
```

### 3. 合理使用关键帧

```typescript
// 请求关键帧（网络恢复、画面卡顿后）
mediaStream.requestVideoKeyFrame();
```

## 注意事项

1. **Rust 原生库必须编译**：所有功能依赖 `libwebrtc_client.so`
2. **权限申请**：需要在 `module.json5` 中声明相机、麦克风权限
3. **上下文传递**：MediaStream 需要调用 `setContext()` 传入 Context
4. **资源释放**：通话结束后必须调用 `release()` 或 `cleanup()` 释放资源

## 参考资料

- [webrtc-rs/rtc GitHub](https://github.com/webrtc-rs/rtc)
- [OpenHarmony 多媒体 API](https://developer.harmonyos.com/cn/docs/documentation/doc-references/mediaoverview-0000001678129123)
- [WebRTC for the Curious](https://webrtcforthecurious.com/)
