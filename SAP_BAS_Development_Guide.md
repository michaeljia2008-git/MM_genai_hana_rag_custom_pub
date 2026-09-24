# SAP BAS + CAP AI 程序开发指南

本指南基于 **genai_hana_rag** 项目实践整理，介绍如何在本地开发 SAP CAP AI 程序并部署到 SAP BTP Cloud Foundry。

---

## 技术栈

| 层次 | 技术 | 说明 |
|------|------|------|
| 前端 | SAP UI5 | XML 视图 + JS 控制器 |
| 后端 | SAP CAP (Node.js) | CDS 服务定义 + 自定义路由 |
| 数据库 | SAP HANA Cloud | 向量搜索（COSINE_SIMILARITY） |
| AI SDK | @sap-ai-sdk/foundation-models | 封装 AI Core 调用 |
| AI 模型 | Azure OpenAI (via AI Core) | GPT-4o + text-embedding-3-large |
| 部署 | SAP BTP Cloud Foundry | mta.yaml 多目标应用 |

---

## 一、项目结构

```
genai-hana-rag/
├── app/                        # 前端 SAP UI5
│   └── webapp/
│       ├── controller/
│       │   └── Main.controller.js   # 主控制器（文档选择、聊天、会话管理）
│       ├── view/
│       │   └── Main.view.xml        # 主视图（Splitter 布局）
│       ├── fragment/
│       │   └── UploadDialog.fragment.xml
│       ├── model/
│       │   └── formatter.js         # 格式化工具（文件大小等）
│       ├── css/
│       │   └── style.css
│       ├── config.js                # 本地开发配置（gitignore）
│       ├── Component.js
│       ├── index.html
│       └── manifest.json
├── db/
│   └── schema.cds                   # 数据模型定义
├── srv/
│   ├── chat-service.cds             # Chat 服务定义
│   ├── chat-service.js              # Chat 服务实现
│   ├── document-service.cds         # Document 服务定义
│   ├── document-service.js          # Document 服务实现
│   ├── server.js                    # 自定义路由（文件上传、删除会话）
│   └── lib/
│       ├── embedder.js              # AI Embedding（@sap-ai-sdk）
│       ├── rag-engine.js            # RAG 回复生成
│       ├── vector-search.js         # HANA 向量相似度搜索
│       ├── chunker.js               # 文本分块
│       ├── file-parser.js           # 文件解析（PDF/TXT/CSV）
│       └── upload-processor.js      # 上传处理流水线
├── mta.yaml                         # BTP 部署配置
├── package.json
├── user-config.json                 # CF 环境配置（gitignore）
└── user-config.mtaext               # MTA 扩展配置（gitignore）
```

---

## 二、数据模型

本项目使用 SAP CAP CDS 定义数据模型，HANA Cloud 存储向量数据：

```cds
namespace genai.rag;

entity Documents {
    key ID        : UUID;
    fileName      : String(255);
    fileType      : String(10);
    fileSize      : Integer;
    status        : String(20);   // PROCESSING | READY | ERROR
    chunkCount    : Integer;
    errorMsg      : String(1000);
    createdAt     : Timestamp @cds.on.insert: $now;
}

entity DocumentChunks {
    key ID        : UUID;
    document      : Association to Documents;
    content       : LargeString;   // NCLOB
    chunkIndex    : Integer;
    tokenCount    : Integer;
    // embedding 字段通过原生 SQL 写入（CAP 不支持 REAL_VECTOR 类型）
}

entity ChatSessions {
    key ID        : UUID;
    document      : Association to Documents;
    title         : String(255);
    createdAt     : Timestamp @cds.on.insert: $now;
}

entity ChatMessages {
    key ID        : UUID;
    session       : Association to ChatSessions;
    role          : String(20);   // user | assistant
    content       : LargeString;
    sources       : LargeString;  // JSON 格式存储来源
    timestamp     : Timestamp @cds.on.insert: $now;
}
```

**关键点：** HANA Cloud 的 `REAL_VECTOR` 类型不在 CDS 标准类型中，需要通过原生 SQL 写入：

```javascript
await cds.run(
  `INSERT INTO "GENAI_RAG_DOCUMENTCHUNKS"
   ("ID", "DOCUMENT_ID", "CONTENT", "CHUNKINDEX", "TOKENCOUNT", "EMBEDDING")
   VALUES (?, ?, ?, ?, ?, TO_REAL_VECTOR(?))`,
  [chunkId, docId, content, index, tokenCount, embeddingStr]
);
```

---

## 三、AI SDK 使用方式

