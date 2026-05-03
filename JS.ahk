#Requires AutoHotkey v2.0
#Include MacroCore.ahk

; ========================================================
; JS宏 状态机引擎
; ========================================================
class JS_MacroEngine extends MacroEngineBase {
    CurrentIndex := 1
    SkillCount := 0

    ; === Start() 时缓存的参数 ===
    _skills := []          ; 技能循环快照
    _pressDur := 200       ; 技能按下持续 (ms)
    _pressInt := 50        ; 技能按键间隔 (ms)
    _mainPressDur := 200   ; A键按下持续 (ms)
    _mainPressInt := 60    ; A键间隔 (ms)

    Start() {
        this._CacheParams()

        this.IsRunning := true
        this.CurrentIndex := 1
        this.SkillCount := 0
        this.App.UI.UpdateStatus(true)

        ; 允许无循环技能但有A普攻的情况启动
        if (this._skills.Length == 0 && !this.App.UI.Ctrl.chkA.Value) {
            this.App.UI.UpdateAction("⚠️ 无启用技能，请至少勾选一个")
            this.IsRunning := false
            this.App.UI.UpdateStatus(false)
            return
        }

        SetTimer(this.BoundTick, -1)
    }

    Stop() {
        this.IsRunning := false
        SetTimer(this.BoundTick, 0)
        this.App.Injector.ReleaseAllKeys()
        this.App.UI.UpdateStatus(false)
    }

    Toggle() {
        if (this.IsRunning)
            this.Stop()
        else
            this.Start()
    }

    _CacheParams() {
        ctrl := this.App.UI.Ctrl
        this._skills := []
        if (ctrl.chkSkillS.Value)
            this._skills.Push({ Name: "S", Key: "s", Count: this._SafeInt(ctrl.edtCountS.Value, 10) })
        if (ctrl.chkSkillD.Value)
            this._skills.Push({ Name: "D", Key: "d", Count: this._SafeInt(ctrl.edtCountD.Value, 50) })
        if (ctrl.chkSkillF.Value)
            this._skills.Push({ Name: "F", Key: "f", Count: this._SafeInt(ctrl.edtCountF.Value, 10) })
        if (ctrl.chkSkillQ.Value)
            this._skills.Push({ Name: "Q", Key: "q", Count: this._SafeInt(ctrl.edtCountQ.Value, 10) })
    }

    ; 主循环: 技能循环(S→D→F→Q) > A键普攻
    GameLoopTick() {
        Critical("On")  ; 保护整个 tick 的原子性，防止热键线程中断

        if (!this.IsRunning) {
            Critical("Off")
            return
        }

        if (this.App.Injector.IsChatMode) {
            this.App.UI.UpdateAction("💬 聊天挂起中 (按Enter/Esc恢复)")
            SetTimer(this.BoundTick, -500)
            Critical("Off")
            return
        }

        ; ====== 优先级最高：物理用户输入避让 ======
        if (this.CheckYield()) {
            if (!this._isYielding) {
                this.App.Injector.ReleaseAllKeys()
                this._isYielding := true
            }
            this.App.UI.UpdateAction("🛑 用户操作中，宏暂时避让...")
            SetTimer(this.BoundTick, -200)
            Critical("Off")
            return
        }
        this._isYielding := false

        ; ====== 第一优先级: 技能循环 (S→D→F→Q) ======
        skills := this._skills
        if (skills.Length > 0) {
            if (this.CurrentIndex > skills.Length) {
                this.CurrentIndex := 1
                this.SkillCount := 0
            }

            startIndex := this.CurrentIndex
            loop skills.Length {
                skill := skills[this.CurrentIndex]
                if (this.SkillCount < skill.Count) {
                    this.SkillCount++
                    this.App.UI.UpdateAction("⚔️ 技能循环：[ " skill.Name " ]")

                    this.App.Injector.SendKey(skill.Key, true)
                    Critical("Off")  ; 在等待期间允许热键中断

                    if (!this.WaitOrInterrupt(this._Jitter(this._pressDur))) {
                        this.App.Injector.SendKey(skill.Key, false)
                        if (this.IsRunning)
                            SetTimer(this.BoundTick, -10)
                        return
                    }

                    ; 等待结束后重新保护
                    Critical("On")
                    if (this.App.Injector.IsChatMode) {
                        this.App.Injector.SendKey(skill.Key, false)
                        SetTimer(this.BoundTick, -500)
                        Critical("Off")
                        return
                    }
                    this.App.Injector.SendKey(skill.Key, false)

                    if (this.IsRunning)
                        SetTimer(this.BoundTick, -1 * this._Jitter(this._pressInt))
                    Critical("Off")
                    return
                }

                this.CurrentIndex++
                this.SkillCount := 0
                if (this.CurrentIndex > skills.Length)
                    this.CurrentIndex := 1

                if (this.CurrentIndex == startIndex) {
                    this.SkillCount := 0
                    break
                }
            }

            ; 所有技能轮空后保底调度，防止状态机死锁
            if (this.IsRunning)
                SetTimer(this.BoundTick, -1)
            Critical("Off")
            return
        }

        ; ====== 第二优先级 (最低): A键普攻 ======
        if (this.App.UI.Ctrl.chkA.Value) {
            this.App.UI.UpdateAction("👉 普攻循环：[ A ]")

            this.App.Injector.SendKey("a", true)
            Critical("Off")  ; 等待期间允许中断

            if (!this.WaitOrInterrupt(this._Jitter(this._mainPressDur))) {
                this.App.Injector.SendKey("a", false)
                if (this.IsRunning)
                    SetTimer(this.BoundTick, -10)
                return
            }

            Critical("On")
            if (this.App.Injector.IsChatMode) {
                this.App.Injector.SendKey("a", false)
                SetTimer(this.BoundTick, -500)
                Critical("Off")
                return
            }
            this.App.Injector.SendKey("a", false)

            if (this.IsRunning)
                SetTimer(this.BoundTick, -1 * this._Jitter(this._mainPressInt))
        } else {
            this.App.UI.UpdateAction("⏳ 全部技能已关闭，空闲等待中...")
            if (this.IsRunning)
                SetTimer(this.BoundTick, -1000)
        }

        Critical("Off")
    }
}

