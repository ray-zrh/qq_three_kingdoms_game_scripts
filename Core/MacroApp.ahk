; ========================================================
; App 基类 (热键注册)
; ========================================================
class GameMacroAppBase {
    Config := ""
    InputManager := ""
    SyncManager := ""
    Engine := ""
    UI := ""
    ToggleKey := ""
    FocusKey := ""
    _boundToggle := ""
    _boundFocus := ""
    _HotkeysEnabled := true   ; 全局热键使能开关 (通过 = 键切换)

    __New(EngineClass, UIClass, toggleKey, focusKey := "", config := "") {
        GameMacroAppBase.InitializeEnvironment()
        this.InputManager := InputManager()
        this.SyncManager := SyncManager(this)
        this.ToggleKey := toggleKey
        this.FocusKey := focusKey
        if (config != "")
            this.Config := config
        this.Engine := EngineClass(this)
        this.UI := UIClass(this)
        this.UI.ComputeOriginalLayout()
        this.UI.ReflowUI()
        this.UI._ApplyEmbedding()

        this._boundToggle := ObjBindMethod(this, "OnHotKeyToggle")

        ; 注册全局热键开关 (= 键)，必须在 QQ 三国窗口生效
        HotIf((*) => this._IsGameWindowActive())
        Hotkey("~;", ObjBindMethod(this, "OnToggleAllHotkeys"), "S")
        HotIf()

        ; 1. 注册聚焦热键 (受开关控制)
        if (this.FocusKey != "") {
            this._boundFocus := ObjBindMethod(this, "OnFocusTarget")
            HotIf((*) => this._IsGameWindowActive() && this._HotkeysEnabled)

            ; 注册主键盘按键
            Hotkey("$" . this.FocusKey, this._boundFocus, "S")

            ; 如果是数字键，额外注册小键盘按键
            if (IsInteger(this.FocusKey)) {
                try Hotkey("$Numpad" . this.FocusKey, this._boundFocus, "S")
            }
            HotIf()
        }

        ; 2. 注册控制热键 (启停)
        HotIf((*) => this._IsGameWindowActive() && this._HotkeysEnabled)
        Hotkey("$" . toggleKey, this._boundToggle, "S")
        if (IsInteger(toggleKey)) {
            Hotkey("$Numpad" . toggleKey, this._boundToggle, "S")
        }

        ; 3. 注册 RShift + ToggleKey 用于切换同步功能
        Hotkey(">+" . toggleKey, ObjBindMethod(this.SyncManager, "OnToggleSync"), "S")
        if (IsInteger(toggleKey)) {
            try Hotkey(">+Numpad" . toggleKey, ObjBindMethod(this.SyncManager, "OnToggleSync"), "S")
        }
        HotIf()

        ; 4. 注册 "5" 键用于切换鼠标同步模式 (解绑条件限制，允许随时切换开关状态)
        HotIf((*) => this._IsGameWindowActive() && this._HotkeysEnabled)
        Hotkey("~5", ObjBindMethod(this.SyncManager, "OnToggleMouseSync"), "S")
        try Hotkey("~Numpad5", ObjBindMethod(this.SyncManager, "OnToggleMouseSync"), "S")
        HotIf()

        ; 5. 左 Shift 的状态拦截 (传递给 SyncManager)
        HotIf((*) => this._IsGameWindowActive() && this._HotkeysEnabled)
        Hotkey("~*LShift", ObjBindMethod(this.SyncManager, "OnShiftDown"), "S")
        Hotkey("~*LShift up", ObjBindMethod(this.SyncManager, "OnShiftUp"), "S")
        HotIf()
    }

    ; 聚焦键判定：仅在任何已识别的游戏窗口活动时生效
    _IsGameWindowActive() {
        return this.InputManager.IsGameWindowActive() || WinActive("QQ三国 ahk_exe QQ三国.exe") || WinActive(
            "QQ三国 ahk_exe QQSG.exe")
    }

    ; 控制键判定：UI 活动 OR 绑定的目标窗口活动
    _IsControlKeyActive() {
        try {
            if WinActive(this.UI.GuiObj.Hwnd)
                return true
        }
        targetHwnd := this.InputManager.TargetHwnd
        return (targetHwnd && WinActive(targetHwnd))
    }

    OnToggleAllHotkeys(*) {
        this._HotkeysEnabled := !this._HotkeysEnabled
        this.UI.UpdateMasterStatus()
    }

    OnHotKeyToggle(*) {
        Critical("On")  ; 保护状态切换的原子性
        if (A_ThisHotkey != "") {
            pressedKey := RegExReplace(A_ThisHotkey, "^[~*$^+!#<>]+")
            KeyWait(pressedKey)
        }
        this.Engine.Toggle()
        Critical("Off")
    }

    ; ========================================================
    ; 远程热键逻辑 (无需 Shift 即可跨窗触发)
    ; ========================================================
    RegisterRemoteHotkey(triggerKey, targetKey) {
        cbDown := (*) => this._OnRemoteKey(targetKey, true)
        cbUp := (*) => this._OnRemoteKey(targetKey, false)

        HotIf((*) => this._IsGameWindowActive() && this._HotkeysEnabled)
        Hotkey("~*" . triggerKey, cbDown, "S")
        Hotkey("~*" . triggerKey . " up", cbUp, "S")
        HotIf()
    }

