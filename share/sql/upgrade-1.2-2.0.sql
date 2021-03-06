SET search_path TO monitoring, public;
BEGIN;

CREATE OR REPLACE FUNCTION metric_tables_config() RETURNS json
LANGUAGE plpgsql
AS $$

DECLARE
  v_query JSON;
  v_conf JSON;
  q_metric_sessions_agg TEXT;
  q_metric_xacts_agg TEXT;
  q_metric_locks_agg TEXT;
  q_metric_blocks_agg TEXT;
  q_metric_bgwriter_agg TEXT;
  q_metric_db_size_agg TEXT;
  q_metric_tblspc_size_agg TEXT;
  q_metric_filesystems_size_agg TEXT;
  q_metric_temp_files_size_tblspc_agg TEXT;
  q_metric_temp_files_size_db_agg TEXT;
  q_metric_wal_files_agg TEXT;
  q_metric_cpu_agg TEXT;
  q_metric_process_agg TEXT;
  q_metric_memory_agg TEXT;
  q_metric_loadavg_agg TEXT;
  q_metric_vacuum_analyze_agg TEXT;
BEGIN
  --
  -- Query template list for the actions: 'history' and 'expand'
  -- 'history': Move data from metric_<type>_current to metric_<type>_history, grouping records into array of records.
  -- 'expand': Return data from both metric_<type>_current and metric_<type>_history tables, depending on the time interval.
  --
  SELECT '{
    "history": {
      "host_id":     "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), host_id, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# GROUP BY date_trunc(''day'', datetime),2 ORDER BY 1,2 ASC;",
      "instance_id": "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), instance_id, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# GROUP BY date_trunc(''day'', datetime),2 ORDER BY 1,2 ASC;",
      "dbname":      "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), instance_id, dbname, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# GROUP BY date_trunc(''day'', datetime),2,3 ORDER BY 1,2 ASC;",
      "spcname":     "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), instance_id, spcname, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# GROUP BY date_trunc(''day'', datetime),2,3 ORDER BY 1,2,3 ASC;",
      "mount_point": "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), host_id, mount_point, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# AS deleted_rows GROUP BY date_trunc(''day'', datetime),2,3 ORDER BY 1,2,3 ASC;",
      "cpu":         "INSERT INTO #history_table# SELECT tstzrange(min(datetime), max(datetime)), host_id, cpu, array_agg(set_datetime_record(datetime, record)::#record_type#) AS records FROM #current_table# AS deleted_rows GROUP BY date_trunc(''day'', datetime),2,3 ORDER BY 1,2,3 ASC;"
    },
    "expand": {
      "host_id": "WITH expand AS (SELECT datetime, host_id, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, host_id, hist_query.record FROM (SELECT host_id, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC",
      "instance_id": "WITH expand AS (SELECT datetime, instance_id, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, instance_id, hist_query.record FROM (SELECT instance_id, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC",
      "dbname": "WITH expand AS (SELECT datetime, instance_id, dbname, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, instance_id, dbname, hist_query.record FROM (SELECT instance_id, dbname, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC",
      "spcname":"WITH expand AS (SELECT datetime, instance_id, spcname, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, instance_id, spcname, hist_query.record FROM (SELECT instance_id, spcname, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC",
      "mount_point": "WITH expand AS (SELECT datetime, host_id, mount_point, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, host_id, mount_point, hist_query.record FROM (SELECT host_id, mount_point, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC",
      "cpu": "WITH expand AS (SELECT datetime, host_id, cpu, record FROM #current_table# WHERE #where_current# UNION SELECT (hist_query.record).datetime, host_id, cpu, hist_query.record FROM (SELECT host_id, cpu, unnest(records)::#record_type# AS record FROM #history_table# WHERE #where_history#) AS hist_query) SELECT * FROM expand WHERE datetime <@ #tstzrange# ORDER BY datetime ASC"
    }
  }'::JSON INTO v_query;

  --
  -- Global configuration.
  --
  -- For each type of metric we have to deal with, there is the following object defining some properties:
  -- // Unique key used to find the configuration based on the metric name.
  -- "<metric_name>": {
  --   // Tables name prefix, for ease stuff it should be the same as <metric_name>
  --   "name": "<metric_tbl_name>",
  --   // Record composite type
  --   "record_type": "<metric_record_type>",
  --   // List of extra columns.
  --   "columns": [
  --     {
  --       // Column name
  --       "name": "<column_name>",
  --       // Column data type
  --       "data_type": "<column_data_type>"
  --     },
  --     [...]
  --   ],
  --   // Query template use to history data.
  --   "history": "<query_tpl_history>",
  --   // Query template use to fetch data from both _current & _history tables.
  --   "expand": "<query_tpl_expand>",
  --   // Query template use to aggregate data.
  --   "aggregate": "<query_tpl_aggregate>"
  -- }

  q_metric_sessions_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      AVG((r).active),
      AVG((r).waiting),
      AVG((r).idle),
      AVG((r).idle_in_xact),
      AVG((r).idle_in_xact_aborted),
      AVG((r).fastpath),
      AVG((r).disabled),
      AVG((r).no_priv)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
   )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_xacts_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).n_commit),
      SUM((r).n_rollback)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
  AS (
    datetime timestamp with time zone,
    instance_id integer,
    dbname text,
    r #record_type#
  )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_locks_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      AVG((r).access_share),
      AVG((r).row_share),
      AVG((r).row_exclusive),
      AVG((r).share_update_exclusive),
      AVG((r).share),
      AVG((r).share_row_exclusive),
      AVG((r).exclusive),
      AVG((r).access_exclusive),
      AVG((r).siread),
      AVG((r).waiting_access_share),
      AVG((r).waiting_row_share),
      AVG((r).waiting_row_exclusive),
      AVG((r).waiting_share_update_exclusive),
      AVG((r).waiting_share),
      AVG((r).waiting_share_row_exclusive),
      AVG((r).waiting_exclusive),
      AVG((r).waiting_access_exclusive)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_blocks_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).blks_read),
      SUM((r).blks_hit),
      AVG((r).hitmiss_ratio)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_bgwriter_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).checkpoints_timed),
      SUM((r).checkpoints_req),
      SUM((r).checkpoint_write_time),
      SUM((r).checkpoint_sync_time),
      SUM((r).buffers_checkpoint),
      SUM((r).buffers_clean),
      SUM((r).maxwritten_clean),
      SUM((r).buffers_backend),
      SUM((r).buffers_backend_fsync),
      SUM((r).buffers_alloc),
      NULL
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2
  ORDER BY 1,2
