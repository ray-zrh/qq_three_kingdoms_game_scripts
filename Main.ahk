#Requires AutoHotkey v2.0

; ========================================================
; 管理员权限自提升 (Win11 默认以管理员运行)
; ========================================================
if !A_IsAdmin {
    try {
        Run('*RunAs "' A_ScriptFullPath '" /restart')
        ExitApp()
    } catch {
        MsgBox("无法获取管理员权限，脚本可能无法正常工作。", "主控控制台 - 权限警告", "Icon!")
    }
}

#SingleInstance Force

; 全局异常拦截 (第一次报错即强制中断)
OnError(GlobalErrorHandler)
GlobalErrorHandler(err, mode) {
    MsgBox("主控台发生严重报错，脚本已强制中断运行！`n`n错误信息: " err.Message "`n所在文件: " err.File "`n所在行数: " err.Line, "安全警报 - 进程终止", "Iconx")
    ExitApp(-1)
    return 1  ; AHK v2: 返回 1 表示已处理
}

; ========================================================
; 创建主界面
; ========================================================
MainGui := Gui(, "多进程游戏宏控制台")
MainGui.OnEvent("Close", (*) => ExitApp())

MainGui.SetFont("s10", "微软雅黑")
Tabs := MainGui.Add("Tab3", "w250 h820", ["JS宏", "XS宏", "YX宏"])

; 针对每个 Tab 增加一个无边框的占位控件，用来挂载子进程的独立窗口
; 手动管理占位控件以避免 Tab3 的渲染和裁切 Bug
Tabs.UseTab()
phJS := MainGui.Add("Text", "w230 h780 x15 y40 +0x02000000")
phXS := MainGui.Add("Text", "w230 h780 x15 y40 +0x02000000 Hidden")
phYX := MainGui.Add("Text", "w230 h780 x15 y40 +0x02000000 Hidden")

Tabs.OnEvent("Change", (*) => OnTabChange())
OnTabChange() {
    phJS.Visible := (Tabs.Value == 1)
    phXS.Visible := (Tabs.Value == 2)
    phYX.Visible := (Tabs.Value == 3)
}

; 显示主界面
MainGui.Show("w270 h840")

; ========================================================
; 注册数字键切换选项卡 (仅在控制台窗口激活时生效)
; ========================================================
HotIfWinActive("ahk_id " MainGui.Hwnd)
Hotkey("1", (*) => SwitchTab(1))
Hotkey("2", (*) => SwitchTab(2))
Hotkey("3", (*) => SwitchTab(3))
Hotkey("Numpad1", (*) => SwitchTab(1))
Hotkey("Numpad2", (*) => SwitchTab(2))
Hotkey("Numpad3", (*) => SwitchTab(3))
HotIf()  ; 恢复全局作用域

SwitchTab(n) {
    Tabs.Choose(n)
    OnTabChange()
}

; ========================================================
; 启动并内嵌子进程
; ========================================================
hwndJS := phJS.Hwnd
hwndXS := phXS.Hwnd
hwndYX := phYX.Hwnd

Global pidJS := 0, pidXS := 0, pidYX := 0

; 启动子进程并传递对应的占位句柄
try
    Run('"' A_AhkPath '" "' A_ScriptDir '\JS.ahk" ' hwndJS, , , &pidJS)
catch as e
    MsgBox("JS宏启动失败: " e.Message, "启动错误", "Icon!")

try
    Run('"' A_AhkPath '" "' A_ScriptDir '\XS.ahk" ' hwndXS, , , &pidXS)
catch as e
    MsgBox("XS宏启动失败: " e.Message, "启动错误", "Icon!")

try
    Run('"' A_AhkPath '" "' A_ScriptDir '\YX.ahk" ' hwndYX, , , &pidYX)
catch as e
    MsgBox("YX宏启动失败: " e.Message, "启动错误", "Icon!")

; ========================================================
; 清理逻辑 (关闭主程序时退出所有子进程)
; ========================================================
OnExit(CloseChildren)

CloseChildren(*) {
    pids := [pidJS, pidXS, pidYX]
    for _, pid in pids {
        if (!pid)
            continue
        try {
            ProcessClose(pid)
            ; 等待最多 500ms，如果还活着就强制终止
            if ProcessExist(pid) {
                Sleep(500)
                if ProcessExist(pid)
                    DllCall("TerminateProcess", "Ptr", DllCall("OpenProcess", "UInt", 1, "Int", 0, "UInt", pid, "Ptr"), "UInt", 1)
            }
        }
    }
}
