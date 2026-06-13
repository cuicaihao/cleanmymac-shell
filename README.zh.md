# mac-cleaner：安全、先审查的 macOS 清理工具

![mac-cleaner](mac-cleaner.webp)

`mac-cleaner` 是一个保守的 macOS 清理命令行工具，适合希望在删除任何内容之前先看到清理计划的用户。

它会扫描旧缓存、日志、临时文件、开发者缓存，以及需要显式开启的清理区域，例如 Downloads、Trash、Docker 和 Xcode archives。

默认行为是安全的：它只扫描、打印审查计划，并写入一个已注释的清理脚本。执行模式不会永久删除文件；你批准的项目会被移动到 `~/.Trash` 下带时间戳的恢复目录。

## 安装

安装最新的 GitHub Release：

```bash
curl -L https://github.com/cuicaihao/cleanmymac-shell/releases/latest/download/mac-cleaner.tar.gz -o mac-cleaner.tar.gz
tar -xzf mac-cleaner.tar.gz
chmod +x mac-cleaner
mkdir -p "$HOME/.local/bin"
mv mac-cleaner "$HOME/.local/bin/mac-cleaner"
```

或者从源码 checkout 安装：

```bash
make install PREFIX="$HOME/.local"
```

请确保 `$HOME/.local/bin` 已在你的 `PATH` 中。

## 快速开始

始终先从 dry run 开始，预览待清理项目：

```bash
mac-cleaner --verbose
```

Dry-run 模式会以精美的格式打印清理计划的层级树，并写入一个已注释的 `clean.sh` 审查脚本：

```text
✨ mac-cleaner v1.2.0
────────────────────────────────────────────────────────
Mode:          Dry Run (Safe mode, preview only)
Log File:      ~/.local/state/mac-cleaner/mac-cleaner.log
Age Threshold: > 14 day(s)
────────────────────────────────────────────────────────

== Cleanup plan ==
❯ Old user logs [low risk]
  Note: Logs are usually safe to move, but can help investigate older issues.
  ├── 8.0 KiB     (1 item)  ~/Library/Logs/PhotosUpgrade.aapbz
  ├── 20.0 KiB    (6 items)  ~/Library/Logs/iStat Menus 7
  └── Total: 28.0 KiB  (7 items)

❯ User cache contents older than threshold [low risk]
  Note: Usually safe to regenerate. Apps may rebuild these files later.
  ├── empty       (1 item)  ~/.cache/antigravity
  ├── 2.0 MiB     (1 item)  ~/.cache/gitstatus
  ├── 75.6 MiB    (4 items)  ~/Library/Application Support/Code/CachedData
  ├── 48.0 KiB    (1 item)  ~/Library/Caches/GameKit
  └── Total: 77.6 MiB  (11 items)

❯ Crash reports older than threshold [medium risk]
  Note: Useful for troubleshooting older app crashes. Safe to move after review.
  ├── 16.0 KiB    (2 items)  ~/Library/Logs/DiagnosticReports
  └── Total: 16.0 KiB  (2 items)

❯ Developer caches [medium risk]
  Note: Usually safe to regenerate, but the next build, package install, or simulator launch may be slower.
  ├── 237.9 MiB   (1 item)  ~/.npm/_cacache
  ├── 55.2 MiB    (1 item)  ~/Library/Caches/Homebrew
  ├── 111.0 MiB   (1 item)  ~/Library/Caches/go-build
  ├── 14.9 MiB    (1 item)  ~/Library/Caches/pip
  ├── empty       (1 item)  ~/Library/Developer/CoreSimulator
  └── Total: 419.0 MiB  (5 items)

Dry-run cleanup script written to: clean.sh
All rm -rf lines are commented. Review, edit, and run it yourself only if you are confident.

== Skipped optional groups ==
  Old Xcode archives: skipped. Use --include-xcode-archives to include Organizer archives older than the threshold.
  Downloads older than threshold: skipped. Use --include-downloads to include ~/Downloads.
  Trash: skipped. Use --empty-trash to include ~/.Trash.
  Docker cleanup: skipped. Use --include-docker to prune Docker caches and stopped resources.

📊 Final Summary
────────────────────────────────────────────────────────
Can be reclaimed:          25 items      496.7 MiB
Actually moved:             0 items            0 B
────────────────────────────────────────────────────────

Review the paths above. If they look safe, run:
  ./mac-cleaner.sh --execute
```

如需逐个文件完整审查：

```bash
mac-cleaner --show-files
```

