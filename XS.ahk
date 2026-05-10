#Requires AutoHotkey v2.0
#SingleInstance Force
#Include MacroCore.ahk

; ========================================================
; XS宏 - 仙术专版 (纯配置声明)
; 特点：远程快捷触发 + 定时技能队列 + A键自动普攻
; ========================================================
cfg := MacroConfig()
cfg.Title := "XS宏"
cfg.ToggleKey := "3"
cfg.FocusKey := "-"
cfg.PreferredY := 800
cfg.BasicPanel := { Text: "🔄 开启长按 [ A ] 键主循环", DefaultVal: 1 }
cfg.TimedSkills := [{ Name: "Q", Key: "q", DefaultInterval: 20, DefaultDuration: 1.0 }, { Name: "W", Key: "w",
    DefaultInterval: 300, DefaultDuration: 1.0 }, { Name: "E", Key: "e", DefaultInterval: 300, DefaultDuration: 1.0 }, { Name: "R",
        Key: "r", DefaultInterval: 1800, DefaultDuration: 1.0 }
]
cfg.RemoteHotkeys := [{ Trigger: "z", Target: "q" }, { Trigger: "x", Target: "w" }, { Trigger: "v", Target: "t" }]

global AppInstance := GameMacroAppBase.LaunchFromConfig(cfg)