本项目使用 `@sap-ai-sdk/foundation-models`，**不需要手动管理 Token 和认证**，SDK 自动读取 CF 环境变量中绑定的 AI Core 服务凭证。

### 安装

```bash
npm install @sap-ai-sdk/foundation-models
```

### Embedding（文本向量化）

```javascript
// srv/lib/embedder.js
const { AzureOpenAiEmbeddingClient } = require('@sap-ai-sdk/foundation-models');

const client = new AzureOpenAiEmbeddingClient('text-embedding-3-large');

async function embedTexts(texts, batchSize = 20) {
  const allEmbeddings = [];
  for (let i = 0; i < texts.length; i += batchSize) {
    const batch = texts.slice(i, i + batchSize);
    const results = await Promise.all(
      batch.map(async (text) => {
        const response = await client.run({ input: text });
        return response.getEmbedding();
      })
    );
    allEmbeddings.push(...results);
  }
  return allEmbeddings;
}
```

**注意：** 批量处理时建议 batchSize=20，避免超过 AI Core 的并发限制。

### Chat Completion（生成回复）

```javascript
const { AzureOpenAiChatClient } = require('@sap-ai-sdk/foundation-models');

const client = new AzureOpenAiChatClient('gpt-4o');

async function generateRAGResponse({ query, chunks, history }) {
  const context = chunks.map((c, i) =>
    `[${i + 1}] ${c.documentName}: ${c.content}`
  ).join('\n\n');

  const messages = [
    { role: 'system', content: `You are a helpful assistant. Answer based on the context:\n\n${context}` },
    ...history.map(m => ({ role: m.role, content: m.content })),
    { role: 'user', content: query }
  ];

  const response = await client.run({ messages, max_tokens: 1000 });
  return response.getContent();
}
```

---

## 四、文件处理流水线

上传文件后的处理流程：**文件解析 → 文本分块 → 向量化 → 存入 HANA**

### 文件解析（PDF/TXT/CSV）

```javascript
// srv/lib/file-parser.js
const pdfParse = require('pdf-parse');
const { parse: csvParseSync } = require('csv-parse/sync');

async function parseFile(buffer, fileType) {
  switch (fileType) {
    case 'pdf': return (await pdfParse(buffer)).text;
    case 'txt': return buffer.toString('utf-8');
    case 'csv':
      // CSV 转换为 "key: value, key: value" 格式的文本
      const records = csvParseSync(buffer.toString('utf-8'), {
        columns: true, skip_empty_lines: true, trim: true
      });
      return records.map((row, i) =>
        `Row ${i + 1}: ` + Object.entries(row).map(([k, v]) => `${k}: ${v}`).join(', ')
      ).join('\n');
  }
}
```

### 文本分块（带重叠）

```javascript
// srv/lib/chunker.js
// maxTokens=1000, overlapTokens=200（相邻块有200 token重叠，保持上下文连续性）
// 优先在句子边界（. ! ? \n）处切分
function chunkText(text, { maxTokens = 1000, overlapTokens = 200 } = {}) {
  const maxChars = maxTokens * 4;   // 估算：1 token ≈ 4 字符
  const overlapChars = overlapTokens * 4;
  // ... 在句子边界处分割，相邻块有重叠
}
```

### 异步处理

上传接口立即返回 `PROCESSING` 状态，文档处理在后台异步完成，前端通过轮询获取状态：

```javascript
// 前端每 3 秒轮询一次
var interval = setInterval(function () {
  fetch(apiBase + "/api/documents/getStatus(documentId='" + docId + "')")
    .then(r => r.json())
    .then(data => {
      if (data.status === "READY" || data.status === "ERROR") {
        clearInterval(interval);
      }
    });
}, 3000);
```

---

## 五、HANA Cloud 向量搜索

```javascript
// srv/lib/vector-search.js
async function searchSimilarChunks(queryEmbedding, topK = 10, documentIds = null) {
  const embeddingStr = JSON.stringify(queryEmbedding);

  let sql = `
    SELECT TOP ${topK}
      c."ID", c."CONTENT", c."CHUNKINDEX", c."DOCUMENT_ID",
      d."FILENAME" AS "documentName",
      COSINE_SIMILARITY(c."EMBEDDING", TO_REAL_VECTOR('${embeddingStr}')) AS "similarity"
    FROM "GENAI_RAG_DOCUMENTCHUNKS" c
    INNER JOIN "GENAI_RAG_DOCUMENTS" d ON c."DOCUMENT_ID" = d."ID"
    WHERE d."STATUS" = 'READY'
  `;

  if (documentIds && documentIds.length > 0) {
    const idList = documentIds.map(id => `'${id}'`).join(',');
    sql += ` AND c."DOCUMENT_ID" IN (${idList})`;
  }

  sql += ` ORDER BY "similarity" DESC`;
  return await cds.run(sql);
}
```