如需引导式设置流程：

```bash
mac-cleaner --interactive
```

如需查找占用空间较大的个人文件：

```bash
mac-cleaner large-files --min-size 500M --older-than 30
```

当你确认计划安全，准备执行清理时：

```bash
mac-cleaner --execute
```

执行模式会再次显示每个分组，打印该分组下的具体文件，并要求你进行确认 (`y/N/q`)。批准的文件会被安全地移动到 `~/.Trash/mac-cleaner-*`（不会被永久删除）。

## 常用选项

```bash
mac-cleaner --verbose                       # 以树状图层级格式展示分组文件夹和大小
mac-cleaner --show-files                     # 打印扫描到的每一个具体文件路径
mac-cleaner --interactive                  # 引导式交互配置与确认
mac-cleaner --no-color                     # 禁用终端彩色输出
mac-cleaner --dry-run --older-than 30 --include-downloads --verbose
mac-cleaner large-files --min-size 1G --older-than 90
mac-cleaner dev-clean --verbose
mac-cleaner dev-clean --include-brew
mac-cleaner applications --output apps.md
mac-cleaner startup --output startup.md
mac-cleaner uninstall /Applications/AppName.app
mac-cleaner --clean-log                    # 清空工具自身的历史日志文件
mac-cleaner --execute --empty-trash        # 执行清理并清空系统垃圾桶 (~/.Trash)
mac-cleaner --execute --include-docker      # 触发 Docker 缓存与停止资源的 prune 清理
mac-cleaner --execute --include-xcode-archives
```

## 它会清理什么

- 旧的用户缓存内容，包括常见浏览器和编辑器缓存。
- `~/Library/Logs` 中的旧文件。
- 旧的崩溃报告。
- 当前 macOS 临时目录中的旧临时文件。
- 开发者缓存，例如 Xcode DerivedData、Homebrew、npm、pip、Cargo、Gradle 和模拟器缓存。
- 可选的 `~/Downloads` 旧文件。
- 可选的 `~/.Trash` 内容。
- 可选的 Docker builder 和 system prune。
- 可选的旧 Xcode Organizer archives。

## 大文件扫描

`large-files` 命令会扫描常见用户内容目录（`Desktop`、`Documents`、`Downloads`、`Movies`、`Music` 和 `Pictures`），找出超过指定大小且早于时间阈值的文件。

```bash
mac-cleaner large-files --min-size 500M --older-than 30
mac-cleaner large-files --execute
```

大文件会被视为高风险个人数据。Dry-run 模式按大小列出匹配文件；执行模式会在移动每个文件到恢复目录前逐个询问。

## 开发工具清理

`dev-clean` 命令先从编辑器扩展清理开始。它会扫描 VS Code 和 Cursor 的扩展目录，为每个扩展保留最近修改的一个版本，并列出旧版本供你审查。它也会以报告形式展示已安装的 iOS Simulator runtimes。Homebrew cleanup 审查需要显式添加 `--include-brew`，并且只会运行 `brew cleanup -n`。

```bash
mac-cleaner dev-clean --verbose
mac-cleaner dev-clean --include-brew
mac-cleaner dev-clean --execute
```

旧扩展版本会被视为中风险项目；执行模式会将其移动到恢复目录。Homebrew cleanup 和 simulator runtimes 仍然仅报告；此命令不会运行永久性的 `brew cleanup`，也不会删除 simulator runtimes。

## 应用报告

`applications` 命令会先盘点已安装 app，帮助你决定哪些 app 值得进一步检查或移除。它默认扫描 `/Applications` 和 `~/Applications`，报告大小与 bundle 元数据，也可以写出 Markdown 报告供审查。

```bash
mac-cleaner applications
mac-cleaner applications --output apps.md
mac-cleaner applications --stale-days 180 --min-size 1G
```

报告包含 app 名称、版本、Apparent Size、Disk Usage、安装日期、最近打开日期（当 Spotlight 元数据可用时）、修改日期、Bundle ID、备注、检查命令和路径。Apparent Size 是文件内容大小之和；Disk Usage 是实际磁盘占用，并用于判断大型 app。备注会标记可能过时、大型 app、最近打开时间未知、Apple/system app 等情况。Markdown 报告还会分出全部 app、可能过时 app、最大 app、最近打开时间未知的 app 等部分。可以使用 `--app-root PATH` 扫描自定义 app 目录。

## 卸载检查

