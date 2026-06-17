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
