create table schema_meta (
  version integer not null
);

insert into schema_meta(version) values (1);

create table sessions (
  id text primary key,
  active_leaf_id text
);

create table events (
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

create table event_paths (
  session_id text not null,
  ancestor_id text not null,
  descendant_id text not null,
  depth_delta integer not null,
  primary key (session_id, ancestor_id, descendant_id)
);

insert into sessions(id, active_leaf_id)
values ('session_legacy', 'entry_legacy');

insert into events(id, session_id, parent_id, run_id, sequence, depth, kind, payload, blob_refs)
values (
  'entry_legacy',
  'session_legacy',
  null,
  'run_legacy',
  1,
  0,
  'UserMessage',
  'legacy payload',
  ''
);

insert into event_paths(session_id, ancestor_id, descendant_id, depth_delta)
values ('session_legacy', 'entry_legacy', 'entry_legacy', 0);
