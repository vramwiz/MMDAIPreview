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
    FBoneList: TListBox;
    FCandidateLabel: TLabel;
    FCurrentCandidateId: string;
    FCurrentModelFile: string;
    FCurrentPoseData: string;
    FCurrentPoseName: string;
    FDisplayCombo: TComboBox;
    FModel: TPmxModel;
    FOpenModelButton: TButton;
    FOpenPoseButton: TButton;
    FSavePoseButton: TButton;
    FPipeServer: TMmdAiPreviewPipeServer;
    FPlaceholderModel: TPmxModel;
    FPoses: TPmxBonePoses;
    FStatusLabel: TLabel;
    FViewport: TMmdAiPreviewViewport;
    procedure ApplyDisplayMode;
    procedure ApplyPoseData(const PoseData: string);
    procedure BoneListClick(Sender: TObject);
    procedure DisplayModeChanged(Sender: TObject);
    function ExtractPoseFile(const FilePath: string; out PoseData,
      PoseName: string): Boolean;
    function GetSettingsFile: string;
    procedure LoadLastModel;
    procedure LoadPlaceholderModel;
    procedure LoadModel(const FilePath: string; SaveAsLast: Boolean);
    procedure LoadPresentation(const PresentationText: string);
    procedure OpenModelClick(Sender: TObject);
    procedure OpenPoseClick(Sender: TObject);
    procedure SavePoseClick(Sender: TObject);
    procedure SaveSettings;
    function GetPoseDirectory: string;
    function MakeSafeFileName(const Value: string): string;
    function NewPoseFilePath(const PoseName: string): string;
    procedure SetStatus(const Text: string; Error: Boolean = False);
    procedure WmPresentPose(var Message: TMessage); message WM_MMD_AI_PRESENT_POSE;
  protected
    procedure DoClose(var Action: TCloseAction); override;
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

  FOpenPoseButton := TButton.Create(Self);
  FOpenPoseButton.Parent := ToolPanel;
  FOpenPoseButton.Caption := 'ポーズを開く';
  FOpenPoseButton.SetBounds(120, 10, 110, 32);
  FOpenPoseButton.OnClick := OpenPoseClick;

  FSavePoseButton := TButton.Create(Self);
  FSavePoseButton.Parent := ToolPanel;
  FSavePoseButton.Caption := '保存';
  FSavePoseButton.Enabled := False;
  FSavePoseButton.SetBounds(238, 10, 76, 32);
  FSavePoseButton.OnClick := SavePoseClick;

  FDisplayCombo := TComboBox.Create(Self);
  FDisplayCombo.Parent := ToolPanel;
  FDisplayCombo.Style := csDropDownList;
  FDisplayCombo.Items.Add('通常');
  FDisplayCombo.Items.Add('ボーンのみ');
  FDisplayCombo.Items.Add('通常＋ボーン');
  FDisplayCombo.ItemIndex := 0;
  FDisplayCombo.SetBounds(326, 12, 140, 28);
  FDisplayCombo.OnChange := DisplayModeChanged;

  FCandidateLabel := TLabel.Create(Self);
  FCandidateLabel.Parent := ToolPanel;
  FCandidateLabel.Caption := '候補: 未受信';
  FCandidateLabel.SetBounds(484, 17, 570, 24);

  LeftPanel := TPanel.Create(Self);
  LeftPanel.Parent := Self;
  LeftPanel.Align := alLeft;
  LeftPanel.Width := 220;
  LeftPanel.BevelOuter := bvNone;

  FBoneList := TListBox.Create(Self);
  FBoneList.Parent := LeftPanel;
  FBoneList.Align := alClient;
  FBoneList.OnClick := BoneListClick;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := LeftPanel;
  FStatusLabel.Align := alBottom;
  FStatusLabel.AutoSize := False;
  FStatusLabel.Height := 62;
  FStatusLabel.WordWrap := True;
  FStatusLabel.Caption := 'PMXまたはポーズを開いてください。';

  FViewport := TMmdAiPreviewViewport.Create(Self);
  FViewport.Parent := Self;
  FViewport.Align := alClient;
  FViewport.ReadOnly := True;
  FViewport.ShowHint := True;
  FViewport.Hint := '右ドラッグ: 回転 / 空白左ドラッグ: 移動 / ホイール: 拡大縮小 / A・S・D: 固定視点';

  RegisterMmdAiPresentationWindow(Handle);
  FPipeServer := TMmdAiPreviewPipeServer.Create;
  FPipeServer.Start;
  LoadPlaceholderModel;
  LoadLastModel;
