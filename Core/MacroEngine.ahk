; ========================================================
; 定时技能定义类 (XS/YX 共用)
; ========================================================
class TimedSkillDef {
    Name := ""
    Key := ""
    DefaultInterval := 0  ; 默认间隔(秒)
    DefaultDuration := 0.5 ; 默认施放时长(秒)

    __New(name, key, defaultInterval, defaultDuration := 0.5) {
        this.Name := name
        this.Key := key
        this.DefaultInterval := defaultInterval
        this.DefaultDuration := defaultDuration
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

    CurrentIndex := 1
    SkillCount := 0
    SkillQueue := []
    TimedSkills := []
    BoundFirers := Map()

    ; 疲劳模拟系统状态
    _lastRestTime := 0
    _nextShortRestTime := 0
    _isResting := false
    _restUntil := 0
    _aHoldStart := 0
    _aNextBreak := 0

    __New(appRef) {
        this.App := appRef
        this.BoundTick := ObjBindMethod(this, "GameLoopTick")
    }

    OnStart() {
        return true
    }

    OnStop() {
    }

    Start() {
        this.IsRunning := true
        this.CurrentIndex := 1
        this.SkillCount := 0
        this.SkillQueue := []

        this.App.UI.UpdateStatus(true)
        this._aHoldStart := 0
        this._aNextBreak := 0
        this._nextShortRestTime := A_TickCount + this._Jitter(120000, 1.0)
        this._isResting := false

        ; 如果子类 OnStart 返回 false，则终止启动
        if (this.OnStart() == false) {
            this.Stop()
            return
        }

        SetTimer(this.BoundTick, -1)
    }

    Stop() {
        this.IsRunning := false
        SetTimer(this.BoundTick, 0)

        this.StopTimedSkills()

        this.OnStop()

        this.SkillQueue := []
        this.App.InputManager.ReleaseAllKeys()
        this.App.UI.UpdateStatus(false)
    }

    StartTimedSkills() {
        if (!this.HasOwnProp("TimedSkills") || !this.HasOwnProp("BoundFirers"))
            return

        this._activeTimedSkills := Map()
        this._activeTimedIntervals := Map()

        for _, def in this.TimedSkills {
            if (this.App.UI.GetVal("chk" def.Key, 1)) {
                this._activeTimedSkills[def.Key] := true
                this._activeTimedIntervals[def.Key] := this._SafeNumber(this.App.UI.GetVal("edt" def.Key, def.DefaultInterval
                ), def.DefaultInterval)
                ; 启动时添加微小随机偏移 (0.5-5秒)，防止 Buff 技能在瞬间同时排队
                initialDelay := Random(500, 5000)
                SetTimer(this.BoundFirers[def.Key], -initialDelay)
            } else {
                this._activeTimedSkills[def.Key] := false
                this._activeTimedIntervals[def.Key] := -1
            }
        }
    }

    StopTimedSkills() {
        if (!this.HasOwnProp("TimedSkills") || !this.HasOwnProp("BoundFirers"))
            return

        for _, def in this.TimedSkills
            SetTimer(this.BoundFirers[def.Key], 0)

        this._activeTimedSkills := Map()
    }

    SyncTimedSkills() {
        if (!this.HasOwnProp("TimedSkills") || !this.HasOwnProp("BoundFirers"))
            return

        if (!this.HasOwnProp("_activeTimedSkills"))
            this._activeTimedSkills := Map()
        if (!this.HasOwnProp("_activeTimedIntervals"))
            this._activeTimedIntervals := Map()

        for _, def in this.TimedSkills {
            isChecked := this.App.UI.GetVal("chk" def.Key, 1)
            currentInterval := this._SafeNumber(this.App.UI.GetVal("edt" def.Key, def.DefaultInterval), def.DefaultInterval
            )

            wasRunning := this._activeTimedSkills.Has(def.Key) && this._activeTimedSkills[def.Key]
            lastInterval := this._activeTimedIntervals.Has(def.Key) ? this._activeTimedIntervals[def.Key] : -1

            if (isChecked && !wasRunning) {
                this._activeTimedSkills[def.Key] := true
                this._activeTimedIntervals[def.Key] := currentInterval
                initialDelay := Random(500, 2000)
                SetTimer(this.BoundFirers[def.Key], -initialDelay)
            } else if (!isChecked && wasRunning) {
                this._activeTimedSkills[def.Key] := false
                SetTimer(this.BoundFirers[def.Key], 0)

                newQueue := []
                for _, qKey in this.SkillQueue {
                    if (qKey != def.Key)
                        newQueue.Push(qKey)
                }
                this.SkillQueue := newQueue
            } else if (isChecked && wasRunning && currentInterval != lastInterval) {
                this._activeTimedIntervals[def.Key] := currentInterval
                SetTimer(this.BoundFirers[def.Key], -this._Jitter(currentInterval * 1000, 0.6))
            }
        }
    }

    FireTimedSkill(keyName, *) {
        if (!this.IsRunning || !this.HasOwnProp("TimedSkills"))
            return

        ; 检查该技能是否仍处于开启状态
        if (!this.App.UI.GetVal("chk" keyName, 1))
            return

        ; 找到该技能的配置
        skillDef := 0
        for _, def in this.TimedSkills {
            if (def.Key == keyName) {
                skillDef := def
                break
            }
        }

        if (skillDef) {
            ; 1. 将技能加入执行队列
            alreadyInQueue := false
            for _, existing in this.SkillQueue {
                if (existing == keyName) {
                    alreadyInQueue := true
                    break
                }
            }
            if (!alreadyInQueue) {
                this.SkillQueue.Push(keyName)
                ; 主动唤醒主循环
                SetTimer(this.BoundTick, -1)
            }

            ; 2. 核心优化：计算下一次触发的随机扰动时间
            baseIntervalMs := this._SafeNumber(this.App.UI.GetVal("edt" keyName, skillDef.DefaultInterval), skillDef.DefaultInterval
            ) * 1000
            jitteredInterval := this._Jitter(baseIntervalMs, 0.6)

            ; 启动下一次单次定时
            SetTimer(this.BoundFirers[keyName], -jitteredInterval)
        }
    }

    Toggle() {
        if (this.IsRunning)
            this.Stop()
        else
            this.Start()
    }

    NextTick(ms) {
        if (this.IsRunning)
            SetTimer(this.BoundTick, ms)
    }

    BaseTick() {
        Critical("On")

        if (!this.IsRunning) {
            Critical("Off")
            return false
        }

        if (this.CheckYield()) {
            if (!this._isYielding) {
                this.App.InputManager.ReleaseAllKeys()
                this._isYielding := true
            }
            this.App.UI.UpdateAction("🛑 用户操作中，宏暂时避让...")
            this.NextTick(-50)
            Critical("Off")
            return false
        }

        this._isYielding := false
        return true
    }

    _SafeNumber(val, fallback) {
        if (!IsNumber(val))
            return fallback
        val := Float(val)
        return (val > 0) ? val : fallback
    }

    _Jitter(baseMs, intensity := 1.0) {
        ; 模拟人类操作的仿生正态分布随机波动算法：
        ; 1. 人类的操作（如反应时间）在统计学上符合正态分布
        ; 2. 时间越长，标准差相对越大，但系数保持在 5%-15% 之间

        if (baseMs <= 0)
            return 1

        ; 设定标准差：通常人类在 10% 左右波动
        stdDev := baseMs * 0.12 * intensity

        ; 使用正态分布生成随机值
        val := RandomGaussian(baseMs, stdDev)

        ; 边界硬约束：防止出现极端的（比如负数或过大）延迟
        ; 约束在 [0.75x, 1.35x] 范围内，使其更紧凑
        minBound := baseMs * 0.75
        maxBound := baseMs * 1.35 + 20

        return Integer(Clamp(val, minBound, maxBound))
    }

    ; 模拟人类按下前的“思考/反应”微小延迟
    _HumanStepDelay() {
        ; 模拟 30ms - 80ms 的熟练玩家反应时间
        delay := RandomGaussian(50, 15)
        Sleep(Integer(Clamp(delay, 20, 100)))
    }

    ; 检查用户是否正在物理操作 (仅在目标窗口前台时检测)
    IsUserHoldingKey() {
        ; 先检查鼠标按钮 (最常用)
        if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P"))
            return true

        ; 再检查修饰键 (注意：移除了 Shift，允许在按住 Shift 时继续运行宏，以兼容操作同步模式)
        if (GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P"))
            return true

        ; 最后检查常用游戏按键 (包含方向键和ZXCV等横版游戏常用键)
        static gameKeys := ["w", "a", "s", "d", "Up", "Down", "Left", "Right",
            "Space", "q", "e", "r", "f", "z", "x", "c", "v",
            "1", "2", "3", "4", "5", "6", "Enter", "Esc", "Tab"]
        for _, k in gameKeys {
            if GetKeyState(k, "P")
                return true
        }
        return false
    }

    ; 检查是否需要避让用户操作
    CheckYield() {
        hwnd := this.App.InputManager.ResolveTarget()
        if (hwnd == 0)
            return false

        isActive := WinActive("ahk_id " hwnd)
        isSyncActive := (this.App.SyncManager._isSyncEnabled || this.App.SyncManager._isShiftSyncing)

        ; 核心避让逻辑更新：
        ; 1. 如果是活跃窗口，或者正在接收同步输入，则进入判定
        ; 2. 判定条件：物理按键、系统键盘空闲时间、或者最近一次同步输入时间

        ; 如果既不是活跃窗口，也没有开启同步，且最近没有同步活动，则不避让
        if (!isActive && !isSyncActive && (A_TickCount - this.App.SyncManager._lastSyncTime > 200))
            return false

        ; 如果开启了同步但在操作非游戏窗口（如浏览器），后台宏不应避让
        if (!isActive && isSyncActive && !this.App._IsGameWindowActive())
            return false

        ; 最终判定：检测物理按键持有、系统输入活跃度、或进程内同步活跃度
        if (this.IsUserHoldingKey() || (A_TimeIdleKeyboard < 200) || (A_TickCount - this.App.SyncManager._lastSyncTime <
            200))
            return true

        return false
    }

    ; 可中断等待 (用于按键 down→up 之间的间隔)
    ; @param ms 等待毫秒数
    ; @param canInterruptByPriority 是否允许被高优先级技能（SkillQueue）中断
    ; @param repeatKey 如果提供，则在等待期间定期发送此按键的 Down (repeat) 报文
    WaitOrInterrupt(ms, canInterruptByPriority := false, repeatKey := "") {
        endTime := A_TickCount + ms
        nextRepeat := A_TickCount + 80 ; 初始 80ms 后开始重复

        while (A_TickCount < endTime) {
            if (!this.IsRunning)
                return false

            isYield := this.CheckYield()

            if (isYield) {
                ; 发生避让，挂起并释放当前按键
                if (repeatKey != "")
                    this.App.InputManager.SendKey(repeatKey, false)
                else
                    this.App.InputManager.ReleaseAllKeys()

                this.App.UI.UpdateAction("🛑 用户操作中，技能挂起避让...")

                remaining := endTime - A_TickCount

                ; 持续等待，直到避让结束 (阻塞当前协程)
                while (this.CheckYield() && this.IsRunning) {
                    Sleep(15)
                }

                if (!this.IsRunning)
                    return false

                ; 避让结束，核心点：重新按下当前按键，恢复宏指令的长压状态！
                if (repeatKey != "") {
                    this.App.UI.UpdateAction("⚔️ 避让完成，恢复长按：[ " StrUpper(repeatKey) " ]")
                    this.App.InputManager.SendKey(repeatKey, true)
                    nextRepeat := A_TickCount + 80
                }

                ; 顺延结束时间，确保目标按键按压的有效总时长不受干扰
                endTime := A_TickCount + remaining
            }

            ; 模拟物理按键重复 (Bit 30 = 1)，保持游戏内长按状态不中断
            if (repeatKey != "" && A_TickCount > nextRepeat) {
                this.App.InputManager.SendKey(repeatKey, true, true)
                nextRepeat := A_TickCount + this._Jitter(100, 0.3) ; 带有微量随机抖动的重复频率
            }

            ; 检查高优先级中断 (例如到了大招释放时间)
            if (canInterruptByPriority && this.HasOwnProp("SkillQueue") && this.SkillQueue.Length > 0)
                return false

            Sleep(15)  ; 15ms 步进
        }
        return true
    }

    ; ========================================================
    ; 通用技能处理逻辑 (供子类组合调用)
    ; ========================================================
    HandleTimedSkills(castDelay := 400) {
        if (!this.HasOwnProp("SkillQueue") || this.SkillQueue.Length == 0)
            return false

        keyName := this.SkillQueue.RemoveAt(1)

        ; 获取配置的时长 (用户要求隐藏 UI，此处直接读取定义值)
        durSec := 0.5
        for _, def in this.TimedSkills {
            if (def.Key == keyName) {
                durSec := def.DefaultDuration
                break
            }
        }

        this.App.UI.UpdateAction("⚡ 定时技能：[ " StrUpper(keyName) " ] (" durSec "秒)")

        Critical("On")

        this._HumanStepDelay()
        this.App.InputManager.SendKey(keyName, true)
        Critical("Off")

        if (!this.WaitOrInterrupt(this._Jitter(durSec * 1000, 0.8), false, keyName)) {
            Critical("On")
            this.App.InputManager.SendKey(keyName, false)
            this.SkillQueue.InsertAt(1, keyName)
            this.NextTick(-10)
            Critical("Off")
            return true
        }

        Critical("On")
        this.App.InputManager.SendKey(keyName, false)
        this.NextTick(-1 * this._Jitter(castDelay, 0.8))
        Critical("Off")
        return true
    }

    HandleCycleSkills(skills, pressInt := 40) {
        if (skills.Length == 0)
            return false

        if (!this.HasOwnProp("CurrentIndex") || this.CurrentIndex > skills.Length)
            this.CurrentIndex := 1

        skill := skills[this.CurrentIndex]
        this.App.UI.UpdateAction("⚔️ 技能长按：[ " skill.Name " ] (" skill.DurSec "秒)")

        ; 熟练玩家优化：模拟连招时的肌肉记忆，延迟在 30ms-60ms 之间波动
        if (this.CurrentIndex == 1)
            this._HumanStepDelay()
        else {
            delay := RandomGaussian(45, 10)
            Sleep(Integer(Clamp(delay, 25, 80)))
        }

        this.App.InputManager.SendKey(skill.Key, true)
        Critical("Off")

        if (!this.WaitOrInterrupt(this._Jitter(skill.DurSec * 1000, 1.0), true, skill.Key)) {
            this.App.InputManager.SendKey(skill.Key, false)
            this.NextTick(-10)
            return true
        }

        Critical("On")
        this.App.InputManager.SendKey(skill.Key, false)

        this.CurrentIndex++
        if (this.CurrentIndex > skills.Length)
            this.CurrentIndex := 1

        ; 技能间隙：使用适度的抖动系数 (0.8)，模拟熟练玩家的节奏感
        this.NextTick(-1 * this._Jitter(pressInt, 0.8))
        Critical("Off")
        return true
    }

    HandleHoldA(mainPressInt := 50) {
        val := this.App.UI.GetVal("chkA", 0)
        if (!val) {
            if (this.App.InputManager._heldKeys.Has("a"))
                this.App.InputManager.SendKey("a", false)
            return false
        }

        ; 疲劳休息逻辑：仅对长按A键生效
        if (this._isResting) {
            if (A_TickCount < this._restUntil) {
                this.App.UI.UpdateAction("☕ 模拟疲劳，A键休息中...")
                this.NextTick(-200)
                return true
            }
            this._isResting := false
            this._nextShortRestTime := A_TickCount + this._Jitter(180000, 1.5) ; 2-4分钟后再休息
        }
        if (!this._isResting && this._nextShortRestTime > 0 && A_TickCount > this._nextShortRestTime) {
            restDur := this._Jitter(4000, 1.5)
            this._isResting := true
            this._restUntil := A_TickCount + restDur
            if (this.App.InputManager._heldKeys.Has("a"))
                this.App.InputManager.SendKey("a", false)
            this.NextTick(-10)
            return true
        }

        if (!this.App.InputManager._heldKeys.Has("a")) {
            this.App.UI.UpdateAction("👉 普攻长按：[ A ]")
            this._HumanStepDelay()
            this.App.InputManager.SendKey("a", true)
            this._aHoldStart := A_TickCount
            this._aNextBreak := A_TickCount + this._Jitter(5000, 2.0)
        } else {
            if (this.HasOwnProp("_aNextBreak") && A_TickCount > this._aNextBreak) {
                this.App.UI.UpdateAction("♻️ A键防检测换气...")
                this.App.InputManager.SendKey("a", false)
                this.NextTick(-1 * this._Jitter(80, 0.5))
                return true
            }
            this.App.UI.UpdateAction("👉 普攻长按：[ A ] (保持中)")
            this.App.InputManager.SendKey("a", true, true)
        }

        this.NextTick(-1 * this._Jitter(mainPressInt, 0.5))
        return true
    }
}

; ========================================================
; 配置驱动的通用引擎 (从 MacroConfig 自动构建)
; ========================================================
class ConfigMacroEngine extends MacroEngineBase {
    CurrentIndex := 1
    SkillCount := 0
    SkillQueue := []

    ; 定时技能配置表
    TimedSkills := []
    BoundFirers := Map()

    ; === 缓存参数 ===
    _cycleSkills := []
    _cyclePressInt := 80
    _mainPressInt := 100
    _castDelay := 500

    __New(appRef) {
        super.__New(appRef)
        cfg := appRef.Config

        ; 从配置读取性能参数
        this._cyclePressInt := cfg.CyclePressInt
        this._mainPressInt := cfg.MainPressInt
        this._castDelay := cfg.CastDelay

        ; 从配置注册定时技能
        if (cfg.TimedSkills.Length > 0) {
            this.TimedSkills := []
            for _, def in cfg.TimedSkills {
                dur := def.HasOwnProp("DefaultDuration") ? def.DefaultDuration : 0.5
                this.TimedSkills.Push(TimedSkillDef(def.Name, def.Key, def.DefaultInterval, dur))
            }
            for _, def in this.TimedSkills
                this.BoundFirers[def.Key] := ObjBindMethod(this, "FireTimedSkill", def.Key)
        }
    }

    OnStart() {
        this._CacheParams()

        if (this.TimedSkills.Length > 0)
            this.StartTimedSkills()
        return true
    }

    _CacheParams() {
        ui := this.App.UI
        cfg := this.App.Config

        this._cycleSkills := []
        for _, skill in cfg.CycleSkills {
            if (ui.GetVal("chkSkill" skill.Name, 1))
                this._cycleSkills.Push({ Name: skill.Name, Key: skill.Key, DurSec: this._SafeNumber(ui.GetVal("edtDur" skill
                    .Name, skill.DefaultDur), skill.DefaultDur) })
        }

        if (this.IsRunning && this.TimedSkills.Length > 0)
            this.SyncTimedSkills()
    }

    ; 通用主循环: 定时技能 > 循环技能 > 长按A普攻
    GameLoopTick() {
        if (!this.BaseTick())
            return

        ; ====== 第一优先级: 定时技能队列 ======
        if (this.HandleTimedSkills(this._castDelay))
            return

        ; ====== 第二优先级: 循环技能 ======
        if (this._cycleSkills.Length > 0 && this.HandleCycleSkills(this._cycleSkills, this._cyclePressInt))
            return

        ; ====== 第三优先级: A 键普攻 ======
        if (this.HandleHoldA(this._mainPressInt))
            return

        this.App.UI.UpdateAction("⏳ 全部技能已关闭，空闲等待中...")
        this.NextTick(-1000)
    }
}
