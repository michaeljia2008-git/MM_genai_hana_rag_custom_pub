namespace genai.rag;

entity Documents {
    key ID         : UUID;
    fileName       : String(255);
    fileType       : String(10);
    fileSize       : Integer;
    status         : String(20);
    chunkCount     : Integer;
    errorMsg       : String(1000);
    createdAt      : Timestamp @cds.on.insert: $now;
}

entity DocumentChunks {
    key ID         : UUID;
    document       : Association to Documents;
    content        : LargeString;
    chunkIndex     : Integer;
    tokenCount     : Integer;
    embedding      : Vector(3072);
}

entity ChatSessions {
    key ID         : UUID;
    document       : Association to Documents;
    title          : String(255);
    createdAt      : Timestamp @cds.on.insert: $now;
}

entity ChatMessages {
    key ID         : UUID;
    session        : Association to ChatSessions;
    role           : String(20);
    content        : LargeString;
    sources        : LargeString;
    timestamp      : Timestamp @cds.on.insert: $now;
}
