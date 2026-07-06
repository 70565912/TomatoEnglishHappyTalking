## 2026-07-06 文档同步与 QA 默认配置

- [x] 文档同步：绘本章节规划 prompt 输出边界、Windows QA 默认开启、脚本示例命令简化

  处理记录：同步更新 `docs/ai-call-flow-and-prompt-logic.md`、`docs/build-and-release-pitfalls.md`、`docs/product_ui_refactor_plan.md`、`docs/qa-remote-control.md` 与 `AGENTS.md`，明确章节规划仍提交完整正文供同次 AI 保留可见细节，但 `chapterDescription` / `sceneDescription` 需排除直接引语和内心独白原句；同时将 Windows QA 的默认启动方式改为脚本内置，文档命令统一为 `build_windows.ps1 -Run/-Release -Run`，并补充发行包关闭 QA 的显式参数。

- [x] 代码与测试同步：绘本缓存引用保持、Windows 构建脚本默认 QA 定义

  处理记录：`app/lib/services/picture_book_service.dart` 与 `app/test/api_cache_service_test.dart` 同步补充按 `pageIndex` 保留 `api_cache_article_refs` 的行为与回归测试；`tools/build_windows.ps1` 增加默认注入 `TOMATO_QA_REMOTE=true` / `TOMATO_QA_PORT=39317` 并保留用户参数覆盖能力。

  验证记录：`git diff --check`、`D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --name "picture-book"`、`D:\DevTools\flutter\bin\flutter.bat test test\practice_input_parser_test.dart`。

## 2026-07-04 Suno 检测下载与构建脚本

- [x] 检测下载跳过 Library 顶部新歌

  原计划：Suno Library 列表顶部新生成的「The Croquet Game」未被打开检查，自动化从下方标题更贴近旧版的「Alice's Croquet Game」开始，详情页歌词不匹配后停止，无法下载新歌。

  处理记录：检测下载（`_sunoExistingDownloadOnly`）启用 Library 广召回：不再要求 Library 行 `expectedScore>0` 或 `sameTitle` 才进详情页，按 DOM 自上而下打开未下载/未拒绝的 `/song/` 行，歌词 exact match 只在详情页做。新增 `library.candidate_open` 日志。同步更新 `docs/suno_song_download_rules.md`、`AGENTS.md`、`sunoAutomationSimulator.ts`。

  验证记录：`.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"` 通过；QA 触发 article 81 检测下载，`broadRecall=true`，新歌 `32e775b4...` 歌词匹配后经 CDN 保存 6.4MB v2。

- [x] `-DartDefine` 逗号参数未拆分导致 QA 不生效

  处理记录：`build_windows.ps1` / `build_android.ps1` 增加 `Expand-DartDefineValues`，单个 `-DartDefine "A=1,B=2"` 会展开为多个 `--dart-define`。

  验证记录：同上构建命令下 QA `/health` 一次可用。

## 2026-06-16 新需求处理状态

- [x] Windows 最小化后隐藏窗口阻挡桌面点击

  原计划：程序最小化以后仍然点不到背后的桌面图标，说明还有隐藏窗口阻挡桌面点击，需要修正 Windows 宿主窗口/Flutter 子窗口的最小化与隐藏状态处理。

  处理记录：前一轮基于猜测修改 Windows runner 的窗口穿透/透明度/子窗口隐藏逻辑是错误方向，已撤回这些改动，避免继续引入不可见窗口和任务栏无法点击的问题。重新联调后确认真正阻挡桌面的不是 Flutter 主窗口，而是 WebView2 独立进程留下的 `msedgewebview2.exe` / `Chrome_RenderWidgetHostHWND` 顶层窗口；只按 `tomato_english_happy_talking.exe` 主进程枚举窗口会漏掉这个对象。已在 Windows runner 中处理 `WM_SIZE`、`WM_SHOWWINDOW`、`WM_WINDOWPOSCHANGED`，当宿主窗口最小化/隐藏时同步隐藏属于本进程子进程链、或与宿主窗口上次可见区域重叠的 WebView2 Chrome 顶层窗口，还原时再显示回来；同时加了 `has_been_shown_` 启动保护，避免首帧显示前误隐藏导致窗口打不开。`tools/window_blocking_probe.ps1` 已增强为输出命中窗口的进程名、父进程、路径和命令行，防止再次把 WebView2 子进程误判为“不是本程序”。

  验证记录：重新执行 `flutter build windows --release --dart-define=TOMATO_DESKTOP_DATA_ROOT=H:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking` 通过，编译产物 `app\build\windows\x64\runner\Release\tomato_english_happy_talking.exe` 时间为 `2026-06-16 15:49:09`，已覆盖到 `release\windows\tomato_english_happy_talking`。对覆盖后的发布目录 EXE 运行 `tools\window_blocking_probe.ps1 -MinimizeMode ClickTitleBar -StartupWaitSeconds 6 -AfterMinimizeWaitSeconds 3`：启动进程 `4944`，`WM_NCHITTEST` 找到最小化按钮点 `(1178,19)`，真实点击后主窗口 `Iconic=true` 且移到 `-25600`；最小化后的桌面左上、窗口原区域和屏幕中心均命中 `explorer.exe` / `SysListView32`，任务栏左侧、任务栏中心、显示桌面角分别命中 `Shell_TrayWnd` / `MSTaskSwWClass` / `TrayNotifyWnd`，未命中 Tomato 主进程或 `msedgewebview2.exe`。probe 结束后已自动退出程序，复查没有遗留 `tomato_english_happy_talking` 进程。

