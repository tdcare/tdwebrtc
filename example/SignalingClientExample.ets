/**
 * 信令客户端使用示例
 *
 * 演示信令客户端的完整使用流程：
 * 1. 连接信令服务器
 * 2. 房间管理
 * 3. SDP/ICE 交换
 * 4. 呼叫控制
 */

import { SignalingClient, CallType, CmdAction, CmdType } from 'tdwebrtc';
import type { SignalingCallback, SignalingData } from 'tdwebrtc';

/**
 * 信令客户端示例类
 */
export class SignalingClientExample {
  private signaling: SignalingClient | null = null;
  private localMac: string = '';
  private currentRoomId: string = '';

  // 回调接口
  public onConnected?: () => void;
  public onDisconnected?: () => void;
  public onPeerJoined?: (fromMac: string, roomId: string) => void;
  public onPeerLeaved?: (fromMac: string, roomId: string) => void;
  public onCallReceived?: (data: SignalingData) => void;
  public onError?: (error: string) => void;

  /**
   * 初始化并连接信令服务器
   *
   * @param url 信令服务器 URL（如 ws://192.168.1.100:8080/ws/）
   * @param mac 本机设备标识
   * @param jsonStr 扩展信息 JSON
   */
  public connect(url: string, mac: string, jsonStr: string = '{}'): void {
    this.localMac = mac;

    // 创建回调实现类
    class CallbackImpl implements SignalingCallback {
      private parent: SignalingClientExample;

      constructor(parent: SignalingClientExample) {
        this.parent = parent;
      }

      onInitSuccess(): void {
        console.log('[SignalingExample] 连接成功');
        this.parent.onConnected?.();
      }

      onPeerJoined(fromMac: string, roomId: string): void {
        console.log(`[SignalingExample] 对端加入: ${fromMac}`);
        this.parent.onPeerJoined?.(fromMac, roomId);
      }

      onPeerLeaved(fromMac: string, roomId: string): void {
        console.log(`[SignalingExample] 对端离开: ${fromMac}`);
        this.parent.onPeerLeaved?.(fromMac, roomId);
      }

      onOfferReceived(data: SignalingData): void {
        console.log(`[SignalingExample] 收到 Offer from ${data.from_mac}`);
      }

      onAnswerReceived(data: SignalingData): void {
        console.log(`[SignalingExample] 收到 Answer from ${data.from_mac}`);
      }

      onIceCandidateReceived(data: SignalingData): void {
        console.log(`[SignalingExample] 收到 ICE 候选`);
      }

      onCall(data: SignalingData): void {
        console.log(`[SignalingExample] 收到来电 from ${data.from_mac}`);
        this.parent.onCallReceived?.(data);
      }

      onDoing(data: SignalingData): void {
        console.log(`[SignalingExample] 对方已接听`);
      }

      onHangup(data: SignalingData): void {
        console.log(`[SignalingExample] 对方已挂断`);
      }

      onVideoCall(data: SignalingData): void {
        console.log(`[SignalingExample] 收到视频呼叫 from ${data.from_mac}`);
        this.parent.onCallReceived?.(data);
      }

      onVideoHangup(data: SignalingData): void {
        console.log(`[SignalingExample] 视频已挂断`);
      }

      onSosCall(data: SignalingData): void {
        console.log(`[SignalingExample] 收到 SOS 呼叫 from ${data.from_mac}`);
      }

      onSosHangup(data: SignalingData): void {
        console.log(`[SignalingExample] SOS 已挂断`);
      }

      onVideoSosCall(data: SignalingData): void {
        console.log(`[SignalingExample] 收到视频 SOS 呼叫 from ${data.from_mac}`);
      }

      onVideoSosHangup(data: SignalingData): void {
        console.log(`[SignalingExample] 视频 SOS 已挂断`);
      }

      onTransfer(data: SignalingData): void {
        console.log(`[SignalingExample] 收到转接请求`);
      }

      onIgnore(data: SignalingData): void {
        console.log(`[SignalingExample] 对方已忽略`);
      }

      onNotice(data: SignalingData): void {
        console.log(`[SignalingExample] 收到通知: ${data.msg ?? ''}`);
      }
    }

    // 创建回调实例
    const callback = new CallbackImpl(this);

    // 创建并初始化信令客户端
    this.signaling = new SignalingClient();
    this.signaling.init(url, mac, jsonStr, callback);
  }

  // ============================================================
  // 房间管理
  // ============================================================

  /**
   * 加入房间
   */
  public joinRoom(roomId: string): void {
    if (!this.signaling) {
      console.error('[SignalingExample] 未连接');
      return;
    }
    this.currentRoomId = roomId;
    this.signaling.sendJoinRoom(roomId);
    console.log(`[SignalingExample] 加入房间: ${roomId}`);
  }