ON CONFLICT (datetime, instance_id)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_db_size_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      AVG((r).size)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_tblspc_size_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    spcname,
    ROW(
      NULL,
      AVG((r).size)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      spcname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, spcname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_filesystems_size_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    host_id,
    mount_point,
    ROW(
      NULL,
      AVG((r).used),
      AVG((r).total),
      NULL
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      host_id integer,
      mount_point text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, host_id, mount_point)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_temp_files_size_tblspc_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    spcname,
    ROW(
      NULL,
      AVG((r).size)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      spcname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, spcname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_temp_files_size_db_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      AVG((r).size)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_wal_files_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    ROW(
      NULL,
      SUM((r).measure_interval),
      MAX((r).written_size),
      MIN((r).current_location::pg_lsn)::TEXT,
      MAX((r).total),
      MAX((r).archive_ready),
      MAX((r).total_size)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2
  ORDER BY 1,2
ON CONFLICT (datetime, instance_id)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_cpu_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    host_id,
    cpu,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).time_user),
      SUM((r).time_system),
      SUM((r).time_idle),
      SUM((r).time_iowait),
      SUM((r).time_steal)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      host_id integer,
      cpu text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, host_id, cpu)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_process_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    host_id,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).context_switches),
      SUM((r).forks),
      AVG((r).procs_running),
      AVG((r).procs_blocked),
      AVG((r).procs_total)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      host_id integer,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2
  ORDER BY 1,2
