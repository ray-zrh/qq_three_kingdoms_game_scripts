#Requires AutoHotkey v2.0
InstallKeybdHook()
InstallMouseHook()

; ========================================================
; 管理员权限自提升 (Win11 默认以管理员运行)
; ========================================================
if !A_IsAdmin {
    try {
        Run('*RunAs "' A_ScriptFullPath '" /restart')
        ExitApp()
    } catch {
        MsgBox("无法获取管理员权限，脚本可能无法正常工作。", "权限警告", "Icon!")
    }
}

#SingleInstance Off

; 全局异常拦截 (捕获后安全退出)
OnError(GlobalMacroErrorHandler)
GlobalMacroErrorHandler(err, mode) {
    MsgBox("宏引擎遇到致命错误，已自动中断运行以保护系统安全！`n`n错误原因: " err.Message "`n发生位置: " err.File " (行 " err.Line ")", "引擎异常终止", "Iconx"
    )
    ExitApp(-1)
    return 1  ; AHK v2: 返回 1 表示"错误已处理"
}

#MaxThreadsPerHotkey 2
KeyHistory(0)
ListLines(false)

; 极致性能优化
SetKeyDelay(-1, -1)
SetMouseDelay(-1)
SetWinDelay(-1)
SetControlDelay(-1)
SetDefaultMouseSpeed(0)
ProcessSetPriority("High")

; 提升系统定时器精度到 1ms (默认 ~15ms)
DllCall("winmm\timeBeginPeriod", "UInt", 1)
OnExit((*) => DllCall("winmm\timeEndPeriod", "UInt", 1))

; ========================================================
; 定时技能定义类 (XS/YX 共用)
; ========================================================
class TimedSkillDef {
    Name := ""
    Key := ""
    DefaultInterval := 0  ; 默认间隔(分钟)

    __New(name, key, defaultInterval) {
        this.Name := name
        this.Key := key
        this.DefaultInterval := defaultInterval
    }
}

; ========================================================
; 底层发送控制器 (完全负责与操作系统的键鼠消息交互)
; ========================================================
class InputInjector {
    TargetHwnd := 0
    IsChatMode := false
    _heldKeys := Map()

    ; 扩展键集合 (bit 24 需要设为 1 的键)
    static _extendedKeys := Map(
        "Insert", 1, "Delete", 1, "Home", 1, "End", 1,
        "PgUp", 1, "PgDn", 1,
        "Up", 1, "Down", 1, "Left", 1, "Right", 1,
        "NumpadEnter", 1,
        "RControl", 1, "RAlt", 1,
        "PrintScreen", 1, "Pause", 1,
        "NumLock", 1
    )

    ; 解析目标句柄 (安全获取)
    ResolveTarget() {
        if (this.TargetHwnd != 0)
            return this.TargetHwnd
        try
            return WinGetID("A")
        catch
            return 0
    }

    SetTarget(hwnd) {
        this.ReleaseAllKeys()
        this.TargetHwnd := hwnd
        this.IsChatMode := false
    }

    ; 构造 lParam (完整的 Win32 键盘消息参数)
    _MakeLParam(sc, isDown, keyName) {
        ; Bit 0-15:  Repeat count (1)
        ; Bit 16-23: Scan code
        ; Bit 24:    Extended key flag
        ; Bit 30:    Previous key state (1 for up)
        ; Bit 31:    Transition state (1 for up)
        lParam := 1 | (sc << 16)

        ; 设置扩展键标志
        if InputInjector._extendedKeys.Has(keyName)
            lParam |= (1 << 24)

        if (!isDown)
            lParam |= (1 << 30) | (1 << 31)

        return lParam
    }

