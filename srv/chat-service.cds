using genai.rag as db from '../db/schema';

service ChatService @(path: '/api/chat') {
    entity ChatSessions as projection on db.ChatSessions;
    entity ChatMessages as projection on db.ChatMessages;

    action createSession(documentId: UUID, title: String) returns {
        ID          : UUID;
        document_ID : UUID;
        title       : String;
    };

    action updateSession(sessionId: UUID, documentId: UUID, title: String) returns {
        ID          : UUID;
        document_ID : UUID;
        title       : String;
    };

    action sendMessage(sessionId: UUID, message: String) returns {
        reply     : String;
        messageId : UUID;
        sources   : array of {
            chunkId      : UUID;
            documentName : String;
            content      : String;
            similarity   : Decimal;
        };
    };

    function getSessionMessages(sessionId: UUID) returns array of db.ChatMessages;
    function getDocumentSessions(documentId: UUID) returns array of db.ChatSessions;
}