- [x] 绘本提示词审核、创作中心简介展示和 AI 阻塞等待反馈调整

  原计划：所有提交 AI 的同步阻塞操作，都需要在界面中显示旋转等待图标，以及等待超时倒计时，防止用户可以操作界面点选其它按钮切走界面和状态。已保存自动生成的绘本提示词供审核，存在几个问题：书籍简介跟绘本故事简述内容一样，绘本故事简述应该是当前章节内容简述，而不是书籍简介；章节组图描述变成了绘本故事简述内容，分镜描述内容才是章节组图简述内容，章节组图简述应改名为章节分镜简述；分镜描述内容框应跟随内容自动调整高度，避免浪费空间；创作中心里书籍名称旁边需要新增编辑按钮，可编辑书名和简介，书籍名称下方显示书籍简介，章节名称下方显示章节简介；已有章节分镜描述时，绘本组图可以先显示章节分镜描述，图片先空白，等生成组图后再加载显示图片。

  处理记录：已增加通用 AI 阻塞等待遮罩，自动生成书籍简介、保存章节、准备绘本提示词、刷新绘本提示词和提交绘本组图时会显示旋转等待图标与超时倒计时，并遮住界面避免用户切走或重复点其它按钮；倒计时到 0 后会提示“已超过预计等待时间，仍在等待服务返回”。绘本提示词审核弹窗已统一为书籍简介、章节描述和分镜描述，并同步调整后端绘本 v4 规划/刷新提示词；章节规划策略版本已更新，避免继续复用旧语义缓存。分镜描述文本框已改为自动高度。创作中心已接入已有 `series.update` 书籍编辑弹窗，书籍卡片和章节工具栏显示书籍简介，章节行显示后端 `story_chapters.summary_json.chapterDescription` 透出的章节简介。绘本组图列表会从每页 `prompt.scene` 读取分镜描述，即使图片仍是 queued/generating 且为空白占位，也会先显示章节分镜内容，图片 ready 后再加载缩略图。

  验证记录：`C:\Users\Ryan\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe node_modules\vitest\vitest.mjs run App.test.tsx` 通过，59 tests passed；`C:\Users\Ryan\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe node_modules\typescript\bin\tsc --noEmit` 通过；`flutter analyze app\lib\features\web_shell\web_shell_screen.dart app\lib\services\picture_book_service.dart` 通过，No issues found；已用 Node 24.14.0 执行 Vite build 并同步生成 `app/assets/web` 静态资源；`git diff --check` 通过。

- [x] 新增书籍只填书名时可自动生成书籍简介

  原计划：联调新增书籍流程时，填入书名后，“自动生成书籍描述 / 简介”按钮仍然是灰色无法点击；需要查明原因并让用户能在只填写书名的情况下生成书籍简介。

  处理记录：原因是前端 `canGenerateSeriesDescription` 只检查文章内容，未把新书籍名称作为可生成依据；同时请求后端时如果正文为空会传空 `content`，会触发后端“请先填写文章内容”的拦截。已改为书籍名称、章节标题或文章内容任一存在即可启用按钮；当正文为空时，前端会用书名构造一条最小英文上下文发给 `series.suggestDescription`，避免空 content 拦截，并让 AI 可以基于书名生成书籍级视觉简介。

  验证记录：已补充 App 回归用例覆盖“只填写书籍名称即可启用自动生成简介按钮，并向后端发送包含书名的 content”。`C:\Users\Ryan\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe node_modules\vitest\vitest.mjs run App.test.tsx` 通过，57 tests passed；`tsc --noEmit` 通过；已用 Node 24.14.0 重新执行 Vite build、Flutter Windows Debug build，并启动发布目录 EXE 供手工审核。