ON CONFLICT (datetime, host_id)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_memory_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    host_id,
    ROW(
      NULL,
      AVG((r).mem_total),
      AVG((r).mem_used),
      AVG((r).mem_free),
      AVG((r).mem_buffers),
      AVG((r).mem_cached),
      AVG((r).swap_total),
      AVG((r).swap_used)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      host_id integer,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2
  ORDER BY 1,2
ON CONFLICT (datetime, host_id)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_loadavg_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    host_id,
    ROW(
      NULL,
      ROUND(AVG((r).load1)::NUMERIC, 2),
      ROUND(AVG((r).load5)::NUMERIC, 2),
      ROUND(AVG((r).load15)::NUMERIC, 2)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      host_id integer,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2
  ORDER BY 1,2
ON CONFLICT (datetime, host_id)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  q_metric_vacuum_analyze_agg := replace(to_json($_$
INSERT INTO #agg_table#
  SELECT
    truncate_time(datetime, '#interval#') AS datetime,
    instance_id,
    dbname,
    ROW(
      NULL,
      SUM((r).measure_interval),
      SUM((r).n_vacuum),
      SUM((r).n_analyze),
      SUM((r).n_autovacuum),
      SUM((r).n_autoanalyze)
    )::#record_type#,
    COUNT(*) AS w
  FROM
    expand_data_limit('#name#', (SELECT tstzrange(MAX(datetime), NOW()) FROM #agg_table#), 100000)
    AS (
      datetime timestamp with time zone,
      instance_id integer,
      dbname text,
      r #record_type#
    )
  WHERE
    truncate_time(datetime, '#interval#') < truncate_time(NOW(), '#interval#')
  GROUP BY 1,2,3
  ORDER BY 1,2,3
ON CONFLICT (datetime, instance_id, dbname)
DO UPDATE SET w = EXCLUDED.w, record = EXCLUDED.record
WHERE #agg_table#.w < EXCLUDED.w
$_$::TEXT)::TEXT, '\n', ' ');

  SELECT ('{
  "metric_sessions": {
    "name": "metric_sessions",
    "record_type": "metric_sessions_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_sessions_agg||'
  },
  "metric_xacts": {
    "name": "metric_xacts",
    "record_type": "metric_xacts_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_xacts_agg||'
  },
  "metric_locks": {
    "name": "metric_locks",
    "record_type": "metric_locks_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_locks_agg||'
  },
  "metric_blocks": {
    "name": "metric_blocks",
    "record_type": "metric_blocks_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_blocks_agg||'
  },
  "metric_bgwriter": {
    "name": "metric_bgwriter",
    "record_type": "metric_bgwriter_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"}
    ],
    "history": "'||(v_query->'history'->>'instance_id')||'",
    "expand": "'||(v_query->'expand'->>'instance_id')||'",
    "aggregate": '||q_metric_bgwriter_agg||'
  },
  "metric_db_size": {
    "name": "metric_db_size",
    "record_type": "metric_db_size_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_db_size_agg||'
  },
  "metric_tblspc_size": {
    "name": "metric_tblspc_size",
    "record_type": "metric_tblspc_size_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "spcname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'spcname')||'",
    "expand": "'||(v_query->'expand'->>'spcname')||'",
    "aggregate": '||q_metric_tblspc_size_agg||'
  },
  "metric_filesystems_size": {
    "name": "metric_filesystems_size",
    "record_type": "metric_filesystems_size_record",
    "columns":
    [
      {"name": "host_id", "data_type": "INTEGER NOT NULL REFERENCES hosts (host_id)"},
      {"name": "mount_point", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'mount_point')||'",
    "expand": "'||(v_query->'expand'->>'mount_point')||'",
    "aggregate": '||q_metric_filesystems_size_agg||'
  },
  "metric_temp_files_size_tblspc": {
    "name": "metric_temp_files_size_tblspc",
    "record_type": "metric_temp_files_size_tblspc_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "spcname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'spcname')||'",
    "expand": "'||(v_query->'expand'->>'spcname')||'",
    "aggregate": '||q_metric_temp_files_size_tblspc_agg||'
  },
  "metric_temp_files_size_db": {
    "name": "metric_temp_files_size_db",
    "record_type": "metric_temp_files_size_db_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_temp_files_size_db_agg||'
  },
  "metric_wal_files": {
    "name": "metric_wal_files",
    "record_type": "metric_wal_files_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"}
    ],
    "history": "'||(v_query->'history'->>'instance_id')||'",
    "expand": "'||(v_query->'expand'->>'instance_id')||'",
    "aggregate": '||q_metric_wal_files_agg||'
  },
  "metric_cpu": {
    "name": "metric_cpu",
    "record_type": "metric_cpu_record",
    "columns":
    [
      {"name": "host_id", "data_type": "INTEGER NOT NULL REFERENCES hosts (host_id)"},
      {"name": "cpu", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'cpu')||'",
    "expand": "'||(v_query->'expand'->>'cpu')||'",
    "aggregate": '||q_metric_cpu_agg||'
  },
  "metric_process": {
    "name": "metric_process",
    "record_type": "metric_process_record",
    "columns":
    [
      {"name": "host_id", "data_type": "INTEGER NOT NULL REFERENCES hosts (host_id)"}
    ],
    "history": "'||(v_query->'history'->>'host_id')||'",
    "expand": "'||(v_query->'expand'->>'host_id')||'",
    "aggregate": '||q_metric_process_agg||'
  },
  "metric_memory": {
    "name": "metric_memory",
    "record_type": "metric_memory_record",
    "columns":
    [
      {"name": "host_id", "data_type": "INTEGER NOT NULL REFERENCES hosts (host_id)"}
    ],
    "history": "'||(v_query->'history'->>'host_id')||'",
    "expand": "'||(v_query->'expand'->>'host_id')||'",
    "aggregate": '||q_metric_memory_agg||'
  },
  "metric_loadavg": {
    "name": "metric_loadavg",
    "record_type": "metric_loadavg_record",
    "columns":
    [
      {"name": "host_id", "data_type": "INTEGER NOT NULL REFERENCES hosts (host_id)"}
    ],
    "history": "'||(v_query->'history'->>'host_id')||'",
    "expand": "'||(v_query->'expand'->>'host_id')||'",
    "aggregate": '||q_metric_loadavg_agg||'
  },
  "metric_vacuum_analyze": {
    "name": "metric_vacuum_analyze",
    "record_type": "metric_vacuum_analyze_record",
    "columns":
    [
      {"name": "instance_id", "data_type": "INTEGER NOT NULL REFERENCES instances (instance_id)"},
      {"name": "dbname", "data_type": "TEXT NOT NULL"}
    ],
    "history": "'||(v_query->'history'->>'dbname')||'",
    "expand": "'||(v_query->'expand'->>'dbname')||'",
    "aggregate": '||q_metric_vacuum_analyze_agg||'
  }}')::JSON INTO v_conf;
  RETURN v_conf;

