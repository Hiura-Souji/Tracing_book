#Region ;**** 由 AutoIt3Wrapper_GUI 建立的指令 ****
#AutoIt3Wrapper_Version=Beta
#AutoIt3Wrapper_Icon=ShengZiBu.ico
#AutoIt3Wrapper_Compression=4
#AutoIt3Wrapper_UseUpx=y
#AutoIt3Wrapper_UseX64=n
#AutoIt3Wrapper_Res_Comment=生字簿練習器
#AutoIt3Wrapper_Res_Description=生字簿練習器
#AutoIt3Wrapper_Res_Fileversion=1.0.0.0
#AutoIt3Wrapper_Res_ProductName=生字簿練習器
#AutoIt3Wrapper_Res_ProductVersion=2026.10.30
#AutoIt3Wrapper_Res_CompanyName=格雷資訊
#AutoIt3Wrapper_Res_LegalCopyright=grayfree.tw 2026 Unlicense.
#AutoIt3Wrapper_Res_LegalTradeMarks=grayfree.tw
#AutoIt3Wrapper_Res_Language=1028
#AutoIt3Wrapper_Res_requestedExecutionLevel=highestAvailable
#AutoIt3Wrapper_Res_CLASS=gWinUI
#AutoIt3Wrapper_Res_HiDpi=y
#EndRegion ;**** 由 AutoIt3Wrapper_GUI 建立的指令 ****
#NoTrayIcon ;不顯示系統匣圖示
#RequireAdmin


; ============================================================================
; 生字簿練習器 — 描紅生字簿產生器（桌面版）
;   介面：Web\index.html，顯示在 AUI 的 WebView2 視窗中（與網頁版同一份檔案）
;   後端：本機 HTTP 伺服器（只綁 127.0.0.1，API 需帶啟動時產生的隨機權杖）
;     ‧設定、自造字、作業清單存成 data\*.json
;     ‧Web\index.html 自帶教育部常用國字標準字體筆順 4,844 字（g0v zh-stroke-data 全部 XML，壓縮內嵌）
;     ‧不在內建資料裡的字，第一次下載後快取到 data\strokes（Make Me a Hanzi 等）
;     ‧fonts 資料夾裡的字型檔會出現在字型選單（例如教育部標準楷書、全字庫正楷體）
;     ‧存成 PDF：WebView2 的 DevTools Protocol「Page.printToPDF」
;
; 格雷資訊 grayfree.tw   GitHub @Hiura-Souji
; ============================================================================

#include "AUI.au3"

Opt("MustDeclareVars", 1)

#Region ;===== 常數與全域變數 =====
Global Const $APP_NAME = "生字簿練習器", $APP_VER = "1.0.0"
Global Const $SZB_MAX_BODY = 33554432 ; 32 MB（作業裡可能有描圖圖片）
Global $g_hMain = 0, $g_iWeb = 0, $g_hMutex = 0
Global $g_sWebRoot = @ScriptDir & "\Web"
Global $g_sData = @ScriptDir & "\data"
Global $g_sFonts = @ScriptDir & "\fonts"
Global $g_iListen = -1, $g_iPort = 0, $g_sToken = ""
Global $g_aConn[0]          ; 每個元素：Map{sock, buf, t}
Global $g_bPolling = False  ; 防止開存檔視窗時計時器重入
Global $g_mPdfStatus[]      ; 工作編號 → "pending" / "done" / "fail:原因"
Global $g_mPdfPath[]        ; 工作編號 → 輸出路徑
Global $g_mPdfReq[]         ; CDP 請求編號 → 工作編號
Global $g_iPdfSeq = 0
Global $g_mStrokeMiss[]     ; 找不到筆順的字（這次執行期間不再重抓）
Global $g_sLastDir = @MyDocumentsDir
Global $g_sTheme = "auto"            ; auto / light / dark
Global $g_hThemeFromWeb = 0         ; 網頁剛改過主題的時間（避免回呼又把設定送回網頁）
Global $g_iThemePending = -1        ; 視窗主題回呼記下的模式，由主迴圈處理
Global $g_aPdfDone[0]               ; CDP 回呼記下的「請求編號|狀態」，由主迴圈處理
Global $g_sWebUrl = ""              ; 介面網址（含權杖）
Global $g_bPageOk = False           ; 網頁已經呼叫過 /api/ping（代表載入成功）
Global $g_hWebT = 0, $g_iWebRetry = 0
Global $g_sCurReq = ""              ; 目前處理中的請求（寫紀錄用）
Global $g_bInCb = False             ; 目前是不是在 AUI 計時器回呼裡
Global $g_aDefer[0]                 ; 回呼裡收到、要交給主迴圈處理的請求（開對話框、下載、寫 PDF）
Global $g_hLoop = TimerInit(), $g_bStall = False
#EndRegion

#Region ;===== 程式進入點 =====
If @AutoItX64 Then
	MsgBox(16, $APP_NAME, "請使用 32 位元 AutoIt3.exe 執行（AUI 只支援 x86）。")
	Exit
EndIf
If Not __App_SingleInstance() Then
	WinActivate($APP_NAME)
	Exit
EndIf
; 編譯成 exe 時，介面（含全部筆順資料）包在 exe 裡，每次啟動解出最新版
If @Compiled Then
	DirCreate($g_sWebRoot)
	FileInstall("Web\index.html", $g_sWebRoot & "\index.html", 1)
EndIf
If Not FileExists($g_sWebRoot & "\index.html") Then
	MsgBox(16, $APP_NAME, "找不到介面檔案：" & @CRLF & $g_sWebRoot & "\index.html")
	Exit