**关键函数：**
- `TO_REAL_VECTOR(jsonStr)` — 将 JSON 数组转为 HANA 向量类型
- `COSINE_SIMILARITY(vec1, vec2)` — 计算余弦相似度（值越接近 1 越相似）

---

## 六、CAP 服务架构

### CDS 服务定义

```cds
// srv/chat-service.cds
service ChatService @(path: '/api/chat') {
  action createSession(documentId: UUID, title: String) returns { ID: UUID; ... };
  action sendMessage(sessionId: UUID, message: String) returns { reply: String; sources: array of {}; };
  function getSessionMessages(sessionId: UUID) returns array of ChatMessages;
  function getDocumentSessions(documentId: UUID) returns array of ChatSessions;
}

// srv/document-service.cds
service DocumentService @(path: '/api/documents') {
  entity Documents as projection on db.Documents;
  function getStatus(documentId: UUID) returns { status: String; chunkCount: Integer; };
  action deleteDocument(documentId: UUID) returns Boolean;
}
```

### 自定义路由（server.js）

CAP 不支持 multipart 文件上传，需要在 `server.js` 里用 Express + multer 注册自定义路由：

```javascript
// srv/server.js
const multer = require('multer');
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });

cds.on('bootstrap', (app) => {
  app.post('/api/documents/upload', upload.single('file'), async (req, res) => {
    const result = await processUpload({ ... req.file ... });
    res.status(201).json(result);
  });

  app.post('/api/chat/deleteSession', async (req, res) => {
    const { sessionId } = req.body;
    await DELETE.from(ChatMessages).where({ session_ID: sessionId });
    await DELETE.from(ChatSessions).where({ ID: sessionId });
    res.json({ success: true });
  });
});
```

---

## 七、前端关键技巧

### SAP UI5 Splitter 初始宽度设置

SAP UI5 Splitter 默认平均分配空间，忽略 VBox 的 width 属性。需要在 `onInit` 里手动设置：

```javascript
// controller/Main.controller.js
setTimeout(function () {
  var oSplitter = that.byId("mainSplitter");
  if (oSplitter) {
    var oLD = oSplitter.getContentAreas()[0].getLayoutData();
    if (oLD) {
      oLD.setSize("350px");
      oSplitter.triggerResize(true);
    }
  }
}, 500);
```

### SAP UI5 动态 CSS 类绑定的限制

`CustomListItem` 的 `class` 属性中的表达式绑定（`{= ... ? 'classA' : 'classB'}`）不会反映到 DOM 中，必须用 JS 手动操作：

```javascript
// 每次消息渲染后调用
_applyMessageClasses: function () {
  var oList = this.byId("messageList");
  oList.getItems().forEach(function (oItem, i) {
    var sRole = aMessages[i] && aMessages[i].role;
    var oDom = oItem.getDomRef();
    if (sRole === "user") {
      oDom.classList.add("chatMessageUser");
    } else {
      oDom.classList.add("chatMessageAssistant");
    }
  });
}
```

### SAP UI5 ScrollContainer 滚动到底部

```javascript
// SAP ScrollContainer 的 API
var oScroll = that.byId("chatScroll");
if (oScroll) {
  oScroll.scrollTo(0, oScroll.getDomRef()?.scrollHeight || 99999);
}
// 同时需要手动滚动外层 Splitter 容器
document.querySelectorAll(".sapUiLoSplitterContent, .chatPanel, .chatPanel > div").forEach(function (el) {
  el.scrollTop = el.scrollHeight;
});
```

### Icon 颜色设置

SAP UI5 `core:Icon` 的 `color` 属性不支持 hex 值，改用 CSS attribute selector：

```css
/* style.css */
[aria-label="da-2"] {
    color: #5851D8 !important;  /* Joule 紫色 */
}
```

---

## 八、本地开发环境

### 启动方式

```bash
# 后端（SAP CAP）
cds watch                          # 默认 http://localhost:4004
# 如需连接 HANA Cloud（hybrid 模式）
cds watch --profile hybrid

# 前端（静态文件）
cd app/webapp
npx serve -l 2142                  # http://localhost:2142
# 注意：Node.js v24 不兼容 http-server，请用 npx serve
```

