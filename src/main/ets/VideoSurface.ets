/**
 * 视频渲染组件
 *
 * 封装 XComponent 用于视频显示。
 * 支持：
 * - 本地摄像头预览（Camera → 此 Surface）
 * - 远端视频渲染（解码后的帧 → 此 Surface）
 * - 获取 surfaceId 供外部使用
 */

import { LogUtil } from './utils/LogUtil';

// ============================================================
// Surface 信息接口
// ============================================================

export interface SurfaceInfo {
  /** 组件 ID */
  componentId: string;
  /** Surface ID 字符串 */
  surfaceId: string;
  /** Surface 宽度 */
  width: number;
  /** Surface 高度 */
  height: number;
}

// ============================================================
// 视频 Surface 组件
// ============================================================

/**
 * 视频 Surface 组件
 *
 * 用法:
 * ```
 * VideoSurface({
 *   componentId: 'local-preview',
 *   onSurfaceReady: (info: SurfaceInfo) => {
 *     // info.surfaceId 可用于 CameraCapture.initialize(surfaceId)
 *     // info.surfaceId 也可传递给 VideoDecoder.setSurface(surfaceId)
 *   },
 *   surfaceWidth: 640,
 *   surfaceHeight: 480,
 * })
 * ```
 */
@Component
export struct VideoSurface {
  /** 组件唯一标识 */
  @Prop componentId: string = 'video-surface';

  /** Surface 宽度 */
  @Prop surfaceWidth: number = 640;

  /** Surface 高度 */
  @Prop surfaceHeight: number = 480;

  /** Surface 就绪回调 */
  onSurfaceReady?: (info: SurfaceInfo) => void;

  /** Surface 销毁回调 */
  onSurfaceDestroy?: () => void;

  private xController: XComponentController = new XComponentController();
  @State surfaceId: string = '';

  build() {
    // v37: 使用 Stack 包裹并设置黑色背景，避免某些设备上 XComponent 透明
    Stack() {
      XComponent({
        id: this.componentId,
        type: XComponentType.SURFACE,
        controller: this.xController,
      })
        .onLoad(() => {
          this.surfaceId = this.xController.getXComponentSurfaceId();
          console.log(`\n\n===== [VideoSurface] Surface 就绪 =====`);
          console.log(`id=${this.componentId}, surfaceId=${this.surfaceId}, len=${this.surfaceId.length}`);
          LogUtil.info(`[VideoSurface] Surface 就绪：id=${this.componentId}, surfaceId=${this.surfaceId}`);
        
          // v32-fix: 添加实际尺寸的日志
          const actualWidth = this.surfaceWidth < 0 ? '100%' : (this.surfaceWidth > 0 ? this.surfaceWidth : '100%');
          const actualHeight = this.surfaceHeight < 0 ? '100%' : (this.surfaceHeight > 0 ? this.surfaceHeight : '100%');
          console.log(`实际尺寸：${actualWidth} x ${actualHeight}`);
          LogUtil.info(`[VideoSurface] 实际尺寸：${actualWidth} x ${actualHeight}`);
        
          // 回调通知外部
          if (this.onSurfaceReady !== undefined) {
            const info: SurfaceInfo = {
              componentId: this.componentId,
              surfaceId: this.surfaceId,
              width: this.surfaceWidth,
              height: this.surfaceHeight,
            };
            console.log(`调用 onSurfaceReady 回调...`);
            this.onSurfaceReady(info);
          }
          console.log(`===== [VideoSurface] END =====\n\n`);
        })
        .onDestroy(() => {
          LogUtil.info(`[VideoSurface] Surface 销毁：id=${this.componentId}`);
          this.surfaceId = '';
          this.onSurfaceDestroy?.();
        })
        .width('100%')
        .height('100%')
    }
    .width(this.surfaceWidth < 0 ? '100%' : (this.surfaceWidth > 0 ? this.surfaceWidth : '100%'))
    .height(this.surfaceHeight < 0 ? '100%' : (this.surfaceHeight > 0 ? this.surfaceHeight : '100%'))
    .backgroundColor('#000000')  // v37: 黑色背景，避免透明
  }

  /**
   * 获取 Surface ID
   */
  public getSurfaceId(): string {
    return this.surfaceId;
  }

  /**
   * 获取 Surface 信息
   */
  public getSurfaceInfo(): SurfaceInfo {
    return {
      componentId: this.componentId,
      surfaceId: this.surfaceId,
      width: this.surfaceWidth,
      height: this.surfaceHeight,
    };
  }
}

// ============================================================
// 远端视频渲染组件（带解码器集成）
// ============================================================

/**
 * 远端视频渲染组件
 *
 * 自动集成 H.264 解码器，接收 RTP 数据并渲染。
 * 用法:
 * ```
 * RemoteVideoSurface({
 *   componentId: 'remote-video',
 *   width: 640,
 *   height: 480,
 * })
 * ```
 */
@Component
export struct RemoteVideoSurface {
  /** 组件唯一标识 */
  @Prop componentId: string = 'remote-video';

  /** Surface 宽度 */
  @Prop surfaceWidth: number = 640;

  /** Surface 高度 */
  @Prop surfaceHeight: number = 480;

  /** Surface 就绪回调 */
  onSurfaceReady?: (info: SurfaceInfo) => void;

  /** Surface 销毁回调 */
  onSurfaceDestroy?: () => void;

  private xController: XComponentController = new XComponentController();
  @State surfaceId: string = '';

  build() {
    Stack() {
      XComponent({
        id: this.componentId,
        type: XComponentType.SURFACE,
        controller: this.xController,
      })
        .onLoad(() => {
          this.surfaceId = this.xController.getXComponentSurfaceId();
          LogUtil.info(`[RemoteVideoSurface] Surface 就绪：id=${this.componentId}, surfaceId=${this.surfaceId}`);

          // 回调通知外部
          if (this.onSurfaceReady !== undefined) {
            const info: SurfaceInfo = {
              componentId: this.componentId,
              surfaceId: this.surfaceId,
              width: this.surfaceWidth,
              height: this.surfaceHeight,
            };
            this.onSurfaceReady(info);
          }
        })
        .onDestroy(() => {
          LogUtil.info(`[RemoteVideoSurface] Surface 销毁：id=${this.componentId}`);
          this.surfaceId = '';
          this.onSurfaceDestroy?.();
        })
        .width(this.surfaceWidth < 0 ? '100%' : (this.surfaceWidth > 0 ? this.surfaceWidth : '100%'))
        .height(this.surfaceHeight < 0 ? '100%' : (this.surfaceHeight > 0 ? this.surfaceHeight : '100%'))

      // 视频未就绪时显示占位符
      if (this.surfaceId === '') {
        Column() {
          Text('等待视频...')
            .fontColor('#FFFFFF')
            .fontSize(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(this.surfaceWidth < 0 ? '100%' : (this.surfaceWidth > 0 ? this.surfaceWidth : '100%'))
    .height(this.surfaceHeight < 0 ? '100%' : (this.surfaceHeight > 0 ? this.surfaceHeight : '100%'))
  }

  /**
   * 获取 Surface ID
   */
  public getSurfaceId(): string {
    return this.surfaceId;
  }
}