    ; 发送后台按键 (PostMessage 物理隔离)
    SendKey(keyName, isDown) {
        hwnd := this.ResolveTarget()
        if (hwnd == 0)
            return

        ; 排除修饰键 (PostMessage 不应发送修饰键状态)
        if (keyName == "Ctrl" || keyName == "Shift" || keyName == "Alt" || keyName == "Win"
            || keyName == "LCtrl" || keyName == "RCtrl" || keyName == "LShift" || keyName == "RShift"
            || keyName == "LAlt" || keyName == "RAlt" || keyName == "LWin" || keyName == "RWin")
            return

        vk := GetKeyVK(keyName)
        sc := GetKeySC(keyName)
        if (!vk)
            return

        ; 如果 GetKeySC 返回 0，用 MapVirtualKey 作为后备
        if (!sc)
            sc := DllCall("MapVirtualKey", "UInt", vk, "UInt", 0, "UInt")

        msg := isDown ? 0x0100 : 0x0101  ; WM_KEYDOWN / WM_KEYUP
        lParam := this._MakeLParam(sc, isDown, keyName)

        try
            PostMessage(msg, vk, lParam, , "ahk_id " hwnd)

        ; 维护按键持有状态表
        if (isDown)
            this._heldKeys[keyName] := true
        else if this._heldKeys.Has(keyName)
            this._heldKeys.Delete(keyName)
    }

    ReleaseAllKeys() {
        if (this._heldKeys.Count == 0)
            return

        ; 先克隆键名列表，再迭代释放 (避免迭代中修改 Map)
        keysToRelease := []
        for key, _ in this._heldKeys
            keysToRelease.Push(key)

        for _, key in keysToRelease
            this.SendKey(key, false)

        this._heldKeys.Clear()
    }
}

; ========================================================
; 引擎基类 (处理时间抖动、用户输入避让、轮询框架)
; ========================================================
class MacroEngineBase {
    IsRunning := false
    App := ""
    BoundTick := ""
    _isYielding := false

    __New(appRef) {
        this.App := appRef
        this.BoundTick := ObjBindMethod(this, "GameLoopTick")
    }

    _SafeInt(val, fallback) {
        if (!IsNumber(val))
            return fallback
        val := Integer(val)
        return (val > 0) ? val : fallback
    }

    _Jitter(baseMs) {
        lo := Integer(baseMs * 0.7)
        hi := Integer(baseMs * 1.3)
        return (lo < 1) ? Random(1, hi) : Random(lo, hi)
    }

    ; 检查用户是否正在物理操作 (仅在目标窗口前台时检测)
    IsUserHoldingKey() {
        ; 先检查鼠标按钮 (最常用)
        if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P"))
            return true

        ; 再检查修饰键
        if (GetKeyState("Shift", "P") || GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P"))
            return true

        ; 最后检查常用游戏按键 (按频率排序，尽早短路)
        static gameKeys := ["w", "a", "s", "d", "Space", "q", "e", "r", "f",
            "1", "2", "3", "4", "5", "Enter", "Esc", "Tab"]
        for k in gameKeys {
            if GetKeyState(k, "P")
                return true
        }
        return false
    }

    ; 检查是否需要避让用户操作
    CheckYield() {
        hwnd := this.App.Injector.ResolveTarget()
        if (hwnd == 0)
            return false
        if (!WinActive("ahk_id " hwnd))
            return false
        if ((A_TimeIdleKeyboard < 800) || this.IsUserHoldingKey())
            return true
        return false
    }

    ; 可中断等待 (用于按键 down→up 之间的间隔)
    WaitOrInterrupt(ms) {
        endTime := A_TickCount + ms
        while (A_TickCount < endTime) {
            if (!this.IsRunning)
                return false
            if (this.CheckYield())
                return false
            Sleep(15)  ; 优化：15ms 已足够精确且大幅降低 CPU 占用
        }
        return true
    }
}

; ========================================================
; UI基类 (处理通用的下拉框悬浮提示、窗口绑定逻辑)
; ========================================================
class MacroUIBase {
    App := ""
    GuiObj := ""
    Ctrl := {}
    _configFile := ""
    _boundCheckHover := ""

    __New(appRef) {
        this.App := appRef
        this.GuiObj := Gui(, "宏控制台")
        this.Ctrl := {}

        ; 使用脚本所在目录构造绝对路径，确保子进程也能正确读写
        this._configFile := A_ScriptDir "\MacroConfig.ini"

        ; 配置保存与清理绑定
        this.GuiObj.OnEvent("Close", (*) => this.OnClose())
        OnExit(ObjBindMethod(this, "SaveConfig"))
    }

    OnClose() {
        this.SaveConfig()
        ExitApp()
    }

