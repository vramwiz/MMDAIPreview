unit MmdAiPreviewMainForm;

// 人間がCodexの完成候補をPMXと骨格で確認する、読み取り専用VCL画面。

interface

uses
  Winapi.Messages,
  System.Classes,
  Vcl.Forms,
  Vcl.StdCtrls,
  MmdAiPreviewPipeServer,
  MmdAiPreviewPresentation,
  MmdD3DViewport,
  MmdD3DScene,
  PmxModel,
  PmxPose;

type
  TMmdAiPreviewViewport = class(TMmdD3DViewport)
  private
    FCachedScene: TMmdPreviewScene;
    FShowBones: Boolean;
  protected
    procedure Paint; override;
  public
    procedure SetPreviewDisplay(ModelVisible, BonesVisible: Boolean);
    procedure SetPreviewScene(AModel: TPmxModel; const APoses: TPmxBonePoses;
      ASelectedBone: Integer);
  end;

  TMmdAiPreviewMainForm = class(TForm)
  private
    FCandidateLabel: TLabel;
    FCurrentCandidateId: string;
    FCurrentModelFile: string;
    FCurrentPoseData: string;
    FCurrentPoseName: string;
    FDisplayCombo: TComboBox;
    FLoadingPoseList: Boolean;
    FModel: TPmxModel;
    FOpenModelButton: TButton;
    FPipeServer: TMmdAiPreviewPipeServer;
    FPlaceholderModel: TPmxModel;
    FPoseFiles: TArray<string>;
    FPoseList: TListBox;
    FPoses: TPmxBonePoses;
    FStatusLabel: TLabel;
    FRuntimeStarted: Boolean;
    FViewport: TMmdAiPreviewViewport;
    procedure ApplyDisplayMode;
    procedure ApplyPoseData(const PoseData: string);
    procedure DisplayModeChanged(Sender: TObject);
    function ExtractPoseFile(const FilePath: string; out PoseData,
      PoseName: string): Boolean;
    function GetSettingsFile: string;
    procedure LoadLastModel;
    procedure LoadPlaceholderModel;
    procedure LoadModel(const FilePath: string; SaveAsLast: Boolean);
    procedure LoadPoseFile(const FilePath: string);
    procedure LoadPresentation(const PresentationText: string);
    procedure OpenModelClick(Sender: TObject);
    procedure PoseListClick(Sender: TObject);
    procedure RefreshPoseList(SelectNewest: Boolean;
      const SelectedFile: string = '');
    procedure SaveSettings;
    procedure SetStatus(const Text: string; Error: Boolean = False);
    procedure WmPresentPose(var Message: TMessage); message WM_MMD_AI_PRESENT_POSE;
  protected
    procedure DoShow; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMmdAiPreviewMainForm;

implementation

uses
  Winapi.Windows,
  System.IOUtils,
  System.JSON,
  System.SysUtils,
  Vcl.Controls,
  Vcl.Dialogs,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  MmdAiDiagnosticOverlay,
  MmdAiPlaceholderModel,
  MmdAiPoseRepository,
  PmxPoseCodec,
  PmxReader;

function ReadJsonString(const Object_: TJSONObject; const Name,
  DefaultValue: string): string;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  Value := Object_.GetValue(Name);
  if Value is TJSONString then
    Result := TJSONString(Value).Value;
end;

procedure TMmdAiPreviewViewport.Paint;
begin
  inherited Paint;
  if FShowBones and (FModel <> nil) then
    DrawDiagnosticBoneScene(Canvas, ClientWidth, ClientHeight, FModel,
      FCachedScene, FCamera);
end;

procedure TMmdAiPreviewViewport.SetPreviewDisplay(ModelVisible,
  BonesVisible: Boolean);
begin
  FShowBones := BonesVisible;
  SetDisplayVisibility(ModelVisible, False);
  Invalidate;
end;

