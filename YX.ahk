#Requires AutoHotkey v2.0
#Include MacroCore.ahk

; ========================================================
; YX宏 状态机引擎
; ========================================================
class YX_MacroEngine extends MacroEngineBase {
    CurrentIndex := 1
    SkillCount := 0
    SkillQueue := []

    ; 定时技能配置表
    TimedSkills := []
    BoundFirers := Map()

    ; === Start() 时缓存的参数 ===
    _cycleSkills := []     ; 循环技能快照
    _cyclePressDur := 120  ; 循环技能按下 (ms)
    _cyclePressInt := 120  ; 循环技能间隔 (ms)
    _mainPressDur := 400   ; A键按下 (ms)
    _mainPressInt := 60    ; A键间隔 (ms)
    _castDelay := 2000     ; 独立技能硬直保护 (ms)

    __New(appRef) {
        super.__New(appRef)

        ; 注册定时技能
        this.TimedSkills := [
            TimedSkillDef("Q", "q", 5),
            TimedSkillDef("W", "w", 30)
        ]

        for _, def in this.TimedSkills {
            this.BoundFirers[def.Key] := ObjBindMethod(this, "FireTimedSkill", def.Key)
        }
    }

    Start() {
        this._CacheParams()

        this.IsRunning := true
        this.CurrentIndex := 1
        this.SkillCount := 0
        this.SkillQueue := []
        this.App.UI.UpdateStatus(true)

        if (this._cycleSkills.Length == 0 && !this.App.UI.Ctrl.chkA.Value) {
            this.App.UI.UpdateAction("⚠️ 无启用技能，请至少勾选一个")
            this.IsRunning := false
            this.App.UI.UpdateStatus(false)
            return
        }

        for _, def in this.TimedSkills {
            ctrl := this.App.UI.GetTimedSkillCtrl(def.Key)
            if (ctrl.chk.Value) {
                interval := this._SafeInt(ctrl.edt.Value, def.DefaultInterval) * 60000
                SetTimer(this.BoundFirers[def.Key], interval)
                this.SkillQueue.Push(def.Key)
            }
        }

        SetTimer(this.BoundTick, -1)
    }

    _CacheParams() {
        ctrl := this.App.UI.Ctrl

        this._cycleSkills := []
        if (ctrl.chkSkillS.Value)
            this._cycleSkills.Push({ Name: "S", Key: "s", Count: this._SafeInt(ctrl.edtCountS.Value, 8) })
        if (ctrl.chkSkillD.Value)
            this._cycleSkills.Push({ Name: "D", Key: "d", Count: this._SafeInt(ctrl.edtCountD.Value, 12) })
        if (ctrl.chkSkillF.Value)
            this._cycleSkills.Push({ Name: "F", Key: "f", Count: this._SafeInt(ctrl.edtCountF.Value, 5) })
    }

    Stop() {
        this.IsRunning := false
        for _, def in this.TimedSkills
            SetTimer(this.BoundFirers[def.Key], 0)
        SetTimer(this.BoundTick, 0)
        this.SkillQueue := []
        this.App.Injector.ReleaseAllKeys()
        this.App.UI.UpdateStatus(false)
    }

    Toggle() {
        if (this.IsRunning)
            this.Stop()
        else
            this.Start()
    }

    FireTimedSkill(keyName, *) {
        if (!this.IsRunning)
            return
        ctrl := this.App.UI.GetTimedSkillCtrl(keyName)
        if (!ctrl.chk.Value)
            return

        ; 防重入：队列中已有同名技能则跳过
        for _, existing in this.SkillQueue {
            if (existing == keyName)
                return
        }

        this.SkillQueue.Push(keyName)
        SetTimer(this.BoundTick, -1)
    }

    ; 主循环: 定时大招 > 循环技能(S/D/F) > 长按A普攻
    GameLoopTick() {
        Critical("On")  ; 保护整个 tick 的原子性

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

        ; ====== 第一优先级: 定时大招队列 (Q/W) ======
        if (this.SkillQueue.Length > 0) {
            keyName := this.SkillQueue.RemoveAt(1)
            this.App.UI.UpdateAction("⚡ 定时大招：[ " StrUpper(keyName) " ]")

            this.App.Injector.ReleaseAllKeys()
            Critical("Off")

            if (!this.WaitOrInterrupt(150)) {
                Critical("On")
                this.SkillQueue.InsertAt(1, keyName)
                if (this.IsRunning)
                    SetTimer(this.BoundTick, -10)
                Critical("Off")
                return
            }

            Critical("On")
            if (this.App.Injector.IsChatMode) {
                this.SkillQueue.InsertAt(1, keyName)
                SetTimer(this.BoundTick, -500)
                Critical("Off")
                return
            }

            this.App.Injector.SendKey(keyName, true)
            Critical("Off")

            if (!this.WaitOrInterrupt(100)) {
                this.App.Injector.SendKey(keyName, false)
                Critical("On")
                this.SkillQueue.InsertAt(1, keyName)
                if (this.IsRunning)
                    SetTimer(this.BoundTick, -10)
                Critical("Off")
                return
            }

            Critical("On")
            this.App.Injector.SendKey(keyName, false)

            if (this.IsRunning)
                SetTimer(this.BoundTick, -1 * this._castDelay)
            Critical("Off")
            return
        }

        ; ====== 第二优先级: 循环技能 (S→D→F) ======
        skills := this._cycleSkills

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
                    this.App.UI.UpdateAction("🏹 技能循环：[ " skill.Name " ]")

                    this.App.Injector.SendKey(skill.Key, true)
                    Critical("Off")

                    if (!this.WaitOrInterrupt(this._Jitter(this._cyclePressDur))) {
                        this.App.Injector.SendKey(skill.Key, false)
                        if (this.IsRunning)
                            SetTimer(this.BoundTick, -10)
                        return
                    }

                    Critical("On")
                    if (this.App.Injector.IsChatMode) {
                        this.App.Injector.SendKey(skill.Key, false)
                        SetTimer(this.BoundTick, -500)
                        Critical("Off")
                        return
                    }
                    this.App.Injector.SendKey(skill.Key, false)

                    if (this.IsRunning)
                        SetTimer(this.BoundTick, -1 * this._Jitter(this._cyclePressInt))
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

            ; 所有技能轮空后保底调度
            if (this.IsRunning)
                SetTimer(this.BoundTick, -1)
            Critical("Off")
            return
        }

