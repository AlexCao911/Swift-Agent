use std::ops::{Deref, DerefMut};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{params, Connection, OptionalExtension, Transaction};

use crate::core::{AgentError, EntryId, EventKind, RunId, RuntimeEvent, SessionId};
use crate::storage::agent_os_state::SqliteAgentOSStateStore;
use crate::storage::conversation_event_store::{
    ConversationEventStore, StoredTranscriptCommandReceipt,
};

pub struct SqliteConversationStore {
    connection: SqliteConversationStoreConnection,
}

enum SqliteConversationStoreConnection {
    Owned(Connection),
    Unified(Arc<Mutex<SqliteAgentOSStateStore>>),
}

enum SqliteConnectionRef<'a> {
    Owned(&'a Connection),
    Unified(MutexGuard<'a, SqliteAgentOSStateStore>),
}

impl Deref for SqliteConnectionRef<'_> {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::Owned(connection) => connection,
            Self::Unified(store) => store.connection(),
        }
    }
}

enum SqliteConnectionMut<'a> {
    Owned(&'a mut Connection),
    Unified(MutexGuard<'a, SqliteAgentOSStateStore>),
}

impl Deref for SqliteConnectionMut<'_> {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::Owned(connection) => connection,
            Self::Unified(store) => store.connection(),
        }
    }
}

impl DerefMut for SqliteConnectionMut<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        match self {
            Self::Owned(connection) => connection,
            Self::Unified(store) => store.connection_mut(),
        }
    }
}