procedure TMmdAiPreviewViewport.SetPreviewScene(AModel: TPmxModel;
  const APoses: TPmxBonePoses; ASelectedBone: Integer);
begin
  if AModel = nil then
    FCachedScene := Default(TMmdPreviewScene)
  else
    BuildPreviewScene(AModel, APoses, nil, EmptyPreviewTarget,
      EmptyPreviewTarget, FCachedScene);
  SetScene(AModel, APoses, ASelectedBone);
end;

constructor TMmdAiPreviewMainForm.Create(AOwner: TComponent);
var
  LeftPanel, ToolPanel: TPanel;
begin
  inherited CreateNew(AOwner);
  Caption := 'MMD AI Preview';
  ShowInTaskBar := True;
  Position := poScreenCenter;
  Width := 1100;
  Height := 760;
  Constraints.MinWidth := 760;
  Constraints.MinHeight := 520;
  Color := RGB(14, 15, 19);

  ToolPanel := TPanel.Create(Self);
  ToolPanel.Parent := Self;
  ToolPanel.Align := alTop;
  ToolPanel.Height := 52;
  ToolPanel.BevelOuter := bvNone;

  FOpenModelButton := TButton.Create(Self);
  FOpenModelButton.Parent := ToolPanel;
  FOpenModelButton.Caption := 'PMXを開く';
  FOpenModelButton.SetBounds(12, 10, 100, 32);
  FOpenModelButton.OnClick := OpenModelClick;

  FDisplayCombo := TComboBox.Create(Self);
  FDisplayCombo.Parent := ToolPanel;
  FDisplayCombo.Style := csDropDownList;
  FDisplayCombo.Items.Add('通常');
  FDisplayCombo.Items.Add('ボーンのみ');
  FDisplayCombo.Items.Add('通常＋ボーン');
  FDisplayCombo.ItemIndex := 0;
  FDisplayCombo.SetBounds(120, 12, 140, 28);
  FDisplayCombo.OnChange := DisplayModeChanged;

  FCandidateLabel := TLabel.Create(Self);
  FCandidateLabel.Parent := ToolPanel;
  FCandidateLabel.Caption := '候補: 未受信';
  FCandidateLabel.SetBounds(278, 17, 776, 24);

  LeftPanel := TPanel.Create(Self);
  LeftPanel.Parent := Self;
  LeftPanel.Align := alLeft;
  LeftPanel.Width := 220;
  LeftPanel.BevelOuter := bvNone;

  FPoseList := TListBox.Create(Self);
  FPoseList.Parent := LeftPanel;
  FPoseList.Align := alClient;
  FPoseList.OnClick := PoseListClick;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := LeftPanel;
  FStatusLabel.Align := alBottom;
  FStatusLabel.AutoSize := False;
  FStatusLabel.Height := 62;
  FStatusLabel.WordWrap := True;
  FStatusLabel.Caption := '保存ポーズを読み込んでいます。';

  FViewport := TMmdAiPreviewViewport.Create(Self);
  FViewport.Parent := Self;
  FViewport.Align := alClient;
  FViewport.ReadOnly := True;
  FViewport.ShowHint := True;
  FViewport.Hint := '右ドラッグ: 回転 / 空白左ドラッグ: 移動 / ホイール: 拡大縮小 / A・S・D: 固定視点';

  FPipeServer := TMmdAiPreviewPipeServer.Create;
  LoadPlaceholderModel;
  LoadLastModel;
  RefreshPoseList(True);
end;

destructor TMmdAiPreviewMainForm.Destroy;
begin
  if FRuntimeStarted then
    UnregisterMmdAiPresentationWindow(Handle);
  FPipeServer.Free;
  FViewport.SetPreviewScene(nil, nil, -1);
  FPlaceholderModel.Free;
  inherited Destroy;
end;

