# fetch-joyose-teg_config

用于拉取 Joyose 下发到设备的调度配置。

## 直接使用

双击运行：

```text
fetch-joyose-teg_config.cmd
```

脚本会在脚本所在目录生成压缩包：

```text
myron-OS3.0.306.0.WPMCNXM-teg_config.zip
```

默认压缩包内只保留这两个文件：

```text
[booster_config].json
[common_config].json
```

运行结束后不会额外留下散文件；需要查看 json 时，直接解压 zip 即可。

## 修改机型和版本

需要拉取其他机型时，打开 `fetch-joyose-teg_config.cmd`，修改文件开头的配置：

```powershell
$Server = "cn"
$Device = "myron"
$MiuiRegion = "CN"
$Locale = "zh_CN"
$Incremental = "OS3.0.306.0.WPMCNXM"
$MiuiVersionName = "V816"
$BuildType = "stable"
$AndroidRelease = "16"
$AppVersion = "490"
$VersionName = "2.4.90"
$LocalVersion = "0"
```

压缩包名称只按脚本里写的 `$Device` 和 `$Incremental` 生成，格式为：

```text
机型-版本-teg_config.zip
```

例如：

```text
myron-OS3.0.306.0.WPMCNXM-teg_config.zip
```

## PowerShell 运行方式

也可以直接运行 PowerShell 版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fetch-joyose-teg_config.ps1
```

指定机型和版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fetch-joyose-teg_config.ps1 -Device myron -Incremental OS3.0.306.0.WPMCNXM
```

## 保留其他文件

默认只输出 zip，不保留中间文件。

如果需要调试或保留其他拉取结果：

- CMD 版本：把 `fetch-joyose-teg_config.cmd` 开头的 `$KeepDebugFiles = $false` 改成 `$true`
- PowerShell 版本：运行时加 `-KeepDebugFiles`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fetch-joyose-teg_config.ps1 -KeepDebugFiles
```

开启后会保留请求响应、规则文件、模块文件和完整导出的配置文件，方便排查格式或接口问题。

## 说明

- 脚本默认输出目录就是脚本运行目录。
- 默认只保留 `[booster_config].json` 和 `[common_config].json` 到 zip 内。
- 如果看到 PowerShell 或 curl 的 TLS 连接警告，脚本会继续尝试其他请求方式；最终看到 zip 生成即为成功。