; ========================================================
; 用户交互界面
; ========================================================
class JS_MacroUI extends MacroUIBase {
    _skillCheckboxes := []

    __New(appRef) {
        super.__New(appRef)
        this.Build()
    }

    Build() {
        this.BuildTop("JS宏")

        ; === 基础设置 ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+15", "⚙️ 基础设置")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.chkSpacePause := this.GuiObj.Add("Checkbox", "w200 y+10", "允许空格键单独暂停此窗口")
        this.Ctrl.chkA := this.GuiObj.Add("Checkbox", "w200 y+10", "🗡️ 仅使用 [ A ] 普攻模式")
        this.Ctrl.chkA.OnEvent("Click", (*) => this._OnToggleA())

        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")

        ; === 技能循环配置 (S→D→F→Q) ===
        this.GuiObj.SetFont("s11 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+10", "⚔️ 技能循环 (S→D→F→Q)")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")

        this.Ctrl.chkSelectAll := this.GuiObj.Add("Checkbox", "w200 Check3 Checked y+10", "全选 / 取消技能组")
        this.Ctrl.chkSelectAll.OnEvent("Click", (*) => this._OnToggleSelectAll())

        ; S 技能行
        this.Ctrl.chkSkillS := this.GuiObj.Add("Checkbox", "Section w85 Checked y+10", "技能 [ S ]")
        this.Ctrl.chkSkillS.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "×")
        this.Ctrl.edtCountS := this.GuiObj.Add("Edit", "ys w45 h22 Number Center", "10")
        this.GuiObj.Add("Text", "ys+2 x+5", "次")

        ; D 技能行
        this.Ctrl.chkSkillD := this.GuiObj.Add("Checkbox", "xs Section w85 Checked y+10", "技能 [ D ]")
        this.Ctrl.chkSkillD.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "×")
        this.Ctrl.edtCountD := this.GuiObj.Add("Edit", "ys w45 h22 Number Center", "50")
        this.GuiObj.Add("Text", "ys+2 x+5", "次")

        ; F 技能行
        this.Ctrl.chkSkillF := this.GuiObj.Add("Checkbox", "xs Section w85 Checked y+10", "技能 [ F ]")
        this.Ctrl.chkSkillF.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "×")
        this.Ctrl.edtCountF := this.GuiObj.Add("Edit", "ys w45 h22 Number Center", "10")
        this.GuiObj.Add("Text", "ys+2 x+5", "次")

        ; Q 技能行
        this.Ctrl.chkSkillQ := this.GuiObj.Add("Checkbox", "xs Section w85 Checked y+10", "技能 [ Q ]")
        this.Ctrl.chkSkillQ.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 x+2 w15 Center", "×")
        this.Ctrl.edtCountQ := this.GuiObj.Add("Edit", "ys w45 h22 Number Center", "10")
        this.GuiObj.Add("Text", "ys+2 x+5", "次")

        this._skillCheckboxes := [this.Ctrl.chkSkillS, this.Ctrl.chkSkillD, this.Ctrl.chkSkillF, this.Ctrl.chkSkillQ]

        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+10")

        ; === 时序参数 (固定) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 c333333 y+15", "⏱️ 按键时序 (只读)")
        this.GuiObj.SetFont("s9 norm c666666", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+10", "技能: 按下200ms / 间隔50ms")
        this.GuiObj.Add("Text", "xs w200 y+6", "普攻: 按下200ms / 间隔60ms")
        this.GuiObj.SetFont("s9 norm c999999", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+4", "(内部实际运行存在 ±30% 随机抖动)")

        this.BuildBottom()
    }

    _OnToggleA() {
        if (this.Ctrl.chkA.Value) {
            for _, chk in this._skillCheckboxes
                chk.Value := 0
            this.Ctrl.chkSelectAll.Value := 0
        }
    }

    _OnToggleSkill() {
        checkedCount := 0
        for _, chk in this._skillCheckboxes {
            if (chk.Value)
                checkedCount++
        }
        if (checkedCount > 0)
            this.Ctrl.chkA.Value := 0
        if (checkedCount == this._skillCheckboxes.Length)
            this.Ctrl.chkSelectAll.Value := 1
        else if (checkedCount > 0)
            this.Ctrl.chkSelectAll.Value := -1
        else
            this.Ctrl.chkSelectAll.Value := 0
    }

    _OnToggleSelectAll() {
        val := this.Ctrl.chkSelectAll.Value
        if (val == 1) {
            for _, chk in this._skillCheckboxes
                chk.Value := 1
            this.Ctrl.chkA.Value := 0
        } else {
            this.Ctrl.chkSelectAll.Value := 0
            for _, chk in this._skillCheckboxes
                chk.Value := 0
        }
    }
}

; 启动应用实例
global AppInstance := GameMacroAppBase(JS_MacroEngine, JS_MacroUI, "1")