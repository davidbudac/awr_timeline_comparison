--
-- fleet/schedule/digest_dir.sql
--
-- OPTIONAL: turns ON the filesystem delivery method. Run ONCE as a privileged
-- user (needs CREATE ANY DIRECTORY). EDIT the two marked values below.
--
-- Once this DIRECTORY exists and is granted to the warehouse owner, every
-- pipeline cycle's awrw_notify.deliver_to_files writes the rendered Digest into
-- it as:
--     awr_fleet_digest_<id>_<YYYYMMDD_HH24MISS>.html   (per-cycle archive)
--     awr_fleet_digest_latest.html                     (always the newest)
-- Until this exists, deliver_to_files is a silent no-op, so file delivery is
-- strictly opt-in. The path is on the SERVER hosting the warehouse database, not
-- the client. The warehouse owner also needs EXECUTE on UTL_FILE (usually public).
--
-- To turn it OFF again: DROP DIRECTORY AWRW_DIGEST_DIR; (delivered digests stay
-- on disk; the archive rows keep their file_name).
--

CREATE OR REPLACE DIRECTORY AWRW_DIGEST_DIR AS '/var/tmp/awr_digests';   -- <<< EDIT: server path (must exist, writable by the DB OS user)
GRANT READ, WRITE ON DIRECTORY AWRW_DIGEST_DIR TO AWRWH;                 -- <<< EDIT: your warehouse owner
