# MMD AI Preview Named Pipe

## 接続

- Pipe短縮名: `MMD.AI.Preview.v1`
- 完全名: `\\.\pipe\MMD.AI.Preview.v1`
- 文字コード: UTF-8（BOMなし）
- フレーミング: 1行1JSONのNDJSON
- 最大要求サイズ: 4 MiB
- 接続中は複数要求を連続送信でき、切断後は新しいクライアントを待ち受ける。

サーバーは次のコマンドで単独起動する。

```powershell
D:\DelphiProg\test\MMDAIPreview\Win64\Debug\MMDAIPreview.exe --pipe
```

## 要求と応答

Pipeは既存のMMDAIPreview JSON操作をそのまま受ける。`request_id`は任意だが、指定した場合は対応する応答へ同じJSON値を返す。

```json
{"request_id":"cap-1","operation":"get_capabilities"}
```

中心となるボーン操作は`get_model_schema`と`preview_pose`である。姿勢形式はMMD共通の`mmd.pose`バージョン1を使用し、Pipe独自形式は作らない。`preview_pose`成功時は正規化済み`pose_data`と解決済みボーン情報を返す。

## PowerShell接続例

```powershell
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
  '.',
  'MMD.AI.Preview.v1',
  [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(5000)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$reader = [System.IO.StreamReader]::new($pipe, $utf8)
$writer = [System.IO.StreamWriter]::new($pipe, $utf8)
$writer.AutoFlush = $true
$writer.WriteLine('{"request_id":"cap-1","operation":"get_capabilities"}')
$response = $reader.ReadLine()
$writer.Dispose()
$reader.Dispose()
$pipe.Dispose()
```

標準出力・標準入力の`--stdio`はテストと障害調査用の予備経路として残す。
