#Requires AutoHotkey v2.0

; 设置工作目录为脚本所在目录
SetWorkingDir(A_ScriptDir)

; 定义需要启动的脚本列表
scripts := ["JS.ahk", "YX.ahk", "XS.ahk", "HL.ahk"]

for script in scripts {
    if FileExist(script) {
        try {
            Run(script)
        } catch as err {
            MsgBox("启动脚本失败: " . script . "`n错误信息: " . err.Message)
        }
    } else {
        MsgBox("未找到脚本文件: " . script)
    }
}

; 启动完成后退出
ExitApp()