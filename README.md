# AirPods SSI Lab

AirPods でサイレントスピーチ(声を出さない発話の認識)を実現するために必要なデータが、実際に取れるかを確かめる実験キット。

- **何が必要か**: [docs/requirements.md](docs/requirements.md)。方式ごと(アクティブ音響 / パッシブ音響 / IMU)の要件を、ID (R1〜R13, L1〜L4) と閾値つきでまとめた。
- **iPhone で確かめる**: `ios/` の iOS アプリ。公開 API で取れる範囲(E1〜E5)を、ガイドに従って順番に実行し、要件ごとに ✅/❌ を出す。
- **非公開経路で確かめる**: `linux/aap_lab.py`(64 kHz マイク・センサー購読)と `mac/`(純正機能のパケットキャプチャ)。L1〜L4 を判定する。
- **オフライン解析**: `analysis/`。アプリが書き出した WAV / CSV を Python で再解析する。

背景: Apple の公開 API では AirPods の内向きマイクも生の IMU も取れない。非公開プロトコルを解析した OSS(LibrePods など)を使えば Linux から 64 kHz のマイクを取れるが、アクティブ音響センシングに必要な帯域とエコー除去の有無は、まだ誰も測っていない。このキットはそこを埋めるためのもの。

## iOS アプリのビルド

Mac に Xcode 26 以降と XcodeGen が必要。

```bash
brew install xcodegen
git clone https://github.com/musashi3814/airpods-ssi-lab
cd airpods-ssi-lab/ios
xcodegen generate
open AirPodsSSILab.xcodeproj
```

1. Xcode で AirPodsSSILab ターゲット → Signing & Capabilities → Team に自分の Apple ID(個人チームで可)を選ぶ。Bundle Identifier が衝突したら適当に変える。
2. iPhone を接続し、Run。初回は iPhone の「設定 → 一般 → VPN とデバイス管理」で開発元を信頼する。
3. 初回起動時にマイクとモーションの許可を求められるので、両方許可する。

`bluetoothHighQualityRecording`(高品質 Bluetooth 録音)は iOS 26 以上の機能。それより古い iOS でも動くが、その構成は通常の A2DP 設定で代用され、結果にその旨が記録される。

push のたびに GitHub Actions(macOS ランナー)で署名なしビルドが走るので、コンパイルが通ることはそこで確認できる。

## アプリの使い方

「実験」タブの **E1〜E5 を順番に全部実行** を押すと、画面の指示に従うだけで全実験が進む。所要時間は合計 10 分ほど。

| 実験 | 内容 | 確認する要件 | ユーザの操作 |
|---|---|---|---|
| E1 経路と形式 | 6 種類の音声構成で、入力が AirPods になるか・実際の fs・遅延を調べる | R1, R7, R8 | なし |
| E2 プローブ行列 | プローブ音(スイープ + 超音波チャープ列)を AirPods から出しながら AirPods マイクで録り、帯域・エコー除去・遅延の安定性を構成ごとに測る。最後に iPhone 内蔵マイクで AirPods の出力帯域を確認する | R1–R5 | 最後に片方の AirPod を iPhone のマイクに近づける |
| E3 マイク位置の推定 | 外来音を流した状態で ANC オン/外部音取り込みを切り替え、マイク信号が耳の内側か外向きかを推定する。ささやきが録れるかも見る | R6, R7 | 別の機器でノイズを流す。コントロールセンターでノイズコントロールを切り替える |
| E4 IMU の性能 | 公開 API のヘッドホンモーションの実効レート・静止時の途切れ・口パクへの感度 | R8–R10 | 安静 → 口パク → 顎の開閉 →… |
| E5 単語情報の検定 | 数個の単語を無声で繰り返し、IMU / パッシブ音 / アクティブ反射のそれぞれで 1-NN DTW の leave-one-out 精度と置換検定 p 値を出す | R11a–c, R12 | 画面の単語を口パク(既定 6 クラス × 8 回) |

- 「要件」タブに、要件ごとの最新判定が一覧で出る。
- 「記録」タブから、全実験のデータを zip で共有できる(AirDrop で Mac に送る想定)。「ファイル」アプリの「このiPhone内 > SSI Lab > Runs」からも見える。
- 「設定」タブで、プローブ帯域(超音波 / 準超音波 / 可聴)、レベル、E3/E5 の録音構成、E5 の単語・回数・発話様式を変えられる。

**安全**: プローブは既定 -30 dBFS。超音波は聞こえなくても耳に届いているので、システム音量は 30〜50% 程度にし、違和感があればすぐ外すこと。

## オフライン解析

```bash
# E2 の WAV を Python で解析し直す(iOS アプリと同じ信号構成)
uv run --script analysis/probe.py analyze --rec Runs/<..._E2>/HQ_default.wav --out out/hq

# E5 を再解析(置換回数を増やす、モダリティを選ぶ)
uv run --script analysis/e5_analyze.py Runs/<..._E5> --perm 2000
```

## 非公開経路(Linux / Mac)

- `linux/aap_lab.py`: AirPods の非公開プロトコル (L2CAP PSM 0x1001) を使う。**実機では未検証**。
  - `mic`: 64 kHz AAC-ELD マイクを録る
  - `probe`: プローブを流しながら録る(L4)
  - `sensor --service spl0`: 音圧センサーを購読する(L3)
  - `fuzz-mode`: マイクのモードバイトを総当たりする(L4)
  ```bash
  uv run --script linux/aap_lab.py --addr XX:XX:XX:XX:XX:XX hello
  uv run --script analysis/probe.py gen --out out/probe.wav
  uv run --script linux/aap_lab.py --addr XX:... probe --wav out/probe.wav --out runs/l4 --anc-off
  ```
- `mac/`: 純正のイヤーチップ装着状態テストやライブ翻訳の通信をキャプチャし、内向きマイクのストリームやマイク構成の切り替えがあるかを判定する(L1, L2)。手順は [mac/README.md](mac/README.md)。

## 判定の読み方

結論の出し方は [docs/requirements.md の「判定の流れ」](docs/requirements.md#3-判定の流れ) を参照。

- iOS で R2/R4 が ❌ → iOS の公開 API ではアクティブ音響方式は不可。Linux の L4 で再判定する。
- R11a だけ ✅ → IMU による少語彙コマンドなら iOS 製品の可能性あり。
- L1 が「あり」→ 内向きマイクは作られていないだけで、取得できる。

## 参考にした OSS と研究

- [librepods-org/librepods](https://github.com/librepods-org/librepods), [superninjv/airpods-helper](https://github.com/superninjv/airpods-helper), [arctumn/ntpods](https://github.com/arctumn/ntpods): AAP プロトコルと 64 kHz マイク経路
- [starman-tech/mousepods](https://github.com/starman-tech/mousepods), [freaktopus/auricle](https://github.com/freaktopus/auricle): SensorDataWX / RemoteHID の IMU
- [pabloaul/apple-wireshark](https://github.com/pabloaul/apple-wireshark): AACP の opcode と能力フラグ
- [joeblau/subvox](https://github.com/joeblau/subvox): 公開 API での口パク認識プロトタイプ
- ReHEarSSE (CHI'24), HEar-ID ([arXiv 2512.16518](https://arxiv.org/abs/2512.16518)): 耳道の超音波反射によるサイレントスペリング

コードはこれらからコピーしておらず、プロトコルの事実(バイト列)だけを参照して書いた。
