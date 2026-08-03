# MusicRateSwitcher

[GitHub：Arczotis/MusicRateSwitcher](https://github.com/Arczotis/MusicRateSwitcher) · 作者：Arczotis · 联系邮箱：841530503@qq.com

一个独立的 macOS 菜单栏工具：自动识别 Apple Music、网易云音乐、QQ 音乐与汽水音乐当前播放内容的源采样率，并把选定输出设备切换到匹配的采样率，减少 macOS 固定输出格式造成的不必要重采样。

项目为独立实现，不包含 LosslessSwitcher 源码，使用 MIT License。播放器检测采用可插拔数据源架构，方便继续加入其他播放器。

如果这个项目对你有帮助，欢迎在 GitHub 仓库点一个 Star。

## 功能

- 同时支持 Apple Music、网易云音乐、QQ 音乐和汽水音乐，可分别启用或禁用。
- Apple Music：读取系统统一日志中的无损解码/播放格式，识别 ALAC 实际采样率与位深。
- 网易云音乐：定位进程当前读取的在线缓存，解析真实音频头。
- QQ 音乐：从播放器缓存索引定位当前曲目；标准音频读取真实音频头，加密缓存结合曲目元数据识别 Hi-Res 格式。
- 汽水音乐：识别当前缓存批次，并从 CENC MP4 音频条目读取实际采样率、位深和声道。
- 网易云支持 FLAC、MP3、AAC/ADTS、ALAC/AAC MP4、WAVE 和 AIFF。
- 使用 Core Audio 判断哪个播放器此刻真的在输出，两个 App 同时打开时不会被暂停播放器抢占。
- 跟随系统默认输出，或固定到指定 DAC/音频设备。
- 查询设备实际支持的采样率，精确匹配；不支持时优先回退到同一采样率家族。
- 监听默认设备切换和 USB 音频设备热插拔。
- 支持登录时启动、菜单栏采样率、手动刷新、诊断摘要和日志。
- 不捕获音频，也不保存、复制或导出歌曲。

## 使用

1. 双击 `dist/MusicRateSwitcher.app`。
2. 如果 macOS 阻止首次打开，按住 Control 点击 App，选择“打开”。
3. 在任一受支持的播放器中开始播放。
4. 菜单栏会显示例如 `♫ 96 kHz`，输出设备会自动匹配。
5. 菜单中的“播放器”可以单独开关数据源；“目标输出设备”可以选择系统默认设备或固定 DAC。

首次读取网易云音乐容器时，macOS 可能询问是否允许访问其他 App 的数据。需要选择允许，否则无法读取缓存格式。

## 构建

需要 macOS 13 或以上，以及 Apple Command Line Tools 或 Xcode。

```bash
./scripts/run-tests.sh
./scripts/build-app.sh
```

构建结果：

```text
dist/MusicRateSwitcher.app
```

构建脚本使用 ad-hoc 签名，适合本机运行。公开分发时应改用 Apple Developer ID 签名并完成 notarization。

## 检测原理

### Apple Music

程序以只读方式订阅 Apple Music 写入的 macOS Unified Logging，解析两类事件：

- 播放管线报告的 `sdFormatID / sdBitDepth / asbdSampleRate`；
- Apple Lossless 解码器报告的声道、Hz 和源位深。

优先采用代表当前播放管线的事件，解码器事件只作为延迟一秒的回退，避免预加载下一首歌时提前切换。普通 AAC 占位格式不会触发无损采样率切换。

### 网易云音乐

网易云在线缓存通常位于：

```text
~/Library/Containers/com.netease.163music/Data/Library/Caches/online_play_cache/
```

程序通过网易云进程的文件描述符确定正在读取的 `.uc!` 文件，只读取文件头，并执行缓存使用的 `XOR 0xA3` 还原。随后直接从标准音频头读取采样率、位深、声道和编码；完整歌曲不会被复制或写回磁盘。

### QQ 音乐

程序只读访问 QQ 音乐的 `iRRCache` 索引，以最近访问记录定位播放器当前使用的 `iMusic` 文件。标准格式直接读取音频头；`.mgg`、`.mflac` 等加密缓存则提取曲目 ID，查询 QQ 音乐公开曲目接口中的 `hires_sample` 和 `hires_bitdepth`。普通加密曲目没有提供采样率字段时，按 44.1 kHz / 16-bit 回退，并在界面中标明 QQ 编码类型。

### 汽水音乐

汽水音乐的在线缓存位于 `LunaCacheV2`。播放器会先创建当前曲目文件，再在同一批次预载后续曲目；程序据此定位最新批次的首个文件，并直接解析 MP4 `enca` 音频条目。缓存使用 CENC 内容加密不影响容器层格式字段，因此无需解密音频内容。

### 多播放器仲裁

macOS 14.2 及以上使用公开的 Core Audio Process Object API 检查活跃输出流。仅实际输出的播放器可以驱动采样率；若多个播放器同时输出，采用最近更新的可靠格式。macOS 13 会回退到最近更新的数据源。

## 设备回退策略

设备支持源采样率时精确匹配；否则优先使用同一采样率家族：

- 44.1 kHz 家族：44.1 / 88.2 / 176.4 / 352.8 kHz
- 48 kHz 家族：48 / 96 / 192 / 384 kHz

例如源为 176.4 kHz、设备最高只支持 96 kHz 时，优先选择同家族的 88.2 kHz。

## 添加新播放器

新的适配器实现 `SampleRateSource` 协议，负责报告 `DetectedSourceFormat`、运行状态，以及必要时播放器音频子进程的 PID；菜单、播放器开关、Core Audio 输出仲裁、设备匹配和诊断层可以直接复用。

## 已知边界

- 播放器切歌后才能确认新音频格式；采样率变化时会出现一次很短的停顿，这是输出设备重新配置造成的。
- Apple Music 当前实现针对无损/高解析度无损 ALAC；有损 AAC 不触发切换。
- 播放器升级后可能改变日志或缓存格式，需要同步更新对应适配器。
- QQ 音乐普通加密缓存的公开元数据不含实际采样率，当前按绝大多数曲目的 44.1 kHz 回退；Hi-Res 曲目使用接口返回的精确采样率和位深。
- 网易云专有 `.ncm` 下载文件不在当前解析范围；标准本地音频可直接识别。
- 蓝牙和 AirPlay 仍可能在后续链路编码或重采样。
- 采样率匹配不等同于绝对 bit-perfect；播放器音效、系统音量和其他 DSP 仍可能处理音频。

## 日志

菜单栏中选择“诊断 → 打开日志文件”，或查看：

```text
~/Library/Logs/MusicRateSwitcher/MusicRateSwitcher.log
```
