# ai-fangfeng · AI 防封与 IP 泄露检查

给 Claude Code / Codex / 网页版 AI 用的一套检查工具。**只管一件事：别把真实 IP 漏出去。**

## 两种用法

**已经配好了，想检查**

> 把这个仓库地址发给 AI，说：帮我检查我电脑的代理环境，只检查不要改。

**换了新电脑**

> 把仓库地址发给 AI，说：帮我按这个仓库配一下 Claude/Codex 的代理环境。

## 两个版本

| 版本 | 适合谁 | 看哪个 |
|---|---|---|
| 机场版 | 买了机场订阅，只想把本地配好 | [docs/机场版.md](docs/机场版.md) |
| 自建版 | 自己买 VPS，IP 只给自己用 | [docs/自建版.md](docs/自建版.md) |

## 检查器

只读，不改任何配置。

```powershell
pwsh ./scripts/check.ps1
```

输出很短：通过了哪些、还有几项要处理、每项怎么改。

## 关键点

- 组名不写死。换机场、换自建，组名全变也能查（靠真实访问判断，不看名字）。
- 不输出订阅地址、密钥、节点信息。
- 修配置前先备份，能回滚。

## 说明

部分思路参考 [nevertoday/xiaoxiaodong-vps](https://github.com/nevertoday/xiaoxiaodong-vps)（MIT）。

## License

MIT
