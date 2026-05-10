; ========================================================
; UI基类 (处理通用的下拉框悬浮提示、窗口绑定逻辑)
; ========================================================
class MacroUIBase {
    App := ""
    GuiObj := ""
    Ctrl := {}
    _configFile := ""
    _boundCheckHover := ""
    Settings := Map()
    PanelStates := Map()
    IsBuilding := false
    PreferredX := 0 ; 默认偏移量 (相对右侧)
    PreferredY := 30
    PreferredPos := "xCenter yCenter" ; 默认居中显示
    SavedX := ""
    SavedY := ""
    BaseTitle := ""
    Headers := Map()
    OriginalLayout := []
    PanelBounds := Map()

    __New(appRef, title) {
        this.App := appRef
        this.BaseTitle := title
        this.GuiObj := Gui(, title)
        this.Ctrl := {}
        this.Settings := Map()
        this.PanelStates := Map()
        this.Headers := Map()
        this.OriginalLayout := []
        this.PanelBounds := Map()

        this._configFile := A_ScriptDir "\MacroConfig.ini"

        this.LoadConfigToSettings()

        this.GuiObj.OnEvent("Close", (*) => this.OnClose())
        OnExit(ObjBindMethod(this, "SaveConfig"))
    }

    OnClose() {
        if (this.App) {
            if (this.App.Engine)
                this.App.Engine.Stop()
            if (this.App.InputManager)
                this.App.InputManager.ReleaseAllKeys()
        }
        this.SaveConfig()
        ExitApp()
    }

    GetVal(key, defaultVal := 0) {
        ; 1. 优先尝试从 UI 控件当前状态读取 (确保实时性)
        if (!this.IsBuilding) {
            try {
                if (this.Ctrl.HasOwnProp(key)) {
                    val := this.Ctrl.%key%.Value
                    ; 同步更新 Settings Map，确保后续逻辑读取一致
                    this.Settings[key] := val
                    return val
                }
            }
        }

        ; 2. 其次才从缓存的配置文件（Settings Map）中读取
        if this.Settings.Has(key)
            return this.Settings[key]

        return defaultVal
    }

    SetVal(key, val) {
        this.Settings[key] := val
        if this.Ctrl.HasOwnProp(key)
            this.Ctrl.%key%.Value := val
    }

    SyncSettings() {
        for key, ctrl in this.Ctrl.OwnProps() {
            if (InStr(key, "chk") == 1 || InStr(key, "edt") == 1) {
                try this.Settings[key] := ctrl.Value
            }
        }
    }

    LoadConfigToSettings() {
        try {
            section := this.BaseTitle ? this.BaseTitle : "宏控制台"
            saved := IniRead(this._configFile, section, , "")
            loop parse, saved, "`n", "`r" {
                if (RegExMatch(A_LoopField, "^([^=]+)=(.*)$", &m))
                    this.Settings[m[1]] := m[2]
            }
        }
    }

    SaveConfig(*) {
        try {
            if (this.App) {
                if (this.App.Engine)
                    this.App.Engine.Stop()
                if (this.App.InputManager)
                    this.App.InputManager.ReleaseAllKeys()
            }
            this.SyncSettings()
            section := this.BaseTitle ? RegExReplace(this.BaseTitle, " - .*") : "宏控制台"
            for key, val in this.Settings {
                IniWrite(val, this._configFile, section, key)
            }
        }
    }

    AddPanelHeader(panelId, title, defaultOpen := false) {
        if !this.PanelStates.Has(panelId)
            this.PanelStates[panelId] := defaultOpen

        isOpen := this.PanelStates[panelId]
        icon := isOpen ? "▼" : "▶"

        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        btn := this.GuiObj.Add("Text", "w200 c333333 BackgroundTrans y+15", icon " " title)
        btn.OnEvent("Click", (*) => this.TogglePanel(panelId))

        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Headers[panelId] := btn
        return true
    }

    TogglePanel(panelId) {
        this.PanelStates[panelId] := !this.PanelStates[panelId]
        isOpen := this.PanelStates[panelId]
        icon := isOpen ? "▼ " : "▶ "
        text := this.Headers[panelId].Value
        this.Headers[panelId].Value := icon . SubStr(text, 3)
        this.ReflowUI()
    }