procedure TMmdAiPreviewMainForm.DoShow;
begin
  inherited DoShow;
  if FRuntimeStarted then
    Exit;
  RegisterMmdAiPresentationWindow(Handle);
  try
    FPipeServer.Start;
    FRuntimeStarted := True;
  except
    UnregisterMmdAiPresentationWindow(Handle);
    raise;
  end;
end;

procedure TMmdAiPreviewMainForm.SetStatus(const Text: string; Error: Boolean);
begin
  FStatusLabel.Caption := Text;
  if Error then
    FStatusLabel.Font.Color := clRed
  else
    FStatusLabel.Font.Color := clWindowText;
end;

function TMmdAiPreviewMainForm.GetSettingsFile: string;
var
  BaseDirectory: string;
begin
  BaseDirectory := GetEnvironmentVariable('LOCALAPPDATA');
  if BaseDirectory = '' then
    BaseDirectory := TPath.GetHomePath;
  Result := TPath.Combine(TPath.Combine(BaseDirectory, 'MMDAIPreview'),
    'settings.json');
end;

procedure TMmdAiPreviewMainForm.SaveSettings;
var
  Root: TJSONObject;
  SettingsFile: string;
begin
  if FCurrentModelFile = '' then
    Exit;
  SettingsFile := GetSettingsFile;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(SettingsFile));
  Root := TJSONObject.Create;
  try
    Root.AddPair('last_model_file', FCurrentModelFile);
    TFile.WriteAllText(SettingsFile, Root.ToJSON, TEncoding.UTF8);
  finally
    Root.Free;
  end;
end;

procedure TMmdAiPreviewMainForm.LoadLastModel;
var
  FilePath, SettingsText: string;
  RootValue: TJSONValue;
begin
  if not TFile.Exists(GetSettingsFile) then
    Exit;
  try
    SettingsText := TFile.ReadAllText(GetSettingsFile, TEncoding.UTF8);
    RootValue := TJSONObject.ParseJSONValue(SettingsText);
    try
      if not (RootValue is TJSONObject) then
        Exit;
      FilePath := ReadJsonString(TJSONObject(RootValue), 'last_model_file', '');
      if (FilePath <> '') and TFile.Exists(FilePath) then
        LoadModel(FilePath, False)
      else if FilePath <> '' then
        SetStatus('前回のPMXが見つかりません。PMXを開き直してください。', True);
    finally
      RootValue.Free;
    end;
  except
    on E: Exception do
      SetStatus('前回PMXの読込みに失敗しました: ' + E.Message, True);
  end;
end;

procedure TMmdAiPreviewMainForm.LoadPlaceholderModel;
begin
  if FPlaceholderModel = nil then
    FPlaceholderModel := CreateMmdPlaceholderModel;
  FModel := FPlaceholderModel;
  FCurrentModelFile := '';
  InitializeBonePoses(FModel, FPoses);
  if FCurrentPoseData <> '' then
    ApplyPoseData(FCurrentPoseData);
  FDisplayCombo.ItemIndex := 1;
  FViewport.SetPreviewScene(FModel, FPoses, -1);
  ApplyDisplayMode;
  SetStatus('PMX未指定: 標準仮骨格で表示しています。');
end;

procedure TMmdAiPreviewMainForm.LoadModel(const FilePath: string;
  SaveAsLast: Boolean);
begin
  if not TFile.Exists(FilePath) then
    raise EFileNotFoundException.Create('PMXファイルが見つかりません。');
  FModel := GetCachedPmxModel(FilePath);
  FCurrentModelFile := TPath.GetFullPath(FilePath);
  InitializeBonePoses(FModel, FPoses);
  if FCurrentPoseData <> '' then
    ApplyPoseData(FCurrentPoseData);
  FViewport.SetPreviewScene(FModel, FPoses, -1);
  ApplyDisplayMode;
  if SaveAsLast then
    SaveSettings;
  SetStatus(Format('%s / ボーン %d / テクスチャ %d',
    [ExtractFileName(FCurrentModelFile), Length(FModel.Bones),
     FViewport.LoadedTextureCount]));
