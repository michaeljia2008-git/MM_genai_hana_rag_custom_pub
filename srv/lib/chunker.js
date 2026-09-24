const CHARS_PER_TOKEN = 4;

function chunkText(text, options = {}) {
  const { maxTokens = 1000, overlapTokens = 200 } = options;

  if (!text || text.trim().length === 0) {
    return [];
  }

  // 如果文本包含双换行（CSV行分隔），按行分块，不合并
  if (text.includes('\n\n')) {
    const lines = text.split('\n\n').map(l => l.trim()).filter(l => l.length > 0);
    // 每行独立成一个 chunk
    return lines.map(line => ({
      content: line,
      tokenCount: Math.ceil(line.length / CHARS_PER_TOKEN)
    }));
  }

  // 原有逻辑保持不变（用于 PDF/TXT）
  const maxChars = maxTokens * CHARS_PER_TOKEN;
  const overlapChars = overlapTokens * CHARS_PER_TOKEN;
  const cleanedText = text.replace(/\s+/g, ' ').trim();
  const chunks = [];
  let startIndex = 0;

  while (startIndex < cleanedText.length) {
    let endIndex = Math.min(startIndex + maxChars, cleanedText.length);

    // Try to break at a sentence boundary
    if (endIndex < cleanedText.length) {
      const searchStart = Math.max(endIndex - 200, startIndex);
      const searchWindow = cleanedText.substring(searchStart, endIndex);
      const lastBreak = Math.max(
        searchWindow.lastIndexOf('. '),
        searchWindow.lastIndexOf('! '),
        searchWindow.lastIndexOf('? '),
        searchWindow.lastIndexOf('\n')
      );
      if (lastBreak > 0) {
        endIndex = searchStart + lastBreak + 2;
      }
    }

    const chunkContent = cleanedText.substring(startIndex, endIndex).trim();
    if (chunkContent.length > 0) {
      chunks.push({
        content: chunkContent,
        tokenCount: Math.ceil(chunkContent.length / CHARS_PER_TOKEN)
      });
    }

    const nextStart = endIndex - overlapChars;
    startIndex = nextStart <= startIndex ? endIndex : nextStart;
    if (endIndex >= cleanedText.length) break;
  }

  return chunks;
}

module.exports = { chunkText };
