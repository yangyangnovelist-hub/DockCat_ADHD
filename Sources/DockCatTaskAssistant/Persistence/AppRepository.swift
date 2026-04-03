import Foundation
import GRDB

struct EventLogEntry: Codable {
    let timestamp: Date
    let event: String
    let details: String
}

actor AppRepository {
    private let dbQueue: DatabaseQueue
    private let legacySnapshotURL: URL
    private let eventLogURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let preferencesStore: AppPreferencesStore
    private var latestSavedSnapshotGeneration = 0

    init(baseDirectory: URL? = nil) {
        let fileManager = FileManager.default
        let appDirectory: URL
        if let currentPath = ProcessInfo.processInfo.environment["CWD"] {
             appDirectory = URL(fileURLWithPath: currentPath).appendingPathComponent("Storage")
        } else {
             let root = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
             appDirectory = root.appendingPathComponent("DockCatTaskAssistant", isDirectory: true)
        }
        let databaseURL = appDirectory.appendingPathComponent("app.sqlite")

        self.legacySnapshotURL = appDirectory.appendingPathComponent("snapshot.json")
        self.eventLogURL = appDirectory.appendingPathComponent("events.jsonl")
        self.preferencesStore = AppPreferencesStore()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        do {
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            self.dbQueue = try DatabaseQueue(path: databaseURL.path)
            try Self.migrator.migrate(self.dbQueue)
            try Self.importLegacySnapshotIfNeeded(
                dbQueue: self.dbQueue,
                legacySnapshotURL: self.legacySnapshotURL,
                decoder: self.decoder,
                encoder: self.encoder,
                preferencesStore: self.preferencesStore
            )
        } catch {
            fatalError("Failed to initialize persistence: \(error.localizedDescription)")
        }
    }

    init(
        dbQueue: DatabaseQueue,
        preferencesStore: AppPreferencesStore = AppPreferencesStore()
    ) throws {
        self.dbQueue = dbQueue
        self.preferencesStore = preferencesStore

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let transientDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DockCatTaskAssistantTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.legacySnapshotURL = transientDirectory.appendingPathComponent("snapshot.json")
        self.eventLogURL = transientDirectory.appendingPathComponent("events.jsonl")

        try Self.migrator.migrate(dbQueue)
    }

    func loadSnapshot() -> AppSnapshot {
        let preferences = preferencesStore.load()

        do {
            return try dbQueue.read { db in
                let projects = try ProjectRecord.fetchAll(db).map(\.project)
                let tasks = try TaskRecord
                    .filter(Column("tombstone") == false)
                    .fetchAll(db)
                    .map { try $0.task(decoder: decoder) }
                let sessions = try SessionRecord.fetchAll(db).map(\.session)
                let interrupts = try InterruptRecord.fetchAll(db).map(\.interrupt)
                let importDrafts = try ImportDraftRecord.fetchAll(db).map(\.draft)
                let importDraftItems = try ImportDraftItemRecord.fetchAll(db).map { try $0.item(decoder: decoder) }
                let appState = try AppStateRecord.fetchOne(db, key: 1)

                return AppSnapshot(
                    projects: projects.sorted { $0.createdAt < $1.createdAt },
                    tasks: tasks.sorted { $0.createdAt < $1.createdAt },
                    sessions: sessions.sorted { $0.startedAt > $1.startedAt },
                    interrupts: interrupts.sorted { $0.startedAt > $1.startedAt },
                    importDrafts: importDrafts.sorted { $0.createdAt < $1.createdAt },
                    importDraftItems: importDraftItems,
                    mindMapDocument: MindMapDocument(
                        dataJSON: appState?.mindMapDataJSON ?? AppSnapshot.empty.mindMapDocument.dataJSON,
                        configJSON: appState?.mindMapConfigJSON,
                        localConfigJSON: appState?.mindMapLocalConfigJSON,
                        language: appState?.mindMapLanguage ?? AppSnapshot.empty.mindMapDocument.language,
                        updatedAt: appState.map { Date(timeIntervalSince1970: $0.mindMapUpdatedAt) }
                            ?? AppSnapshot.empty.mindMapDocument.updatedAt
                    ),
                    preferences: preferences,
                    selectedTaskID: appState?.selectedTaskID.flatMap(UUID.init(uuidString:)),
                    lastCelebrationAt: appState?.lastCelebrationAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        } catch {
            NSLog("Snapshot load failed: \(error.localizedDescription)")
            var fallback = AppSnapshot.empty
            fallback.preferences = preferences
            return fallback
        }
    }

    func saveSnapshot(_ snapshot: AppSnapshot, generation: Int = 0) async {
        guard generation >= latestSavedSnapshotGeneration else { return }
        latestSavedSnapshotGeneration = generation

        do {
            try writeSnapshot(snapshot)
            preferencesStore.save(snapshot.preferences)
        } catch {
            NSLog("Snapshot save failed: \(error.localizedDescription)")
        }
    }

    func appendEvent(_ event: String, details: String) async {
        let entry = EventLogEntry(timestamp: Date(), event: event, details: details)
        do {
            try FileManager.default.createDirectory(at: eventLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(entry)
            if let line = String(data: data, encoding: .utf8) {
                let handle: FileHandle
                if FileManager.default.fileExists(atPath: eventLogURL.path) {
                    handle = try FileHandle(forWritingTo: eventLogURL)
                    try handle.seekToEnd()
                } else {
                    FileManager.default.createFile(atPath: eventLogURL.path, contents: nil)
                    handle = try FileHandle(forWritingTo: eventLogURL)
                }
                try handle.write(contentsOf: Data((line + "\n").utf8))
                try handle.close()
            }
        } catch {
            NSLog("Event log write failed: \(error.localizedDescription)")
        }
    }

    private func writeSnapshot(_ snapshot: AppSnapshot) throws {
        try Self.writeSnapshot(snapshot, dbQueue: dbQueue, encoder: encoder)
    }

    private static func importLegacySnapshotIfNeeded(
        dbQueue: DatabaseQueue,
        legacySnapshotURL: URL,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        preferencesStore: AppPreferencesStore
    ) throws {
        guard FileManager.default.fileExists(atPath: legacySnapshotURL.path) else {
            return
        }

        let isDatabaseEmpty = try dbQueue.read { db in
            let tableCounts = [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM interrupts") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_drafts") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_draft_items") ?? 0,
            ]
            return tableCounts.allSatisfy { $0 == 0 }
        }

        guard isDatabaseEmpty else {
            return
        }

        let data = try Data(contentsOf: legacySnapshotURL)
        let snapshot = try decoder.decode(AppSnapshot.self, from: data)
        try writeSnapshot(snapshot, dbQueue: dbQueue, encoder: encoder)
        preferencesStore.save(snapshot.preferences)
    }

    private static func writeSnapshot(_ snapshot: AppSnapshot, dbQueue: DatabaseQueue, encoder: JSONEncoder) throws {
        try dbQueue.write { db in
            try syncProjects(snapshot.projects, db: db)
            try syncTasks(snapshot.tasks, db: db, encoder: encoder)
            try syncSessions(snapshot.sessions, db: db)
            try syncInterrupts(snapshot.interrupts, db: db)
            try syncImportDrafts(snapshot.importDrafts, db: db)
            try syncImportDraftItems(snapshot.importDraftItems, db: db, encoder: encoder)

            let appState = AppStateRecord(
                selectedTaskID: snapshot.selectedTaskID?.uuidString,
                lastCelebrationAt: snapshot.lastCelebrationAt?.timeIntervalSince1970,
                mindMapDataJSON: snapshot.mindMapDocument.dataJSON,
                mindMapConfigJSON: snapshot.mindMapDocument.configJSON,
                mindMapLocalConfigJSON: snapshot.mindMapDocument.localConfigJSON,
                mindMapLanguage: snapshot.mindMapDocument.language,
                mindMapUpdatedAt: snapshot.mindMapDocument.updatedAt.timeIntervalSince1970
            )
            try appState.save(db)
        }
    }

    private static func syncProjects(_ projects: [Project], db: Database) throws {
        let incomingIDs = Set(projects.map(\.id.uuidString))
        let existingIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM \(ProjectRecord.databaseTableName)"))

        for project in projects {
            let record = ProjectRecord(project)
            try record.save(db)
        }

        for removedID in existingIDs.subtracting(incomingIDs) {
            _ = try ProjectRecord.deleteOne(db, key: removedID)
        }
    }

    private static func syncTasks(_ tasks: [Task], db: Database, encoder: JSONEncoder) throws {
        let incomingIDs = Set(tasks.map(\.id.uuidString))
        let existingTaskRecords = try TaskRecord.fetchAll(db)
        let existingActiveIDs = Set(existingTaskRecords.filter { !$0.tombstone }.map(\.id))

        for task in tasks {
            var record = try TaskRecord(task, encoder: encoder)
            record.tombstone = false
            try record.save(db)
        }

        let removedIDs = existingActiveIDs.subtracting(incomingIDs)
        guard !removedIDs.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        for removedID in removedIDs {
            guard var record = existingTaskRecords.first(where: { $0.id == removedID }) else { continue }
            record.tombstone = true
            record.version += 1
            record.updatedAt = now
            record.isCurrent = false
            try record.save(db)
        }
    }

    private static func syncSessions(_ sessions: [Session], db: Database) throws {
        let incomingIDs = Set(sessions.map(\.id.uuidString))
        let existingIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM \(SessionRecord.databaseTableName)"))

        for session in sessions {
            let record = SessionRecord(session)
            try record.save(db)
        }

        for removedID in existingIDs.subtracting(incomingIDs) {
            _ = try SessionRecord.deleteOne(db, key: removedID)
        }
    }

    private static func syncInterrupts(_ interrupts: [Interrupt], db: Database) throws {
        let incomingIDs = Set(interrupts.map(\.id.uuidString))
        let existingIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM \(InterruptRecord.databaseTableName)"))

        for interrupt in interrupts {
            let record = InterruptRecord(interrupt)
            try record.save(db)
        }

        for removedID in existingIDs.subtracting(incomingIDs) {
            _ = try InterruptRecord.deleteOne(db, key: removedID)
        }
    }

    private static func syncImportDrafts(_ drafts: [ImportDraft], db: Database) throws {
        let incomingIDs = Set(drafts.map(\.id.uuidString))
        let existingIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM \(ImportDraftRecord.databaseTableName)"))

        for draft in drafts {
            let record = ImportDraftRecord(draft)
            try record.save(db)
        }

        for removedID in existingIDs.subtracting(incomingIDs) {
            _ = try ImportDraftRecord.deleteOne(db, key: removedID)
        }
    }

    private static func syncImportDraftItems(_ items: [ImportDraftItem], db: Database, encoder: JSONEncoder) throws {
        let incomingIDs = Set(items.map(\.id.uuidString))
        let existingIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM \(ImportDraftItemRecord.databaseTableName)"))

        for item in items {
            let record = try ImportDraftItemRecord(item, encoder: encoder)
            try record.save(db)
        }

        for removedID in existingIDs.subtracting(incomingIDs) {
            _ = try ImportDraftItemRecord.deleteOne(db, key: removedID)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: ProjectRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("notes", .text)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }

            try db.create(table: TaskRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("projectID", .text)
                t.column("parentTaskID", .text)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("status", .text).notNull()
                t.column("priority", .integer).notNull()
                t.column("urgencyScore", .integer).notNull()
                t.column("importanceScore", .integer).notNull()
                t.column("quadrant", .text)
                t.column("estimatedMinutes", .integer)
                t.column("dueAt", .double)
                t.column("smartSpecificMissing", .integer).notNull()
                t.column("smartMeasurableMissing", .integer).notNull()
                t.column("smartActionableMissing", .integer).notNull()
                t.column("smartRelevantMissing", .integer).notNull()
                t.column("smartBoundedMissing", .integer).notNull()
                t.column("tagsJSON", .text).notNull()
                t.column("isCurrent", .integer).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("completedAt", .double)
            }

            try db.create(table: SessionRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("taskID", .text).notNull()
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double)
                t.column("totalSeconds", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("interruptionCount", .integer).notNull()
            }

            try db.create(table: InterruptRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("sessionID", .text).notNull()
                t.column("reason", .text)
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double)
            }

            try db.create(table: ImportDraftRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("rawText", .text).notNull()
                t.column("sourceType", .text).notNull()
                t.column("parseStatus", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }

            try db.create(table: ImportDraftItemRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("draftID", .text).notNull()
                t.column("parentItemID", .text)
                t.column("proposedTitle", .text).notNull()
                t.column("proposedNotes", .text)
                t.column("proposedProjectName", .text)
                t.column("proposedTagsJSON", .text).notNull()
                t.column("proposedUrgencyScore", .integer)
                t.column("proposedImportanceScore", .integer)
                t.column("proposedQuadrant", .text)
                t.column("proposedDueAt", .double)
                t.column("smartHintsJSON", .text).notNull()
                t.column("isAccepted", .integer).notNull()
            }

            try db.create(table: AppStateRecord.databaseTableName) { t in
                t.column("id", .integer).notNull().primaryKey()
                t.column("selectedTaskID", .text)
                t.column("lastCelebrationAt", .double)
                t.column("mindMapDataJSON", .text).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.dataJSON)
                t.column("mindMapConfigJSON", .text)
                t.column("mindMapLocalConfigJSON", .text)
                t.column("mindMapLanguage", .text).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.language)
                t.column("mindMapUpdatedAt", .double).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.updatedAt.timeIntervalSince1970)
            }
        }

        migrator.registerMigration("v2_import_item_priority_and_sort") { db in
            try db.alter(table: ImportDraftItemRecord.databaseTableName) { t in
                t.add(column: "sortIndex", .integer).notNull().defaults(to: 0)
                t.add(column: "proposedPriority", .integer)
            }
        }

        migrator.registerMigration("v3_priority_coordinates") { db in
            try db.alter(table: TaskRecord.databaseTableName) { t in
                t.add(column: "urgencyValue", .double).notNull().defaults(to: 0.5)
                t.add(column: "importanceValue", .double).notNull().defaults(to: 0.5)
            }
            try db.execute(
                sql: """
                UPDATE \(TaskRecord.databaseTableName)
                SET urgencyValue = (urgencyScore - 1) / 3.0,
                    importanceValue = (importanceScore - 1) / 3.0
                """
            )

            try db.alter(table: ImportDraftItemRecord.databaseTableName) { t in
                t.add(column: "proposedUrgencyValue", .double)
                t.add(column: "proposedImportanceValue", .double)
            }
            try db.execute(
                sql: """
                UPDATE \(ImportDraftItemRecord.databaseTableName)
                SET proposedUrgencyValue = CASE
                    WHEN proposedUrgencyScore IS NULL THEN NULL
                    ELSE (proposedUrgencyScore - 1) / 3.0
                END,
                proposedImportanceValue = CASE
                    WHEN proposedImportanceScore IS NULL THEN NULL
                    ELSE (proposedImportanceScore - 1) / 3.0
                END
                """
            )
        }

        migrator.registerMigration("v4_priority_percent_and_smart_entries") { db in
            try db.alter(table: TaskRecord.databaseTableName) { t in
                t.add(column: "smartEntriesJSON", .text).notNull().defaults(to: "[]")
            }
            try db.execute(
                sql: """
                UPDATE \(TaskRecord.databaseTableName)
                SET urgencyValue = CASE
                        WHEN urgencyValue > 1.0 THEN urgencyValue
                        ELSE ROUND(urgencyValue * 10000) / 100.0
                    END,
                    importanceValue = CASE
                        WHEN importanceValue > 1.0 THEN importanceValue
                        ELSE ROUND(importanceValue * 10000) / 100.0
                    END
                """
            )

            try db.alter(table: ImportDraftItemRecord.databaseTableName) { t in
                t.add(column: "smartEntriesJSON", .text).notNull().defaults(to: "[]")
            }
            try db.execute(
                sql: """
                UPDATE \(ImportDraftItemRecord.databaseTableName)
                SET proposedUrgencyValue = CASE
                        WHEN proposedUrgencyValue IS NULL OR proposedUrgencyValue > 1.0 THEN proposedUrgencyValue
                        ELSE ROUND(proposedUrgencyValue * 10000) / 100.0
                    END,
                    proposedImportanceValue = CASE
                        WHEN proposedImportanceValue IS NULL OR proposedImportanceValue > 1.0 THEN proposedImportanceValue
                        ELSE ROUND(proposedImportanceValue * 10000) / 100.0
                    END
                """
            )
        }

        migrator.registerMigration("v4_mind_map_document") { db in
            let existingColumns = try Set(db.columns(in: AppStateRecord.databaseTableName).map(\.name))
            try db.alter(table: AppStateRecord.databaseTableName) { t in
                if !existingColumns.contains("mindMapDataJSON") {
                    t.add(column: "mindMapDataJSON", .text).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.dataJSON)
                }
                if !existingColumns.contains("mindMapConfigJSON") {
                    t.add(column: "mindMapConfigJSON", .text)
                }
                if !existingColumns.contains("mindMapLocalConfigJSON") {
                    t.add(column: "mindMapLocalConfigJSON", .text)
                }
                if !existingColumns.contains("mindMapLanguage") {
                    t.add(column: "mindMapLanguage", .text).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.language)
                }
                if !existingColumns.contains("mindMapUpdatedAt") {
                    t.add(column: "mindMapUpdatedAt", .double).notNull().defaults(to: AppSnapshot.empty.mindMapDocument.updatedAt.timeIntervalSince1970)
                }
            }
        }

        migrator.registerMigration("v5_task_sort_index") { db in
            let existingColumns = try Set(db.columns(in: TaskRecord.databaseTableName).map(\.name))
            guard !existingColumns.contains("sortIndex") else { return }
            try db.alter(table: TaskRecord.databaseTableName) { t in
                t.add(column: "sortIndex", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v6_task_sync_metadata") { db in
            try db.alter(table: TaskRecord.databaseTableName) { t in
                t.add(column: "version", .integer).notNull().defaults(to: 1)
                t.add(column: "tombstone", .boolean).notNull().defaults(to: false)
                t.add(column: "device_id", .text)
            }
        }

        return migrator
    }
}

