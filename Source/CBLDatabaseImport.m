//
//  CBLDatabaseImport.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 6/24/14.
//
//

#import "CBLDatabaseImport.h"
#import "CouchbaseLitePrivate.h"
#import "CBLDatabase+Attachments.h"
#import "CBLDatabase+Insertion.h"
#import "CBLDatabase+LocalDocs.h"
#import "CBL_Revision.h"
#import "CBLMisc.h"
#import <sqlite3.h>


static NSString* columnString(sqlite3_stmt* stmt, int column) {
    const char* cstr = (const char*)sqlite3_column_text(stmt, column);
    if (!cstr)
        return nil;
    return [[NSString alloc] initWithCString: cstr encoding: NSUTF8StringEncoding];
}

static NSData* columnData(sqlite3_stmt* stmt, int column) {
    const void* blob = (const char*)sqlite3_column_blob(stmt, column);
    if (!blob)
        return nil;
    size_t length = sqlite3_column_bytes(stmt, column);
    return [[NSData alloc] initWithBytes: blob length: length];
}

static CBLStatus sqliteErrToStatus(int sqliteErr) {
    switch (sqliteErr) {
        case SQLITE_OK:
        case SQLITE_DONE:
            return kCBLStatusOK;
        case SQLITE_NOTADB:
            return kCBLStatusBadRequest;
        case SQLITE_PERM:
            return kCBLStatusForbidden;
        case SQLITE_CORRUPT:
        case SQLITE_IOERR:
            return kCBLStatusCorruptError;
        case SQLITE_CANTOPEN:
            return kCBLStatusNotFound;
        default:
            return kCBLStatusDBError;
    }
}


@implementation CBLDatabaseImport
{
    CBLDatabase* _db;
    NSString* _path;
    sqlite3* _sqlite;
    sqlite3_stmt* _docQuery;
    sqlite3_stmt* _revQuery;
    sqlite3_stmt* _attQuery;
}


@synthesize numDocs=_numDocs, numRevs=_numRevs, moveAttachmentsDir=_moveAttachmentsDir;


- (instancetype) initWithDatabase: (CBLDatabase*)db sqliteFile: (NSString*)sqliteFile {
    self = [super init];
    if (self) {
        _db = db;
        _path = sqliteFile;
        _moveAttachmentsDir = YES;
    }
    return self;
}

- (void)dealloc
{
    sqlite3_finalize(_docQuery);
    sqlite3_finalize(_revQuery);
    sqlite3_finalize(_attQuery);
    sqlite3_close(_sqlite);
}


- (CBLStatus) import {
    // Open source and destination databases:
    NSError* error;
    if (![_db open: &error]) {
        Warn(@"Upgrade failed: Couldn't open new db: %@", error);
        return CBLStatusFromNSError(error, 0);
    }

    int err = sqlite3_open_v2(_path.fileSystemRepresentation, &_sqlite,
                              SQLITE_OPEN_READONLY, NULL);
    if (err)
        return sqliteErrToStatus(err);

    // Import documents:
    // CREATE TABLE docs (doc_id INTEGER PRIMARY KEY, docid TEXT UNIQUE NOT NULL);
    CBLStatus status = [self prepare: &_docQuery
                             fromSQL: "SELECT doc_id, docid FROM docs"];
    if (CBLStatusIsError(status))
        return status;

    status = [_db _inTransaction: ^CBLStatus {
        int err;
        while (SQLITE_ROW == (err = sqlite3_step(_docQuery))) {
            @autoreleasepool {
                int64_t docNumericID = sqlite3_column_int64(_docQuery, 0);
                NSString* docID = columnString(_docQuery, 1);
                CBLStatus status = [self importDoc: docID numericID: docNumericID];
                if (CBLStatusIsError(status))
                    return status;
            }
        }
        return sqliteErrToStatus(err);
    }];
    if (CBLStatusIsError(status))
        return status;

    // Import local docs:
    status = [self importLocalDocs];
    if (CBLStatusIsError(status))
        return status;

    // Import info (public/private UUIDs):
    status = [self importInfo];
    if (CBLStatusIsError(status))
        return status;

    // Finally, move attachment storage directory:
    if (_moveAttachmentsDir) {
        NSString* oldAttachmentsPath = [[_path stringByDeletingPathExtension]
                                                       stringByAppendingString: @" attachments"];
        if (![[NSFileManager defaultManager] moveItemAtPath: oldAttachmentsPath
                                                     toPath: _db.attachmentStorePath
                                                      error: &error]) {
            if (!CBLIsFileNotFoundError(error)) {
                Warn(@"Import failed: Couldn't move attachments: %@", error);
                status = CBLStatusFromNSError(error, 0);
            }
        }
    }
    return status;
}