end;

destructor TMmdAiPreviewMainForm.Destroy;
begin
  UnregisterMmdAiPresentationWindow(Handle);
  FPipeServer.Free;
  FViewport.SetPreviewScene(nil, nil, -1);
  FPlaceholderModel.Free;
  inherited Destroy;
end;

procedure TMmdAiPreviewMainForm.DoClose(var Action: TCloseAction);
begin
  Application.Terminate;
  inherited DoClose(Action);
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

function TMmdAiPreviewMainForm.GetPoseDirectory: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'Poses');
end;

function TMmdAiPreviewMainForm.MakeSafeFileName(const Value: string): string;
var
  C: Char;
  InvalidChars: TArray<Char>;
begin
  Result := Trim(Value);
  InvalidChars := TPath.GetInvalidFileNameChars;
  for C in InvalidChars do
    Result := Result.Replace(C, '_');
  while (Result <> '') and CharInSet(Result[Length(Result)], [' ', '.']) do
    Delete(Result, Length(Result), 1);
  if Result = '' then
    Result := 'pose';
  if SameText(Result, 'CON') or SameText(Result, 'PRN') or
     SameText(Result, 'AUX') or SameText(Result, 'NUL') or
     SameText(Copy(Result, 1, 3), 'COM') or
     SameText(Copy(Result, 1, 3), 'LPT') then
    Result := '_' + Result;
end;

function TMmdAiPreviewMainForm.NewPoseFilePath(
  const PoseName: string): string;
var
  BaseName: string;
  Number: Integer;
begin
  BaseName := MakeSafeFileName(PoseName);
  Result := TPath.Combine(GetPoseDirectory, BaseName + '.json');
  Number := 2;
  while TFile.Exists(Result) do
  begin
    Result := TPath.Combine(GetPoseDirectory,
      Format('%s-%d.json', [BaseName, Number]));
    Inc(Number);
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
var
  BoneIndex: Integer;
begin
  if FPlaceholderModel = nil then
    FPlaceholderModel := CreateMmdPlaceholderModel;
  FModel := FPlaceholderModel;
  FCurrentModelFile := '';
  InitializeBonePoses(FModel, FPoses);
  if FCurrentPoseData <> '' then
    ApplyPoseData(FCurrentPoseData);
  FBoneList.Items.BeginUpdate;
  try
    FBoneList.Clear;
    for BoneIndex := 0 to High(FModel.Bones) do
      FBoneList.Items.Add(FModel.Bones[BoneIndex].Name);
    if FBoneList.Count > 0 then
      FBoneList.ItemIndex := 0;
  finally
    FBoneList.Items.EndUpdate;
  end;
  FDisplayCombo.ItemIndex := 1;
  FViewport.SetPreviewScene(FModel, FPoses, FBoneList.ItemIndex);
  ApplyDisplayMode;
  SetStatus('PMX未指定: 標準仮骨格で表示しています。');
end;

procedure TMmdAiPreviewMainForm.LoadModel(const FilePath: string;
  SaveAsLast: Boolean);
var
  BoneIndex: Integer;
begin
  if not TFile.Exists(FilePath) then
    raise EFileNotFoundException.Create('PMXファイルが見つかりません。');
  FModel := GetCachedPmxModel(FilePath);
  FCurrentModelFile := TPath.GetFullPath(FilePath);
  InitializeBonePoses(FModel, FPoses);
  if FCurrentPoseData <> '' then
    ApplyPoseData(FCurrentPoseData);
  FBoneList.Items.BeginUpdate;
  try
    FBoneList.Clear;
    for BoneIndex := 0 to High(FModel.Bones) do
      FBoneList.Items.Add(FModel.Bones[BoneIndex].Name);
    if FBoneList.Count > 0 then
      FBoneList.ItemIndex := 0;
  finally
    FBoneList.Items.EndUpdate;
  end;
  FViewport.SetPreviewScene(FModel, FPoses, FBoneList.ItemIndex);
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

procedure TMmdAiPreviewMainForm.BoneListClick(Sender: TObject);
begin
  if FModel <> nil then
    FViewport.SetPreviewScene(FModel, FPoses, FBoneList.ItemIndex);
  ApplyDisplayMode;
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