impl SqliteConversationStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, AgentError> {
        let conn = Connection::open(path).map_err(storage_error)?;
        let store = Self {
            connection: SqliteConversationStoreConnection::Owned(conn),
        };
        store.migrate()?;
        Ok(store)
    }

    pub(crate) fn from_unified_owner(
        owner: Arc<Mutex<SqliteAgentOSStateStore>>,
    ) -> Result<Self, AgentError> {
        let store = Self {
            connection: SqliteConversationStoreConnection::Unified(owner),
        };
        store.migrate()?;
        Ok(store)
    }

    fn connection(&self) -> Result<SqliteConnectionRef<'_>, AgentError> {
        match &self.connection {
            SqliteConversationStoreConnection::Owned(connection) => {
                Ok(SqliteConnectionRef::Owned(connection))
            }
            SqliteConversationStoreConnection::Unified(owner) => owner
                .lock()
                .map(SqliteConnectionRef::Unified)
                .map_err(|_| AgentError::Storage("unified sqlite owner mutex poisoned".into())),
        }
    }

    fn connection_mut(&mut self) -> Result<SqliteConnectionMut<'_>, AgentError> {
        match &mut self.connection {
            SqliteConversationStoreConnection::Owned(connection) => {
                Ok(SqliteConnectionMut::Owned(connection))
            }
            SqliteConversationStoreConnection::Unified(owner) => owner
                .lock()
                .map(SqliteConnectionMut::Unified)
                .map_err(|_| AgentError::Storage("unified sqlite owner mutex poisoned".into())),
        }
    }

    pub fn schema_version(&self) -> Result<i64, AgentError> {
        self.connection()?
            .query_row("select version from schema_meta", [], |row| row.get(0))
            .map_err(storage_error)
    }

    pub fn table_names(&self) -> Result<Vec<String>, AgentError> {
        let connection = self.connection()?;
        let mut statement = connection
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
        <Self as ConversationEventStore>::list_sessions(self)
    }

    pub fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        <Self as ConversationEventStore>::active_leaf(self, session_id)
    }

    pub fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        <Self as ConversationEventStore>::last_event(self, session_id)
    }

    pub fn rename_session(
        &mut self,
        session_id: &SessionId,
        title: String,
    ) -> Result<(), AgentError> {
        <Self as ConversationEventStore>::rename_session(self, session_id, title)
    }

    pub fn session_title_override(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<String>, AgentError> {
        <Self as ConversationEventStore>::session_title_override(self, session_id)
    }

    fn migrate(&self) -> Result<(), AgentError> {
        self.connection()?
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

                create table if not exists conversation_command_receipt (
                  conversation_stream_id text not null,
                  request_id text not null,
                  command_digest text not null,
                  outcome_json text not null,
                  primary key (conversation_stream_id, request_id)
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

    fn append_command_transaction(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        mut events: Vec<RuntimeEvent>,
        receipt: Option<&StoredTranscriptCommandReceipt>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut connection = self.connection_mut()?;
        let tx = connection.transaction().map_err(storage_error)?;
        let actual_next_sequence = tx
            .query_row(
                "
                select coalesce(max(sequence), 0) + 1
                from events
                where session_id = ?1
                ",
                params![conversation_stream_id],
                |row| row.get::<_, i64>(0),
            )
            .map_err(storage_error)?
            .max(1) as u64;
        if actual_next_sequence != expected_next_sequence {
            return Err(AgentError::Storage(format!(
                "conversation sequence conflict: expected {expected_next_sequence}, actual {actual_next_sequence}"
            )));
        }

        for (offset, event) in events.iter_mut().enumerate() {
            if event.session_id.0 != conversation_stream_id {
                return Err(AgentError::Storage(
                    "conversation transaction mixed stream identifiers".into(),
                ));
            }
            event.sequence = expected_next_sequence + offset as u64;
            append_event_in_transaction(&tx, event)?;
        }

        if let Some(receipt) = receipt {
            tx.execute(
                "
                insert into conversation_command_receipt(
                  conversation_stream_id, request_id, command_digest, outcome_json
                )
                values (?1, ?2, ?3, ?4)
                ",
                params![
                    receipt.conversation_stream_id,
                    receipt.request_id,
                    receipt.command_digest,
                    receipt.outcome_json,
                ],
            )
            .map_err(storage_error)?;
        }

        tx.commit().map_err(storage_error)?;
        Ok(events)
    }

    fn ensure_sessions_archived_column(&self) -> Result<(), AgentError> {
        let connection = self.connection()?;
        if connection
            .prepare("select archived from sessions limit 0")
            .is_ok()
        {
            return Ok(());
        }

        connection
            .execute(
                "alter table sessions add column archived integer not null default 0",
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn ensure_sessions_title_override_column(&self) -> Result<(), AgentError> {
        let connection = self.connection()?;
        if connection
            .prepare("select title_override from sessions limit 0")
            .is_ok()
        {
            return Ok(());
        }

        connection
            .execute("alter table sessions add column title_override text", [])
            .map_err(storage_error)?;
        Ok(())
    }

    fn ensure_events_created_at_millis_column(&self) -> Result<(), AgentError> {
        let connection = self.connection()?;
        if connection
            .prepare("select created_at_millis from events limit 0")
            .is_ok()
        {
            return Ok(());
        }

        connection
            .execute(
                "alter table events add column created_at_millis integer not null default 0",
                [],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn write_audit(
        &self,
        session_id: &str,
        event_id: &str,
        summary: &str,
    ) -> Result<(), AgentError> {
        self.connection()?
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
}

impl ConversationEventStore for SqliteConversationStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        if let Some(parent_id) = &event.parent_id {
            self.get(&event.session_id, parent_id)?;
        }

        let mut connection = self.connection_mut()?;
        let tx = connection.transaction().map_err(storage_error)?;
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

    fn append_transaction(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.append_command_transaction(
            conversation_stream_id,
            expected_next_sequence,
            events,
            None,
        )
    }

    fn events_after(
        &self,
        session_id: &SessionId,
        after_sequence: u64,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "
                select id
                from events
                where session_id = ?1 and sequence > ?2
                order by sequence
                ",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map(params![session_id.0, after_sequence as i64], |row| {
                row.get::<_, String>(0)
            })
            .map_err(storage_error)?;
        let mut ids = Vec::new();
        for row in rows {
            ids.push(EntryId(row.map_err(storage_error)?));
        }
        drop(statement);
        drop(connection);

        ids.into_iter()
            .map(|entry_id| self.get(session_id, &entry_id))
            .collect()
    }

    fn command_receipt(
        &self,
        conversation_stream_id: &str,
        request_id: &str,
    ) -> Result<Option<StoredTranscriptCommandReceipt>, AgentError> {
        self.connection()?
            .query_row(
                "
                select conversation_stream_id, request_id, command_digest, outcome_json
                from conversation_command_receipt
                where conversation_stream_id = ?1 and request_id = ?2
                ",
                params![conversation_stream_id, request_id],
                |row| {
                    Ok(StoredTranscriptCommandReceipt {
                        conversation_stream_id: row.get(0)?,
                        request_id: row.get(1)?,
                        command_digest: row.get(2)?,
                        outcome_json: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(storage_error)
    }

    fn commit_command(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
        receipt: StoredTranscriptCommandReceipt,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.append_command_transaction(
            conversation_stream_id,
            expected_next_sequence,
            events,
            Some(&receipt),
        )
    }

    fn write_audit(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
        summary: &str,
    ) -> Result<(), AgentError> {
        SqliteConversationStore::write_audit(self, &session_id.0, &entry_id.0, summary)
    }

    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError> {
        self.connection()?
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
        let connection = self.connection()?;
        let mut statement = connection
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
        drop(statement);
        drop(connection);

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
        let connection = self.connection()?;
        let mut statement = connection
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
        let connection = self.connection()?;
        let mut statement = connection
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
        let connection = self.connection()?;
        let mut statement = connection
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
        let connection = self.connection()?;
        let mut statement = connection
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

        let entry_id = rows
            .next()
            .map_err(storage_error)?
            .map(|row| row.get::<_, String>(0).map_err(storage_error))
            .transpose()?;
        drop(rows);
        drop(statement);
        drop(connection);
        entry_id
            .map(|entry_id| self.get(session_id, &EntryId(entry_id)))
            .transpose()
    }

    fn rename_session(&mut self, session_id: &SessionId, title: String) -> Result<(), AgentError> {
        let changed = self
            .connection()?
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
        let connection = self.connection()?;
        let mut statement = connection
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
            .connection()?
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
        let mut connection = self.connection_mut()?;
        let tx = connection.transaction().map_err(storage_error)?;
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
}

fn append_event_in_transaction(
    tx: &Transaction<'_>,
    event: &RuntimeEvent,
) -> Result<(), AgentError> {
    if let Some(parent_id) = &event.parent_id {
        let parent_exists = tx
            .query_row(
                "
                select 1 from events
                where session_id = ?1 and id = ?2
                ",
                params![event.session_id.0, parent_id.0],
                |_| Ok(()),
            )
            .optional()
            .map_err(storage_error)?
            .is_some();
        if !parent_exists {
            return Err(AgentError::Storage(format!(
                "missing parent event: {}",
                parent_id.0
            )));
        }
    }

    tx.execute(
        "
        insert into sessions(id, active_leaf_id, archived)
        values (?1, ?2, 0)
        on conflict(id) do update set
          active_leaf_id = excluded.active_leaf_id
        ",
        params![event.session_id.0, event.id.0],
    )
    .map_err(storage_error)?;
    tx.execute(
        "
        insert into events(
          id, session_id, parent_id, run_id, sequence, created_at_millis, depth,
          kind, payload, blob_refs
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
    Ok(())
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
        EventKind::TranscriptRetryRequested => "TranscriptRetryRequested",
        EventKind::MessageEdited => "MessageEdited",
        EventKind::MessageDeleted => "MessageDeleted",
        EventKind::ConversationCleared => "ConversationCleared",
        EventKind::BranchCreated => "BranchCreated",
        EventKind::ConversationArchived => "ConversationArchived",
        EventKind::ConversationDeleted => "ConversationDeleted",
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
        "TranscriptRetryRequested" => Ok(EventKind::TranscriptRetryRequested),
        "MessageEdited" => Ok(EventKind::MessageEdited),
        "MessageDeleted" => Ok(EventKind::MessageDeleted),
        "ConversationCleared" => Ok(EventKind::ConversationCleared),
        "BranchCreated" => Ok(EventKind::BranchCreated),
        "ConversationArchived" => Ok(EventKind::ConversationArchived),
        "ConversationDeleted" => Ok(EventKind::ConversationDeleted),
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