private extension AppRepository {
    static func encodeJSON<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PersistenceEncodingError.invalidUTF8
        }
        return string
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from string: String, decoder: JSONDecoder) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw PersistenceEncodingError.invalidUTF8
        }
        return try decoder.decode(type, from: data)
    }
}

private enum PersistenceEncodingError: Error {
    case invalidUTF8
}

private struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "projects"

    var id: String
    var name: String
    var notes: String?
    var createdAt: Double
    var updatedAt: Double

    init(_ project: Project) {
        self.id = project.id.uuidString
        self.name = project.name
        self.notes = project.notes
        self.createdAt = project.createdAt.timeIntervalSince1970
        self.updatedAt = project.updatedAt.timeIntervalSince1970
    }

    var project: Project {
        Project(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            notes: notes,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

private struct TaskRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "tasks"

    var id: String
    var projectID: String?
    var parentTaskID: String?
    var sortIndex: Int
    var title: String
    var notes: String?
    var status: String
    var priority: Int
    var urgencyScore: Int
    var importanceScore: Int
    var urgencyValue: Double
    var importanceValue: Double
    var quadrant: String?
    var estimatedMinutes: Int?
    var dueAt: Double?
    var smartSpecificMissing: Bool
    var smartMeasurableMissing: Bool
    var smartActionableMissing: Bool
    var smartRelevantMissing: Bool
    var smartBoundedMissing: Bool
    var smartEntriesJSON: String
    var tagsJSON: String
    var isCurrent: Bool
    var createdAt: Double
    var updatedAt: Double
    var completedAt: Double?
    var version: Int
    var tombstone: Bool
    var device_id: String?

    init(_ task: Task, encoder: JSONEncoder) throws {
        self.id = task.id.uuidString
        self.projectID = task.projectID?.uuidString
        self.parentTaskID = task.parentTaskID?.uuidString
        self.sortIndex = task.sortIndex
        self.title = task.title
        self.notes = task.notes
        self.status = task.status.rawValue
        self.priority = task.priority
        self.urgencyScore = task.urgencyScore
        self.importanceScore = task.importanceScore
        self.urgencyValue = task.urgencyValue
        self.importanceValue = task.importanceValue
        self.quadrant = task.quadrant?.rawValue
        self.estimatedMinutes = task.estimatedMinutes
        self.dueAt = task.dueAt?.timeIntervalSince1970
        self.smartSpecificMissing = task.smartSpecificMissing
        self.smartMeasurableMissing = task.smartMeasurableMissing
        self.smartActionableMissing = task.smartActionableMissing
        self.smartRelevantMissing = task.smartRelevantMissing
        self.smartBoundedMissing = task.smartBoundedMissing
        self.smartEntriesJSON = try AppRepository.encodeJSON(task.smartEntries, encoder: encoder)
        self.tagsJSON = try AppRepository.encodeJSON(task.tags, encoder: encoder)
        self.isCurrent = task.isCurrent
        self.createdAt = task.createdAt.timeIntervalSince1970
        self.updatedAt = task.updatedAt.timeIntervalSince1970
        self.completedAt = task.completedAt?.timeIntervalSince1970
        self.version = task.version
        self.tombstone = task.tombstone
        self.device_id = task.device_id
    }

    func task(decoder: JSONDecoder) throws -> Task {
        Task(
            id: UUID(uuidString: id) ?? UUID(),
            projectID: projectID.flatMap(UUID.init(uuidString:)),
            parentTaskID: parentTaskID.flatMap(UUID.init(uuidString:)),
            sortIndex: sortIndex,
            title: title,
            notes: notes,
            status: TaskStatus(rawValue: status) ?? .todo,
            priority: priority,
            urgencyScore: urgencyScore,
            importanceScore: importanceScore,
            urgencyValue: urgencyValue,
            importanceValue: importanceValue,
            quadrant: quadrant.flatMap(TaskQuadrant.init(rawValue:)),
            estimatedMinutes: estimatedMinutes,
            dueAt: dueAt.map(Date.init(timeIntervalSince1970:)),
            smartSpecificMissing: smartSpecificMissing,
            smartMeasurableMissing: smartMeasurableMissing,
            smartActionableMissing: smartActionableMissing,
            smartRelevantMissing: smartRelevantMissing,
            smartBoundedMissing: smartBoundedMissing,
            smartEntries: try AppRepository.decodeJSON([SmartEntry].self, from: smartEntriesJSON, decoder: decoder),
            tags: try AppRepository.decodeJSON([String].self, from: tagsJSON, decoder: decoder),
            isCurrent: isCurrent,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            completedAt: completedAt.map(Date.init(timeIntervalSince1970:)),
            version: version,
            tombstone: tombstone,
            device_id: device_id
        )
    }
}

private struct SessionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "sessions"

    var id: String
    var taskID: String
    var startedAt: Double
    var endedAt: Double?
    var totalSeconds: Int
    var state: String
    var interruptionCount: Int

    init(_ session: Session) {
        self.id = session.id.uuidString
        self.taskID = session.taskID.uuidString
        self.startedAt = session.startedAt.timeIntervalSince1970
        self.endedAt = session.endedAt?.timeIntervalSince1970
        self.totalSeconds = session.totalSeconds
        self.state = session.state.rawValue
        self.interruptionCount = session.interruptionCount
    }

    var session: Session {
        Session(
            id: UUID(uuidString: id) ?? UUID(),
            taskID: UUID(uuidString: taskID) ?? UUID(),
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:)),
            totalSeconds: totalSeconds,
            state: SessionState(rawValue: state) ?? .stopped,
            interruptionCount: interruptionCount
        )
    }
}

