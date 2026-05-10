; ========================================================
; 全局启动配置与环境检查
; ========================================================
; 确保以管理员权限运行
if !A_IsAdmin {
    try {
        Run("*RunAs `"" . A_ScriptFullPath . "`"")
    }
    ExitApp()
}

#WinActivateForce
SetTitleMatchMode(2)  ; 匹配模式：包含即可 (提高窗口检测成功率)
InstallKeybdHook()
InstallMouseHook()

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
SendMode("Input") ; 优化：提升非 PostMessage 注入的默认发送速度
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
; 仿生辅助函数 (全局)
; ========================================================
; 正态分布随机数 (Box-Muller)
RandomGaussian(mean, stdDev) {
    static nextNextGaussian := 0
    static hasNextNextGaussian := false

    if (hasNextNextGaussian) {
        hasNextNextGaussian := false
        return nextNextGaussian * stdDev + mean
    }

    u := 0, v := 0, s := 0
    while (s >= 1 || s == 0) {
        u := Random() * 2 - 1
        v := Random() * 2 - 1
        s := u * u + v * v
    }

    s := Sqrt(-2 * Log(s) / s)
    nextNextGaussian := v * s
    hasNextNextGaussian := true
    return u * s * stdDev + mean
}

Clamp(val, min, max) {
    return (val < min) ? min : (val > max ? max : val)
}

; ========================================================
; 配置类 (用于声明式驱动宏引擎)
; ========================================================
class MacroConfig {
    Title := ""
    ToggleKey := ""
    FocusKey := ""
    PreferredX := 0
    PreferredY := 30
    BasicPanel := ""        ; { Text: "...", DefaultVal: 0 } 或 "" 表示不显示
    CycleSkills := []       ; [ { Name: "S", Key: "s", DefaultDur: 1 }, ... ]
    TimedSkills := []       ; [ { Name: "E", Key: "e", DefaultInterval: 1800, DefaultDuration: 0.5 }, ... ]
    RemoteHotkeys := []     ; [ { Trigger: "z", Target: "q" }, ... ]
    CyclePressInt := 80     ; 技能切换的物理抬手间隔 (ms)
    MainPressInt := 100     ; A键逻辑的轮询心跳间隔 (ms)
    CastDelay := 500        ; 独立技能后的硬直保护时长 (ms)
}

; ========================================================
; 核心模块引入
; ========================================================
#Include Core\InputManager.ahk
#Include Core\SyncManager.ahk
#Include Core\MacroEngine.ahk
#Include Core\MacroUI.ahk
#Include Core\MacroApp.ahk
