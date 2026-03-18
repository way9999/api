<div align="center">

# OB1-2API

**将 [OB-1](https://openblocklabs.com) AI 服务转为 OpenAI 兼容 API**

[快速开始](#快速开始) | [功能特性](#功能特性) | [配置说明](#配置说明) | [API 文档](#api-接口)

</div>

## 功能特性

- 🔄 **OpenAI 兼容** — `/v1/chat/completions`、`/v1/models`，直接对接主流客户端
- 🤖 **Anthropic Messages API** — `/v1/messages`，兼容 Claude Code 等 Anthropic 原生客户端
- 👥 **多账号轮换** — 缓存优先 / 平衡轮换 / 性能优先三种调度策略
- 🔐 **自动 Token 管理** — 基于 WorkOS OAuth 设备授权，自动续期，401 即时重试
- 📡 **流式输出** — 完整 SSE 流式响应，实时返回生成内容
- 🖥️ **Web 管理面板** — 账号、API Key、系统设置、设备授权一站式操作
- ⚡ **热重载配置** — 后台修改即时生效，无需重启服务
- 🌐 **代理支持** — HTTP 代理配置，可视化连通性测试

## 快速开始

### 直接运行

```bash
# 克隆项目
git clone https://github.com/longnghiemduc6-art/ob12api.git
cd ob12api

# 安装依赖
pip install -r requirements.txt

# 启动服务
python main.py
```

### Docker 部署

```bash
docker run -d \
  --name ob12api \
  -p 8081:8081 \
  -v ./config:/app/config \
  -v ./data:/app/data \
  ob12api
```

### Docker Compose

```yaml
version: '3.8'
services:
  ob12api:
    build: .
    ports:
      - "8081:8081"
    volumes:
      - ./config:/app/config
      - ./data:/app/data
    restart: unless-stopped
```

服务启动后访问 `http://localhost:8081` 进入管理面板。

## 配置说明

编辑 `config/setting.toml`：

```toml
[global]
api_key = "your-api-key"          # 客户端调用使用的 API Key

[server]
host = "0.0.0.0"
port = 8081

[admin]
username = "admin"
password = "admin"                 # ⚠️ 请务必修改默认密码

[proxy]
url = ""                           # HTTP 代理地址（可选）

[ob1]
rotation_mode = "cache-first"      # 调度模式：cache-first / balanced / performance

[logging]
level = "INFO"                     # 日志级别：DEBUG / INFO / WARNING / ERROR
```

## 添加账号

进入管理面板后，支持两种方式添加 OB-1 账号：

| 方式 | 说明 |
|------|------|
| **设备授权** | 点击「设备授权」按钮，获取授权码后在 OB-1 网站完成授权 |
| **JSON 导入** | 批量导入已有账号的 JSON 数据 |

## 调度模式

| 模式 | 策略 | 适用场景 |
|------|------|----------|
| `cache-first` | 优先使用上次成功的账号，减少切换开销 | 稳定使用 |
| `balanced` | 轮流使用各账号，均衡分配请求负载 | 日常使用，延长账号寿命 |
| `performance` | 随机选择可用账号，分散请求压力 | 高并发场景 |

## API 接口

### 获取模型列表

```bash
curl http://localhost:8081/v1/models \
  -H "Authorization: Bearer your-api-key"
```

### 对话补全（流式）

```bash
curl http://localhost:8081/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

### 对话补全（非流式）

```bash
curl http://localhost:8081/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'
```

## 项目结构

```
ob12api/
├── main.py                  # 启动入口
├── requirements.txt         # Python 依赖
├── config/
│   ├── setting.toml         # 配置文件
│   ├── accounts.json        # 账号数据（自动生成）
│   └── api_keys.json        # API Key 数据（自动生成）
├── data/
│   └── tokens.json          # OAuth Token 存储
├── src/
│   ├── main.py              # FastAPI 应用
│   ├── api/
│   │   ├── routes.py        # OpenAI 兼容路由
│   │   └── admin.py         # 管理后台接口
│   ├── core/
│   │   ├── config.py        # 配置加载（热重载）
│   │   ├── auth.py          # 认证鉴权
│   │   ├── models.py        # 请求/响应模型
│   │   └── logger.py        # 日志系统
│   └── services/
│       ├── token_manager.py # Token 生命周期管理
│       ├── ob1_client.py    # OB-1 API 客户端
│       └── api_key_manager.py # API Key 管理
└── static/                  # 管理面板前端资源
```

## 常见问题

### Docker 相关

**Q: Docker 部署后设备授权报错 400**

确保容器能访问外网（WorkOS API）。如需代理，在 `config/setting.toml` 中配置：

```toml
[proxy]
url = "http://your-proxy:7890"
```

或在 Docker 启动时传入网络代理环境变量。

**Q: Docker 重启后管理面板需要重新登录**

这是正常现象。管理面板的 JWT 密钥在每次进程启动时重新生成，重启后旧 Token 失效，重新登录即可。

**Q: Docker 挂载卷后配置不生效**

确认挂载路径正确，配置文件应在宿主机的 `./config/setting.toml`：

```bash
docker run -d -p 8081:8081 \
  -v ./config:/app/config \
  -v ./data:/app/data \
  ob12api
```

### 启动报错

**Q: 启动时报 `FileNotFoundError` 或 `KeyError`**

缺少配置文件或配置项不完整。确保 `config/setting.toml` 存在且包含必要字段（`[global]`、`[server]`、`[ob1]`）。可参考上方 [配置说明](#配置说明)。

**Q: 启动时报 `JSONDecodeError`**

`config/accounts.json` 或 `data/tokens.json` 文件损坏。删除对应文件后重启，系统会自动重建：

```bash
rm config/accounts.json data/tokens.json
python main.py
```

### 账号与 Token

**Q: 所有请求返回 503 `No valid OB-1 token`**

所有账号的 Token 均已过期且自动刷新失败。进入管理面板检查账号状态，尝试重新授权或删除失效账号重新添加。

**Q: 设备授权时 WorkOS 返回错误**

- 检查网络连通性，确认能访问 `api.workos.com`
- 如使用代理，确认代理配置正确且代理服务正常运行
- 在管理面板的「代理设置」中可测试连通性

**Q: 调用 API 返回 401 Unauthorized**

- 检查请求头中的 API Key 是否正确：`Authorization: Bearer your-api-key`
- Anthropic 格式也支持 `x-api-key` 头
- 确认 `config/setting.toml` 中的 `api_key` 或管理面板中已添加对应的 Key

### 代理相关

**Q: 配置代理后仍然连接超时**

确认代理地址格式正确（需包含协议）：`http://127.0.0.1:7890`，不要写成 `127.0.0.1:7890`。可在管理面板「代理设置」中点击测试按钮验证。

## 环境要求

- Python >= 3.11
- 依赖：FastAPI, uvicorn, httpx, PyJWT, tomli_w

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=longnghiemduc6-art/ob12api&type=Date)](https://star-history.com/#longnghiemduc6-art/ob12api&Date)

## 免责声明

**本项目仅供学习和研究用途，不得用于商业目的。使用者应遵守相关服务条款和法律法规，因使用本项目产生的任何后果由使用者自行承担。**

## License

MIT
