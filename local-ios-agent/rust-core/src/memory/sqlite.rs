use std::path::Path;

use rusqlite::Connection;

use crate::core::AgentError;

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
                  active_leaf_id text
                );

                create table if not exists events (
                  id text not null,
                  session_id text not null,
                  parent_id text,
                  run_id text,
                  sequence integer not null,
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
                ",
            )
            .map_err(storage_error)?;

        let version = self.schema_version()?;
        if version != 1 {
            return Err(AgentError::Storage(format!(
                "unsupported sqlite schema version: {version}"
            )));
        }
        Ok(())
    }
}

fn storage_error(error: rusqlite::Error) -> AgentError {
    AgentError::Storage(error.to_string())
}