EndIf
DirCreate($g_sData & "\strokes")
DirCreate($g_sData & "\projects")
DirCreate($g_sFonts)
$g_sLastDir = IniRead($g_sData & "\ShengZiBu.ini", "UI", "LastDir", @MyDocumentsDir)
$g_sTheme = IniRead($g_sData & "\ShengZiBu.ini", "UI", "Theme", "auto")
If Not StringRegExp($g_sTheme, "^(auto|light|dark)$") Then $g_sTheme = "auto"

If FileGetSize($g_sData & "\ShengZiBu.log") > 524288 Then FileDelete($g_sData & "\ShengZiBu.log")
__Log("===== 啟動 " & $APP_NAME & " " & $APP_VER & "（AutoIt " & @AutoItVersion & (@Compiled ? "，已編譯" : "") & "）")
If _UI_Init() = 0 Then
	MsgBox(16, $APP_NAME, "AUI 初始化失敗：" & _UI_GetLastErrorText())
	Exit
EndIf
If Not _UI_WebViewIsRuntimeInstalled() Then
	If MsgBox(52, $APP_NAME, "這台電腦沒有安裝 Microsoft Edge WebView2 Runtime，生字簿練習器的介面需要它。" & @CRLF & @CRLF & "要開啟微軟的下載頁面嗎？") = 6 Then
		ShellExecute("https://developer.microsoft.com/microsoft-edge/webview2/")
	EndIf
	Exit
EndIf
If Not __Srv_Start() Then
	MsgBox(16, $APP_NAME, "無法啟動本機服務（連接埠 21890～21909 都被占用）。")
	Exit
EndIf

$g_hMain = _UI_WindowCreate($APP_NAME, 1320, 880)
If $g_hMain = 0 Then Exit
If FileExists(@ScriptDir & "\ShengZiBu.ico") Then _UI_WindowSetIcon($g_hMain, @ScriptDir & "\ShengZiBu.ico")
; 主題：視窗右上角的主題按鈕和網頁裡的深淺色按鈕互相同步
_UI_ThemeSetMode($g_hMain, __ThemeMode($g_sTheme))
_UI_OnThemeChange($g_hMain, "__App_OnTheme")
; 本機服務同時由計時器回呼與主迴圈輪詢：WebView2 初始化時 _UI_PumpOnce 可能停在內部迴圈，
; 這時只有計時器還會跑，網頁才拿得到內容（不然兩邊互等，畫面卡在空白）
_UI_TimerStart($g_hMain, 15, "__Srv_Tick")
; 根容器撐滿視窗，WebView 跟著視窗縮放
Global $g_iRoot = _UI_Column($g_hMain, 0)
_UI_SetAlign($g_hMain, $g_iRoot, $AUI_ALIGN_STRETCH, $AUI_ALIGN_START)
_UI_SetFlexGrow($g_hMain, $g_iRoot, 1)
; 先顯示視窗、處理幾輪訊息，等視窗有實際大小後才建立 WebView
; （視窗還沒顯示就建立，偶爾 WebView 會拿到 0 大小，整個畫面一直空白）
_UI_WindowShow($g_hMain)
Global $hPump = TimerInit()
While TimerDiff($hPump) < 150
	If _UI_PumpOnce() < 0 Then Exit
	Sleep(10)
WEnd
; 網址 # 後面帶權杖與目前深淺色（啟動畫面第一格就用對的顏色）
$g_sWebUrl = "http://127.0.0.1:" & $g_iPort & "/#t=" & $g_sToken & "&th=" & __EffectiveTheme()
; WebView2 資料夾：每個程式各用各的，系統管理員身分另外一個。
; 預設所有 AutoIt 腳本共用 AutoIt3.exe 旁邊同一個資料夾，和 RiftMate 等程式同時開、
; 或一般／系統管理員身分混用時，WebView2 會初始化失敗，畫面卡在空白。
EnvSet("WEBVIEW2_USER_DATA_FOLDER", $g_sData & "\WebView2" & (IsAdmin() ? "_admin" : ""))
__Log("WebView2 資料夾：" & EnvGet("WEBVIEW2_USER_DATA_FOLDER") & (IsAdmin() ? "（系統管理員身分）" : ""))
$g_iWeb = _UI_WebView($g_hMain, $g_iRoot, $g_sWebUrl)
If $g_iWeb = 0 Then
	__Log("建立 WebView 失敗：" & _UI_GetLastErrorText())
	MsgBox(16, $APP_NAME, "無法建立網頁畫面（WebView2）：" & @CRLF & _UI_GetLastErrorText(), 0, $g_hMain)
	Exit
EndIf
_UI_SetFlexGrow($g_hMain, $g_iWeb, 1)
$g_hWebT = TimerInit()
__Log("WebView 已建立，連接埠 " & $g_iPort)

; 自建主迴圈：所有工作（本機服務、存檔視窗、下載筆順、寫 PDF、主題同步）都在這裡做，
; 不在 AUI 的回呼裡做。回呼裡開對話框或長時間阻塞，AutoIt 可能整個當掉。
Global $iMsgs = 0, $bBusy = False
While 1
	$iMsgs = _UI_PumpOnce()
	If $iMsgs < 0 Then ExitLoop               ; 視窗已關閉
	If $g_bStall Then
		__Log("主迴圈恢復（停了 " & Round(TimerDiff($g_hLoop) / 1000, 1) & " 秒）")
		$g_bStall = False
	EndIf
	$g_hLoop = TimerInit()
	$bBusy = __Srv_Poll()
	__Srv_RunDeferred()
	__Pdf_Process()
	__Theme_Process()
	__Web_Watchdog()
	If $iMsgs = 0 And Not $bBusy Then Sleep(10)
WEnd
__Log("視窗關閉，程式結束")

