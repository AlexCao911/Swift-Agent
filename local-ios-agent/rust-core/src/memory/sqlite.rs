use std::path::Path;

use rusqlite::{params, Connection};

use crate::core::{AgentError, EntryId, EventKind, RunId, RuntimeEvent, SessionId};
use crate::memory::{
    AuditRow, BlobRecord, BranchSummaryRecord, EventStore, LongTermMemoryRecord, MemoryCandidate,
    ProviderSetting,
};

pub struct SqliteEventStore {
    conn: Connection,
}

impl SqliteEventStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, AgentError> {
        let conn = Connection::open(path).map_err(storage_error)?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn schema_version(&self) -> Result<i64, AgentError> {
        self.conn
            .query_row("select version from schema_meta", [], |row| row.get(0))
            .map_err(storage_error)
    }

    pub fn table_names(&self) -> Result<Vec<String>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select name from sqlite_master where type = 'table' order by name")
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(storage_error)?;

        let mut names = Vec::new();
        for row in rows {
            names.push(row.map_err(storage_error)?);
        }
        Ok(names)
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        <Self as EventStore>::list_sessions(self)
    }

    pub fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        <Self as EventStore>::active_leaf(self, session_id)
    }

    pub fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        <Self as EventStore>::last_event(self, session_id)
    }

    pub fn rename_session(
        &mut self,
        session_id: &SessionId,
        title: String,
    ) -> Result<(), AgentError> {
        <Self as EventStore>::rename_session(self, session_id, title)
    }

    pub fn session_title_override(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<String>, AgentError> {
        <Self as EventStore>::session_title_override(self, session_id)
    }

    fn migrate(&self) -> Result<(), AgentError> {
        self.conn
            .execute_batch(
                "
                create table if not exists schema_meta (
                  version integer not null
                );

                insert into schema_meta(version)
                select 1
                where not exists (select 1 from schema_meta);

                create table if not exists sessions (
                  id text primary key,
                  active_leaf_id text,
                  archived integer not null default 0,
                  title_override text
                );

                create table if not exists events (
                  id text not null,
                  session_id text not null,
                  parent_id text,
                  run_id text,
                  sequence integer not null,
                  created_at_millis integer not null default 0,
                  depth integer not null,
                  kind text not null,
                  payload text not null,
                  blob_refs text not null default '',
                  primary key (session_id, id)
                );

                create table if not exists event_paths (
                  session_id text not null,
                  ancestor_id text not null,
                  descendant_id text not null,
                  depth_delta integer not null,
                  primary key (session_id, ancestor_id, descendant_id)
                );

                create index if not exists idx_event_paths_descendant
                on event_paths(session_id, descendant_id, depth_delta);

                create table if not exists audit_log (
                  id integer primary key autoincrement,
                  session_id text not null,
                  event_id text not null,
                  summary text not null
                );

                create table if not exists long_term_memory (
                  id text primary key,
                  text text not null,
                  keywords text not null,
                  confirmed integer not null
                );

                create table if not exists long_term_memory_keywords (
                  keyword text not null,
                  memory_id text not null,
                  primary key (keyword, memory_id)
                );

                create index if not exists idx_long_term_memory_keywords_keyword
                on long_term_memory_keywords(keyword);

                create table if not exists memory_candidates (
                  text text primary key,
                  confirmed integer not null
                );

                create table if not exists blobs (
                  id text primary key,
                  path text not null,
                  mime_type text not null,
                  byte_count integer not null
                );

                create table if not exists branch_summaries (
                  session_id text not null,
                  leaf_id text not null,
                  summary text not null,
                  primary key (session_id, leaf_id)
                );

                create table if not exists provider_settings (
                  key text primary key,
                  value text not null
                );
                ",
            )
            .map_err(storage_error)?;

        self.ensure_sessions_archived_column()?;
        self.ensure_sessions_title_override_column()?;
        self.ensure_events_created_at_millis_column()?;

        let version = self.schema_version()?;
        if version != 1 {
            return Err(AgentError::Storage(format!(
                "unsupported sqlite schema version: {version}"
            )));
        }
        Ok(())
    }

    fn ensure_sessions_archived_column(&self) -> Result<(), AgentError> {
        if self
            .conn
            .prepare("select archived from sessions limit 0")
            .is_ok()
        {
            return Ok(());
        }

        self.conn
            .execute(
                "alter table sessions add column archived integer not null default 0",
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn ensure_sessions_title_override_column(&self) -> Result<(), AgentError> {
        if self
            .conn
            .prepare("select title_override from sessions limit 0")
            .is_ok()
        {
            return Ok(());
        }

        self.conn
            .execute("alter table sessions add column title_override text", [])
            .map_err(storage_error)?;
        Ok(())
    }

    fn ensure_events_created_at_millis_column(&self) -> Result<(), AgentError> {
        if self
            .conn
            .prepare("select created_at_millis from events limit 0")
            .is_ok()
        {
            return Ok(());
        }

        self.conn
            .execute(
                "alter table events add column created_at_millis integer not null default 0",
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn upsert_memory(&self, record: LongTermMemoryRecord) -> Result<(), AgentError> {
        let LongTermMemoryRecord {
            id,
            text,
            keywords,
            confirmed,
        } = record;
        let keywords_json = serde_json::to_string(&keywords)
            .map_err(|error| AgentError::Storage(error.to_string()))?;
        self.conn
            .execute(
                "
                insert into long_term_memory(id, text, keywords, confirmed)
                values (?1, ?2, ?3, ?4)
                on conflict(id) do update set
                  text = excluded.text,
                  keywords = excluded.keywords,
                  confirmed = excluded.confirmed
                ",
                params![id, text, keywords_json, confirmed as i64],
            )
            .map_err(storage_error)?;

        self.conn
            .execute(
                "delete from long_term_memory_keywords where memory_id = ?1",
                params![id.as_str()],
            )
            .map_err(storage_error)?;

        for keyword in &keywords {
            self.conn
                .execute(
                    "
                    insert or ignore into long_term_memory_keywords(keyword, memory_id)
                    values (?1, ?2)
                    ",
                    params![keyword, id.as_str()],
                )
                .map_err(storage_error)?;
        }
        Ok(())
    }

    pub fn search_memory(&self, keyword: &str) -> Result<Vec<LongTermMemoryRecord>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select m.id, m.text, m.keywords, m.confirmed
                from long_term_memory m
                join long_term_memory_keywords k on k.memory_id = m.id
                where m.confirmed = 1 and k.keyword = ?1
                order by m.id
                ",
            )
            .map_err(storage_error)?;

        let rows = statement
            .query_map(params![keyword], |row| {
                let keywords: String = row.get(2)?;
                Ok(LongTermMemoryRecord {
                    id: row.get(0)?,
                    text: row.get(1)?,
                    keywords: serde_json::from_str(&keywords).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            2,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?,
                    confirmed: row.get::<_, i64>(3)? != 0,
                })
            })
            .map_err(storage_error)?;

        let mut records = Vec::new();
        for row in rows {
            records.push(row.map_err(storage_error)?);
        }
        Ok(records)
    }

    pub fn save_memory_candidate(&self, candidate: MemoryCandidate) -> Result<(), AgentError> {
        self.conn
            .execute(
                "
                insert into memory_candidates(text, confirmed)
                values (?1, ?2)
                on conflict(text) do update set confirmed = excluded.confirmed
                ",
                params![candidate.text, candidate.confirmed as i64],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn memory_candidates(&self) -> Result<Vec<MemoryCandidate>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select text, confirmed
                from memory_candidates
                order by text
                ",
            )
            .map_err(storage_error)?;

        let rows = statement
            .query_map([], |row| {
                Ok(MemoryCandidate::persisted(
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)? != 0,
                ))
            })
            .map_err(storage_error)?;

        let mut candidates = Vec::new();
        for row in rows {
            candidates.push(row.map_err(storage_error)?);
        }
        Ok(candidates)
    }

    pub fn put_blob(&self, record: BlobRecord) -> Result<(), AgentError> {
        let byte_count = i64::try_from(record.byte_count).map_err(|_| {
            AgentError::Storage(format!(
                "blob byte_count exceeds sqlite integer range: {}",
                record.byte_count
            ))
        })?;

        self.conn
            .execute(
                "
                insert into blobs(id, path, mime_type, byte_count)
                values (?1, ?2, ?3, ?4)
                on conflict(id) do update set
                  path = excluded.path,
                  mime_type = excluded.mime_type,
                  byte_count = excluded.byte_count
                ",
                params![record.id, record.path, record.mime_type, byte_count],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn get_blob(&self, id: &str) -> Result<Option<BlobRecord>, AgentError> {
        match self.conn.query_row(
            "
            select id, path, mime_type, byte_count
            from blobs
            where id = ?1
            ",
            params![id],
            |row| {
                let byte_count: i64 = row.get(3)?;
                Ok(BlobRecord {
                    id: row.get(0)?,
                    path: row.get(1)?,
                    mime_type: row.get(2)?,
                    byte_count: u64::try_from(byte_count).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            3,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                })
            },
        ) {
            Ok(record) => Ok(Some(record)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(storage_error(error)),
        }
    }

    pub fn put_branch_summary(&self, record: BranchSummaryRecord) -> Result<(), AgentError> {
        self.conn
            .execute(
                "
                insert into branch_summaries(session_id, leaf_id, summary)
                values (?1, ?2, ?3)
                on conflict(session_id, leaf_id) do update set
                  summary = excluded.summary
                ",
                params![record.session_id, record.leaf_id, record.summary],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn branch_summary(
        &self,
        session_id: &str,
        leaf_id: &str,
    ) -> Result<Option<BranchSummaryRecord>, AgentError> {
        match self.conn.query_row(
            "
            select session_id, leaf_id, summary
            from branch_summaries
            where session_id = ?1 and leaf_id = ?2
            ",
            params![session_id, leaf_id],
            |row| {
                Ok(BranchSummaryRecord {
                    session_id: row.get(0)?,
                    leaf_id: row.get(1)?,
                    summary: row.get(2)?,
                })
            },
        ) {
            Ok(record) => Ok(Some(record)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(storage_error(error)),
        }
    }

    pub fn write_audit(
        &self,
        session_id: &str,
        event_id: &str,
        summary: &str,
    ) -> Result<(), AgentError> {
        self.conn
            .execute(
                "
                insert into audit_log(session_id, event_id, summary)
                values (?1, ?2, ?3)
                ",
                params![session_id, event_id, summary],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn audit_rows(&self, session_id: &str) -> Result<Vec<AuditRow>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select session_id, event_id, summary
                from audit_log
                where session_id = ?1
                order by id
                ",
            )
            .map_err(storage_error)?;

        let rows = statement
            .query_map(params![session_id], |row| {
                Ok(AuditRow {
                    session_id: row.get(0)?,
                    event_id: row.get(1)?,
                    summary: row.get(2)?,
                })
            })
            .map_err(storage_error)?;

        let mut audit_rows = Vec::new();
        for row in rows {
            audit_rows.push(row.map_err(storage_error)?);
        }
        Ok(audit_rows)
    }

    pub fn save_provider_setting(&self, key: &str, value: &str) -> Result<(), AgentError> {
        self.conn
            .execute(
                "
                insert into provider_settings(key, value)
                values (?1, ?2)
                on conflict(key) do update set value = excluded.value
                ",
                params![key, value],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn provider_setting(&self, key: &str) -> Result<Option<String>, AgentError> {
        match self.conn.query_row(
            "
            select value
            from provider_settings
            where key = ?1
            ",
            params![key],
            |row| row.get(0),
        ) {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(storage_error(error)),
        }
    }
}

impl EventStore for SqliteEventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        if let Some(parent_id) = &event.parent_id {
            self.get(&event.session_id, parent_id)?;
        }

        let tx = self.conn.transaction().map_err(storage_error)?;
        tx.execute(
            "
            insert into sessions(id, active_leaf_id, archived)
            values (?1, ?2, 0)
            on conflict(id) do update set
              active_leaf_id = excluded.active_leaf_id,
              archived = 0
            ",
            params![event.session_id.0, event.id.0],
        )
        .map_err(storage_error)?;

        tx.execute(
            "
            insert into events(
              id, session_id, parent_id, run_id, sequence, created_at_millis, depth, kind, payload, blob_refs
            )
            values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ",
            params![
                event.id.0,
                event.session_id.0,
                event.parent_id.as_ref().map(|id| id.0.as_str()),
                event.run_id.as_ref().map(|id| id.0.as_str()),
                event.sequence as i64,
                event.created_at_millis as i64,
                event.depth as i64,
                event_kind_to_str(&event.kind),
                event.payload,
                event.blob_refs.join("\n"),
            ],
        )
        .map_err(storage_error)?;

        tx.execute(
            "
            insert into event_paths(session_id, ancestor_id, descendant_id, depth_delta)
            values (?1, ?2, ?3, 0)
            ",
            params![event.session_id.0, event.id.0, event.id.0],
        )
        .map_err(storage_error)?;

        if let Some(parent_id) = &event.parent_id {
            tx.execute(
                "
                insert into event_paths(session_id, ancestor_id, descendant_id, depth_delta)
                select session_id, ancestor_id, ?1, depth_delta + 1
                from event_paths
                where session_id = ?2 and descendant_id = ?3
                ",
                params![event.id.0, event.session_id.0, parent_id.0],
            )
            .map_err(storage_error)?;
        }

        tx.commit().map_err(storage_error)?;
        Ok(())
    }

    fn write_audit(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
        summary: &str,
    ) -> Result<(), AgentError> {
        SqliteEventStore::write_audit(self, &session_id.0, &entry_id.0, summary)
    }

    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError> {
        self.conn
            .query_row(
                "
                select id, session_id, parent_id, run_id, sequence, created_at_millis, depth, kind, payload, blob_refs
                from events
                where session_id = ?1 and id = ?2
                ",
                params![session_id.0, entry_id.0],
                |row| {
                    let id: String = row.get(0)?;
                    let session_id: String = row.get(1)?;
                    let parent_id: Option<String> = row.get(2)?;
                    let run_id: Option<String> = row.get(3)?;
                    let sequence: i64 = row.get(4)?;
                    let created_at_millis: i64 = row.get(5)?;
                    let depth: i64 = row.get(6)?;
                    let kind: String = row.get(7)?;
                    let payload: String = row.get(8)?;
                    let blob_refs: String = row.get(9)?;
                    Ok((
                        id,
                        session_id,
                        parent_id,
                        run_id,
                        sequence,
                        created_at_millis,
                        depth,
                        kind,
                        payload,
                        blob_refs,
                    ))
                },
            )
            .map_err(storage_error)
            .and_then(
                |(
                    id,
                    session_id,
                    parent_id,
                    run_id,
                    sequence,
                    created_at_millis,
                    depth,
                    kind,
                    payload,
                    blob_refs,
                )| {
                    Ok(RuntimeEvent {
                        id: EntryId(id),
                        session_id: SessionId(session_id),
                        parent_id: parent_id.map(EntryId),
                        run_id: run_id.map(RunId),
                        sequence: sequence as u64,
                        created_at_millis: created_at_millis.max(0) as u64,
                        depth: depth as u32,
                        kind: event_kind_from_str(&kind)?,
                        payload,
                        blob_refs: if blob_refs.is_empty() {
                            Vec::new()
                        } else {
                            blob_refs.split('\n').map(ToString::to_string).collect()
                        },
                    })
                },
            )
    }

    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select ancestor_id
                from event_paths
                where session_id = ?1 and descendant_id = ?2
                order by depth_delta desc
                ",
            )
            .map_err(storage_error)?;

        let rows = statement
            .query_map(params![session_id.0.as_str(), leaf_id.0.as_str()], |row| {
                row.get::<_, String>(0)
            })
            .map_err(storage_error)?;

        let mut ancestor_ids = Vec::new();
        for row in rows {
            ancestor_ids.push(EntryId(row.map_err(storage_error)?));
        }

        if ancestor_ids.is_empty() {
            return Err(AgentError::Storage(format!(
                "leaf has no path rows: {}",
                leaf_id.0
            )));
        }

        let mut events = Vec::with_capacity(ancestor_ids.len());
        for ancestor_id in ancestor_ids {
            events.push(self.get(session_id, &ancestor_id)?);
        }
        Ok(events)
    }

    fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select id from sessions where archived = 0 order by id")
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(storage_error)?;

        let mut sessions = Vec::new();
        for row in rows {
            sessions.push(SessionId(row.map_err(storage_error)?));
        }
        Ok(sessions)
    }

    fn list_all_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select id from sessions order by id")
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(storage_error)?;

        let mut sessions = Vec::new();
        for row in rows {
            sessions.push(SessionId(row.map_err(storage_error)?));
        }
        Ok(sessions)
    }

    fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select active_leaf_id from sessions where id = ?1")
            .map_err(storage_error)?;
        let mut rows = statement
            .query(params![session_id.0.as_str()])
            .map_err(storage_error)?;

        match rows.next().map_err(storage_error)? {
            Some(row) => {
                let active_leaf_id: Option<String> = row.get(0).map_err(storage_error)?;
                Ok(active_leaf_id.map(EntryId))
            }
            None => Ok(None),
        }
    }

    fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select id
                from events
                where session_id = ?1
                order by sequence desc
                limit 1
                ",
            )
            .map_err(storage_error)?;
        let mut rows = statement
            .query(params![session_id.0.as_str()])
            .map_err(storage_error)?;

        match rows.next().map_err(storage_error)? {
            Some(row) => {
                let entry_id: String = row.get(0).map_err(storage_error)?;
                self.get(session_id, &EntryId(entry_id)).map(Some)
            }
            None => Ok(None),
        }
    }

    fn rename_session(&mut self, session_id: &SessionId, title: String) -> Result<(), AgentError> {
        let changed = self
            .conn
            .execute(
                "update sessions set title_override = ?2 where id = ?1",
                params![session_id.0.as_str(), title.as_str()],
            )
            .map_err(storage_error)?;
        if changed == 0 {
            return Err(AgentError::Storage(format!(
                "session not found: {}",
                session_id.0
            )));
        }
        Ok(())
    }

    fn session_title_override(&self, session_id: &SessionId) -> Result<Option<String>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select title_override from sessions where id = ?1")
            .map_err(storage_error)?;
        let mut rows = statement
            .query(params![session_id.0.as_str()])
            .map_err(storage_error)?;

        match rows.next().map_err(storage_error)? {
            Some(row) => row.get::<_, Option<String>>(0).map_err(storage_error),
            None => Ok(None),
        }
    }

    fn archive_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        let changed = self
            .conn
            .execute(
                "update sessions set archived = 1 where id = ?1",
                params![session_id.0.as_str()],
            )
            .map_err(storage_error)?;
        if changed == 0 {
            return Err(AgentError::Storage(format!(
                "session not found: {}",
                session_id.0
            )));
        }
        Ok(())
    }

    fn delete_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        let tx = self.conn.transaction().map_err(storage_error)?;
        tx.execute(
            "delete from branch_summaries where session_id = ?1",
            params![session_id.0.as_str()],
        )
        .map_err(storage_error)?;
        tx.execute(
            "delete from audit_log where session_id = ?1",
            params![session_id.0.as_str()],
        )
        .map_err(storage_error)?;
        tx.execute(
            "delete from event_paths where session_id = ?1",
            params![session_id.0.as_str()],
        )
        .map_err(storage_error)?;
        tx.execute(
            "delete from events where session_id = ?1",
            params![session_id.0.as_str()],
        )
        .map_err(storage_error)?;
        tx.execute(
            "delete from sessions where id = ?1",
            params![session_id.0.as_str()],
        )
        .map_err(storage_error)?;
        tx.commit().map_err(storage_error)?;
        Ok(())
    }

    fn save_provider_setting(&mut self, setting: ProviderSetting) -> Result<(), AgentError> {
        SqliteEventStore::save_provider_setting(self, &setting.key, &setting.value)
    }

    fn load_provider_setting(&self, key: &str) -> Result<Option<ProviderSetting>, AgentError> {
        Ok(self.provider_setting(key)?.map(|value| ProviderSetting {
            key: key.to_string(),
            value,
        }))
    }
}

