#Requires AutoHotkey v2.0
#SingleInstance Force
#Include MacroCore.ahk

; ========================================================
; JS宏 - 剑侍专版 (纯配置声明)
; 特点：S/D/F/Q 技能循环 + A键自动普攻
; ========================================================
cfg := MacroConfig()
cfg.Title := "JS宏"
cfg.ToggleKey := "1"
cfg.FocusKey := "9"
cfg.PreferredX := -2550
cfg.BasicPanel := { Text: "🗡️ 仅使用 [ A ] 普攻模式", DefaultVal: 0 }
cfg.CycleSkills := [{ Name: "S", Key: "s", DefaultDur: 1 }, { Name: "D", Key: "d", DefaultDur: 10 }, { Name: "F", Key: "f",
    DefaultDur: 1 }, { Name: "Q", Key: "q", DefaultDur: 2 }
]

global AppInstance := GameMacroAppBase.LaunchFromConfig(cfg)