    BuildTop(title) {
        this.GuiObj.Title := title
        this.GuiObj.MarginX := 15
        this.GuiObj.MarginY := 15

        ; === 状态区 ===
        this.GuiObj.SetFont("s15 bold", "微软雅黑")
        this.Ctrl.txtStatus := this.GuiObj.Add("Text", "w200 Center cRed", "🔴 等待启动")

        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.txtAction := this.GuiObj.Add("Text", "w200 Center c0066CC y+8", "当前动作: 待命")

        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        keyDisp := StrReplace(this.App.ToggleKey, "^", "Ctrl+")
        this.GuiObj.Add("Text", "w200 Center c888888 y+8", "快捷键: " keyDisp " 启停 | 空格 暂停")

        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")

        ; === 启动按钮 ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.Ctrl.btnToggle := this.GuiObj.Add("Button", "w200 h40 y+15", "▶️ 启动宏 (按 " keyDisp ")")
        this.Ctrl.btnToggle.OnEvent("Click", (*) => this.App.Engine.Toggle())

        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")
    }

    BuildBottom(showRefresh := true) {
        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")

        ; === 窗口绑定 ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 c333333 y+15", "🎯 绑定后台游戏窗口")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.ddlWindow := this.GuiObj.Add("DropDownList", "xs w200 Choose1 y+10", ["🌍 全局前台生效"])
        this.Ctrl.ddlWindow.OnEvent("Change", (*) => this.OnWindowSelect())

        if (showRefresh) {
            btnRefresh := this.GuiObj.Add("Button", "xs w200 h35 y+10", "🔄 刷新窗口列表")
            btnRefresh.OnEvent("Click", (*) => this.RefreshWindowList())
        }

        this.LoadConfig()
        this.RefreshWindowList()
        this._ApplyEmbedding()
    }

    SaveConfig(*) {
        try {
            section := this.GuiObj.Title
            for key, ctrl in this.Ctrl.OwnProps() {
                ; 只保存带存储意图的控件，如 Checkbox, Edit
                if (InStr(key, "chk") == 1 || InStr(key, "edt") == 1) {
                    IniWrite(ctrl.Value, this._configFile, section, key)
                }
            }
        }
    }

    LoadConfig() {
        try {
            section := this.GuiObj.Title
            for key, ctrl in this.Ctrl.OwnProps() {
                if (InStr(key, "chk") == 1 || InStr(key, "edt") == 1) {
                    savedVal := IniRead(this._configFile, section, key, "NOT_FOUND")
                    if (savedVal != "NOT_FOUND") {
                        ctrl.Value := savedVal
                    }
                }
            }
        }
    }

    ; 需要被子类调用的方法，用于支持 SetParent 内嵌
    _ApplyEmbedding() {
        if (A_Args.Length > 0 && IsInteger(A_Args[1])) {
            parentHwnd := Integer(A_Args[1])
            if (parentHwnd == 0) {
                ; 无效句柄，回退到独立窗口模式
                this._ShowStandalone()
                return
            }
            try {
                this.GuiObj.Opt("-Caption -0x80000000 +0x40000000")
                this.GuiObj.BackColor := "FFFFFF"
                DllCall("SetParent", "Ptr", this.GuiObj.Hwnd, "Ptr", parentHwnd)
                this.GuiObj.Show("w230 h780 NoActivate x0 y0")
            } catch {
                this._ShowStandalone()
            }
        } else {
            this._ShowStandalone()
        }

        this._boundCheckHover := ObjBindMethod(this, "CheckHover")
        SetTimer(this._boundCheckHover, 300)  ; 降频到 300ms，减少开销
    }

    _ShowStandalone() {
        MonitorGetWorkArea(1, &workLeft, &workTop, &workRight, &workBottom)
        xPos := workRight - 480
        yPos := workTop + 30
        this.GuiObj.Show("w230 NoActivate x" xPos " y" yPos)
    }