fn storage_error(error: rusqlite::Error) -> AgentError {
    AgentError::Storage(error.to_string())
}

fn event_kind_to_str(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::SessionCreated => "SessionCreated",
        EventKind::ProviderChanged => "ProviderChanged",
        EventKind::ToolRegistered => "ToolRegistered",
        EventKind::UserMessage => "UserMessage",
        EventKind::AssistantMessageStarted => "AssistantMessageStarted",
        EventKind::AssistantTextDelta => "AssistantTextDelta",
        EventKind::AssistantMessageCompleted => "AssistantMessageCompleted",
        EventKind::ToolCallRequested => "ToolCallRequested",
        EventKind::ToolCallApproved => "ToolCallApproved",
        EventKind::ToolCallRejected => "ToolCallRejected",
        EventKind::ToolExecutionStarted => "ToolExecutionStarted",
        EventKind::ToolExecutionUpdate => "ToolExecutionUpdate",
        EventKind::ToolExecutionCompleted => "ToolExecutionCompleted",
        EventKind::ToolExecutionFailed => "ToolExecutionFailed",
        EventKind::ToolResultMessage => "ToolResultMessage",
        EventKind::RunSuspended => "RunSuspended",
        EventKind::RunResumed => "RunResumed",
        EventKind::CompactionCreated => "CompactionCreated",
        EventKind::BranchSummaryCreated => "BranchSummaryCreated",
        EventKind::RunCancelled => "RunCancelled",
        EventKind::RunFailed => "RunFailed",
    }
}