procedure TMmdAiPreviewMainForm.OpenPoseClick(Sender: TObject);
var
  Dialog: TOpenDialog;
  PoseData, PoseName: string;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'MMDポーズ JSON (*.json)|*.json|すべてのファイル (*.*)|*.*';
    if not Dialog.Execute then
      Exit;
    try
      if not ExtractPoseFile(Dialog.FileName, PoseData, PoseName) then
        raise EArgumentException.Create('ポーズデータが空です。');
      ApplyPoseData(PoseData);
      FCurrentPoseName := PoseName;
      FCurrentCandidateId := '';
      FCandidateLabel.Caption := '候補: ' + PoseName;
      FSavePoseButton.Enabled := True;
      if FModel <> nil then
      begin
        FViewport.SetPreviewScene(FModel, FPoses, FBoneList.ItemIndex);
        ApplyDisplayMode;
        SetStatus('ポーズを読み込みました: ' + PoseName);
      end;
    except
      on E: Exception do
        SetStatus('ポーズ読込みエラー: ' + E.Message, True);
    end;
  finally
    Dialog.Free;
  end;
end;

procedure TMmdAiPreviewMainForm.SavePoseClick(Sender: TObject);
var
  FilePath, PoseName: string;
  Root: TJSONObject;
begin
  if FCurrentPoseData = '' then
  begin
    SetStatus('保存するポーズがありません。', True);
    Exit;
  end;
  PoseName := FCurrentPoseName;
  if PoseName = '' then
    PoseName := '新しいポーズ';
  if not InputQuery('ポーズを保存', '名称:', PoseName) then
    Exit;
  PoseName := Trim(PoseName);
  if PoseName = '' then
  begin
    SetStatus('ポーズ名を入力してください。', True);
    Exit;
  end;
  try
    TDirectory.CreateDirectory(GetPoseDirectory);
    FilePath := NewPoseFilePath(PoseName);
    Root := TJSONObject.Create;
    try
      Root.AddPair('format', 'mmd-ai-preview-pose');
      Root.AddPair('version', TJSONNumber.Create(1));
      Root.AddPair('name', PoseName);
      if FCurrentCandidateId <> '' then
        Root.AddPair('candidate_id', FCurrentCandidateId);
      Root.AddPair('pose_data', FCurrentPoseData);
      TFile.WriteAllText(FilePath, Root.Format(2), TEncoding.UTF8);
    finally
      Root.Free;
    end;
    FCurrentPoseName := PoseName;
    FCandidateLabel.Caption := '候補: ' + PoseName;
    SetStatus('保存しました: ' + FilePath);
  except
    on E: Exception do
      SetStatus('ポーズ保存エラー: ' + E.Message, True);
  end;
end;

procedure TMmdAiPreviewMainForm.LoadPresentation(
  const PresentationText: string);
var
  ModelFile, PoseData: string;
  RootValue: TJSONValue;
begin
  RootValue := TJSONObject.ParseJSONValue(PresentationText);
  try
    if not (RootValue is TJSONObject) then
      raise EArgumentException.Create('提示データがJSON objectではありません。');
    ModelFile := ReadJsonString(TJSONObject(RootValue), 'model_file', '');
    PoseData := ReadJsonString(TJSONObject(RootValue), 'pose_data', '');
    if PoseData = '' then
      raise EArgumentException.Create('pose_dataがありません。');
    FCurrentPoseData := PoseData;
    if (ModelFile <> '') and
       not SameText(FCurrentModelFile, TPath.GetFullPath(ModelFile)) then
      LoadModel(ModelFile, True)
    else
    begin
      ApplyPoseData(PoseData);
      FViewport.SetPreviewScene(FModel, FPoses, FBoneList.ItemIndex);
      ApplyDisplayMode;
    end;
    FCurrentCandidateId := ReadJsonString(TJSONObject(RootValue),
      'candidate_id', '');
    FCurrentPoseName := ReadJsonString(TJSONObject(RootValue), 'pose_name',
      '新しいポーズ');
    FCandidateLabel.Caption := '候補: ' + FCurrentPoseName;
    FSavePoseButton.Enabled := True;
    SetStatus('Codexから候補を受信しました。3D表示を確認してください。');
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