        ; ====== 第三优先级: 长按 A 键普攻 ======
        if (this.App.UI.Ctrl.chkA.Value) {
            this.App.UI.UpdateAction("👉 普攻循环：[ A ]")

            this.App.Injector.SendKey("a", true)
            Critical("Off")

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
class YX_MacroUI extends MacroUIBase {
    _timedSkillCtrls := Map()
    _skillCheckboxes := []

    __New(appRef) {
        super.__New(appRef)
        this.Build()
    }

    Build() {
        this.BuildTop("YX宏")

        ; === 基础设置 ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+15", "⚙️ 基础设置")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.chkSpacePause := this.GuiObj.Add("Checkbox", "w200 y+10", "允许空格键单独暂停此窗口")
        this.Ctrl.chkA := this.GuiObj.Add("Checkbox", "w200 y+10", "🏹 仅开启 [ A ] 键普攻循环 (互斥)")
        this.Ctrl.chkA.OnEvent("Click", (*) => this._OnToggleA())

        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")

        ; === 循环技能配置 (S/D/F) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+15", "⚔️ 循环技能 (S→D→F)")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")

        this.Ctrl.chkSkillS := this.GuiObj.Add("Checkbox", "Section w80 Checked y+10", "技能 [ S ]")
        this.Ctrl.chkSkillS.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 w20 Right", "×")
        this.Ctrl.edtCountS := this.GuiObj.Add("Edit", "ys w45 Number Center", "8")
        this.GuiObj.Add("Text", "ys+2", "次")

        this.Ctrl.chkSkillD := this.GuiObj.Add("Checkbox", "xs Section w80 Checked", "技能 [ D ]")
        this.Ctrl.chkSkillD.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 w20 Right", "×")
        this.Ctrl.edtCountD := this.GuiObj.Add("Edit", "ys w45 Number Center", "12")
        this.GuiObj.Add("Text", "ys+2", "次")

        this.Ctrl.chkSkillF := this.GuiObj.Add("Checkbox", "xs Section w80 Checked", "技能 [ F ]")
        this.Ctrl.chkSkillF.OnEvent("Click", (*) => this._OnToggleSkill())
        this.GuiObj.Add("Text", "ys+2 w20 Right", "×")
        this.Ctrl.edtCountF := this.GuiObj.Add("Edit", "ys w45 Number Center", "5")
        this.GuiObj.Add("Text", "ys+2", "次")

        this._skillCheckboxes := [this.Ctrl.chkSkillS, this.Ctrl.chkSkillD, this.Ctrl.chkSkillF]

        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")

        ; === 定时独立技能 (Q/W) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 c333333 y+15", "🕒 定时独立技能 (分钟)")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")

        isFirst := true
        for _, def in this.App.Engine.TimedSkills {
            if (isFirst) {
                chk := this.GuiObj.Add("Checkbox", "Section w130 Checked y+10", "定时释放 [ " def.Name " ]")
                isFirst := false
            } else {
                chk := this.GuiObj.Add("Checkbox", "xs Section w130 Checked", "定时释放 [ " def.Name " ]")
            }
            edt := this.GuiObj.Add("Edit", "ys w45 Number Center", String(def.DefaultInterval))
            this.GuiObj.Add("Text", "ys+2", "分")
            this._timedSkillCtrls[def.Key] := { chk: chk, edt: edt }
        }

        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")

        ; === 时序参数 (固定) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 c333333 y+15", "⏱️ 按键时序 (只读)")
        this.GuiObj.SetFont("s9 norm c666666", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+10", "循环技能: 按下120ms / 间隔120ms")
        this.GuiObj.Add("Text", "xs w200 y+6", "普攻: 按下400ms / 间隔60ms")
        this.GuiObj.Add("Text", "xs w200 y+6", "独立技能: 施放后等 2s")
        this.GuiObj.SetFont("s9 norm c999999", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+4", "(内部实际运行存在 ±30% 随机抖动)")

        this.BuildBottom()
    }

    GetTimedSkillCtrl(keyName) {
        return this._timedSkillCtrls[keyName]
    }

    _OnToggleA() {
        if (this.Ctrl.chkA.Value) {
            for _, chk in this._skillCheckboxes
                chk.Value := 0
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
    }
}

; 启动应用实例
global AppInstance := GameMacroAppBase(YX_MacroEngine, YX_MacroUI, "3")