fn event_kind_from_str(value: &str) -> Result<EventKind, AgentError> {
    match value {
        "SessionCreated" => Ok(EventKind::SessionCreated),
        "ProviderChanged" => Ok(EventKind::ProviderChanged),
        "ToolRegistered" => Ok(EventKind::ToolRegistered),
        "UserMessage" => Ok(EventKind::UserMessage),
        "AssistantMessageStarted" => Ok(EventKind::AssistantMessageStarted),
        "AssistantTextDelta" => Ok(EventKind::AssistantTextDelta),
        "AssistantMessageCompleted" => Ok(EventKind::AssistantMessageCompleted),
        "ToolCallRequested" => Ok(EventKind::ToolCallRequested),
        "ToolCallApproved" => Ok(EventKind::ToolCallApproved),
        "ToolCallRejected" => Ok(EventKind::ToolCallRejected),
        "ToolExecutionStarted" => Ok(EventKind::ToolExecutionStarted),
        "ToolExecutionUpdate" => Ok(EventKind::ToolExecutionUpdate),
        "ToolExecutionCompleted" => Ok(EventKind::ToolExecutionCompleted),
        "ToolExecutionFailed" => Ok(EventKind::ToolExecutionFailed),
        "ToolResultMessage" => Ok(EventKind::ToolResultMessage),
        "RunSuspended" => Ok(EventKind::RunSuspended),
        "RunResumed" => Ok(EventKind::RunResumed),
        "CompactionCreated" => Ok(EventKind::CompactionCreated),
        "BranchSummaryCreated" => Ok(EventKind::BranchSummaryCreated),
        "RunCancelled" => Ok(EventKind::RunCancelled),
        "RunFailed" => Ok(EventKind::RunFailed),
        _ => Err(AgentError::Storage(format!("unknown event kind: {value}"))),
    }
}