### 本地连接 HANA Cloud 和 AI Core

在项目根目录创建 `user-config.json`（加入 `.gitignore`）：

```json
{
  "VCAP_SERVICES": {
    "aicore": [{
      "label": "aicore",
      "credentials": {
        "clientid": "your-client-id",
        "clientsecret": "your-client-secret",
        "url": "https://your-auth-url",
        "serviceurls": {
          "AI_API_URL": "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com"
        }
      }
    }],
    "hana": [{
      "label": "hana",
      "credentials": {
        "host": "your-hana-host",
        "port": "443",
        "user": "your-user",
        "password": "your-password"
      }
    }]
  }
}
```

然后启动时注入：

```bash
CDS_CONFIG='{"requires":{"db":{"kind":"hana-cloud"}}}' \
  VCAP_SERVICES=$(cat user-config.json | jq .VCAP_SERVICES) \
  cds watch
```

### 前端 API 地址切换

```javascript
// app/webapp/config.js（加入 .gitignore）
window.RAG_CONFIG = {
    apiBaseUrl: "http://localhost:4004"  // 本地
    // apiBaseUrl: "https://your-app.cfapps.eu10.hana.ondemand.com"  // CF
};
```

---

## 九、部署到 SAP BTP Cloud Foundry

### mta.yaml 关键配置

```yaml
_schema-version: "3.1"
ID: genai-hana-rag
version: 1.0.0

build-parameters:
  before-all:
    - builder: custom
      commands:
        - npm ci
        - npx cds build --production   # 生成 gen/ 目录

modules:
  - name: genai-hana-rag-srv           # 后端服务
    type: nodejs
    path: gen/srv
    parameters:
      buildpack: nodejs_buildpack
      memory: 512M
    requires:
      - name: hana-hdi-rag             # HANA HDI 容器
      - name: aicore                   # AI Core 服务

  - name: genai-hana-rag-db-deployer   # 数据库部署器
    type: hdb
    path: gen/db
    requires:
      - name: hana-hdi-rag

  - name: genai-hana-rag-app           # 前端静态文件
    type: staticfile
    path: app/webapp
    parameters:
      buildpack: staticfile_buildpack
      memory: 64M

resources:
  - name: hana-hdi-rag                 # HANA HDI 容器（自动创建）
    type: com.sap.xs.hdi-container
    parameters:
      service: hana
      service-plan: hdi-shared
      config:
        database_id: your-hana-db-id

  - name: aicore                       # 绑定已有 AI Core 服务实例
    type: org.cloudfoundry.existing-service
    parameters:
      service-name: your-aicore-service-name
```

### 部署命令

```bash
# 完整 MTA 部署（推荐，首次或有数据库变更时）
mbt build
cf deploy mta_archives/genai-hana-rag_1.0.0.mtar

# 仅更新后端代码（快速，无数据库变更时）
cf push genai-hana-rag-srv

# 仅更新前端（最快）
cf push genai-hana-rag-app

# 查看日志
cf logs genai-hana-rag-srv --recent
```

### 需要加入 .gitignore 的文件

```gitignore
user-config.json        # CF 环境凭证
user-config.mtaext      # MTA 扩展配置
app/webapp/config.js    # 前端 API 地址配置
*.mtar                  # MTA 构建产物
gen/                    # CDS 构建产物
node_modules/
.env
```

---

## 十、常见问题

| 问题 | 原因 | 解决方法 |
|------|------|---------|
| CSS 类不生效（CustomListItem）| SAP UI5 不会把表达式绑定渲染到 DOM class | 用 `getDomRef().classList.add()` 手动添加 |
| Splitter 有大空隙 | Splitter 默认平均分配宽度 | 在 onInit 里调用 `getLayoutData().setSize()` |
| ScrollContainer 不滚动 | scrollTop 不生效 | 用 `oScroll.scrollTo()` API + 手动滚动外层容器 |
| Icon 颜色不生效 | color 属性不支持 hex | 用 CSS `[aria-label="icon-name"]` selector |
| 页面空白 | XML 命名空间重复定义 | 同一 namespace 只能绑定一个前缀 |
| Node.js v24 启动前端报错 | http-server 不兼容 v24 | 改用 `npx serve` |
| REAL_VECTOR 写入失败 | CAP CDS 不支持该类型 | 用原生 SQL `TO_REAL_VECTOR()` 写入 |

---

---

## 十一、多环境部署差异（eu10 vs cn40）

### 环境对比

