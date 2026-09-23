const { AzureOpenAiChatClient } = require('@sap-ai-sdk/foundation-models');

let chatClient = null;

function getChatClient() {
  if (!chatClient) {
    chatClient = new AzureOpenAiChatClient('gpt-4o');
  }
  return chatClient;
}

async function generateRAGResponse({ query, chunks, history = [] }) {
  const client = getChatClient();

  const context = chunks.map((c, i) => {
    let content = c.content;
    if (Buffer.isBuffer(content)) {
      content = content.toString('utf8');
    } else if (typeof content !== 'string') {
      content = String(content || '');
    }
    return `[${i + 1}] ${c.documentName}:\n${content}`;
  }).join('\n\n');

  const systemPrompt = context.length > 0
    ? `You are a helpful assistant. Answer the user's question based on the following document context. If the answer is not in the context, say so.\n\nContext:\n${context}`
    : `You are a helpful assistant.`;

  const messages = [
    { role: 'system', content: systemPrompt },
    ...history.slice(-10).map(m => ({ role: m.role, content: m.content })),
    { role: 'user', content: query }
  ];

  const response = await client.run({ messages, max_tokens: 1000, temperature: 0.7 });
  return response.getContent();
}

module.exports = { generateRAGResponse };