  /**
   * 离开房间
   */
  public leaveRoom(): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendLeaveRoom(this.currentRoomId);
    this.currentRoomId = '';
    console.log('[SignalingExample] 已离开房间');
  }

  // ============================================================
  // SDP/ICE 交换
  // ============================================================

  /**
   * 发送 SDP 描述
   */
  public sendSessionDescription(sdp: string, type: 'offer' | 'answer', toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendSessionDescription(sdp, type, toMac, this.currentRoomId);
    console.log(`[SignalingExample] 发送 ${type} to ${toMac}`);
  }

  /**
   * 发送 ICE 候选
   */
  public sendIceCandidate(candidate: string, sdpMid: string, sdpMLineIndex: number, toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendIceCandidate(candidate, sdpMid, sdpMLineIndex, toMac, this.currentRoomId);
    console.log(`[SignalingExample] 发送 ICE 候选 to ${toMac}`);
  }

  // ============================================================
  // 呼叫控制
  // ============================================================

  /**
   * 发起语音呼叫
   */
  public makeVoiceCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendCall(toMac, this.currentRoomId, '');
    console.log(`[SignalingExample] 发起语音呼叫 to ${toMac}`);
  }

  /**
   * 发起视频呼叫
   */
  public makeVideoCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendVideoCall(toMac, this.currentRoomId, '', CallType.VIDEO);
    console.log(`[SignalingExample] 发起视频呼叫 to ${toMac}`);
  }

  /**
   * 接听呼叫
   */
  public answerCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendAnswer(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 接听呼叫 from ${toMac}`);
  }

  /**
   * 挂断
   */
  public hangup(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendHangup(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 挂断 to ${toMac}`);
  }

  /**
   * 忽略来电
   */
  public ignoreCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendIgnore(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 忽略来电 from ${toMac}`);
  }

  /**
   * 发送转接请求
   */
  public transferCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendTransfer(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 转接呼叫 to ${toMac}`);
  }

  // ============================================================
  // SOS 呼叫
  // ============================================================

  /**
   * 发起 SOS 呼叫
   */
  public sendSosCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendSosCall(toMac, this.currentRoomId, '');
    console.log(`[SignalingExample] 发起 SOS 呼叫 to ${toMac}`);
  }

  /**
   * 挂断 SOS
   */
  public sendSosHangup(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendSosHangup(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 挂断 SOS to ${toMac}`);
  }

  /**
   * 发起视频 SOS 呼叫
   */
  public sendVideoSosCall(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendVideoSosCall(toMac, this.currentRoomId, '', CallType.VIDEO);
    console.log(`[SignalingExample] 发起视频 SOS 呼叫 to ${toMac}`);
  }

  /**
   * 挂断视频 SOS
   */
  public sendVideoSosHangup(toMac: string): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.sendVideoSosHangup(toMac, this.currentRoomId);
    console.log(`[SignalingExample] 挂断视频 SOS to ${toMac}`);
  }

  // ============================================================
  // 工具方法
  // ============================================================

  /**
   * 设置当前通话类型
   */
  public setCallType(callType: CallType): void {
    if (!this.signaling) {
      return;
    }
    this.signaling.setCurrentCallType(callType);
  }

  /**
   * 获取当前房间 ID
   */
  public getCurrentRoomId(): string {
    return this.currentRoomId;
  }

  /**
   * 断开连接
   */
  public disconnect(): void {
    if (this.signaling) {
      this.signaling.destroy();
      this.signaling = null;
    }
    console.log('[SignalingExample] 已断开连接');
  }
}

/**
 * 使用示例
 */
export function signalingUsageExample(): void {
  const example = new SignalingClientExample();

  // 设置回调
  example.onConnected = () => {
    console.log('信令已连接，可以加入房间');
    example.joinRoom('room-123');
  };

  example.onPeerJoined = (fromMac: string, roomId: string) => {
    console.log(`对端 ${fromMac} 已加入房间`);
    // 可以在这里发起呼叫
    example.makeVideoCall(fromMac);
  };

  example.onCallReceived = (data: SignalingData) => {
    console.log(`收到来电 from ${data.from_mac}`);
    // 可以在这里显示来电界面，让用户选择接听或忽略
    // example.answerCall(data.from_mac); // 接听
    // example.ignoreCall(data.from_mac); // 忽略
  };

  // 连接信令服务器
  example.connect('ws://192.168.1.100:8080/ws/', 'OHOS-DEVICE-001', '{}');

  // 使用完毕后断开
  // example.disconnect();
}
