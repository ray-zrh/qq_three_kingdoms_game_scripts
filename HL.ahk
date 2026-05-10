#Requires AutoHotkey v2.0
#SingleInstance Force
#Include MacroCore.ahk

; ========================================================
; HL宏 - 唤灵专版 (纯配置声明)
; 特点：定时大招队列(E/R/T) + S/D/F/Q 技能循环 + A键自动普攻
; ========================================================
cfg := MacroConfig()
cfg.Title := "HL宏"
cfg.ToggleKey := "4"
cfg.FocusKey := "="
cfg.PreferredX := -2550
cfg.PreferredY := 800
cfg.BasicPanel := { Text: "🐉 仅开启 [ A ] 普攻", DefaultVal: 0 }
cfg.CycleSkills := [{ Name: "S", Key: "s", DefaultDur: 0.7 }, { Name: "D", Key: "d", DefaultDur: 8 }, { Name: "F", Key: "f",
    DefaultDur: 1 }, { Name: "Q", Key: "q", DefaultDur: 1.5 }
]
cfg.TimedSkills := [{ Name: "E", Key: "e", DefaultInterval: 1800 }, { Name: "R", Key: "r", DefaultInterval: 360 }, { Name: "T",
    Key: "t", DefaultInterval: 300 }]

global AppInstance := GameMacroAppBase.LaunchFromConfig(cfg)