END;

$$;


CREATE OR REPLACE FUNCTION create_tables() RETURNS TABLE(tblname TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
  t JSON;
  c JSON;
  v_agg_periods TEXT[] := array['30m', '6h'];
  v_create_tbl_cols_cur TEXT;
  v_create_idx_cols_cur TEXT;
  v_create_tbl_cols_hist TEXT;
  v_create_idx_cols_hist TEXT;
  v_tablename TEXT;
  v_like_tablename TEXT;
  v_create_tbl_stmt TEXT;
  v_create_idx_stmt TEXT;
  i_period TEXT;
BEGIN
  -- Tables creation if they do not exist
  FOR t IN SELECT metric_tables_config()->json_object_keys(metric_tables_config()) LOOP
    v_create_tbl_cols_cur := 'datetime TIMESTAMPTZ NOT NULL';
    v_create_idx_cols_cur := 'datetime';
    FOR c IN SELECT json_array_elements(t->'columns') LOOP
      v_create_tbl_cols_cur := v_create_tbl_cols_cur||', '||trim((c->'name')::TEXT, '"')||' '||trim((c->'data_type')::TEXT, '"');
      v_create_idx_cols_cur := v_create_idx_cols_cur||', '||trim((c->'name')::TEXT, '"');
    END LOOP;

  -- Creation of current table.
    v_tablename := trim((t->'name')::TEXT, '"')||'_current';
    PERFORM 1 FROM pg_tables WHERE tablename = v_tablename AND schemaname = current_schema();
    IF NOT FOUND THEN
      EXECUTE 'CREATE TABLE '||v_tablename||' ('||v_create_tbl_cols_cur||', record '||trim((t->'record_type')::TEXT, '"')||')';
      EXECUTE 'CREATE INDEX idx_'||v_tablename||' ON '||v_tablename||' ('||v_create_idx_cols_cur||')';
      RETURN QUERY SELECT v_tablename;
    END IF;

    -- Creation of history table.
    v_create_tbl_cols_hist := 'history_range TSTZRANGE NOT NULL';
    v_create_idx_cols_hist := 'history_range';
    FOR c IN SELECT json_array_elements(t->'columns') LOOP
      v_create_tbl_cols_hist := v_create_tbl_cols_hist||', '||trim((c->'name')::TEXT, '"')||' '||trim((c->'data_type')::TEXT, '"');
      v_create_idx_cols_hist := v_create_idx_cols_hist||', '||trim((c->'name')::TEXT, '"');
    END LOOP;

    v_tablename := trim((t->'name')::TEXT, '"')||'_history';
    PERFORM 1 FROM pg_tables WHERE tablename = v_tablename AND schemaname = current_schema();
    IF NOT FOUND THEN
      EXECUTE 'CREATE TABLE '||v_tablename||' ('||v_create_tbl_cols_hist||', records '||trim((t->'record_type')::TEXT, '"')||'[])';
      EXECUTE 'CREATE INDEX idx_'||v_tablename||' ON '||v_tablename||' ('||v_create_idx_cols_hist||')';
      RETURN QUERY SELECT v_tablename;
    END IF;

    -- Aggregate tables creation.
    FOREACH i_period IN ARRAY v_agg_periods LOOP
      v_tablename := trim((t->'name')::TEXT, '"')||'_'||i_period||'_current';
      v_like_tablename := trim((t->'name')::TEXT, '"')||'_current';
      PERFORM 1 FROM pg_tables WHERE tablename = v_tablename AND schemaname = current_schema();
      IF NOT FOUND THEN
        EXECUTE 'CREATE TABLE '||v_tablename||' (LIKE '||v_like_tablename||')';
        -- Weight: number of record aggregated
        EXECUTE 'ALTER TABLE '||v_tablename||' ADD COLUMN w INTEGER DEFAULT 1';
        EXECUTE 'ALTER TABLE '||v_tablename||' ADD UNIQUE ('||v_create_idx_cols_cur||')';
        RETURN QUERY SELECT v_tablename;
      END IF;
    END LOOP;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION history_tables() RETURNS TABLE(tblname TEXT, nb_rows INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
  t JSON;
  v_table_current TEXT;
  v_table_history TEXT;
  v_query TEXT;
  i INTEGER;
BEGIN
  -- History data from each _current table
  FOR t IN SELECT metric_tables_config()->json_object_keys(metric_tables_config()) LOOP
    v_table_current := trim((t->'name')::TEXT, '"')||'_current';
    v_table_history := trim((t->'name')::TEXT, '"')||'_history';
    -- Lock _current table to prevent concurrent updates
    EXECUTE 'LOCK TABLE '||v_table_current||' IN SHARE MODE';
    v_query := replace(t->>'history', '#history_table#', v_table_history);
    v_query := replace(v_query, '#current_table#', v_table_current);
    v_query := replace(v_query, '#record_type#', trim((t->'record_type')::TEXT, '"'));
    -- Move data into _history table
    EXECUTE v_query;
    GET DIAGNOSTICS i = ROW_COUNT;
    -- Truncate _current table
    EXECUTE 'TRUNCATE '||v_table_current;
    -- Return each history table name and the number of rows inserted
    RETURN QUERY SELECT v_table_history, i;
  END LOOP;
END;
$$;


CREATE OR REPLACE FUNCTION build_expand_data_query(i_name TEXT, i_range TSTZRANGE) RETURNS TEXT
LANGUAGE plpgsql
AS $$

DECLARE
  t JSON;
  v_query TEXT;
  v_table_current TEXT;
  v_table_history TEXT;
BEGIN
  -- Build and execute 'expand' query
  SELECT metric_tables_config()->i_name INTO t;
  v_query := t->>'expand';
  v_table_current := trim((t->'name')::TEXT, '"')||'_current';
  v_table_history := trim((t->'name')::TEXT, '"')||'_history';
  v_query := replace(v_query, '#history_table#', v_table_history);
  v_query := replace(v_query, '#current_table#', v_table_current);
  v_query := replace(v_query, '#record_type#', trim((t->'record_type')::TEXT, '"'));
  v_query := replace(v_query, '#where_current#', 'datetime <@ '''||i_range::TEXT||'''::TSTZRANGE');
  v_query := replace(v_query, '#where_history#', 'history_range && '''||i_range::TEXT||'''::TSTZRANGE');
  v_query := replace(v_query, '#tstzrange#', ''''||i_range::TEXT||'''::TSTZRANGE');
  RETURN v_query;
END;

$$;


CREATE OR REPLACE FUNCTION expand_data(i_name TEXT, i_range TSTZRANGE) RETURNS SETOF RECORD
LANGUAGE plpgsql
AS $$

DECLARE
  v_query TEXT;
BEGIN
  -- Build and execute 'expand' query
  SELECT monitoring.build_expand_data_query(i_name, i_range) INTO v_query;
  RAISE NOTICE '%', v_query;
  RETURN QUERY EXECUTE v_query;
END;

$$;


CREATE OR REPLACE FUNCTION expand_data_limit(i_name TEXT, i_range TSTZRANGE, i_limit INTEGER) RETURNS SETOF RECORD
LANGUAGE plpgsql
AS $$

DECLARE
  v_query TEXT;
BEGIN
  -- Build and execute 'expand' query
  SELECT monitoring.build_expand_data_query(i_name, i_range) INTO v_query;
  v_query := v_query||' LIMIT '||i_limit::TEXT;
  RAISE NOTICE '%', v_query;
  RETURN QUERY EXECUTE v_query;
END;

$$;


COMMIT;
