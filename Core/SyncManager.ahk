; ========================================================
; 同步操作控制器 (负责跨窗口的键鼠事件拦截与广播分发)
; ========================================================
class SyncManager {
    App := ""
    SyncKeyMap := Map()  ; 同步按键映射表 (用于实现如 Z -> E 的跨窗触发)

    _syncHook := ""
    _isShiftSyncing := false
    _isSyncEnabled := false
    _isMouseSyncEnabled := false  ; 鼠标同步子开关 (仅在操作同步模式开启时可用)
    _isMouseSyncRunning := false  ; 内部实际运行状态

    _boundMouseMoveTick := ""      ; 鼠标移动轮询定时器回调
    _lastMouseX := -1
    _lastMouseY := -1
    _lastClickTime := 0            ; 记录上次点击的时间 (用于双击判定)
    _lastClickButton := ""         ; 记录上次点击的按键
    _lastSyncTime := 0

    __New(AppRef) {
        this.App := AppRef

        ; 初始化 Ctrl/Shift 等同步键盘钩子 (多窗同步)
        this._syncHook := InputHook("V")
        this._syncHook.KeyOpt("{All}", "N")
        this._syncHook.OnKeyDown := (hook, vk, sc) => this.OnSyncKey(vk, sc, true)
        this._syncHook.OnKeyUp := (hook, vk, sc) => this.OnSyncKey(vk, sc, false)

        ; 预注册鼠标同步热键 (初始关闭，由 _StartMouseSync 开启)
        this._mouseHotIfFn := (*) => this.App.InputManager.IsGameWindowActive()
        this._boundMouseLDown := ObjBindMethod(this, "_OnMouseSync", "L", true)
        this._boundMouseLUp := ObjBindMethod(this, "_OnMouseSync", "L", false)
        this._boundMouseRDown := ObjBindMethod(this, "_OnMouseSync", "R", true)
        this._boundMouseRUp := ObjBindMethod(this, "_OnMouseSync", "R", false)

        HotIf(this._mouseHotIfFn)
        Hotkey("~*LButton", this._boundMouseLDown, "Off")
        Hotkey("~*LButton up", this._boundMouseLUp, "Off")
        Hotkey("~*RButton", this._boundMouseRDown, "Off")
        Hotkey("~*RButton up", this._boundMouseRUp, "Off")
        HotIf()
    }

    ; ========================================================
    ; Shift 同步逻辑与状态分发
    ; ========================================================
    OnShiftDown(*) {
        if (this._isShiftSyncing)
            return

        ; 核心逻辑：只有在游戏窗口活动且热键启用时，才允许响应 Shift
        if (!this.App.InputManager.IsGameWindowActive() || !this.App._HotkeysEnabled)
            return

        this._isShiftSyncing := true
        this._UpdateSyncState()
    }

    OnShiftUp(*) {
        if (!this._isShiftSyncing)
            return

        this._isShiftSyncing := false
        this._UpdateSyncState()
    }

    OnToggleSync(*) {
        this._isSyncEnabled := !this._isSyncEnabled

        this._UpdateSyncState()

        if (this.App.UI.Ctrl.HasOwnProp("chkShiftSync"))
            this.App.UI.Ctrl.chkShiftSync.Value := this._isSyncEnabled

        this.App.UI.UpdateSyncDisplay()
    }

    OnToggleMouseSync(*) {
        this._isMouseSyncEnabled := !this._isMouseSyncEnabled
        this._UpdateSyncState()
        this.App.UI.UpdateSyncDisplay()
    }

    ; 统一的同步状态更新与分发入口
    _UpdateSyncState() {
        isGameActive := this.App.InputManager.IsGameWindowActive()
        isHotkeysOn := this.App._HotkeysEnabled

        ; 1. 计算期望的键盘同步状态
        wantKeyboard := (this._isSyncEnabled != this._isShiftSyncing)
        if (!isHotkeysOn || !isGameActive)
            wantKeyboard := false

        ; 2. 计算期望的鼠标同步状态
        wantMouse := false
        if (isHotkeysOn && isGameActive) {
            if (this._isSyncEnabled) {
                ; 开启操作同步模式时：
                ; 如果按了 Shift，则暂停所有同步 (包括鼠标，返回 false)
                ; 如果没按 Shift，则看 _isMouseSyncEnabled 开关
                wantMouse := this._isShiftSyncing ? false : this._isMouseSyncEnabled
            } else {
                ; 关闭操作同步模式时：
                ; 如果按了 Shift，则临时全局开启同步 (若鼠标同步开启，则一并同步)
                wantMouse := this._isShiftSyncing ? this._isMouseSyncEnabled : false
            }
        }

        ; 3. 应用键盘钩子状态
        if (wantKeyboard && !this._syncHook.InProgress)
            this._syncHook.Start()
        else if (!wantKeyboard && this._syncHook.InProgress)
            this._syncHook.Stop()

        ; 4. 应用鼠标同步状态
        if (wantMouse && !this._isMouseSyncRunning) {
            this._StartMouseSync()
            this._isMouseSyncRunning := true
        } else if (!wantMouse && this._isMouseSyncRunning) {
            this._StopMouseSync()
            this._isMouseSyncRunning := false
        }
    }