    CheckHover() {
        try {
            ; 前置判断：GUI 不可见时跳过
            if !WinExist("ahk_id " this.GuiObj.Hwnd)
                return

            MouseGetPos(, , &mWin, &mCtrl, 2)
            isHoveringDDL := false
            currentText := ""

            if (this.Ctrl.HasOwnProp("ddlWindow") && mCtrl == this.Ctrl.ddlWindow.Hwnd) {
                isHoveringDDL := true
                currentText := this.Ctrl.ddlWindow.Text
            } else if (mWin) {
                static lastWin := 0, lastClass := ""
                if (mWin != lastWin) {
                    lastWin := mWin
                    try
                        lastClass := WinGetClass(mWin)
                    catch
                        lastClass := ""
                }

                if (lastClass == "ComboLBox") {
                    try {
                        if (WinGetPID(mWin) == WinGetPID(this.GuiObj.Hwnd)) {
                            POINT := Buffer(8)
                            DllCall("GetCursorPos", "Ptr", POINT)
                            DllCall("ScreenToClient", "Ptr", mWin, "Ptr", POINT)
                            cX := NumGet(POINT, 0, "Int")
                            cY := NumGet(POINT, 4, "Int")

                            lParam := (cX & 0xFFFF) | ((cY & 0xFFFF) << 16)
                            res := SendMessage(0x01A9, 0, lParam, , "ahk_id " mWin)
                            if ((res >> 16) == 0) {
                                idx := res & 0xFFFF
                                len := SendMessage(0x018A, idx, 0, , "ahk_id " mWin)
                                if (len > 0) {
                                    buf := Buffer((len + 1) * 2)
                                    SendMessage(0x0189, idx, buf.Ptr, , "ahk_id " mWin)
                                    currentText := StrGet(buf)
                                    isHoveringDDL := true
                                }
                            }
                        }
                    }
                }
            }

            if (isHoveringDDL && currentText != "") {
                if (!this.HasOwnProp("_hoverStart") || this._hoverStart == 0) {
                    this._hoverStart := A_TickCount
                    this._hoverText := currentText
                    this._isTooltipVisible := false
                } else if (this.HasOwnProp("_hoverText") && this._hoverText != currentText) {
                    this._hoverStart := A_TickCount
                    this._hoverText := currentText
                    if (this.HasOwnProp("_isTooltipVisible") && this._isTooltipVisible) {
                        ToolTip()
                        this._isTooltipVisible := false
                    }
                } else if (this.HasOwnProp("_isTooltipVisible") && !this._isTooltipVisible && (A_TickCount - this._hoverStart >
                    600)) {
                    ToolTip(currentText)
                    this._isTooltipVisible := true
                }
            } else {
                if (this.HasOwnProp("_hoverStart") && this._hoverStart != 0) {
                    this._hoverStart := 0
                    this._hoverText := ""
                    if (this.HasOwnProp("_isTooltipVisible") && this._isTooltipVisible) {
                        ToolTip()
                        this._isTooltipVisible := false
                    }
                }
            }
        }
    }

    RefreshWindowList() {
        static macroTitles := ["JS宏", "XS宏", "YX宏"]
        this.App.WinMap.Clear()
        arr := ["🌍 全局前台生效"]

        if (!this.HasOwnProp("BaseTitle"))
            this.BaseTitle := this.GuiObj.Title

        for , hwnd in WinGetList() {
            try {
                title := WinGetTitle(hwnd)
                if (title == "")
                    continue
                skip := false
                for _, mt in macroTitles {
                    if (InStr(title, mt) == 1) {
                        skip := true
                        break
                    }
                }
                if (skip)
                    continue
                pid := WinGetPID(hwnd)
                displayText := title " (PID:" pid ")"
                if this.App.WinMap.Has(displayText)
                    displayText .= " [ID:" hwnd "]"
                arr.Push(displayText)
                this.App.WinMap[displayText] := hwnd
            }
        }

        this.Ctrl.ddlWindow.Delete()
        this.Ctrl.ddlWindow.Add(arr)
        this.Ctrl.ddlWindow.Choose(1)
        this.App.Injector.SetTarget(0)
        this.GuiObj.Title := this.BaseTitle
        this.UpdateAction("🔄 列表已重置")
    }

    OnWindowSelect() {
        this.App.Injector.ReleaseAllKeys()

        if (!this.HasOwnProp("BaseTitle"))
            this.BaseTitle := this.GuiObj.Title

        selected := this.Ctrl.ddlWindow.Text
        if (selected == "🌍 全局前台生效") {
            this.App.Injector.SetTarget(0)
            this.GuiObj.Title := this.BaseTitle
        } else if this.App.WinMap.Has(selected) {
            this.App.Injector.SetTarget(this.App.WinMap[selected])
            shortTitle := RegExReplace(selected, " \(PID:.*\).*$", "")
            this.GuiObj.Title := this.BaseTitle " - " shortTitle
        }

        this.UpdateAction("🔄 已切换目标")
    }

