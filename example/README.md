# tdwebrtc 使用示例

本目录包含 tdwebrtc 模块的使用示例代码。

## 示例文件

### BasicVideoCallExample.ets

完整的视频通话示例，演示：

- WebRTC 初始化
- 媒体流创建与配置
- 信令客户端连接
- 发起/接听视频呼叫
- 挂断并释放资源
- 摄像头切换、静音、免提等控制

```typescript
import { BasicVideoCallExample } from './example/BasicVideoCallExample';
```

### SignalingClientExample.ets

信令客户端使用示例，演示：

- 连接信令服务器
- 房间管理（加入/离开）
- SDP/ICE 交换
- 呼叫控制（呼叫/接听/挂断/忽略/转接）
- SOS 呼叫

```typescript
import { SignalingClientExample, signalingUsageExample } from './example/SignalingClientExample';
```

### MediaStreamAdvancedExample.ets

媒体流高级使用示例，演示：

- 编解码器能力检测
- 低端设备优化（自动降级分辨率/帧率）
- 动态选择最优编解码器
- 视频控制（开关、切换摄像头、请求关键帧）
- 音频控制（静音、路由切换）

```typescript
import { MediaStreamAdvancedExample } from './example/MediaStreamAdvancedExample';
```

## 快速开始

### 1. 配置权限

在 `module.json5` 中添加必要权限：

```json5
{
  "requestPermissions": [
    { "name": "ohos.permission.CAMERA" },
    { "name": "ohos.permission.MICROPHONE" },
    { "name": "ohos.permission.INTERNET" }
  ]
}
```

### 2. 初始化 WebRTC

```typescript
import { WebRTC, createMediaStream } from 'tdwebrtc';

// 初始化 WebRTC 引擎
await WebRTC.init({
  stunServers: ['stun:stun.l.google.com:19302'],
  localPort: 0,
});

// 创建媒体流
const mediaStream = createMediaStream({
  video: { enabled: true, width: 1280, height: 720, codec: 'H264' },
  audio: { enabled: true, sampleRate: 8000, codec: 'PCMU' },
});
mediaStream.setContext(context);
```

### 3. 使用视频组件

```typescript
import { VideoSurface, RemoteVideoSurface } from 'tdwebrtc';

// 本地预览
VideoSurface({
  componentId: 'local-preview',
  surfaceWidth: 640,
  surfaceHeight: 480,
  onSurfaceReady: (info) => {
    mediaStream.initializeVideoSender(info.surfaceId);
  },
})

// 远端视频
RemoteVideoSurface({
  componentId: 'remote-video',
  surfaceWidth: 640,
  surfaceHeight: 480,
  onSurfaceReady: (info) => {
    mediaStream.setRemoteVideoSurface(info.surfaceId);
  },
})
```

## 注意事项

1. **权限申请**：使用前必须申请相机、麦克风、网络权限
2. **主线程调用**：所有 API 必须在主线程调用
3. **资源释放**：通话结束后务必调用 `release()` 释放资源
4. **低端设备**：模块会自动检测设备能力并降级配置