end;

procedure TMmdAiPreviewMainForm.ApplyPoseData(const PoseData: string);
var
  NamedPoses: TPmxNamedBonePoses;
begin
  if not TryDecodePoseData(PoseData, NamedPoses) then
    raise EArgumentException.Create('mmd.poseバージョン1として解釈できません。');
  FCurrentPoseData := PoseData;
  if FModel = nil then
  begin
    SetStatus('ポーズを読み込みました。表示にはPMXが必要です。');
    Exit;
  end;
  InitializeBonePoses(FModel, FPoses);
  ApplyNamedBonePoses(FModel, NamedPoses, FPoses);
end;

procedure TMmdAiPreviewMainForm.ApplyDisplayMode;
begin
  case FDisplayCombo.ItemIndex of
    0: FViewport.SetPreviewDisplay(True, False);
    1: FViewport.SetPreviewDisplay(False, True);
  else
    FViewport.SetPreviewDisplay(True, True);
  end;
end;

procedure TMmdAiPreviewMainForm.DisplayModeChanged(Sender: TObject);
begin
  ApplyDisplayMode;
end;

procedure TMmdAiPreviewMainForm.LoadPoseFile(const FilePath: string);
var
  PoseData, PoseName: string;
begin
  if not ExtractPoseFile(FilePath, PoseData, PoseName) then
    raise EArgumentException.Create('ポーズデータが空です。');
  ApplyPoseData(PoseData);
  FCurrentPoseName := PoseName;
  FCurrentCandidateId := '';
  FCandidateLabel.Caption := '候補: ' + PoseName;
  FViewport.SetPreviewScene(FModel, FPoses, -1);
  ApplyDisplayMode;
  SetStatus('ポーズを選択しました: ' + ExtractFileName(FilePath));
end;

procedure TMmdAiPreviewMainForm.PoseListClick(Sender: TObject);
begin
  if FLoadingPoseList or (FPoseList.ItemIndex < 0) or
     (FPoseList.ItemIndex >= Length(FPoseFiles)) then
    Exit;
  try
    LoadPoseFile(FPoseFiles[FPoseList.ItemIndex]);
  except
    on E: Exception do
      SetStatus('ポーズ読込みエラー: ' + E.Message, True);
  end;
end;

procedure TMmdAiPreviewMainForm.RefreshPoseList(SelectNewest: Boolean;
  const SelectedFile: string);
var
  I, J, SelectedIndex: Integer;
  Files: TArray<string>;
  Temp: string;
begin
  TDirectory.CreateDirectory(GetMmdAiPoseDirectory);
  Files := TDirectory.GetFiles(GetMmdAiPoseDirectory, '*.json');
  for I := 0 to High(Files) - 1 do
    for J := I + 1 to High(Files) do
      if TFile.GetLastWriteTimeUtc(Files[J]) >
         TFile.GetLastWriteTimeUtc(Files[I]) then
      begin
        Temp := Files[I];
        Files[I] := Files[J];
        Files[J] := Temp;
      end;
  FPoseFiles := Files;
  SelectedIndex := -1;
  FLoadingPoseList := True;
  FPoseList.Items.BeginUpdate;
  try
    FPoseList.Clear;
    for I := 0 to High(FPoseFiles) do
    begin
      FPoseList.Items.Add(ExtractFileName(FPoseFiles[I]));
      if (SelectedFile <> '') and
         SameText(TPath.GetFullPath(FPoseFiles[I]),
           TPath.GetFullPath(SelectedFile)) then
        SelectedIndex := I;
    end;
    if (SelectedIndex < 0) and SelectNewest and
       (Length(FPoseFiles) > 0) then
      SelectedIndex := 0;
    FPoseList.ItemIndex := SelectedIndex;
  finally
    FPoseList.Items.EndUpdate;
    FLoadingPoseList := False;
  end;
  if SelectedIndex >= 0 then
  begin
    try
      LoadPoseFile(FPoseFiles[SelectedIndex]);
    except
      on E: Exception do
        SetStatus('最新ポーズ読込みエラー: ' + E.Message, True);
    end;
  end;