- (CBLStatus) importDoc: (NSString*)docID numericID: (int64_t)docNumericID {
    // CREATE TABLE revs (
    //  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    //  doc_id INTEGER NOT NULL REFERENCES docs(doc_id) ON DELETE CASCADE,
    //  revid TEXT NOT NULL COLLATE REVID,
    //  parent INTEGER REFERENCES revs(sequence) ON DELETE SET NULL,
    //  current BOOLEAN,
    //  deleted BOOLEAN DEFAULT 0,
    //  json BLOB,
    //  no_attachments BOOLEAN,
    //  UNIQUE (doc_id, revid) );

    CBLStatus status = [self prepare: &_revQuery
                             fromSQL: "SELECT sequence, revid, parent, current, deleted, json,"
                                      " no_attachments FROM revs WHERE doc_id=? ORDER BY sequence"];
    if (CBLStatusIsError(status))
        return status;
    sqlite3_bind_int64(_revQuery, 1, docNumericID);

    NSMutableDictionary* tree = $mdict();

    int err;
    while (SQLITE_ROW == (err = sqlite3_step(_revQuery))) {
        int64_t sequence = sqlite3_column_int64(_revQuery, 0);
        NSString* revID = columnString(_revQuery, 1);
        int64_t parentSeq = sqlite3_column_int64(_revQuery, 2);
        BOOL current = (BOOL)sqlite3_column_int(_revQuery, 3);

        if (current) {
            // Add a leaf revision:
            BOOL deleted = (BOOL)sqlite3_column_int(_revQuery, 4);
            NSData* json = columnData(_revQuery, 5);

            if (!sqlite3_column_int(_revQuery, 6)) {
                NSMutableData* nuJson = [json mutableCopy];
                status = [self addAttachmentsToSequence: sequence json: nuJson];
                if (CBLStatusIsError(status))
                    return status;
                json = nuJson;
            }

            CBL_MutableRevision* rev = [[CBL_MutableRevision alloc] initWithDocID: docID revID: revID
                                                                          deleted: deleted];
            rev.asJSON = json;

            NSMutableArray* history = $marray();
            [history addObject: revID];
            while (parentSeq > 0) {
                NSArray* ancestor = tree[@(parentSeq)];
                Assert(ancestor, @"Couldn't find parent of seq %lld (doc %@)", parentSeq, docID);
                [history addObject: ancestor[0]];
                parentSeq = [ancestor[1] longLongValue];
            }

            Log(@"Importing %@, history = %@", rev, history);
            status = [_db forceInsert: rev revisionHistory: history source: nil];
            if (CBLStatusIsError(status))
                return status;
            ++_numRevs;
        } else {
            tree[@(sequence)] = @[revID, @(parentSeq)];
        }
    }
    ++_numDocs;
    return sqliteErrToStatus(err);
}