| 项目 | eu10 | cn40 |
|------|------|------|
| CF API | `api.cf.eu10-004.hana.ondemand.com` | `api.cf.cn40.platform.sapcloud.cn` |
| 应用域名 | `cfapps.eu10-004.hana.ondemand.com` | `innolab.oncloud.top`（自定义域名） |
| AI Core 服务 | space 内有 AI Core 服务实例 | 无 AI Core 服务，用环境变量代替 |
| AI_API_URL | `api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com` | 同上（eu10 的 AI Core 跨区调用） |

### cn40 特殊处理：无 AI Core 服务绑定

cn40 的 space 里没有 AI Core 服务实例，SDK 会报：
```
Could not find service binding of type 'aicore'
```

解决方案：用 `AICORE_SERVICE_KEY` 环境变量注入凭证：

```bash
cf set-env genai-hana-rag-srv AICORE_SERVICE_KEY '{"clientid":"...","clientsecret":"...","url":"...","serviceurls":{"AI_API_URL":"..."}}'
cf restart genai-hana-rag-srv
```

同时在 `my-deployment.mtaext` 里禁用 aicore 资源：
```yaml
resources:
  - name: aicore
    active: false
```

### config.js 被 .gitignore 忽略的问题

`app/webapp/config.js` 被 `.gitignore` 忽略，换环境部署后需要手动更新：

```bash
cat > app/webapp/config.js << 'EOF'
window.RAG_CONFIG = {
    apiBaseUrl: "https://<新环境的srv地址>"
};
EOF
```

### CSV 分块逻辑

CSV 文件每行应该独立成一个 chunk，不应被合并。关键逻辑：

- `file-parser.js`：每行格式化为 `Product {ID} information: key: value, ...`，行间用 `\n\n` 分隔
- `chunker.js`：检测到 `\n\n` 时按行分块，不走普通的 maxTokens 切分逻辑

```javascript
// chunker.js - CSV 专用分块
if (text.includes('\n\n')) {
  const lines = text.split('\n\n').map(l => l.trim()).filter(l => l.length > 0);
  return lines.map(line => ({
    content: line,
    tokenCount: Math.ceil(line.length / CHARS_PER_TOKEN)
  }));
}
```

### topK 查询参数

向量搜索返回的 chunks 数量：
- `vector-search.js` 默认值：`topK = 20`
- `chat-service.js` 调用时显式传入：`searchSimilarChunks(queryEmbedding, 20, [...])`

两处需要保持一致。

---

## 十二、cn40 部署脚本（setup-deployment_cn40.sh）

针对 cn40 环境的一键部署脚本，固化了所有环境参数。

### 使用方式

```bash
# 仅生成配置文件（mtaext + config.js），不执行部署
chmod +x setup-deployment_cn40.sh
./setup-deployment_cn40.sh

# 完整部署（生成配置 + mbt build + cf deploy + 设置 AICORE_SERVICE_KEY）
./setup-deployment_cn40.sh --deploy
```

### 典型部署流程（推荐）

```bash
git pull
./setup-deployment_cn40.sh           # 生成 mtaext 和 config.js
mbt build
cf deploy mta_archives/genai-hana-rag_1.0.0.mtar -e my-deployment.mtaext
# AICORE_SERVICE_KEY 已存在则无需重新设置
```

### 数据库错误文档清理

部署后如有 ERROR 状态的文档残留，用以下命令清理：

```bash
# 查询 ERROR 文档
cf run-task genai-hana-rag-srv --command "node -e \"
const cds = require('@sap/cds');
cds.connect().then(async () => {
  const docs = await cds.run('SELECT ID, FILENAME, STATUS FROM GENAI_RAG_DOCUMENTS WHERE STATUS = \\'ERROR\\'');
  console.log(JSON.stringify(docs));
  process.exit(0);
});
\"" --name list-error-docs

# 查看结果
cf logs genai-hana-rag-srv --recent | grep "APP/TASK"

# 删除指定文档（替换 <DOC_ID>）
cf run-task genai-hana-rag-srv --command "node -e \"
const cds = require('@sap/cds');
cds.connect().then(async () => {
  const docId = '<DOC_ID>';
  await cds.run('DELETE FROM GENAI_RAG_DOCUMENTCHUNKS WHERE DOCUMENT_ID = ?', [docId]);
  await cds.run('DELETE FROM GENAI_RAG_DOCUMENTS WHERE ID = ?', [docId]);
  console.log('Deleted successfully');
  process.exit(0);
});
\"" --name delete-error-doc
```

---

*基于 genai_hana_rag 项目实践整理 — 2026/09*
