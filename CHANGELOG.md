# CHANGELOG

## [1.0.2] - 2026-03-22

### 文档与示例
- 更新 README.md 功能文档，扩展 MediaStream、SignalingClient、视频组件等使用说明
- 更新 CHANGELOG.md，详细说明 WebRTC 引擎、编解码器、媒体流管理等功能
- 新增编解码器能力检测 API 文档
- 添加 example 目录下的代码示例：
  - BasicVideoCallExample.ets: 基础视频通话示例
  - MediaStreamAdvancedExample.ets: 高级媒体流管理示例
  - SignalingClientExample.ets: 信令客户端示例
  - example/README.md: 示例文档

## [1.0.1] - 2026-03-12

### 变更说明
- 更新许可证为 MIT License
- 完善 oh-package.json5 配置（添加 homepage、repository）

## [1.0.0] - 2026-03-04

### 新增功能

**WebRTC 引擎**
- 实现了基于 Rust WebRTC 的音视频通话功能
- 支持 SDP 协商、ICE 交换、DTLS 握手、RTP/RTCP 传输
- 支持 STUN/TURN 服务器配置
- 支持数据通道（SCTP 可靠/非可靠传输）

**视频编解码**
- 支持 H.264/H.265 硬件加速编解码
- 支持 VP8 软件编解码（兜底方案）
- 动态编解码器选择：根据设备能力自动选择最优编解码器
- 编解码器能力检测 API

**音频编解码**
- 支持 G.711 (PCMU/PCMA) 软件编解码
- 支持 OPUS 高质量音频编解码
- 支持 AAC 音频格式

**媒体流管理**
- 摄像头采集与本地预览
- 麦克风采集与音频发送
- 远端视频接收与渲染
- 远端音频接收与播放
- 摄像头前后切换
- 音频静音控制
- 音频路由切换（听筒/免提）
- 视频开关控制（关闭时发送带时间戳的占位画面）
- 关键帧请求（RTCP PLI）

**信令客户端**
- WebSocket 信令连接
- 房间管理（join/leave）
- SDP/ICE 交换
- 呼叫控制（call/doing/hangup/transfer/ignore/notice）
- 视频呼叫（video_call/video_hangup）
- SOS 呼叫（sos/soshangup/video_sos/video_soshangup）
- 心跳保活与断线重连

**视频渲染组件**
- VideoSurface：本地预览组件
- RemoteVideoSurface：远端视频渲染组件

**低端设备优化**
- 自动检测低端设备（不支持 H264 硬件编解码）
- 动态降级视频分辨率和帧率
- 批量解码优化，减少渲染开销

### 修复问题
- 解决了视频渲染组件初始化问题
- 修复了媒体流传输中的内存泄漏
- 优化了 ICE 连接建立流程
- 解决了 VP8 软件编解码的花屏问题
- 修复了 SDP Glare 场景下的协商冲突

### 变更说明
- 重构了 WebRTC 管理器架构
- 统一了错误处理机制
- 更新了 API 接口定义
- Rust 层集成媒体帧处理（零拷贝架构）