IniWrite($g_sData & "\ShengZiBu.ini", "UI", "LastDir", $g_sLastDir)
IniWrite($g_sData & "\ShengZiBu.ini", "UI", "Theme", $g_sTheme)
__Srv_Stop()
Exit
#EndRegion

#Region ;===== 主題 =====
Func __ThemeMode($s)
	Switch $s
		Case "light"
			Return $AUI_THEME_LIGHT
		Case "dark"
			Return $AUI_THEME_DARK
	EndSwitch
	Return $AUI_THEME_AUTO
EndFunc   ;==>__ThemeMode

; 實際的深淺色：選「自動」時看 Windows 的應用程式模式
Func __EffectiveTheme()
	If $g_sTheme = "light" Or $g_sTheme = "dark" Then Return $g_sTheme
	Local $iLight = RegRead("HKCU64\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
	If @error Then Return "light"
	Return ($iLight = 0) ? "dark" : "light"
EndFunc   ;==>__EffectiveTheme

; 視窗主題改變（按了標題列的主題按鈕）：記住並同步到網頁
Func __App_OnTheme($hWnd, $iMode)
	#forceref $hWnd
	$g_iThemePending = $iMode          ; 回呼裡只記錄，實際工作交給主迴圈
EndFunc   ;==>__App_OnTheme

Func __Theme_Process()
	If $g_iThemePending < 0 Then Return
	Local $iMode = $g_iThemePending
	$g_iThemePending = -1
	If $g_hThemeFromWeb And TimerDiff($g_hThemeFromWeb) < 800 Then Return ; 是網頁自己改的，不用送回去
	$g_sTheme = ($iMode = $AUI_THEME_DARK) ? "dark" : "light"
	IniWrite($g_sData & "\ShengZiBu.ini", "UI", "Theme", $g_sTheme)
	If $g_iWeb Then _UI_WebViewExecuteScriptAsync($g_hMain, $g_iWeb, "window.szbSetTheme&&window.szbSetTheme('" & $g_sTheme & "')")
EndFunc   ;==>__Theme_Process
#EndRegion

#Region ;===== 紀錄與看門狗 =====
; 寫紀錄到 data\ShengZiBu.log（畫面空白、存檔失敗時可以看是卡在哪一步）
Func __Log($s)
	Local $h = FileOpen($g_sData & "\ShengZiBu.log", 1 + 8 + 128)
	If $h = -1 Then Return
	FileWriteLine($h, @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & "." & @MSEC & "  " & $s)
	FileClose($h)
EndFunc   ;==>__Log

; 網頁 7 秒內沒有回報（呼叫 /api/ping）就重新載入，最多 2 次
Func __Web_Watchdog()
	If $g_bPageOk Or $g_iWeb = 0 Or $g_iWebRetry >= 2 Then Return
	If TimerDiff($g_hWebT) < 7000 Then Return
	$g_iWebRetry += 1
	__Log("網頁 7 秒沒有回報，重新載入（第 " & $g_iWebRetry & " 次）")
	_UI_WebViewNavigate($g_hMain, $g_iWeb, $g_sWebUrl)
	$g_hWebT = TimerInit()
EndFunc   ;==>__Web_Watchdog
#EndRegion

#Region ;===== 計時器回呼與延後處理 =====
Func __Srv_Tick($hWnd, $iTimer)
	#forceref $hWnd, $iTimer
	If Not $g_bStall And TimerDiff($g_hLoop) > 3000 Then
		$g_bStall = True
		__Log("主迴圈超過 3 秒沒有執行（由計時器繼續提供網頁）")
	EndIf
	$g_bInCb = True
	__Srv_Poll()
	$g_bInCb = False
EndFunc   ;==>__Srv_Tick

; 會開對話框、上網下載、寫檔或改視窗的請求，不在回呼裡做
Func __Srv_IsHeavy($sHead)
	Return StringRegExp($sHead, "^\S+\s+/api/(savedialog|pickfolder|pdf[?\s]|open|theme|stroke)") = 1
EndFunc   ;==>__Srv_IsHeavy

Func __Srv_RunDeferred()
	If UBound($g_aDefer) = 0 Then Return
	Local $aJobs = $g_aDefer
	Local $aEmpty[0]
	$g_aDefer = $aEmpty
	$g_bPolling = True                  ; 處理期間（可能開對話框）計時器先不接新請求
	For $mD In $aJobs
		__Srv_Handle($mD["sock"], $mD["head"], $mD["body"])
		TCPCloseSocket($mD["sock"])
	Next
	$g_bPolling = False
EndFunc   ;==>__Srv_RunDeferred
#EndRegion

#Region ;===== 單一執行個體 =====
Func __App_SingleInstance()
	Local $a = DllCall("kernel32.dll", "handle", "CreateMutexW", "ptr", 0, "bool", True, "wstr", "GrayFree_ShengZiBu_SingleInstance")
	If @error Then Return True
	$g_hMutex = $a[0]
	Local $aErr = DllCall("kernel32.dll", "dword", "GetLastError")
	Return Not (IsArray($aErr) And $aErr[0] = 183)
EndFunc   ;==>__App_SingleInstance
#EndRegion

#Region ;===== 本機 HTTP 伺服器 =====
Func __Srv_Start()
	$g_sToken = __RandomHex(24)
	TCPStartup()
	Opt("TCPTimeout", 1)
	For $iPort = 21890 To 21909
		$g_iListen = TCPListen("127.0.0.1", $iPort, 16)
		If Not @error And $g_iListen <> -1 Then
			$g_iPort = $iPort
			Return True
		EndIf
	Next
	$g_iListen = -1
	Return False
EndFunc   ;==>__Srv_Start

Func __Srv_Stop()
	For $mC In $g_aConn
		TCPCloseSocket($mC["sock"])
	Next
	If $g_iListen <> -1 Then TCPCloseSocket($g_iListen)
	TCPShutdown()
EndFunc   ;==>__Srv_Stop

Func __RandomHex($iBytes)
	Local $s = ""
	Local $t = DllStructCreate("byte[" & $iBytes & "]")
	Local $a = DllCall("advapi32.dll", "bool", "SystemFunction036", "struct*", $t, "ulong", $iBytes) ; RtlGenRandom
	If Not @error And IsArray($a) And $a[0] Then
		$s = StringLower(StringTrimLeft(String(DllStructGetData($t, 1)), 2))
	Else
		For $i = 1 To $iBytes
			$s &= StringLower(Hex(Random(0, 255, 1), 2))
		Next
	EndIf
	Return $s
EndFunc   ;==>__RandomHex

; 傳回 True＝這一輪有連線在處理（主迴圈就不休息）
Func __Srv_Poll()
	If $g_bPolling Or $g_iListen = -1 Then Return False
	$g_bPolling = True
	For $i = 1 To 16
		Local $iSock = TCPAccept($g_iListen)
		If $iSock = -1 Then ExitLoop
		; 加大傳送緩衝區（8 MB），6.9 MB 的介面一次就能送出
		DllCall("ws2_32.dll", "int", "setsockopt", "uint_ptr", $iSock, "int", 0xFFFF, "int", 0x1001, "int*", 8388608, "int", 4)
		Local $mNew[]
		$mNew["sock"] = $iSock
		$mNew["buf"] = Binary("")
		$mNew["t"] = TimerInit()
		__Push($g_aConn, $mNew)
	Next
	If UBound($g_aConn) = 0 Then
		$g_bPolling = False
		Return False
	EndIf
	Local $aKeep[0]
	For $mC In $g_aConn
		; 一次最多讀 1 MB，避免大的作業檔要等很久
		Local $bErr = False
		For $k = 1 To 16
			Local $bData = TCPRecv($mC["sock"], 65536, 1)
			If @error Then
				$bErr = True
				ExitLoop
			EndIf
			If BinaryLen($bData) = 0 Then ExitLoop
			$mC["buf"] = $mC["buf"] & $bData
		Next
		If $bErr Then
			TCPCloseSocket($mC["sock"])
			ContinueLoop
		EndIf
		Local $iHeadEnd = __Srv_FindHeadEnd($mC["buf"])
		If $iHeadEnd > 0 Then
			Local $sHead = BinaryToString(BinaryMid($mC["buf"], 1, $iHeadEnd - 1), 4)
			Local $iLen = 0
			Local $aCL = StringRegExp($sHead, "(?im)^content-length:\s*(\d+)", 1)
			If Not @error Then $iLen = Int($aCL[0])
			If $iLen > $SZB_MAX_BODY Then
				__Srv_Send($mC["sock"], 413, "內容太大")
				TCPCloseSocket($mC["sock"])
				ContinueLoop
			EndIf
			If BinaryLen($mC["buf"]) - ($iHeadEnd + 3) >= $iLen Then
				Local $bBody = ($iLen > 0) ? BinaryMid($mC["buf"], $iHeadEnd + 4, $iLen) : Binary("")
				If $g_bInCb And __Srv_IsHeavy($sHead) Then
					Local $mD[]
					$mD["sock"] = $mC["sock"]
					$mD["head"] = $sHead
					$mD["body"] = $bBody
					__Push($g_aDefer, $mD)
					ContinueLoop
				EndIf
				__Srv_Handle($mC["sock"], $sHead, $bBody)
				TCPCloseSocket($mC["sock"])
				ContinueLoop
			EndIf
		ElseIf BinaryLen($mC["buf"]) > 32768 Then
			TCPCloseSocket($mC["sock"])
			ContinueLoop
		EndIf
		If TimerDiff($mC["t"]) > 30000 Then
			TCPCloseSocket($mC["sock"])
			ContinueLoop
		EndIf
		__Push($aKeep, $mC)
	Next
	$g_aConn = $aKeep
	$g_bPolling = False
	Return True
EndFunc   ;==>__Srv_Poll

Func __Push(ByRef $a, $v)
	ReDim $a[UBound($a) + 1]
	$a[UBound($a) - 1] = $v
EndFunc   ;==>__Push

Func __Srv_FindHeadEnd($b)
	Local $s = BinaryToString(BinaryMid($b, 1, 32768), 1)
	Return StringInStr($s, @CRLF & @CRLF, 1)
EndFunc   ;==>__Srv_FindHeadEnd

Func __Srv_Header($sHead, $sName)
	Local $a = StringRegExp($sHead, "(?im)^" & $sName & ":\s*([^\r\n]*)", 1)
	If @error Then Return ""
	Return StringStripWS($a[0], 3)
EndFunc   ;==>__Srv_Header

Func __Srv_Handle($iSock, $sHead, $bBody)
	Local $aLine = StringRegExp($sHead, "^(\S+)\s+(\S+)", 1)
	If @error Then Return __Srv_Send($iSock, 400, "Bad request")
	Local $sMethod = StringUpper($aLine[0]), $sTarget = $aLine[1]
	$g_sCurReq = $sMethod & " " & StringRegExpReplace($sTarget, "\?.*$", "")
	; 防 DNS rebinding：Host 必須是本機
	Local $sHost = __Srv_Header($sHead, "Host")
	If $sHost <> "127.0.0.1:" & $g_iPort And $sHost <> "localhost:" & $g_iPort Then Return __Srv_Send($iSock, 403, "Forbidden")
	Local $sPath = $sTarget, $sQuery = ""
	Local $iQ = StringInStr($sTarget, "?")
	If $iQ Then
		$sPath = StringLeft($sTarget, $iQ - 1)
		$sQuery = StringMid($sTarget, $iQ + 1)
	EndIf

	; ---- 介面檔案 ----
	If $sPath = "/" Or $sPath = "/index.html" Then Return __Srv_SendFile($iSock, $g_sWebRoot & "\index.html")
	If StringLeft($sPath, 7) = "/fonts/" Then
		Local $sFont = __UrlDecode(StringMid($sPath, 8))
		If $sFont = "" Or StringRegExp($sFont, '[\\/:*?"<>|]') Or StringInStr($sFont, "..") Then Return __Srv_Send($iSock, 404, "Not found")
		Return __Srv_SendFile($iSock, $g_sFonts & "\" & $sFont)
	EndIf
	If StringLeft($sPath, 5) <> "/api/" Then
		Local $sRel = StringMid($sPath, 2)
		If StringRegExp($sRel, "^[A-Za-z0-9_\-]+\.[A-Za-z0-9]+$") Then Return __Srv_SendFile($iSock, $g_sWebRoot & "\" & $sRel)
		Return __Srv_Send($iSock, 404, "Not found")
	EndIf

	; ---- API：必須帶權杖 ----
	If __Srv_Header($sHead, "X-SZB-Token") <> $g_sToken Then Return __Srv_Send($iSock, 401, "Unauthorized")
	Local $sApi = StringMid($sPath, 6)
	Local $sBody = BinaryToString($bBody, 4)
	Switch $sMethod & " " & $sApi
		Case "GET theme"
			Return __Srv_Send($iSock, 200, $g_sTheme)

		Case "POST theme"
			Local $sM = __Query($sQuery, "m")
			If Not StringRegExp($sM, "^(auto|light|dark)$") Then Return __Srv_Send($iSock, 400, "Bad mode")
			$g_sTheme = $sM
			IniWrite($g_sData & "\ShengZiBu.ini", "UI", "Theme", $g_sTheme)
			$g_hThemeFromWeb = TimerInit()
			_UI_ThemeSetMode($g_hMain, __ThemeMode($g_sTheme))
			Return __Srv_Send($iSock, 200, "ok")

		Case "GET ping"
			If Not $g_bPageOk Then __Log("網頁載入完成（" & Round(TimerDiff($g_hWebT)) & " ms）")
			$g_bPageOk = True
			Return __Srv_Send($iSock, 200, '{"host":"au3","ver":"' & $APP_VER & '"}', "application/json; charset=utf-8")

		Case "GET store", "POST store"
			Local $sKey = __Query($sQuery, "k")
			If Not StringRegExp($sKey, "^(state|glyphs)$") Then Return __Srv_Send($iSock, 400, "Bad key")
			Local $sFile = $g_sData & "\" & $sKey & ".json"
			If $sMethod = "GET" Then Return __Srv_Send($iSock, 200, FileExists($sFile) ? __ReadUtf8($sFile) : "null", "application/json; charset=utf-8")
			If Not __WriteUtf8($sFile, $sBody) Then Return __Srv_Send($iSock, 500, "無法寫入 " & $sFile)
			Return __Srv_Send($iSock, 200, "ok")

		Case "GET stroke"
			Return __Api_Stroke($iSock, StringLower(__Query($sQuery, "c")))

		Case "GET fonts"
			Local $sList = "", $hFind = FileFindFirstFile($g_sFonts & "\*.*")
			If $hFind <> -1 Then
				While 1
					Local $sF = FileFindNextFile($hFind)
					If @error Then ExitLoop
					If StringRegExp($sF, "(?i)\.(ttf|otf|woff2?|ttc)$") Then $sList &= ($sList = "" ? "" : ",") & __J($sF)
				WEnd
				FileClose($hFind)
			EndIf
			Return __Srv_Send($iSock, 200, "[" & $sList & "]", "application/json; charset=utf-8")

		Case "GET projects"
			Local $sOut = "", $hP = FileFindFirstFile($g_sData & "\projects\*.json")
			If $hP <> -1 Then
				While 1
					Local $sPF = FileFindNextFile($hP)
					If @error Then ExitLoop
					Local $sData = StringStripWS(__ReadUtf8($g_sData & "\projects\" & $sPF), 3)
					If StringLeft($sData, 1) <> "{" Then ContinueLoop
					$sOut &= ($sOut = "" ? "" : ",") & '{"name":' & __J(StringTrimRight($sPF, 5)) & ',"data":' & $sData & '}'
				WEnd
				FileClose($hP)
			EndIf
			Return __Srv_Send($iSock, 200, "[" & $sOut & "]", "application/json; charset=utf-8")

		Case "POST projects", "POST projdel"
			Local $sName = __SafeName(__HexUtf8(__Query($sQuery, "n")))
			If $sName = "" Then Return __Srv_Send($iSock, 400, "缺少作業名稱")
			Local $sPFile = $g_sData & "\projects\" & $sName & ".json"
			If $sApi = "projdel" Then
				FileDelete($sPFile)
				Return __Srv_Send($iSock, 200, "ok")
			EndIf
			If StringLeft(StringStripWS($sBody, 1), 1) <> "{" Then Return __Srv_Send($iSock, 400, "內容格式不正確")
			If Not __WriteUtf8($sPFile, $sBody) Then Return __Srv_Send($iSock, 500, "無法寫入 " & $sPFile)
			Return __Srv_Send($iSock, 200, "ok")

		Case "POST savedialog"
			Local $sSave = FileSaveDialog("存成 PDF", $g_sLastDir, "PDF 檔 (*.pdf)", 2 + 16, __SafeName($sBody), $g_hMain)
			If @error Or $sSave = "" Then Return __Srv_Send($iSock, 200, "")
			If StringRight($sSave, 4) <> ".pdf" Then $sSave &= ".pdf"
			$g_sLastDir = StringRegExpReplace($sSave, "\\[^\\]*$", "")
			Return __Srv_Send($iSock, 200, $sSave)

		Case "POST pickfolder"
			Local $sDir = FileSelectFolder("選擇 PDF 要存放的資料夾", "", 1 + 2, $g_sLastDir, $g_hMain)
			If @error Or $sDir = "" Then Return __Srv_Send($iSock, 200, "")
			$g_sLastDir = $sDir
			Return __Srv_Send($iSock, 200, $sDir)

		Case "POST pdf"
			Return __Api_PdfStart($iSock, StringStripWS($sBody, 3))

		Case "GET pdfstatus"
			Local $sId = __Query($sQuery, "id")
			If Not MapExists($g_mPdfStatus, $sId) Then Return __Srv_Send($iSock, 200, "fail:找不到工作")
			Local $sSt = $g_mPdfStatus[$sId]
			If $sSt <> "pending" Then
				MapRemove($g_mPdfStatus, $sId)
				MapRemove($g_mPdfPath, $sId)
			EndIf
			Return __Srv_Send($iSock, 200, $sSt)

		Case "POST open"
			Local $sOpen = StringStripWS($sBody, 3)
			If StringRegExp($sOpen, "(?i)\.pdf$") And FileExists($sOpen) Then
				ShellExecute($sOpen)
			ElseIf FileExists($sOpen) And StringInStr(FileGetAttrib($sOpen), "D") Then
				ShellExecute("explorer.exe", '"' & $sOpen & '"')
			Else
				Return __Srv_Send($iSock, 404, "找不到檔案")
			EndIf
			Return __Srv_Send($iSock, 200, "ok")
	EndSwitch
	Return __Srv_Send($iSock, 404, "Not found")
EndFunc   ;==>__Srv_Handle

Func __Srv_SendFile($iSock, $sFile)
	If Not FileExists($sFile) Or StringInStr(FileGetAttrib($sFile), "D") Then Return __Srv_Send($iSock, 404, "Not found")
	Local $h = FileOpen($sFile, 16)
	Local $b = FileRead($h)
	FileClose($h)
	Local $sType = "application/octet-stream", $sCache = "no-cache"
	Switch StringLower(StringRegExpReplace($sFile, "^.*\.", ""))
		Case "html"
			$sType = "text/html; charset=utf-8"
		Case "js"
			$sType = "text/javascript; charset=utf-8"
		Case "css"
			$sType = "text/css; charset=utf-8"
		Case "json"
			$sType = "application/json; charset=utf-8"
			; 內建筆順資料（約 13 MB）讓 WebView2 快取一天，開啟比較快
			If StringRegExp($sFile, "(?i)\\strokes\.json$") Then $sCache = "max-age=86400"
		Case "png"
			$sType = "image/png"
		Case "ico"
			$sType = "image/x-icon"
		Case "svg"
			$sType = "image/svg+xml"
		Case "ttf"
			$sType = "font/ttf"
			$sCache = "max-age=86400"
		Case "otf"
			$sType = "font/otf"
			$sCache = "max-age=86400"
		Case "ttc"
			$sType = "font/collection"
			$sCache = "max-age=86400"
		Case "woff"
			$sType = "font/woff"
			$sCache = "max-age=86400"
		Case "woff2"
			$sType = "font/woff2"
			$sCache = "max-age=86400"
	EndSwitch
	Return __Srv_Send($iSock, 200, $b, $sType, $sCache)
EndFunc   ;==>__Srv_SendFile

Func __Srv_Send($iSock, $iStatus, $vBody, $sType = "text/plain; charset=utf-8", $sCache = "no-store")
	If IsString($vBody) Then $vBody = StringToBinary($vBody, 4)
	Local $sReason = "OK"
	Switch $iStatus
		Case 400
			$sReason = "Bad Request"
		Case 401
			$sReason = "Unauthorized"
		Case 403
			$sReason = "Forbidden"
		Case 404
			$sReason = "Not Found"
		Case 413
			$sReason = "Payload Too Large"
		Case 500
			$sReason = "Internal Server Error"
		Case 502
			$sReason = "Bad Gateway"
	EndSwitch
	Local $sH = "HTTP/1.1 " & $iStatus & " " & $sReason & @CRLF & _
			"Content-Type: " & $sType & @CRLF & _
			"Content-Length: " & BinaryLen($vBody) & @CRLF & _
			"Cache-Control: " & $sCache & @CRLF & _
			"X-Content-Type-Options: nosniff" & @CRLF & _
			"Referrer-Policy: no-referrer" & @CRLF & _
			"Connection: close" & @CRLF & @CRLF
	Local $bAll = StringToBinary($sH, 4) & $vBody
	Local $iSent = 0, $iTotal = BinaryLen($bAll), $hT = TimerInit(), $n, $iErr
	While $iSent < $iTotal And TimerDiff($hT) < 30000
		$n = TCPSend($iSock, BinaryMid($bAll, $iSent + 1, 1048576))
		$iErr = @error
		If $iErr Then
			If $iErr = 10035 Then           ; WSAEWOULDBLOCK：傳送緩衝區滿了，等一下再送
				Sleep(1)
				ContinueLoop
			EndIf
			__Log("傳送失敗 " & $g_sCurReq & "：錯誤 " & $iErr & "，已送 " & $iSent & "/" & $iTotal)
			ExitLoop
		EndIf
		$iSent += $n
		If $n = 0 Then Sleep(1)
	WEnd
	If $iSent < $iTotal Then
		If Not $iErr Then __Log("傳送逾時 " & $g_sCurReq & "：已送 " & $iSent & "/" & $iTotal)
	ElseIf $iStatus <> 200 Or $iTotal > 100000 Then
		If Not StringInStr($g_sCurReq, "pdfstatus") Then __Log($g_sCurReq & " → " & $iStatus & "（" & $iTotal & " bytes，" & Round(TimerDiff($hT)) & " ms）")
	EndIf
	Return 1
EndFunc   ;==>__Srv_Send
#EndRegion

#Region ;===== 筆順資料（下載＋快取） =====
; 傳回 {"src":"來源","json":原始資料}；第一次向網路下載，之後讀 data\strokes
Func __Api_Stroke($iSock, $sHex)
	If Not StringRegExp($sHex, "^[0-9a-f]{4,6}$") Then Return __Srv_Send($iSock, 400, "Bad code")
	Local $sCache = $g_sData & "\strokes\" & $sHex & ".json"
	If FileExists($sCache) Then Return __Srv_Send($iSock, 200, __ReadUtf8($sCache), "application/json; charset=utf-8")
	If MapExists($g_mStrokeMiss, $sHex) Then Return __Srv_Send($iSock, 404, "沒有筆順資料")
	Local $aSrc[2][2] = [ _
			["教育部筆順（g0v）", "https://raw.githubusercontent.com/g0v/zh-stroke-data/HEAD/json/" & $sHex & ".json"], _
			["Make Me a Hanzi", "https://cdn.jsdelivr.net/npm/hanzi-writer-data@2.0.1/" & __CpToPct(Dec($sHex)) & ".json"]]
	For $i = 0 To 1
		Local $b = InetRead($aSrc[$i][1], 1)
		If @error Or BinaryLen($b) < 20 Then ContinueLoop
		Local $sJson = StringStripWS(BinaryToString($b, 4), 3)
		If StringLeft($sJson, 1) <> "[" And StringLeft($sJson, 1) <> "{" Then ContinueLoop
		Local $sOut = '{"src":' & __J($aSrc[$i][0]) & ',"json":' & $sJson & '}'
		__WriteUtf8($sCache, $sOut)
		Return __Srv_Send($iSock, 200, $sOut, "application/json; charset=utf-8")
	Next
	$g_mStrokeMiss[$sHex] = True
	Return __Srv_Send($iSock, 404, "沒有筆順資料")
EndFunc   ;==>__Api_Stroke

; Unicode 碼位 → UTF-8 百分比編碼（網址用）
Func __CpToPct($iCp)
	Local $aB[0]
	If $iCp < 0x80 Then
		__Push($aB, $iCp)
	ElseIf $iCp < 0x800 Then
		__Push($aB, BitOR(0xC0, BitShift($iCp, 6)))
		__Push($aB, BitOR(0x80, BitAND($iCp, 0x3F)))
	ElseIf $iCp < 0x10000 Then
		__Push($aB, BitOR(0xE0, BitShift($iCp, 12)))
		__Push($aB, BitOR(0x80, BitAND(BitShift($iCp, 6), 0x3F)))
		__Push($aB, BitOR(0x80, BitAND($iCp, 0x3F)))
	Else
		__Push($aB, BitOR(0xF0, BitShift($iCp, 18)))
		__Push($aB, BitOR(0x80, BitAND(BitShift($iCp, 12), 0x3F)))
		__Push($aB, BitOR(0x80, BitAND(BitShift($iCp, 6), 0x3F)))
		__Push($aB, BitOR(0x80, BitAND($iCp, 0x3F)))
	EndIf
	Local $s = ""
	For $v In $aB
		$s &= "%" & Hex($v, 2)
	Next
	Return $s
EndFunc   ;==>__CpToPct
#EndRegion

#Region ;===== 存成 PDF（WebView2 DevTools Protocol） =====
Func __Api_PdfStart($iSock, $sPath)
	If Not StringRegExp($sPath, "(?i)^[a-z]:\\.+\.pdf$|^\\\\.+\.pdf$") Then Return __Srv_Send($iSock, 400, "路徑不正確")
	Local $sDir = StringRegExpReplace($sPath, "\\[^\\]*$", "")
	If Not FileExists($sDir) Then DirCreate($sDir)
	$g_iPdfSeq += 1
	Local $sId = String($g_iPdfSeq)
	Local $sParams = '{"printBackground":true,"preferCSSPageSize":true,"marginTop":0,"marginBottom":0,"marginLeft":0,"marginRight":0,"transferMode":"ReturnAsBase64"}'
	Local $iReq = _UI_WebViewCallCdpAsync($g_hMain, $g_iWeb, "Page.printToPDF", $sParams, "__Pdf_OnDone")
	If $iReq <= 0 Then
		$g_mPdfStatus[$sId] = "fail:WebView2 無法執行列印成 PDF"
	Else
		$g_mPdfStatus[$sId] = "pending"
		$g_mPdfPath[$sId] = $sPath
		$g_mPdfReq[String($iReq)] = $sId
	EndIf
	Return __Srv_Send($iSock, 200, $sId)
EndFunc   ;==>__Api_PdfStart

Func __Pdf_OnDone($iWebId, $iReqId, $iStatus)
	#forceref $iWebId
	__Push($g_aPdfDone, $iReqId & "|" & $iStatus) ; 回呼裡只記錄，實際工作交給主迴圈
EndFunc   ;==>__Pdf_OnDone

; 主迴圈：處理已完成的 PDF 請求（取結果、解碼、寫檔）
Func __Pdf_Process()
	If UBound($g_aPdfDone) = 0 Then Return
	Local $aJobs = $g_aPdfDone
	Local $aEmpty[0]
	$g_aPdfDone = $aEmpty
	For $sJob In $aJobs
		Local $aP = StringSplit($sJob, "|", 2)
		__Pdf_Finish(Int($aP[0]), Int($aP[1]))
	Next
EndFunc   ;==>__Pdf_Process

Func __Pdf_Finish($iReqId, $iStatus)
	Local $sReq = String($iReqId)
	If Not MapExists($g_mPdfReq, $sReq) Then Return
	Local $sId = $g_mPdfReq[$sReq]
	MapRemove($g_mPdfReq, $sReq)
	If $iStatus <> $AUI_WEB_RESULT_SUCCEEDED Then
		$g_mPdfStatus[$sId] = "fail:列印成 PDF 失敗（0x" & Hex(_UI_WebViewResultError($g_hMain, $g_iWeb, $iReqId)) & "）"
		_UI_WebViewResultRelease($g_hMain, $g_iWeb, $iReqId)
		Return
	EndIf
	Local $sRes = _UI_WebViewResultGet($g_hMain, $g_iWeb, $iReqId)
	_UI_WebViewResultRelease($g_hMain, $g_iWeb, $iReqId)
	Local $a = StringRegExp($sRes, '"data"\s*:\s*"([^"]+)"', 1)
	If @error Then
		$g_mPdfStatus[$sId] = "fail:沒有收到 PDF 資料"
		Return
	EndIf
	Local $bPdf = __B64Decode(StringReplace($a[0], "\/", "/"))
	If @error Or BinaryLen($bPdf) < 100 Then
		$g_mPdfStatus[$sId] = "fail:PDF 資料解碼失敗"
		Return
	EndIf
	Local $h = FileOpen($g_mPdfPath[$sId], 2 + 8 + 16)
	If $h = -1 Then
		$g_mPdfStatus[$sId] = "fail:無法寫入檔案（可能正在被其他程式開啟）"
		Return
	EndIf
	FileWrite($h, $bPdf)
	FileClose($h)
	$g_mPdfStatus[$sId] = "done"
EndFunc   ;==>__Pdf_Finish

Func __B64Decode($s)
	Local $a = DllCall("crypt32.dll", "bool", "CryptStringToBinaryW", "wstr", $s, "dword", 0, "dword", 1, "ptr", 0, "dword*", 0, "ptr", 0, "ptr", 0)
	If @error Or Not $a[0] Or $a[5] = 0 Then Return SetError(1, 0, Binary(""))
	Local $iLen = $a[5]
	Local $t = DllStructCreate("byte[" & $iLen & "]")
	$a = DllCall("crypt32.dll", "bool", "CryptStringToBinaryW", "wstr", $s, "dword", 0, "dword", 1, "struct*", $t, "dword*", $iLen, "ptr", 0, "ptr", 0)
	If @error Or Not $a[0] Then Return SetError(2, 0, Binary(""))
	Return BinaryMid(DllStructGetData($t, 1), 1, $a[5])
EndFunc   ;==>__B64Decode
#EndRegion

#Region ;===== 小工具 =====
Func __Query($sQuery, $sKey)
	Local $a = StringRegExp("&" & $sQuery, "&" & $sKey & "=([^&]*)", 1)
	If @error Then Return ""
	Return __UrlDecode($a[0])
EndFunc   ;==>__Query

; %XX 解碼（UTF-8）
Func __UrlDecode($s)
	If Not StringInStr($s, "%") And Not StringInStr($s, "+") Then Return $s
	$s = StringReplace($s, "+", " ")
	Local $sHex = "", $i = 1, $n = StringLen($s)
	While $i <= $n
		Local $c = StringMid($s, $i, 1)
		If $c = "%" And $i + 2 <= $n And StringIsXDigit(StringMid($s, $i + 1, 2)) Then
			$sHex &= StringMid($s, $i + 1, 2)
			$i += 3
		Else
			$sHex &= StringTrimLeft(String(StringToBinary($c, 4)), 2)
			$i += 1
		EndIf
	WEnd
	Return BinaryToString(Binary("0x" & $sHex), 4)
EndFunc   ;==>__UrlDecode

; 網頁用十六進位傳 UTF-8 字串（作業名稱）
Func __HexUtf8($sHex)
	If $sHex = "" Or Mod(StringLen($sHex), 2) Or Not StringIsXDigit($sHex) Then Return ""
	Return BinaryToString(Binary("0x" & $sHex), 4)
EndFunc   ;==>__HexUtf8

Func __SafeName($s)
	$s = StringStripWS(StringRegExpReplace($s, '[\\/:*?"<>|\x00-\x1F]+', "_"), 3)
	Return StringLeft($s, 80)
EndFunc   ;==>__SafeName

Func __J($s)
	$s = StringReplace($s, "\", "\\")
	$s = StringReplace($s, '"', '\"')
	$s = StringReplace($s, @CR, "\r")
	$s = StringReplace($s, @LF, "\n")
	$s = StringReplace($s, @TAB, "\t")
	Return '"' & $s & '"'
EndFunc   ;==>__J

Func __ReadUtf8($sFile)
	Local $h = FileOpen($sFile, 256)
	If $h = -1 Then Return ""
	Local $s = FileRead($h)
	FileClose($h)
	Return $s
EndFunc   ;==>__ReadUtf8

; 先寫暫存檔再取代，避免寫到一半當機把設定弄壞
Func __WriteUtf8($sFile, $s)
	Local $sTmp = $sFile & ".tmp"
	Local $h = FileOpen($sTmp, 2 + 8 + 256)
	If $h = -1 Then Return False
	FileWrite($h, $s)
	FileClose($h)
	Return FileMove($sTmp, $sFile, 1) = 1
EndFunc   ;==>__WriteUtf8
#EndRegion