private struct InterruptRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "interrupts"

    var id: String
    var sessionID: String
    var reason: String?
    var startedAt: Double
    var endedAt: Double?

    init(_ interrupt: Interrupt) {
        self.id = interrupt.id.uuidString
        self.sessionID = interrupt.sessionID.uuidString
        self.reason = interrupt.reason
        self.startedAt = interrupt.startedAt.timeIntervalSince1970
        self.endedAt = interrupt.endedAt?.timeIntervalSince1970
    }

    var interrupt: Interrupt {
        Interrupt(
            id: UUID(uuidString: id) ?? UUID(),
            sessionID: UUID(uuidString: sessionID) ?? UUID(),
            reason: reason,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct ImportDraftRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "import_drafts"

    var id: String
    var rawText: String
    var sourceType: String
    var parseStatus: String
    var createdAt: Double
    var updatedAt: Double

    init(_ draft: ImportDraft) {
        self.id = draft.id.uuidString
        self.rawText = draft.rawText
        self.sourceType = draft.sourceType.rawValue
        self.parseStatus = draft.parseStatus.rawValue
        self.createdAt = draft.createdAt.timeIntervalSince1970
        self.updatedAt = draft.updatedAt.timeIntervalSince1970
    }

    var draft: ImportDraft {
        ImportDraft(
            id: UUID(uuidString: id) ?? UUID(),
            rawText: rawText,
            sourceType: ImportSourceType(rawValue: sourceType) ?? .text,
            parseStatus: ParseStatus(rawValue: parseStatus) ?? .pending,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

private struct ImportDraftItemRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "import_draft_items"

    var id: String
    var draftID: String
    var sortIndex: Int
    var parentItemID: String?
    var proposedTitle: String
    var proposedNotes: String?
    var proposedProjectName: String?
    var proposedPriority: Int?
    var proposedTagsJSON: String
    var proposedUrgencyScore: Int?
    var proposedImportanceScore: Int?
    var proposedUrgencyValue: Double?
    var proposedImportanceValue: Double?
    var proposedQuadrant: String?
    var proposedDueAt: Double?
    var smartEntriesJSON: String
    var smartHintsJSON: String
    var isAccepted: Bool

    init(_ item: ImportDraftItem, encoder: JSONEncoder) throws {
        self.id = item.id.uuidString
        self.draftID = item.draftID.uuidString
        self.sortIndex = item.sortIndex
        self.parentItemID = item.parentItemID?.uuidString
        self.proposedTitle = item.proposedTitle
        self.proposedNotes = item.proposedNotes
        self.proposedProjectName = item.proposedProjectName
        self.proposedPriority = item.proposedPriority
        self.proposedTagsJSON = try AppRepository.encodeJSON(item.proposedTags, encoder: encoder)
        self.proposedUrgencyScore = item.proposedUrgencyScore
        self.proposedImportanceScore = item.proposedImportanceScore
        self.proposedUrgencyValue = item.proposedUrgencyValue
        self.proposedImportanceValue = item.proposedImportanceValue
        self.proposedQuadrant = item.proposedQuadrant?.rawValue
        self.proposedDueAt = item.proposedDueAt?.timeIntervalSince1970
        self.smartEntriesJSON = try AppRepository.encodeJSON(item.smartEntries, encoder: encoder)
        self.smartHintsJSON = try AppRepository.encodeJSON(item.smartHints, encoder: encoder)
        self.isAccepted = item.isAccepted
    }

    func item(decoder: JSONDecoder) throws -> ImportDraftItem {
        ImportDraftItem(
            id: UUID(uuidString: id) ?? UUID(),
            draftID: UUID(uuidString: draftID) ?? UUID(),
            sortIndex: sortIndex,
            parentItemID: parentItemID.flatMap(UUID.init(uuidString:)),
            proposedTitle: proposedTitle,
            proposedNotes: proposedNotes,
            proposedProjectName: proposedProjectName,
            proposedPriority: proposedPriority,
            proposedTags: try AppRepository.decodeJSON([String].self, from: proposedTagsJSON, decoder: decoder),
            proposedUrgencyScore: proposedUrgencyScore,
            proposedImportanceScore: proposedImportanceScore,
            proposedUrgencyValue: proposedUrgencyValue,
            proposedImportanceValue: proposedImportanceValue,
            proposedQuadrant: proposedQuadrant.flatMap(TaskQuadrant.init(rawValue:)),
            proposedDueAt: proposedDueAt.map(Date.init(timeIntervalSince1970:)),
            smartEntries: try AppRepository.decodeJSON([SmartEntry].self, from: smartEntriesJSON, decoder: decoder),
            smartHints: try AppRepository.decodeJSON([String].self, from: smartHintsJSON, decoder: decoder),
            isAccepted: isAccepted
        )
    }
}

private struct AppStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "app_state"

    var id: Int64 = 1
    var selectedTaskID: String?
    var lastCelebrationAt: Double?
    var mindMapDataJSON: String
    var mindMapConfigJSON: String?
    var mindMapLocalConfigJSON: String?
    var mindMapLanguage: String
    var mindMapUpdatedAt: Double
}