    ; ========================================================
    ; 键盘事件处理
    ; ========================================================
    OnSyncKey(vk, sc, isDown) {
        ; 1. 安全检查: 必须有绑定窗口
        targetHwnd := this.App.InputManager.TargetHwnd
        if (targetHwnd == 0)
            return

        ; 2. 避免自我同步: 如果目标窗口正好是当前活跃窗口，跳过
        if WinActive(targetHwnd)
            return

        ; 3. 获取按键名
        keyName := GetKeyName(Format("vk{:x}sc{:x}", vk, sc))

        ; 过滤特定的数字行按键 (1234567890-=)，防止同步发送到后台触发其他多开的宏或物品
        if RegExMatch(keyName, "^[0-9\-\=]$")
            return

        ; 4. 检查映射逻辑: 如果存在同步映射，则转换按键 (例如 Z -> E)
        if (this.SyncKeyMap.Has(keyName)) {
            keyName := this.SyncKeyMap[keyName]
        }

        ; 记录同步时间点，供 CheckYield 判定避让 (未来给自动化引擎用)
        this._lastSyncTime := A_TickCount
        this.App.InputManager.SendKey(keyName, isDown)
    }

    ; ========================================================
    ; 鼠标事件处理
    ; ========================================================
    _StartMouseSync() {
        HotIf(this._mouseHotIfFn)
        Hotkey("~*LButton", , "On")
        Hotkey("~*LButton up", , "On")
        Hotkey("~*RButton", , "On")
        Hotkey("~*RButton up", , "On")
        HotIf()

        this._lastMouseX := -1
        this._lastMouseY := -1
        this._boundMouseMoveTick := ObjBindMethod(this, "_OnMouseMoveTick")
        SetTimer(this._boundMouseMoveTick, 16)
    }

    _StopMouseSync() {
        if (this._boundMouseMoveTick)
            SetTimer(this._boundMouseMoveTick, 0)

        HotIf(this._mouseHotIfFn)
        Hotkey("~*LButton", , "Off")
        Hotkey("~*LButton up", , "Off")
        Hotkey("~*RButton", , "Off")
        Hotkey("~*RButton up", , "Off")
        HotIf()
    }

    _OnMouseSync(button, isDown, *) {
        targetHwnd := this.App.InputManager.TargetHwnd
        if (targetHwnd == 0)
            return

        if WinActive(targetHwnd)
            return

        prevMode := CoordMode("Mouse", "Client")
        MouseGetPos(&cx, &cy)
        CoordMode("Mouse", prevMode)

        ; 双击判定逻辑
        isDoubleClick := false
        if (isDown) {
            dblClickTime := DllCall("GetDoubleClickTime", "UInt")
            if (this._lastClickButton == button && (A_TickCount - this._lastClickTime) <= dblClickTime) {
                isDoubleClick := true
                this._lastClickTime := 0
            } else {
                this._lastClickButton := button
                this._lastClickTime := A_TickCount
            }
        }

        this._lastSyncTime := A_TickCount
        this.App.InputManager.SendMouseClick(cx, cy, button, isDown, isDoubleClick)
    }

    _OnMouseMoveTick() {
        targetHwnd := this.App.InputManager.TargetHwnd
        if (targetHwnd == 0)
            return

        if WinActive(targetHwnd)
            return

        if (!this.App.InputManager.IsGameWindowActive())
            return

        prevMode := CoordMode("Mouse", "Client")
        MouseGetPos(&cx, &cy)
        CoordMode("Mouse", prevMode)

        if (cx != this._lastMouseX || cy != this._lastMouseY) {
            this._lastMouseX := cx
            this._lastMouseY := cy
            this.App.InputManager.SendMouseMove(cx, cy)
        }
    }
}
