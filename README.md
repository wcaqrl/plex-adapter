# Plex → 懒猫应用商店

将 Plex 官方 `plexinc/pms-docker` 的公开正式版本适配为懒猫应用
`cloud.lazycat.app.plex`，复用 `wcaqrl/lazycat-action@v1`。

官网：<https://www.plex.tv>。本适配器部署个人 Plex Media Server；官网的公开网页
不是镜像监控源，也不会被打包为应用的入口。

## 版本来源和判断规则

- 主监控源：<https://hub.docker.com/r/plexinc/pms-docker/tags>，通过 Registry API
  查询版本标签及目标架构摘要，不抓取网页。
- 只接受 `1.43.4.10903-e5521bd8c` 这样的完整标签，忽略 `latest`、`public`、
  `beta` 及 `-amd64`、`-arm64`、`-armhf` 重复标签。
- `sort: numeric` 按全部四段数字比较，例如 `1.43.3.10896` 大于
  `1.43.3.10861`，`1.43.3.10` 大于 `1.43.3.9`。镜像时间、GitHub 仓库提交、
  哈希字符串字典序均不能代替上游版本判断。
- Plex 公开下载接口 <https://plex.tv/api/downloads/5.json> 用于确认所选标签
  确为当前公开正式版，并读取 `items_added`、`items_fixed`。接口与镜像版本不一致
  或无更新说明时本轮停止，等待元数据同步，绝不套用另一个版本的日志。

完整上游版本保存在状态锁 `source.version`，完整镜像标签保存在 `source.tag`。
`.lpk` 使用三段 SemVer：首次以 `1.43.4` 为版本基数；若后续只有第四段变化，
或已经分配过该三段版本，则在当前应用版本上递增 patch。例如上游
`1.43.3.10861 → 1.43.3.10896` 可以对应应用包 `1.43.3 → 1.43.4`。
因此应用包版本可能与 Plex 的前三段不同，监控和去重始终使用完整上游身份。
此规则避免 SemVer `+build` 不参与大小比较而漏掉更新的问题。

同一数字版本的标签或摘要被替换会报错，需要人工核查。同一上游版本已提交过审核，
包括被拒绝、撤销的记录，默认不重复提交。修复适配后可手动勾选 `retry-rejected`，
分配新的应用包版本重试。新上游版本可以替换旧的待审核版本。

## 流程和操作

1. 每天北京时间 **12:37** 由 GitHub Runner 定时检查；调度可能延迟。
2. 发现新版本后确认公开版本并取得准确日志。
3. 在 Runner 的独立临时目录中运行商店旧镜像，初始化真实数据库，然后升级到
   本次选中的不可变镜像摘要，验证数据库完整性、数据库标记、服务器标识、网页、
   持久文件以及容器重建。验证失败不转存、不送审。
4. 调用官方镜像转存接口，等待完成后使用返回的 `registry.lazycat.cloud` 地址。
5. 构建和校验 `.lpk`，将配置与状态提交回本仓库。
6. 官方送审和 GitHub Release 上传分别由独立任务执行；Release 的自定义附件只有
   带应用包版本号的 `.lpk`，没有 `.sha256`。GitHub 自动生成的源码 zip/tar.gz
   是平台自带入口，不是本工作流上传的附件。Release 失败不阻断送审。

修改配置后 push 只触发检查。手动测试：进入 **Actions → Update Plex for LazyCat
→ Run workflow**，先保留 `dry-run` 勾选；检查完成后取消勾选，才执行升级测试、
镜像转存、打包和送审。仅检查不启动 Plex 容器、不改状态、不提交审核。

## 首次部署条件

本配置需要包含四段数字版本支持的公共 Action；发布该实现后应由其发布流程更新
`v1`，本仓库继续引用 `@v1`。发布前旧 `v1` 无法识别新增配置字段。

在本仓库 **Settings → Secrets and variables → Actions → Repository secrets**
设置 `LZC_API_TOKEN`，其开发者必须拥有 `cloud.lazycat.app.plex` 的更新权限。
本适配器固定使用懒猫官方生产应用商店。工作流需要 `contents: write`，并需允许
GitHub Actions 推送到默认分支；分支保护策略也必须允许记录打包、送审状态。
正式运行在转存前会验证 PAT 的应用权限及 Git 写权限。

初始配置和状态来自商店 `1.42.2` 包：
<https://lzc-download-1301583638.cos.ap-guangzhou.myqcloud.com/appstore/lpks/pkgs/cloud.lazycat.app.plex/cloud.lazycat.app.plex-v1.42.2.lpk>。
初始状态为 `baseline`，不代表本适配器已经提交或测试通过。

## 数据兼容

| 宿主应用持久目录 | 容器目录 | 用途 |
| --- | --- | --- |
| `/lzcapp/var/config` | `/config` | 配置、媒体库数据库、服务器账户关联 |
| `/lzcapp/var/transcode` | `/transcode` | 转码临时数据 |
| `/lzcapp/var/data` | `/data` | 原版媒体目录 |
| `/lzcapp/run/mnt/home` | `/home` | 用户文稿 |

外接存储仍通过 `/media` 访问，并保留 GPU 配置。官方镜像使用 `PLEX_UID`、
`PLEX_GID`，不使用 LinuxServer 的 `PUID`、`PGID`、`VERSION=docker`。
应用域名使用安装时的 `.S.AppDomain`，不写入任何个人微服域名。
不打包个人 Plex 账户 token 或懒猫开发者 PAT。

自动测试覆盖临时数据库的升级，不替代已有大型媒体库的实际升级备份和播放、
硬件转码验收。首次正式升级前应备份 `/lzcapp/var/config`。

## 本地检查

```sh
python3 -B -m unittest discover -s tests -v
bash -n scripts/test-upgrade.sh
sh -n content/bind.sh
lazycat-action run --operation check --config lazycat-action.yml --dry-run
```

本地检查只读取远端镜像元数据及公开日志。真实 Docker 升级测试由正式工作流运行，
避免占用本机资源。打包产物、缓存和密钥文件通过 `.gitignore` 排除。
