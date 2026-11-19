# 2026-11-19 工具链升级

- 官方稳定下载渠道：cli.moonbitlang.cn/binaries/latest。
- moonc：v0.10.21+06da1ed44，编译器日期 2026-11-16。
- moon / moonrun：0.1.20261117，提交 eb64713。
- 安装位置：项目 .tools/0.10.21+06da1ed44；旧 v0.10.20 工具链保留。
- Windows x64 安装包：94,201,777 字节，SHA-256 `941b6596813861350d43e2fc92b4444f562f2b5589b07c1b82e5c62f07f47239`，与官方 .sha256 完全一致。
- 配套标准库：core-0.10.21+06da1ed44.zip，SHA-256 `9dee22c988998e41c6b39dfeacca3f354d6ac9da2159afd9f9d9853bcad1cc36`；编译器与标准库版本一致，标准库 bundle 成功。

官方下载主站出现 TLS EOF，中国镜像可连接。整包下载连接停滞后改为 ETag 约束的分段下载，校验每段 Content-Range 和长度，最后仍校验完整安装包摘要。

Windows TemporaryDirectory 的权限会随目录移动保留，初次安装导致普通项目终端不可访问；已改为复制到项目目录，使正式目录继承项目权限。保留了原目录备份，并逐一核对 moon、moonc 和 moonrun 的文件摘要。

新环境使用已有项目依赖索引和公开包缓存，依赖版本保持不变，未复制账号凭据。为配合新标准库，将 layout.mbt 和 range.mbt 中两处 Buffer(size_hint=...) 改为 Buffer(capacity=...)。v1 键与契约、游标格式不变。

本提交的最终本地结果以运行 `python scripts/acceptance.py` 后生成的 `_build/acceptance/acceptance.json` 为准。验收覆盖四个核心后端、历史键格式、双引擎 SQLite 对照、18 项恢复检查、查询集、SDK、源码包独立消费和十万条规模。

toolchain.json 固定新版本，本地构建入口自动激活项目工具链，Windows/Linux CI 使用同一固定版本。release_gate.py 同时检查当前编译器与验收报告的编译器身份，防止用旧编译器的成功报告放行新工具链构建。远端 CI、公开发布及主办方验收分别确认。
