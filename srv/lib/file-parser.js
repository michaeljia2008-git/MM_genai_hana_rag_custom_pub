const pdfParse = require('pdf-parse');
const { parse: csvParseSync } = require('csv-parse/sync');

async function parseFile(buffer, fileType) {
  switch (fileType.toLowerCase()) {
    case 'pdf':
      return await parsePDF(buffer);
    case 'txt':
      return parseTXT(buffer);
    case 'csv':
      return parseCSV(buffer);
    default:
      throw new Error(`Unsupported file type: ${fileType}`);
  }
}

async function parsePDF(buffer) {
  const data = await pdfParse(buffer);
  return data.text;
}

function parseTXT(buffer) {
  return buffer.toString('utf-8');
}

function parseCSV(buffer) {
  const text = buffer.toString('utf-8');
  const records = csvParseSync(text, {
    columns: true,
    skip_empty_lines: true,
    trim: true
  });

  return records.map((row) => {
    const idField = Object.keys(row).find(k => /id$/i.test(k));
    const idValue = idField ? row[idField] : '';
    const pairs = Object.entries(row)
      .map(([key, value]) => `${key}: ${value}`)
      .join(', ');
    return `Product ${idValue} information: ${pairs}`;
  }).join('\n\n');
}

module.exports = { parseFile };
