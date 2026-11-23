# Mac 麦克风按键监听在唤醒后未恢复

- 状态：候选修复完成，等待真实休眠、唤醒和豆包语音输入验收
- 日期：2026-11-23
- 功能点：Mac 麦克风、键盘/鼠标语音键、系统休眠唤醒

## 错误证据

用户反馈键盘和鼠标触发语音输入在运行一段时间后失效，停用再启用 Mac 麦克风即可恢复。Build 176 现场日志显示：

- 系统挂起时，Mac 麦克风会话以 `reason=interrupted` 结束，`MAC MICROPHONE KEY_MONITOR` 随后停止。
- 多次唤醒后，`MiRemoteV 2ch` 均重新进入 `AUDIO READY`，遥控器语音也能收到首个 PCM 并正常排空。
- 同期没有新的 `MAC MICROPHONE KEY_MONITOR phase=started`，右 Option 也没有进入 `phase=voice_key`。
- 用户停用再启用 Mac 麦克风后，监听器重新创建并恢复。

因此错误边界位于 Mac 麦克风的系统生命周期恢复，不是虚拟音频输出或遥控器音频链路。

## 根因

`BridgeAppModel.handleSystemAudioLifecycle` 在挂起事件到达时以 `.interrupted` 停止 Mac 麦克风会话。会话转为未启用后，状态回调会停止只读键盘 event tap。最后一个系统挂起原因解除时，现有代码只恢复虚拟音频和蓝牙连接，没有保留用户此前已经启用 Mac 麦克风的意图，也没有重新进入待命准备，因此右 Option 监听永久缺失，直到用户手动重新启用。

首次候选只修复了系统生命周期恢复。Build 177 进一步现场复现显示：14:14–14:20 多次右 Option 会话均收到按键边沿、有效 PCM 并成功送入虚拟音频；之后进程和虚拟音频仍正常，但不再出现任何右 Option 边沿。该证据确认还存在第二条路径：macOS 临时禁用 listen-only event tap 后，即时重新启用可能发生在安全输入仍生效的窗口内，随后 tap 保持禁用。Build 176 曾在禁用回调中销毁并重建 tap，形成重复禁用/重建风暴。

## 最小修复

- 系统挂起时，仅在 Mac 麦克风此前已启用的情况下记录恢复意图，然后按既有流程停止采集、排空音频并释放按键监听。
- 最后一个系统挂起原因解除后，自动重新执行选择准备并回到待命状态；不自动恢复休眠前的录音，仍需下一次物理语音键才能开始采集。
- 如果唤醒早于旧采集排空完成，先记录 `phase=resume_deferred`，等停止终态完成后再重新待命。
- 如果 Mac 麦克风在挂起前未启用，唤醒不自动启用。
- event tap 收到系统禁用通知后延迟尝试恢复，并在待命期间每 2 秒检查一次；只重新启用原 tap，不在回调内销毁重建。持续禁用时日志最多每 30 秒记录一次，恢复时记录一次 `result=restored`。
- Build 178 再次复现时，event tap 持续报告启用，但 operation 11 从 14:43:43 起不再收到停止边沿，Mac 麦克风持续产生 PCM。这确认仅检查 tap 启用状态仍不充分。修复增加 20ms HID 系统按键状态兜底，并与 event tap 边沿去重；兜底命中记录 `source=key_state_poll`。短按切换会话另设 5 分钟强制安全停止，避免任何监听故障造成无限采集。

## 验证

- `swift test --disable-keychain --filter MacMicrophoneInputTests`：HID 按键状态兜底和录音安全停止完成后 30 项通过。
- 新增覆盖：待命状态挂起/唤醒后重新待命且不自动采集；录音中快速挂起/唤醒时等待排空再恢复；原本关闭时唤醒不自动开启。
- `git diff --check`：通过。

## 验证边界

自动化只证明状态机、监听器准备接线和快速恢复顺序。尚未在真实 macOS 休眠/锁屏、真实键盘或鼠标右 Option、真实 `MiRemoteV 2ch` 与豆包语音输入法上完成首次唤醒后文字上屏，因此当前只能称为候选修复。真机验收必须确认唤醒后日志重新出现 `KEY_MONITOR phase=started` 和 `phase=armed`，第一次右 Option 产生 `phase=voice_key`、首个有效 PCM、正常排空及完整文字。
