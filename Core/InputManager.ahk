; ========================================================
; 底层输入与窗口管理器 (负责键鼠消息发送与多开窗口追踪)
; ========================================================
class InputManager {
    TargetHwnd := 0
    WinMap := Map()
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

    ; ========================================================
    ; 窗口管理 API
    ; ========================================================

    ; 刷新当前系统中的所有 QQ 三国窗口列表
    RefreshWindowList() {
        static macroTitles := ["JS宏", "XS宏", "YX宏", "HL宏"]
        this.WinMap.Clear()
        arr := ["🌍 全局前台生效"]

        for , hwnd in WinGetList() {
            try {
                title := WinGetTitle(hwnd)
                if (title == "")
                    continue
                
                ; 过滤掉宏自己的控制台窗口
                skip := false
                for _, mt in macroTitles {
                    if (InStr(title, mt) == 1) {
                        skip := true
                        break
                    }
                }
                if (skip)
                    continue
                
                if (InStr(title, "QQ三国")) {
                    pid := WinGetPID(hwnd)
                    displayText := title " (PID:" pid ")"
                    if this.WinMap.Has(displayText)
                        displayText .= " [ID:" hwnd "]"
                    arr.Push(displayText)
                    this.WinMap[displayText] := hwnd
                }
            }
        }
        return arr
    }

    ; 判断当前活跃窗口是否为已知的 QQ 三国窗口
    IsGameWindowActive() {
        activeHwnd := WinActive("A")
        if (activeHwnd == 0)
            return false

        for displayText, hwnd in this.WinMap {
            if (activeHwnd == hwnd && InStr(displayText, "QQ三国"))
                return true
        }
        return false
    }

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
    }

    ; 构造 lParam (完整的 Win32 键盘消息参数)
    _MakeLParam(sc, isDown, keyName, isRepeat := false) {
        ; Bit 0-15:  Repeat count (1)
        ; Bit 16-23: Scan code
        ; Bit 24:    Extended key flag
        ; Bit 30:    Previous key state (1 for down, 0 for up)
        ; Bit 31:    Transition state (0 for down, 1 for up)
        lParam := 1 | (sc << 16)

        ; 设置扩展键标志
        if InputManager._extendedKeys.Has(keyName)
            lParam |= (1 << 24)

        if (isRepeat)
            lParam |= (1 << 30)

        if (!isDown)
            lParam |= (1 << 30) | (1 << 31)

        return lParam
    }

    ; 发送后台按键 (PostMessage 物理隔离)
    SendKey(keyName, isDown, isRepeat := false) {
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
        lParam := this._MakeLParam(sc, isDown, keyName, isRepeat)

        try {
            ; 极致性能优化：使用原生 DllCall 跳过 AHK 内部针对 ahk_id 字符串的二次解析与窗口查找逻辑
            DllCall("PostMessageW", "Ptr", hwnd, "UInt", msg, "Ptr", vk, "Ptr", lParam)
            
            ; 核心优化：在高频发送时，给予 Windows 消息队列一个极微小的处理窗口（1ms）
            ; 这能显著提升 PostMessage 的到达顺序稳定性，防止 Down/Up 消息在游戏端由于处理延迟而颠倒
            DllCall("Sleep", "UInt", 1)
        }

        ; 维护按键持有状态表
        if (isDown)
            this._heldKeys[keyName] := true
        else if this._heldKeys.Has(keyName)
            this._heldKeys.Delete(keyName)
    }

    ; 发送后台鼠标点击 (PostMessage 物理隔离)
    ; @param x, y: 相对于目标窗口客户区的坐标
    ; @param button: "L" 左键 或 "R" 右键
    ; @param isDown: true=按下, false=抬起
    SendMouseClick(x, y, button := "L", isDown := true, isDoubleClick := false) {
        hwnd := this.ResolveTarget()
        if (hwnd == 0)
            return

        ; 如果是双击的第二次按下操作，必须显式发送 DBLCLK 消息
        ; (因为我们之前为了支持鼠标拖拽，是将 Down 和 Up 拆开发送的，
        ; 导致系统无法在后台自动合并成双击)
        if (isDoubleClick) {
            lParam := (x & 0xFFFF) | ((y & 0xFFFF) << 16)
            msg := (button == "L") ? 0x0203 : 0x0206     ; WM_LBUTTONDBLCLK / WM_RBUTTONDBLCLK
            wParam := (button == "L") ? 0x0001 : 0x0002  ; MK_LBUTTON / MK_RBUTTON
            
            ; 极致性能优化：使用原生 DllCall
            try DllCall("PostMessageW", "Ptr", hwnd, "UInt", msg, "Ptr", wParam, "Ptr", lParam)
            return
        }

        ; 普通的单击或拖拽
        ; 使用 ControlClick 代替纯 PostMessage，因为 ControlClick 内部会自动处理
        ; NCHITTEST 和 SETCURSOR 等一些游戏引擎需要的附带消息，成功率更高。
        ; NA 选项确保不会意外激活后台窗口
        ; 极致性能优化：使用原生 hwnd 整数而非 "ahk_id " 拼接字符串，极大降低 CPU 消耗
        options := "NA " (isDown ? "D" : "U")
        try ControlClick("x" x " y" y, hwnd, , button, 1, options)
    }

    ; 发送后台鼠标移动 (PostMessage 物理隔离)
    ; @param x, y: 相对于目标窗口客户区的坐标
    SendMouseMove(x, y) {
        hwnd := this.ResolveTarget()
        if (hwnd == 0)
            return

        lParam := (x & 0xFFFF) | ((y & 0xFFFF) << 16)
        
        ; 许多游戏引擎需要完整的鼠标消息链才能识别移动
        try {
            ; 极致性能优化：避免 AHK 内部高频循环中三次寻找窗口
            DllCall("PostMessageW", "Ptr", hwnd, "UInt", 0x0084, "Ptr", 0, "Ptr", lParam) ; WM_NCHITTEST
            DllCall("PostMessageW", "Ptr", hwnd, "UInt", 0x0020, "Ptr", hwnd, "Ptr", (0x0200 << 16) | 1) ; WM_SETCURSOR
            DllCall("PostMessageW", "Ptr", hwnd, "UInt", 0x0200, "Ptr", 0, "Ptr", lParam)  ; WM_MOUSEMOVE
        }
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