end;

procedure TMmdAiPreviewMainForm.OpenModelClick(Sender: TObject);
var
  Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'PMXモデル (*.pmx)|*.pmx|すべてのファイル (*.*)|*.*';
    if FCurrentModelFile <> '' then
      Dialog.FileName := FCurrentModelFile;
    if not Dialog.Execute then
      Exit;
    try
      LoadModel(Dialog.FileName, True);
    except
      on E: Exception do
        SetStatus('PMX読込みエラー: ' + E.Message, True);
    end;
  finally
    Dialog.Free;
  end;
end;

function TMmdAiPreviewMainForm.ExtractPoseFile(const FilePath: string;
  out PoseData, PoseName: string): Boolean;
var
  RootValue: TJSONValue;
  Text: string;
begin
  Text := TFile.ReadAllText(FilePath, TEncoding.UTF8);
  PoseData := Text;
  PoseName := ChangeFileExt(ExtractFileName(FilePath), '');
  RootValue := TJSONObject.ParseJSONValue(Text);
  try
    if RootValue is TJSONObject then
    begin
      if TJSONObject(RootValue).GetValue('pose_data') is TJSONString then
        PoseData := TJSONString(
          TJSONObject(RootValue).GetValue('pose_data')).Value;
      PoseName := ReadJsonString(TJSONObject(RootValue), 'name', PoseName);
    end;
  finally
    RootValue.Free;
  end;
  Result := PoseData <> '';
end;

procedure TMmdAiPreviewMainForm.LoadPresentation(
  const PresentationText: string);
var
  ModelFile, PoseData, PoseFile: string;
  RootValue: TJSONValue;
begin
  RootValue := TJSONObject.ParseJSONValue(PresentationText);
  try
    if not (RootValue is TJSONObject) then
      raise EArgumentException.Create('提示データがJSON objectではありません。');
    ModelFile := ReadJsonString(TJSONObject(RootValue), 'model_file', '');
    PoseData := ReadJsonString(TJSONObject(RootValue), 'pose_data', '');
    PoseFile := ReadJsonString(TJSONObject(RootValue), 'pose_file', '');
    if PoseData = '' then
      raise EArgumentException.Create('pose_dataがありません。');
    FCurrentPoseData := PoseData;
    if (ModelFile <> '') and
       not SameText(FCurrentModelFile, TPath.GetFullPath(ModelFile)) then
      LoadModel(ModelFile, True)
    else
    begin
      ApplyPoseData(PoseData);
      FViewport.SetPreviewScene(FModel, FPoses, -1);
      ApplyDisplayMode;
    end;
    RefreshPoseList(False, PoseFile);
    FCurrentCandidateId := ReadJsonString(TJSONObject(RootValue),
      'candidate_id', '');
    FCurrentPoseName := ReadJsonString(TJSONObject(RootValue), 'pose_name',
      '新しいポーズ');
    FCandidateLabel.Caption := '候補: ' + FCurrentPoseName;
    SetStatus('AIが作成した最新ポーズを表示しています: ' +
      ExtractFileName(PoseFile));
  finally
    RootValue.Free;
  end;
end;

procedure TMmdAiPreviewMainForm.WmPresentPose(var Message: TMessage);
var
  ErrorText, PresentationText: string;
begin
  ErrorText := '';
  try
    if not TakePendingMmdAiPresentation(PresentationText) then
      ErrorText := '提示待ちデータがありません。'
    else
      LoadPresentation(PresentationText);
  except
    on E: Exception do
    begin
      ErrorText := E.Message;
      SetStatus('候補表示エラー: ' + ErrorText, True);
    end;
  end;
  CompleteMmdAiPresentation(ErrorText);
  Message.Result := Ord(ErrorText = '');
end;

end.
