# PP Friend

[English](README.md) · [中文](README.zh.md) · 日本語

セルフホスト型のリアルタイム音声アシスタントクライアントです。スマホ側がやることは二つだけ——**録音と再生**。認識・対話・音声合成はすべて自分のサーバー（コードでは **brain**）で動きます。

**PP は Push and Pull**。人とエージェントの両側が、それぞれ push し、それぞれ pull します。スマホはあなたの音声を brain に push し、長いポーリングで返事を pull します。エージェントはテキストを push し、人のテキストを pull します。四本のチャネルが同時に開いているので、協働は非同期です——あなたが話している最中でも、エージェントは話し始められます。

> **Made with deepseek v4.1 flash and pp-friend itself.**
> このプロジェクト自体の開発も PP Friend で回しています。スマホに向かって話すことでコーディングを駆動し、要件もレビューも修正も音声で進めました。

---

## これは何か

いつでも話しかけられる音声アシスタント。自宅の brain 上で動き、データは自分のサーバーの外に出ません。

- **全二重**：ユーザーが話している間も AI は聞き、AI が話している間もユーザーは聞く。両方向が同時に開いています
- **割り込み**：AI が話している途中でユーザーが話し始めると、すぐに止まります。そのとき「どこまで聞こえたか」を brain に報告し、話し終えたことにはしません
- **バックグラウンドで継続**：別のアプリに切り替えても、画面をロックしても会話は続きます（フォアグラウンドサービスが録音を保持）
- **端末側の区間検出**：Silero VAD がスマホ上（Rust）で動き、文が完結した区間だけを送ります。連続した音声を丸ごとストリーミングするのではありません
- **声紋ゲート**：作成した声紋とその区間の音声の ECAPA コサイン類似度を計算し、十分に長い文がしきい値を下回れば区間ごと破棄します。家族の声はアップロードされず、エージェントのコンテキストにも入りません
- **複数プロファイル**：プロファイルごとに brain 設定と独立した履歴を持ち、同時に動かせます。音声を出すのはフォーカス中の一つだけで、ほかはテキストのみ記録します

## プロジェクトサイトと声紋作成

プロジェクトサイト（製品紹介・アーキテクチャ・プライバシー。中国語 / English / 日本語）：

**<https://thautwarm.github.io/pp-friend/>**

自分で brain を書きたい場合は、まずプロトコルから：

**<https://thautwarm.github.io/pp-friend/brain-api/>**

話者識別には本人の声紋が必要です。作成ページ：

**<https://thautwarm.github.io/pp-friend/enroll/>**

ブラウザで短い音声を録音し、`spkemb.f32` をダウンロードして、アプリの **設定 → 一般 → 話者識別** から読み込みます。録音も推論もブラウザ内で完結し、音声はアップロードされません。サイトのソースは `tools/voiceprint` にあり、アプリにも「声紋をローカルで作成してダウンロード」ボタンがあります。

## アーキテクチャ

**スマホ側は会話コンテキストを持ちません**——それはサーバー側にあり、brain の名前を変えれば別の会話になります。スマホに保存されるのは**表示用の履歴**だけで、どのリクエストにも含まれず、削除しても会話に影響しません。

| 層 | 技術 |
|---|---|
| UI / ビジネスロジック | Flutter（Dart 3.13） |
| 端末側の区間検出 | Rust + Silero VAD、flutter_rust_bridge 2.13 |
| 声紋ゲート | Rust + ECAPA コサイン類似度（int8 ONNX、23 MB）。声紋は `tools/voiceprint` の Web ページで生成 |
| 音声エンジン | Android ネイティブ（Kotlin）：AudioRecord / AudioTrack / AEC |
| 上りエンコード | Ogg Opus 16 kHz（MediaCodec + MediaMuxer） |
| 下りデコード | Ogg Opus 24 kHz（MediaExtractor + MediaCodec）→ 16 kHz にリサンプル |
| サーバーとの通信 | HTTP + MessagePack、独立した 2 本のロングポーリングループ |
| 履歴の保存 | NDJSON、1 MB ごとに分割、追記のみ |

**Android arm64 のみ**、minSdk 29。iOS の Dart 側の契約は用意済みですが、ネイティブ側は未実装です。

## ビルド

前提：Flutter 3.47 以上、Android NDK、Rust ツールチェーン。

```bash
# 1. ONNX Runtime（Android 用の .so はリポジトリに含まれています。ホストで cargo test を回すときだけ必要）
tools/fetch_onnxruntime.sh

# 2. ビルド——新しく clone しただけなら NDK なしでビルドできます（jniLibs の .so は同梱）
flutter build apk --release

# 3. Rust のソースを変えたときだけ再実行（成果物も一緒にコミット）
tools/build_rust_android.sh
```

## エンドツーエンドの自己テスト

リポジトリには、プロトコルに沿って手書きした**偽の brain** が入っています。サーバーなしで経路全体を動かせます：

```bash
tools/mock_brain.py
```

手書きの MessagePack 実装も同梱されており、プロトコルの理解がずれていないか確認できます。

## ディレクトリ

```
lib/            Dart 側：設定、セッション、保存、UI
rust/           端末側の区間検出（Silero VAD）、話者ゲート（ECAPA）、frb バインディング
android/        ネイティブ音声エンジン、フォアグラウンドサービス、通知
assets/         モデル（ecapa.onnx、int8）
tools/          ビルドスクリプト、偽の brain、声紋作成 Web ページ、アイコン生成
docs/           設計・プロトコル文書
test/           ユニットテスト
```

## ドキュメント

| 文書 | 内容 |
|---|---|
| `docs/voice-assistant.md` | 要件と技術設計 |
| `docs/voice-engine.md` | ネイティブ音声エンジンと AEC |
| `docs/brain-api.md` | brain とのプロトコル（エンドポイント、ペイロード、履歴ページング） |
| `docs/handoff.md` | 決定事項、レビュー結果、既知の問題 |
| `docs/需求-闭麦与打断.md` | ミュートと割り込みの意味 |
| `docs/屏幕输出约定.md` | TTS 出力時の話し方の約束 |

## ライセンス

未定です。