    ComputeOriginalLayout() {
        this.OriginalLayout := []
        currentPanel := "TOP"

        for hwnd, ctrl in this.GuiObj {
            ctrl.GetPos(&x, &y, &w, &h)

            isHeader := false
            for pid, hCtrl in this.Headers {
                if (hCtrl.Hwnd == ctrl.Hwnd) {
                    currentPanel := pid
                    isHeader := true
                    break
                }
            }

            this.OriginalLayout.Push({
                Ctrl: ctrl,
                OrigY: y,
                OrigH: h,
                PanelId: currentPanel,
                IsHeader: isHeader
            })
        }

        this.PanelBounds := Map()
        for pid in this.PanelStates {
            minY := 999999
            maxY := 0
            for item in this.OriginalLayout {
                if (item.PanelId == pid && !item.IsHeader) {
                    if (item.OrigY < minY)
                        minY := item.OrigY
                    if (item.OrigY + item.OrigH > maxY)
                        maxY := item.OrigY + item.OrigH
                }
            }
            if (maxY > minY) {
                this.PanelBounds[pid] := { MinY: minY, MaxY: maxY, Height: maxY - minY + 15 }
            } else {
                this.PanelBounds[pid] := { MinY: 0, MaxY: 0, Height: 0 }
            }
        }
    }

    ; ========================================================
    ; 通用 UI 面板构建组件
    ; ========================================================
    BuildBasicPanel(aKeyText := "🗡️ 仅使用 [ A ] 普攻模式", defaultA := 0) {
        if this.AddPanelHeader("Basic", "⚙️ 基础设置", false) {
            this.Ctrl.chkA := this.GuiObj.Add("Checkbox", "w200 y+10", aKeyText)
            if this.HasMethod("_OnToggleA")
                this.Ctrl.chkA.OnEvent("Click", (*) => this._OnToggleA())
            this.Ctrl.chkA.Value := this.GetVal("chkA", defaultA)
        }
        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")
    }

