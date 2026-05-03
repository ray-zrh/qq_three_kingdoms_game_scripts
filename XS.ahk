#Requires AutoHotkey v2.0
#Include MacroCore.ahk

; ========================================================
; XS宏 状态机引擎
; ========================================================
class XS_MacroEngine extends MacroEngineBase {
    SkillQueue := []

    ; 定时技能配置表
    TimedSkills := []
    BoundFirers := Map()

    ; === Start() 时缓存的参数 ===
    _mainPressDur := 200   ; A键按下持续基准值 (ms)
    _mainPressInt := 50    ; A键间隔基准值 (ms)
    _castDelay := 2000     ; 硬直保护 (ms)

    __New(appRef) {
        super.__New(appRef)

        ; 注册定时技能: 名称, 按键, 默认间隔(分钟)
        this.TimedSkills := [
            TimedSkillDef("F", "f", 30),
            TimedSkillDef("Q", "q", 6),
            TimedSkillDef("W", "w", 5)
        ]

        for _, def in this.TimedSkills {
            this.BoundFirers[def.Key] := ObjBindMethod(this, "FireTimedSkill", def.Key)
        }
    }

    Start() {
        this.IsRunning := true
        this.SkillQueue := []
        this.App.UI.UpdateStatus(true)

        ; 启动所有启用的定时技能计时器
        for _, def in this.TimedSkills {
            ctrl := this.App.UI.GetTimedSkillCtrl(def.Key)
            if (ctrl.chk.Value) {
                interval := this._SafeInt(ctrl.edt.Value, def.DefaultInterval) * 60000
                SetTimer(this.BoundFirers[def.Key], interval)
                ; 启动时立即入队一次
                this.SkillQueue.Push(def.Key)
            }
        }

        SetTimer(this.BoundTick, -1)
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

    ; 定时技能触发器 + 主动唤醒主循环
    FireTimedSkill(keyName, *) {
        if (!this.IsRunning)
            return
        ctrl := this.App.UI.GetTimedSkillCtrl(keyName)
        if (!ctrl.chk.Value)
            return

        ; 防重入：如果队列里已经有同名技能，跳过
        for _, existing in this.SkillQueue {
            if (existing == keyName)
                return
        }

        this.SkillQueue.Push(keyName)
        ; 主动唤醒主循环
        SetTimer(this.BoundTick, -1)
    }

    ; 主循环 Tick
    GameLoopTick() {
        Critical("On")  ; 保护整个 tick 的原子性

        if (!this.IsRunning) {
            Critical("Off")
            return
        }

        ; 聊天模式挂起
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

        ; ====== 优先处理定时大招队列 ======
        if (this.SkillQueue.Length > 0) {
            keyName := this.SkillQueue.RemoveAt(1)
            this.App.UI.UpdateAction("⚡ 定时大招：[ " StrUpper(keyName) " ]")

            ; 先释放所有按键
            this.App.Injector.ReleaseAllKeys()
            Critical("Off")  ; 等待期间允许中断

            if (!this.WaitOrInterrupt(150)) {
                Critical("On")
                this.SkillQueue.InsertAt(1, keyName)
                if (this.IsRunning)
                    SetTimer(this.BoundTick, -10)
                Critical("Off")
                return
            }

            Critical("On")
            ; 聊天安全检查
            if (this.App.Injector.IsChatMode) {
                this.SkillQueue.InsertAt(1, keyName)
                SetTimer(this.BoundTick, -500)
                Critical("Off")
                return
            }

            ; 按下大招键
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

            ; 释放大招键
            Critical("On")
            this.App.Injector.SendKey(keyName, false)

            ; 硬直保护等待
            if (this.IsRunning)
                SetTimer(this.BoundTick, -1 * this._castDelay)
            Critical("Off")
            return
        }

        ; ====== 主循环: 长按 A ======
        if (this.App.UI.Ctrl.chkA.Value) {
            this.App.UI.UpdateAction("👉 正在循环长按：[ A ]")

            this.App.Injector.SendKey("a", true)
            Critical("Off")

            if (!this.WaitOrInterrupt(this._Jitter(this._mainPressDur))) {
                this.App.Injector.SendKey("a", false)
                if (this.IsRunning)
                    SetTimer(this.BoundTick, -10)
                return
            }

            ; 聊天安全检查 + up
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
            ; A键关闭，使用长间隔轮询（定时技能由 FireTimedSkill 主动唤醒）
            this.App.UI.UpdateAction("⏳ 主循环 [ A ] 已关，等待定时...")
            if (this.IsRunning)
                SetTimer(this.BoundTick, -1000)
        }

        Critical("Off")
    }
}

; ========================================================
; 用户交互界面
; ========================================================
class XS_MacroUI extends MacroUIBase {
    _timedSkillCtrls := Map()

    __New(appRef) {
        super.__New(appRef)
        this.Build()
    }

    Build() {
        this.BuildTop("XS宏")

        ; === 基础设置 ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+15", "⚙️ 基础设置")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")
        this.Ctrl.chkSpacePause := this.GuiObj.Add("Checkbox", "w200 y+10", "允许空格键单独暂停此窗口")
        this.Ctrl.chkA := this.GuiObj.Add("Checkbox", "w200 Checked y+10", "🔄 开启长按 [ A ] 键主循环")

        this.GuiObj.Add("Text", "w200 h1 BackgroundE5E5E5 y+15")

        ; === 定时独立技能 (数据驱动生成) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "w200 c333333 y+15", "🕒 定时独立技能 (分钟)")
        this.GuiObj.SetFont("s10 norm", "微软雅黑")

        isFirst := true
        for _, def in this.App.Engine.TimedSkills {
            if (isFirst) {
                chk := this.GuiObj.Add("Checkbox", "Section w120 Checked y+5", "定时释放 [ " def.Name " ]")
                isFirst := false
            } else {
                chk := this.GuiObj.Add("Checkbox", "xs Section w120 Checked", "定时释放 [ " def.Name " ]")
            }
            edt := this.GuiObj.Add("Edit", "ys w40 Number Center", String(def.DefaultInterval))
            this.GuiObj.Add("Text", "ys", "分")

            this._timedSkillCtrls[def.Key] := { chk: chk, edt: edt }
        }

        this.GuiObj.Add("Text", "xs w200 h1 BackgroundE5E5E5 y+15")

        ; === 时序参数 (固定) ===
        this.GuiObj.SetFont("s12 bold", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 c333333 y+15", "⏱️ 按键时序 (只读)")
        this.GuiObj.SetFont("s9 norm c666666", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+10", "主循环: 按下200ms / 间隔50ms")
        this.GuiObj.Add("Text", "xs w200 y+6", "独立技能: 施放后等 2s")
        this.GuiObj.SetFont("s9 norm c999999", "微软雅黑")
        this.GuiObj.Add("Text", "xs w200 y+4", "(内部实际运行存在 ±30% 随机抖动)")

        this.BuildBottom()
    }

    GetTimedSkillCtrl(keyName) {
        return this._timedSkillCtrls[keyName]
    }
}

; 启动应用实例
global AppInstance := GameMacroAppBase(XS_MacroEngine, XS_MacroUI, "2")