- (CBLStatus) addAttachmentsToSequence: (int64_t)sequence json: (NSMutableData*)json {
    // CREATE TABLE attachments (
    //  sequence INTEGER NOT NULL REFERENCES revs(sequence) ON DELETE CASCADE,
    //  filename TEXT NOT NULL,
    //  key BLOB NOT NULL,
    //  type TEXT,
    //  length INTEGER NOT NULL,
    //  revpos INTEGER DEFAULT 0,
    //  encoding INTEGER DEFAULT 0,
    //  encoded_length INTEGER );

    CBLStatus status = [self prepare: &_attQuery fromSQL: "SELECT filename, key, type, length,"
                                    " revpos, encoding, encoded_length FROM attachments WHERE sequence=?"];
    if (CBLStatusIsError(status))
        return status;
    sqlite3_bind_int64(_attQuery, 1, sequence);

    NSMutableDictionary* attachments = $mdict();

    int err;
    while (SQLITE_ROW == (err = sqlite3_step(_attQuery))) {
        NSString* name = columnString(_attQuery, 0);
        NSData* key = columnData(_attQuery, 1);
        NSString* mimeType = columnString(_attQuery, 2);
        int64_t length = sqlite3_column_int64(_attQuery, 3);
        int revpos = sqlite3_column_int(_attQuery, 4);
        int encoding = sqlite3_column_int(_attQuery, 5);
        int64_t encodedLength = sqlite3_column_int64(_attQuery, 6);

        if (key.length != sizeof(CBLBlobKey))
            return kCBLStatusCorruptError;
        NSString* digest = [CBLDatabase blobKeyToDigest: *(CBLBlobKey*)key.bytes];

        NSDictionary* att = $dict({@"type", mimeType},
                                  {@"digest", digest},
                                  {@"length", @(length)},
                                  {@"revpos", @(revpos)},
                                  {@"encoding", (encoding ?@"gzip" : nil)},
                                  {@"encoded_length", (encoding ?@(encodedLength) :nil)} );
        attachments[name] = att;
    }
    if (err != SQLITE_DONE)
        return sqliteErrToStatus(err);

    if (attachments.count > 0) {
        // Splice attachment JSON into the document JSON:
        NSData* attJson = [CBLJSON dataWithJSONObject: @{@"_attachments": attachments}
                                              options: 0 error: NULL];
        if (json.length > 2)
            [json replaceBytesInRange: NSMakeRange(json.length-1, 0) withBytes: "," length: 1];
        [json replaceBytesInRange: NSMakeRange(json.length-1, 0)
                        withBytes: (const uint8_t*)attJson.bytes + 1
                           length: attJson.length - 2];
    }
    return kCBLStatusOK;
}


- (CBLStatus) importLocalDocs {
    // CREATE TABLE localdocs (
    //  docid TEXT UNIQUE NOT NULL,
    //  revid TEXT NOT NULL COLLATE REVID,
    //  json BLOB );

    sqlite3_stmt* localQuery = NULL;
    CBLStatus status = [self prepare: &localQuery fromSQL: "SELECT docid, json FROM localdocs"];
    if (CBLStatusIsError(status))
        return status;
    int err;
    while (SQLITE_ROW == (err = sqlite3_step(localQuery))) {
        NSString* docID = columnString(localQuery, 0);
        NSData* json = columnData(localQuery, 1);
        NSDictionary* props = [CBLJSON JSONObjectWithData: json options: 0 error: NULL];
        NSError* error;
        if (props && ![_db putLocalDocument: props withID: docID error: &error]) {
            Warn(@"Couldn't import local doc '%@': %@", docID, error);
        }
    }
    sqlite3_finalize(localQuery);
    return sqliteErrToStatus(err);
}


- (CBLStatus) importInfo {
    // CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT);
    sqlite3_stmt* infoQuery = NULL;
    CBLStatus status = [self prepare: &infoQuery fromSQL: "SELECT key, value FROM info"];
    if (CBLStatusIsError(status))
        return status;
    int err;
    while (SQLITE_ROW == (err = sqlite3_step(infoQuery))) {
        [_db setInfo: columnString(infoQuery, 1) forKey: columnString(infoQuery, 0)];
    }
    return sqliteErrToStatus(err);
}


- (CBLStatus) prepare: (sqlite3_stmt**)pStmt fromSQL: (const char*)sql {
    int err;
    if (*pStmt)
        err = sqlite3_reset(*pStmt);
    else
        err = sqlite3_prepare_v2(_sqlite, sql, -1, pStmt, NULL);
    return sqliteErrToStatus(err);
}


@end


#if DEBUG

static CBLDatabase* createDB(void) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent: @"cbl_test.cblite2"];
    CBLDatabase *db = [CBLDatabase createEmptyDBAtPath: path];
    CAssert([db open: nil]);
    return db;
}

TestCase(ImportDB) {
    CBLDatabase* db = createDB();
    NSString* path = @"/Users/snej/Library/Application Support/com.mooseyard.Beanbag/CouchbaseLite/people.cblite";
    CBLDatabaseImport* import = [[CBLDatabaseImport alloc] initWithDatabase: db
                                                                 sqliteFile: path];
    Assert(import);
    import.moveAttachmentsDir = NO;
    CBLStatus status = [import import];
    AssertEq(status, kCBLStatusOK);
    Log(@"Imported %lu docs, %lu revisions", (unsigned long)import.numDocs, (unsigned long)import.numRevs);
    [db close];
}

#endif