    BuildCycleSkillsPanel(skillConfigs := "") {
        ; 兼容旧调用方式：如果传入的不是数组，使用默认 S/D/F/Q
        if (!IsObject(skillConfigs) || skillConfigs == "") {
            skillConfigs := [{ Name: "S", Key: "s", DefaultDur: 2 }, { Name: "D", Key: "d", DefaultDur: 10 }, { Name: "F",
                Key: "f", DefaultDur: 3 }, { Name: "Q", Key: "q", DefaultDur: 2 }
            ]
        }

        ; 构建面板标题 (动态生成 S→D→F→Q 显示)
        titleParts := ""
        for idx, s in skillConfigs {
            titleParts .= (idx > 1 ? "→" : "") . s.Name
        }

        if this.AddPanelHeader("Skills", "⚔️ 技能循环 (" titleParts ")", false) {
            this.Ctrl.chkSelectAll := this.GuiObj.Add("Checkbox", "w200 Check3 y+10", "全选 / 取消技能组")
            this.Ctrl.chkSelectAll.Value := this.GetVal("chkSelectAll", 1)
            this.Ctrl.chkSelectAll.OnEvent("Click", (*) => this._OnToggleSelectAll())

            this._skillCheckboxes := []
            this._cycleSkillKeys := []

            for idx, s in skillConfigs {
                this._cycleSkillKeys.Push(s.Name)
                opts := (idx == 1) ? "Section w85 y+10" : "xs Section w85 y+10"
                chk := this.GuiObj.Add("Checkbox", opts, "技能 [ " s.Name " ]")
                chk.Value := this.GetVal("chkSkill" s.Name, 1)
                chk.OnEvent("Click", (*) => this._OnToggleSkill())
                this.Ctrl.chkSkill%s.Name% := chk
                this._skillCheckboxes.Push(chk)

                this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "")
                this.Ctrl.edtDur%s.Name% := this.GuiObj.Add("Edit", "ys w45 h22 Center", this.GetVal("edtDur" s.Name,
                    s.DefaultDur
                ))
                this.Ctrl.edtDur%s.Name%.OnEvent("Change", (*) => this._OnEditChanged())
                this.GuiObj.Add("Text", "ys+2 x+5", "秒")
            }
        } else {
            this._skillCheckboxes := []
            this._cycleSkillKeys := []
        }
        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")
    }

    BuildTimedSkillsPanel() {
        if this.AddPanelHeader("Timed", "⚡ 定时技能队列", false) {
            this.Ctrl.chkTimedSelectAll := this.GuiObj.Add("Checkbox", "w200 Check3 y+10", "全选 / 取消技能组")
            this.Ctrl.chkTimedSelectAll.Value := this.GetVal("chkTimedSelectAll", 1)
            this.Ctrl.chkTimedSelectAll.OnEvent("Click", (*) => this._OnToggleTimedSelectAll())

            isFirst := true
            this._timedCheckboxes := []
            for _, def in this.App.Engine.TimedSkills {
                chkName := "chk" def.Key
                edtName := "edt" def.Key
                edtDurName := "edtDur" def.Key
                opts := isFirst ? "Section w85 y+10" : "xs Section w85 y+10"
                chk := this.GuiObj.Add("Checkbox", opts, "技能 [ " def.Name " ]")
                chk.Name := chkName
                this.Ctrl.%chkName% := chk
                this.Ctrl.%chkName%.Value := this.GetVal(chkName, 1)
                this.Ctrl.%chkName%.OnEvent("Click", (*) => this._OnToggleTimedSkill())
                this._timedCheckboxes.Push(this.Ctrl.%chkName%)
                isFirst := false

                this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "")
                this.Ctrl.%edtName% := this.GuiObj.Add("Edit", "ys w40 h22 Center", this.GetVal(edtName, def.DefaultInterval
                ))
                this.Ctrl.%edtName%.OnEvent("Change", (*) => this._OnEditChanged())
                this.GuiObj.Add("Text", "ys+2 x+2", "秒")
            }
        } else {
            this._timedCheckboxes := []
        }
        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")
    }

    ; ========================================================
    ; 通用 UI 交互事件
    ; ========================================================
    _OnToggleA() {
        val := this.GetVal("chkA", 0)
        if (val) {
            ; 动态读取技能列表，取消所有循环技能
            if (this.HasOwnProp("_cycleSkillKeys") && this._cycleSkillKeys.Length > 0) {
                for _, sName in this._cycleSkillKeys {
                    if this.Ctrl.HasOwnProp("chkSkill" sName)
                        this.SetVal("chkSkill" sName, 0)
                }
                if this.Ctrl.HasOwnProp("chkSelectAll")
                    this.SetVal("chkSelectAll", 0)
            }
        }
        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    _OnToggleTimedSelectAll() {
        if !this.Ctrl.HasOwnProp("chkTimedSelectAll")
            return

        val := this.GetVal("chkTimedSelectAll", 0)
        newVal := (val == 1) ? 1 : 0 ; 将三态转换为 0/1

        for chk in this._timedCheckboxes {
            if (chk.Name)
                this.SetVal(chk.Name, newVal)
        }

        this.SaveConfig()
        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    _OnToggleTimedSkill() {
        checkedCount := 0
        totalCount := this._timedCheckboxes.Length
        for chk in this._timedCheckboxes {
            checkedCount += chk.Value
        }

        if this.Ctrl.HasOwnProp("chkTimedSelectAll") {
            if (checkedCount == totalCount)
                this.SetVal("chkTimedSelectAll", 1)
            else if (checkedCount > 0)
                this.SetVal("chkTimedSelectAll", -1)
            else
                this.SetVal("chkTimedSelectAll", 0)
        }

        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    _OnToggleSkill() {
        checkedCount := 0
        skills := this.HasOwnProp("_cycleSkillKeys") ? this._cycleSkillKeys : ["S", "D", "F", "Q"]
        totalCount := skills.Length
        for _, s in skills {
            if this.Ctrl.HasOwnProp("chkSkill" s)
                checkedCount += this.GetVal("chkSkill" s, 0)
        }

        if (checkedCount > 0 && this.Ctrl.HasOwnProp("chkA"))
            this.SetVal("chkA", 0)

        if this.Ctrl.HasOwnProp("chkSelectAll") {
            if (checkedCount == totalCount)
                this.SetVal("chkSelectAll", 1)
            else if (checkedCount > 0)
                this.SetVal("chkSelectAll", -1)
            else
                this.SetVal("chkSelectAll", 0)
        }

        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    _OnToggleSelectAll() {
        if !this.Ctrl.HasOwnProp("chkSelectAll")
            return

        val := this.GetVal("chkSelectAll", 0)
        skills := this.HasOwnProp("_cycleSkillKeys") ? this._cycleSkillKeys : ["S", "D", "F", "Q"]

        if (val == 1) {
            for _, s in skills
                if this.Ctrl.HasOwnProp("chkSkill" s)
                    this.SetVal("chkSkill" s, 1)
            if this.Ctrl.HasOwnProp("chkA")
                this.SetVal("chkA", 0)
        } else {
            this.SetVal("chkSelectAll", 0)
            for _, s in skills
                if this.Ctrl.HasOwnProp("chkSkill" s)
                    this.SetVal("chkSkill" s, 0)
        }

        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    _OnEditChanged() {
        if (this.App.Engine.IsRunning && this.App.Engine.HasMethod("_CacheParams"))
            this.App.Engine._CacheParams()
    }

    ReflowUI() {
        for item in this.OriginalLayout {
            itemOffsetY := 0
            for pid, bounds in this.PanelBounds {
                if (!this.PanelStates[pid]) {
                    if (item.OrigY > bounds.MaxY) {
                        itemOffsetY += bounds.Height
                    }
                }
            }

            if (this.PanelStates.Has(item.PanelId) && !item.IsHeader && !this.PanelStates[item.PanelId]) {
                item.Ctrl.Visible := false
            } else {
                item.Ctrl.Visible := true
                item.Ctrl.Move(, item.OrigY - itemOffsetY)
            }
        }

        this.GuiObj.Show("AutoSize NoActivate")
    }

    BuildTop() {
        this.GuiObj.MarginX := 15
        this.GuiObj.MarginY := 15

        this.GuiObj.SetFont("s15 bold", "微软雅黑")
        this.Ctrl.txtStatus := this.GuiObj.Add("Text", "w200 Center cRed", "🔴 宏等待启动")

        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.txtAction := this.GuiObj.Add("Text", "w200 Center c0066CC y+8", "当前动作: 待命")

        this.GuiObj.SetFont("s9 norm", "微软雅黑")
        this.Ctrl.txtSyncStatus := this.GuiObj.Add("Text", "w200 Center c666666 y+5", "⌨️ 操作同步模式: 关闭")
        this.Ctrl.txtMasterStatus := this.GuiObj.Add("Text", "w200 Center c666666 y+5", "🛡️ 快捷键总开关: 开启")
        this.UpdateSyncDisplay()
        this.UpdateMasterStatus()
    }

    BuildBottom(showRefresh := true) {
        if this.AddPanelHeader("WindowBind", "🎯 绑定后台游戏窗口", false) {
            this.Ctrl.ddlWindow := this.GuiObj.Add("DropDownList", "xs w200 Choose1 y+10", ["🌍 全局前台生效"])
            this.Ctrl.ddlWindow.OnEvent("Change", (*) => this.OnWindowSelect())

            this.GuiObj.SetFont("s10 cDefault")

            if (showRefresh) {
                btnRefresh := this.GuiObj.Add("Button", "xs w95 h35 y+10", "🔄 刷新列表")
                btnRefresh.OnEvent("Click", (*) => this.RefreshWindowList())

                btnBindQQ := this.GuiObj.Add("Button", "x+10 w95 h35", "🔗 绑QQ三国")
                btnBindQQ.OnEvent("Click", (*) => this.AutoBindQQSanGuo())
            }
        }

        this.RefreshWindowList()
        this.AutoBindQQSanGuo(true)
    }

    _ApplyEmbedding() {
        if (A_Args.Length > 0 && IsInteger(A_Args[1])) {
            parentHwnd := Integer(A_Args[1])
            if (parentHwnd == 0) {
                this._ShowStandalone()
                return
            }
            try {
                this.GuiObj.Opt("-Caption -0x80000000 +0x40000000")
                this.GuiObj.BackColor := "FFFFFF"
                DllCall("SetParent", "Ptr", this.GuiObj.Hwnd, "Ptr", parentHwnd)
                this.GuiObj.Show("w230 AutoSize NoActivate x0 y0")
            } catch {
                this._ShowStandalone()
            }
        } else {
            this._ShowStandalone()
        }

        if !this._boundCheckHover
            this._boundCheckHover := ObjBindMethod(this, "CheckHover")
        SetTimer(this._boundCheckHover, 300)
    }

    _ShowStandalone() {
        if this.HasOwnProp("SavedX") && this.SavedX != "" {
            xPos := this.SavedX
            yPos := this.SavedY
        } else {
            MonitorGetWorkArea(1, &workLeft, &workTop, &workRight, &workBottom)
            ; 基于 PreferredX/Y 进行初始定位
            xPos := workRight - 480 + this.PreferredX
            yPos := workTop + this.PreferredY
        }
        this.GuiObj.Show("w230 AutoSize NoActivate x" xPos " y" yPos)
    }

    CheckHover() {
        try {
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
                } else if (this.HasOwnProp("_isTooltipVisible") && !this._isTooltipVisible && (A_TickCount -
                    this._hoverStart >
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
        arr := this.App.InputManager.RefreshWindowList()

        if (this.Ctrl.HasOwnProp("ddlWindow")) {
            ; 记录当前选择，以便刷新后恢复
            oldSelection := this.Ctrl.ddlWindow.Text

            this.Ctrl.ddlWindow.Delete()
            this.Ctrl.ddlWindow.Add(arr)

            ; 尝试恢复之前的选择
            try {
                this.Ctrl.ddlWindow.Choose(oldSelection)
            } catch {
                this.Ctrl.ddlWindow.Choose(1)
                if (this.App.InputManager.TargetHwnd != 0) {
                    this.App.InputManager.SetTarget(0)
                    this.GuiObj.Title := this.BaseTitle
                }
            }
            this.UpdateAction("🔄 窗口列表已刷新")
        }
    }

    OnWindowSelect() {
        this.App.InputManager.ReleaseAllKeys()

        if (!this.HasOwnProp("BaseTitle"))
            this.BaseTitle := this.GuiObj.Title

        if !this.Ctrl.HasOwnProp("ddlWindow")
            return

        selected := this.Ctrl.ddlWindow.Text
        if (selected == "🌍 全局前台生效") {
            this.App.InputManager.SetTarget(0)
            this.GuiObj.Title := this.BaseTitle
        } else if this.App.InputManager.WinMap.Has(selected) {
            this.App.InputManager.SetTarget(this.App.InputManager.WinMap[selected])
        }

        this.UpdateAction("🔄 已切换目标")
        this.App.OnFocusTarget()  ; 修正：OnFocusTarget 属于 App 类，而非 UI 类
    }

    AutoBindQQSanGuo(silent := false) {
        this.RefreshWindowList()

        qqsgList := []
        for displayText, hwnd in this.App.InputManager.WinMap {
            if InStr(displayText, "QQ三国") {
                if RegExMatch(displayText, "PID:(\d+)", &m) {
                    qqsgList.Push({ txt: displayText, pid: Integer(m[1]) })
                }
            }
        }

        if (qqsgList.Length == 0) {
            if (!silent)
                MsgBox("未找到任何 QQ三国 窗口！请确保游戏已启动。", "提示", "Iconi")
            return
        }

        ; 对 PID 进行升序排序 (冒泡)
        len := qqsgList.Length
        loop len {
            i := A_Index
            loop len - i {
                if (qqsgList[A_Index].pid > qqsgList[A_Index + 1].pid) {
                    temp := qqsgList[A_Index]
                    qqsgList[A_Index] := qqsgList[A_Index + 1]
                    qqsgList[A_Index + 1] := temp
                }
            }
        }

        targetText := ""
        if InStr(this.BaseTitle, "JS") {
            ; JS.ahk 绑定 PID 最小
            targetText := qqsgList[1].txt
        } else if InStr(this.BaseTitle, "YX") {
            ; YX.ahk 绑定次小 (第2小)
            targetText := qqsgList.Length >= 2 ? qqsgList[2].txt : qqsgList[1].txt
        } else if InStr(this.BaseTitle, "XS") {
            ; XS.ahk 绑定第3小
            targetText := qqsgList.Length >= 3 ? qqsgList[3].txt : qqsgList[qqsgList.Length].txt
        } else if InStr(this.BaseTitle, "HL") {
            ; HL.ahk 绑定第4小
            targetText := qqsgList.Length >= 4 ? qqsgList[4].txt : qqsgList[qqsgList.Length].txt
        } else {
            ; 默认绑第一个
            targetText := qqsgList[1].txt
        }

        if (targetText != "") {
            try {
                this.Ctrl.ddlWindow.Choose(targetText)
                this.OnWindowSelect()
                this.UpdateAction("🎯 一键绑定成功：" targetText)
            }
        }
    }

    UpdateStatus(isRunning) {
        try {
            if !this.Ctrl.HasOwnProp("txtStatus")
                return

            if (isRunning) {
                if (this.Ctrl.txtStatus.Value != "🟢 宏运行中") {
                    this.Ctrl.txtStatus.Value := "🟢 宏运行中"
                    this.Ctrl.txtStatus.Opt("cGreen")
                }
            } else {
                if (this.Ctrl.txtStatus.Value != "🔴 宏等待启动") {
                    this.Ctrl.txtStatus.Value := "🔴 宏等待启动"
                    this.Ctrl.txtStatus.Opt("cRed")
                    this.UpdateAction("当前动作: 待命")
                }
            }
        }
    }

    UpdateAction(text) {
        try {
            if (this.Ctrl.HasOwnProp("txtAction") && this.Ctrl.txtAction.Value != text)
                this.Ctrl.txtAction.Value := text
        }
    }

    UpdateSyncDisplay() {
        if (!this.Ctrl.HasOwnProp("txtSyncStatus"))
            return
        isEnabled := this.App.SyncManager._isSyncEnabled
        isMouseSync := this.App.SyncManager._isMouseSyncEnabled
        mouseText := isMouseSync ? " | 🖱️ 鼠标: 开" : " | 🖱️ 鼠标: 关"
        if (isEnabled) {
            this.Ctrl.txtSyncStatus.Value := "⌨️ 操作同步: 开启" . mouseText
            this.Ctrl.txtSyncStatus.Opt("c008000")
        } else {
            this.Ctrl.txtSyncStatus.Value := "⌨️ 操作同步: 关闭" . mouseText
            this.Ctrl.txtSyncStatus.Opt("c888888")
        }
    }

    UpdateMasterStatus() {
        if (!this.Ctrl.HasOwnProp("txtMasterStatus"))
            return
        isEnabled := this.App._HotkeysEnabled
        this.Ctrl.txtMasterStatus.Value := "🛡️ 快捷键总开关: " . (isEnabled ? "开启" : "关闭")
        this.Ctrl.txtMasterStatus.Opt(isEnabled ? "c008000" : "c888888")
    }
}

; ========================================================
; 配置驱动的通用 UI (从 MacroConfig 自动构建)
; ========================================================
class ConfigMacroUI extends MacroUIBase {
    _skillCheckboxes := []
    _cycleSkillKeys := []

    __New(appRef) {
        cfg := appRef.Config
        if (cfg.PreferredX != 0)
            this.PreferredX := cfg.PreferredX
        if (cfg.PreferredY != 30)
            this.PreferredY := cfg.PreferredY
        super.__New(appRef, cfg.Title)
        this.IsBuilding := true
        this.BuildFromConfig(cfg)
        this.IsBuilding := false
    }

    BuildFromConfig(cfg) {
        this.BuildTop()

        ; 基础设置面板 (如果配置存在)
        if (IsObject(cfg.BasicPanel) && cfg.BasicPanel != "") {
            defaultVal := cfg.BasicPanel.HasOwnProp("DefaultVal") ? cfg.BasicPanel.DefaultVal : 0
            this.BuildBasicPanel(cfg.BasicPanel.Text, defaultVal)
        }

        ; 技能循环面板 (如果配置了循环技能)
        if (cfg.CycleSkills.Length > 0)
            this.BuildCycleSkillsPanel(cfg.CycleSkills)

        ; 定时技能面板 (如果配置了定时技能)
        if (cfg.TimedSkills.Length > 0)
            this.BuildTimedSkillsPanel()

        this.BuildBottom()
    }
}