- [x] Suno 自动风格魔法棒只执行一次

  原计划：Suno 中打开页面后，展开 Styles，然后点击自动生成风格魔法棒按钮；等了一会刚生成风格文本就被删除了，然后重新展开 Styles 继续点击自动生成风格魔法棒按钮，不停反复。这里应该只执行一次，然后停下来等用户去确认是否提交 Create 操作，不要反复去点击自动生成风格魔法棒按钮。

  处理记录：已将 Suno 创建页的自动风格魔法棒改为单次动作。首次点击魔法棒后，Flutter 自动化立即进入 `waitingConfirm`，显示确认创建按钮并停止后续填表轮询，不再使用原来的 18 秒超时重试；注入脚本也增加保护，`magicAlreadyRequested=true` 后不会再清空 Styles 或再次点击魔法棒。用户点击确认创建前会只读同步一次当前 Styles 文本，用于保存 metadata，但同步失败不会阻断 Create。同步更新了 `sunoAutomationSimulator` 逻辑和回归用例，覆盖“即使外层误传 allowMagicClick=true，已请求过魔法棒也不能再次点击”。

  验证记录：`C:\Users\Ryan\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe node_modules\vitest\vitest.mjs run sunoAutomationSimulator.test.ts` 通过，39 tests passed；`flutter analyze lib\features\web_shell\web_shell_screen.dart` 通过，No issues found。普通 `npm --prefix web_ui test -- sunoAutomationSimulator.test.ts` 因 PATH 上 Node 16.20.2 缺少 `crypto.getRandomValues` 无法启动 Vite，已改用 bundled Node 24.14.0 完成验证。

- [x] 复核 change_list.md 中新的修改需求

  处理记录：已复核本文件中列出的新需求和当前代码实现，确认经典名著角色补全 / 章节审核提示词、云平台模型下拉选择、空书籍删除孤儿章节关系、听力进度条布局与颜色调整等实现入口和回归用例均已存在。本次复核未产生新的代码改动；`git status --short`、`git diff --stat`、`git diff --check` 均为干净输出。按前述“用户已确认测试过，提交时不用再做测试”的说明，本次未重复执行测试命令。

- [x] 经典名著公开角色补全、章节角色累积和图片 prompt 限制

  原计划：如果书籍是经典名著，网络上就有大量现成信息资料，AI 也会有相关信息。像爱丽丝梦游仙境里主要角色有白兔、疯帽匠、三月兔、红桃皇后、国王、公爵夫人、假海龟、狮鹫等，都是公开信息。可以让 AI 自己列出来主要角色，然后再去生成描述；如果 AI 找不到这本书的信息，就不用描述角色。如果书籍只有主角的描述，也可能其它角色只出现在部分章节里，可以让 AI 在章节描述里查找并生成本章节出现角色的描述，然后添加到书籍的角色描述中，这样章节角色描述可以横跨几个章节。另外，要注意图片生成提示词的限制。

  处理记录：当前绘本 v4 规划已收敛为书籍简介、章节描述和分镜描述；不再自动生成章节角色补丁，也不再把章节描述合并回 `story_series.description`。最终组图 prompt 按审核内容完整提交，不再按场景数量压缩书籍描述、章节描述或单图分镜描述。

## 2026-06-16 处理状态

- [x] E01 - All In The Golden Afternoon 提示词检查与调整

  原计划：这篇文章已经用阿里云百炼平台生成提示词并保存，需要检查生成的提示词是否达到设计要求；当前书籍描述偏向主角，没有其它配角描述，后期其它主要角色出场时无法稳定外观。

  处理记录：已读取已保存提示词，结论是章节连续性和分镜覆盖基本可用，但配角外观锚点不足。当前绘本 v4 提示词已收敛为 `bookDescription` / `chapterDescription` / `scenes[].sceneDescription`，角色外观锚点只放在书籍简介或章节描述中，不再拆出旧字段。

- [x] 云平台模型不固定为单一模型，改为下拉选择

  原计划：阿里云大模型使用 max、火山引擎使用 lite，生成效果不能横向比较；阿里云和火山引擎的大模型都应允许用户选择不同级别模型。万相可以组图，千问生图不能组图生成，这种功能性不能实现的就没必要选择。

  处理记录：设置页模型字段已改为下拉候选。阿里云百炼文本模型提供 Max/Plus/Flash 等档位，火山方舟文本模型提供高效果/低成本档位。万相和 Seedream 图片候选只保留当前组图链路可用模型，不暴露不能完成连续组图的图片模型；如果本机已有列表外自定义模型，会保留为“当前自定义”选项。

- [x] 文章为空的书籍删除失败

  原计划：文章为空的书籍，点击删除后也不能删除。

  处理记录：后端删除逻辑已改为只按真实存在的文章章节判断；如果书籍只有孤儿 `story_chapters` 关系，会先清理这些关系，再删除空书。已补充回归用例覆盖孤儿章节关系。

- [x] 听力进度条布局与颜色调整

  原计划：听力进度缩短一点，进度条换个明显的颜色，跟其它不同功能类型的 UI 控件保持部分间隔距离，而不是挤在一起。

  处理记录：听力播放器顶部已把章节导航按钮和听力进度分组，进度条缩短为固定较窄宽度，左侧增加分隔，进度色改为更明显的蓝色。

## 提交说明

- 本轮代码、文档和修改日志已更新。
- 最新 Suno 自动风格魔法棒修复已执行定向 Vitest 和 `flutter analyze` 验证；上一轮用户已确认测试过的其它事项未重复执行测试命令。