`uninstall` 命令目前仅用于检查。它会读取 app bundle 的 `Info.plist`，报告 app 名称和 Bundle ID，然后列出用户 Library 中可能相关的文件。

```bash
mac-cleaner uninstall /Applications/AppName.app
```

它会报告 application support、cache、preferences、containers、group containers、logs 以及 app bundle 本身等匹配项。每个匹配项都会显示被选中的原因，例如 Bundle ID 或 app 名称。它暂时不会移动文件；在匹配规则被验证足够保守之前，`--execute` 会被明确拒绝。

## 启动项报告

`startup` 命令目前仅用于报告。它会列出用户 LaunchAgents、全局 LaunchAgents、LaunchDaemons，以及在可读取时列出 Login Items。

```bash
mac-cleaner startup
mac-cleaner startup --output startup.md
```

报告包含 scope、label、program、`RunAtLoad`、`KeepAlive`、可用时的 disabled 状态、修改日期、大小、备注和路径。备注会标记 auto-start、keepalive、system-wide、Apple/system、third-party、recently modified、missing program path 等情况。Markdown 报告会分出全部项目、用户启动项、系统级启动项、auto-start/KeepAlive 项、缺失 program 路径等部分。它不会禁用或删除启动项。

## 审查脚本

Dry-run 模式会写入一个带注释命令的 `clean.sh` 审查脚本。非破坏性元数据、标题和大小均使用双井号 `##` 前缀注释，而实际具有破坏性的清理命令则使用单井号 `#` 注释：

```bash
## == User cache contents older than threshold [low risk] ==
## Size: 4.0 KB
# rm -rf -- /Users/you/Library/Caches/example
```

这种布局允许你在任何现代编辑器（如 VS Code、Cursor、Xcode）中打开 `clean.sh`，直接选择你想要批准的文件块，然后按下 **Cmd + /** (或 **Ctrl + /**) 即可快速仅反注释 `rm -rf` 命令行，同时让分组标题和大小警告保持被 `##` 注释的状态。

在你手动审查和运行之前，此文件中的任何命令都绝对不会执行。注意，内置的 `--execute` 模式比运行生成的脚本更安全，因为它会先将文件移动到 Trash 而非直接永久删除。

## 配置

你可以在 `~/.config/mac-cleaner/config` 中保存常用选项。也支持旧路径 `~/.mac-cleaner.rc`。

配置按以下顺序生效：

```text
内置默认值 < 配置文件 < 命令行参数
```

可以从示例配置开始：

```bash
mkdir -p ~/.config/mac-cleaner
cp examples/mac-cleaner.config.example ~/.config/mac-cleaner/config
```

示例配置：

```bash
# 使用 1 启用选项，使用 0 禁用选项。
OLDER_THAN_DAYS=30
VERBOSE=1
SHOW_FILES=0

INCLUDE_DOWNLOADS=0
INCLUDE_DOCKER=0
INCLUDE_XCODE_ARCHIVES=0
EMPTY_TRASH=0
```

配置文件会作为 shell 片段加载。不要粘贴或使用来自不可信来源的配置文件。

## 日志

脚本会在 `${XDG_STATE_HOME:-$HOME/.local/state}/mac-cleaner/mac-cleaner.log` 维护持久日志。

持久日志会注意隐私：终端输出会显示准确的本地路径供你审查，但保存到日志中的路径细节会被省略。

如需在不运行清理扫描的情况下清空日志：

```bash
mac-cleaner --clean-log
```

## 安全说明

- 脚本不会扫描受保护的系统目录。
- 脚本不需要管理员权限。
- `~/Downloads`、`~/.Trash`、Docker 清理和 Xcode Organizer archives 都需要显式开启。
- 执行模式会先把文件移动到 `~/.Trash/mac-cleaner-*`，而不是永久删除。
- 执行模式在移动每个分组前都需要输入 `y`；默认是 No。输入 `q` 可以停止审查剩余分组。
- `--yes` 可以在可信自动化中跳过低/中风险提示。高风险分组仍然会询问。
- Docker 清理是独立且永久的。在交互式执行模式中，它需要输入 `PRUNE`。
- 使用 `--include-downloads`、`--empty-trash`、`--include-docker` 和 `--include-xcode-archives` 时要格外小心。
- Xcode Organizer archives 可能包含发布构建、dSYM 和提交历史。开启前请先审查 dry-run 输出。
- 始终先运行 dry run，并在使用 `--execute` 前阅读输出。

## 开发

检查、版本管理和发布步骤请参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT License。参见 [LICENSE](LICENSE)。
