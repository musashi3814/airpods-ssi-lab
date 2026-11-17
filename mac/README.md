# Mac / iPhone でのパケットキャプチャ実験(L1, L2)

内向きマイクがプロトコル上に存在するか(L1)、マイク構成を切り替えられるか(L2)を、Apple 純正機能が動いているときの通信を見て判定する。どちらも iOS アプリからは確かめられない。

## 必要なもの

- Mac と AirPods Pro(L2 は iPhone + AirPods Pro 3 + iOS 26)
- PacketLogger: Apple Developer の「Additional Tools for Xcode」に入っている
- Wireshark(`brew install --cask wireshark`)と apple-wireshark プラグイン

  ```bash
  git clone https://github.com/pabloaul/apple-wireshark
  mkdir -p ~/.local/lib/wireshark/plugins
  cp -r apple-wireshark/plugins/* ~/.local/lib/wireshark/plugins/
  ```

## L1: イヤーチップ装着状態テスト中の通信

1. AirPods Pro を Mac に接続する。
2. PacketLogger を起動し、File → New MacOS Trace でキャプチャを開始する。
3. 10 秒待ってから(基準区間)、システム設定 → AirPods → 「イヤーチップ装着状態テスト」を実行する。開始と終了の時刻(キャプチャ上の秒数)をメモする。
4. 10 秒待ってから停止し、`.pklg` で保存する。
5. 集計する:

   ```bash
   python3 aacp_capture_summary.py fit.pklg                   # 全体
   python3 aacp_capture_summary.py fit.pklg --window 12 20     # テスト中だけ
   ```

**判定**
- テスト中だけ、イヤホン→ホスト方向で数 kB/s 以上流れる opcode が現れる → 内向きマイクの音声がホストに送られている(L1 = あり)。その opcode とペイロードを調べれば、取得方法が分かる。
- テスト中に小さなパケットが数個だけ → 判定はイヤホン内で完結している(L1 = なし)。

macOS に装着状態テストがない場合は、iPhone で行う。iPhone に Bluetooth ログ用の構成プロファイル(Apple Developer の「Profiles and Logs」)を入れ、テスト後に sysdiagnose を取り、中の btsnoop ファイルを同じスクリプトにかける。

## L2: ライブ翻訳時のマイク構成

1. iPhone(iOS 26)に Bluetooth ログ用プロファイルを入れる。
2. AirPods Pro 3 で、通話(またはボイスメモ)を 10 秒 → ライブ翻訳を 10 秒の順に使う。
3. sysdiagnose を取り、btsnoop を Mac に移す。
4. `python3 aacp_capture_summary.py capture.btsnoop --dump 0x58`

**判定**: 0x58 の START ペイロードが、通話時の `000182000000049600` とライブ翻訳時で違えば、マイク構成をホストから切り替えられる(L2 = あり)。違う値は `linux/aap_lab.py mic --payload <hex>` でそのまま試せる。