    UpdateStatus(isRunning) {
        keyDisp := StrReplace(this.App.ToggleKey, "^", "Ctrl+")
        try {
            if (isRunning) {
                if (this.Ctrl.txtStatus.Value != "🟢 后台运行中...") {
                    this.Ctrl.txtStatus.Value := "🟢 后台运行中..."
                    this.Ctrl.txtStatus.Opt("cGreen")
                    this.Ctrl.btnToggle.Text := "⏹️ 停止宏 (按 " keyDisp ")"
                }
            } else {
                if (this.Ctrl.txtStatus.Value != "🔴 等待启动") {
                    this.Ctrl.txtStatus.Value := "🔴 等待启动"
                    this.Ctrl.txtStatus.Opt("cRed")
                    this.UpdateAction("当前动作: 待命")
                    this.Ctrl.btnToggle.Text := "▶️ 启动宏 (按 " keyDisp ")"
                }
            }
        }
    }

    UpdateAction(text) {
        try {
            if (this.Ctrl.txtAction.Value != text)
                this.Ctrl.txtAction.Value := text
        }
    }
}

; ========================================================
; App 基类 (热键注册)
; ========================================================
class GameMacroAppBase {
    Injector := ""
    Engine := ""
    UI := ""
    WinMap := Map()
    ToggleKey := ""
    _boundToggle := ""
    _boundSpace := ""

    __New(EngineClass, UIClass, toggleKey := "^z") {
        this.Injector := InputInjector()
        this.ToggleKey := toggleKey
        this.Engine := EngineClass(this)
        this.UI := UIClass(this)

        this._boundToggle := ObjBindMethod(this, "OnHotKeyToggle")
        this._boundSpace := ObjBindMethod(this, "OnSpacePause")
        Hotkey("~" . toggleKey, this._boundToggle, "S")
        if (IsInteger(toggleKey)) {
            Hotkey("~Numpad" . toggleKey, this._boundToggle, "S")
        }
        Hotkey("~Space", this._boundSpace, "S")

        ; Chat Mode hooks
        Hotkey("~Enter", ObjBindMethod(this, "OnEnterPress"), "S")
        Hotkey("~NumpadEnter", ObjBindMethod(this, "OnEnterPress"), "S")
        Hotkey("~Esc", ObjBindMethod(this, "OnEscPress"), "S")
    }

    OnHotKeyToggle(*) {
        Critical("On")  ; 保护状态切换的原子性
        if (A_ThisHotkey != "") {
            pressedKey := RegExReplace(A_ThisHotkey, "^[~*$^+!#]+")
            KeyWait(pressedKey)
        }
        this.Engine.Toggle()
        Critical("Off")
    }

    OnSpacePause(*) {
        if (this.Injector.TargetHwnd != 0 && !WinActive("ahk_id " this.Injector.TargetHwnd))
            return
        if (this.UI.Ctrl.HasOwnProp("chkSpacePause") && this.UI.Ctrl.chkSpacePause.Value == 1 && this.Engine.IsRunning)
            this.Engine.Stop()
    }

    OnEnterPress(*) {
        if (this.Injector.TargetHwnd != 0 && !WinActive("ahk_id " this.Injector.TargetHwnd))
            return
        Critical("On")  ; 保护聊天状态切换
        this.Injector.IsChatMode := !this.Injector.IsChatMode
        if (!this.Injector.IsChatMode && this.Engine.IsRunning) {
            this.UI.UpdateAction("🔄 从聊天状态恢复")
            this.Injector.ReleaseAllKeys()
        }
        Critical("Off")
    }

    OnEscPress(*) {
        if (this.Injector.TargetHwnd != 0 && !WinActive("ahk_id " this.Injector.TargetHwnd))
            return
        Critical("On")  ; 保护聊天状态切换
        if (this.Injector.IsChatMode) {
            this.Injector.IsChatMode := false
            if (this.Engine.IsRunning) {
                this.UI.UpdateAction("🔄 取消聊天，状态恢复")
                this.Injector.ReleaseAllKeys()
            }
        }
        Critical("Off")
    }
}