    _OnRemoteKey(targetKey, isDown) {
        ; 只有在绑定了窗口，且当前【不是】活动窗口时才触发
        ; (即：在操作其他角色时触发本角色的特定技能)
        if (this.InputManager.TargetHwnd == 0 || WinActive(this.InputManager.TargetHwnd))
            return

        this.InputManager.SendKey(targetKey, isDown)
    }

    OnFocusTarget(*) {
        static lastFocusTime := 0
        static isFocusing := false
        static hFocusMutex := 0

        ; 1. 预初始化全局锁句柄 (持久化以提升性能)
        if (!hFocusMutex)
            hFocusMutex := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "AHK_QQSanguo_FocusMutex", "Ptr")

        ; 2. 极致响应：防抖时间缩短至 50ms
        if (isFocusing || A_TickCount - lastFocusTime < 50)
            return

        ; 3. 核心优化：增加等待时间 (500ms)，允许进程排队切换，解决“打架”问题
        if (DllCall("WaitForSingleObject", "Ptr", hFocusMutex, "UInt", 500) != 0)
            return

        isFocusing := true
        lastFocusTime := A_TickCount

        ; 提取当前按键名称 (处理 $0, $- 等前缀)
        pressedKey := (A_ThisHotkey != "") ? RegExReplace(A_ThisHotkey, "^[~*$^+!#<>]+") : ""

        try {
            targetHwnd := this.InputManager.TargetHwnd

            ; 检查是否绑定了窗口
            if (targetHwnd == 0 || !WinExist(targetHwnd))
                return

            ; 极速路径：已激活则瞬间退出
            if WinActive(targetHwnd)
                return

            ; 开启 Critical 保护激活序列不被干扰
            Critical("On")

            ; 1. 核心权限修复：授权并解锁前台权限
            DllCall("AllowSetForegroundWindow", "Int", -1) ; ASFW_ANY
            DllCall("LockSetForegroundWindow", "UInt", 2)   ; LSFW_UNLOCK

            ; 2. 消除锁定超时 (消除红闪的关键)
            ; SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000, SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001
            origTimeout := 0
            DllCall("SystemParametersInfo", "UInt", 0x2000, "UInt", 0, "Ptr*", &origTimeout, "UInt", 0)
            DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", 0, "UInt", 2) ; 设置为 0ms

            ; 3. 恢复最小化窗口
            if (WinGetMinMax(targetHwnd) == -1)
                WinRestore(targetHwnd)

            ; 4. 强力激活序列 (SwitchToThisWindow + SetForegroundWindow)
            ; SwitchToThisWindow 是最接近 Alt-Tab 的原生切换方式
            DllCall("User32\SwitchToThisWindow", "Ptr", targetHwnd, "Int", 1)

            foreHwnd := DllCall("GetForegroundWindow", "Ptr")
            if (foreHwnd != targetHwnd) {
                foreThreadID := DllCall("GetWindowThreadProcessId", "Ptr", foreHwnd, "Ptr", 0, "UInt")
                targetThreadID := DllCall("GetWindowThreadProcessId", "Ptr", targetHwnd, "Ptr", 0, "UInt")
                thisThreadID := DllCall("GetCurrentThreadId", "UInt")

                if (foreThreadID != targetThreadID) {
                    DllCall("AttachThreadInput", "UInt", thisThreadID, "UInt", foreThreadID, "Int", 1)
                    DllCall("SetForegroundWindow", "Ptr", targetHwnd)
                    DllCall("BringWindowToTop", "Ptr", targetHwnd)
                    DllCall("AttachThreadInput", "UInt", thisThreadID, "UInt", foreThreadID, "Int", 0)
                } else {
                    DllCall("SetForegroundWindow", "Ptr", targetHwnd)
                }
            }

            ; 5. AHK 内部状态同步
            WinActivate(targetHwnd)

            ; 恢复原始锁定超时
            DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", origTimeout, "UInt", 2)

        } catch {
            ; 异常不处理以保持速度
        } finally {
            ; 核心性能优化：激活逻辑结束立即释放锁，允许其他进程立即接管
            DllCall("ReleaseMutex", "Ptr", hFocusMutex)

            ; 等待物理按键释放，防止连发导致激活循环
            if (pressedKey != "")
                KeyWait(pressedKey)

            isFocusing := false
            lastFocusTime := A_TickCount ; 释放后再更新时间，确保冷却
            Critical("Off")
        }
    }

    ; (SyncManager now handles all shift, sync, and mouse sync logic)

    static InitializeEnvironment() {
        static initialized := false
        if (initialized)
            return

        ProcessSetPriority("High")
        SetWorkingDir(A_ScriptDir)
        SetTitleMatchMode(2)  ; 模式2：包含即可
        SetWinDelay(-1)       ; 极致速度：移除窗口操作延迟

        ; 关键优化：允许抢占焦点，防止任务栏图标闪烁
        ; SPI_SETFOREGROUNDLOCKTIMEOUT (0x2001), 设为 0 表示立即允许切换前台
        DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", 0, "UInt", 2)

        initialized := true
    }

    ; ========================================================
    ; 配置驱动的一键启动入口
    ; ========================================================
    static LaunchFromConfig(config) {
        app := GameMacroAppBase(ConfigMacroEngine, ConfigMacroUI, config.ToggleKey, config.FocusKey, config)

        ; 注册远程热键 (如 XS 的 Z→Q 映射)
        if (config.RemoteHotkeys.Length > 0) {
            for _, rh in config.RemoteHotkeys
                app.RegisterRemoteHotkey(rh.Trigger, rh.Target)
        }

        return app
    }
}
