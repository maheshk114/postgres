use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $scenario = $ENV{V28_SCENARIO} // 'stable-default';
my $serial = ($scenario =~ s/-serial$//);
my $publisher = PostgreSQL::Test::Cluster->new('publisher');
$publisher->init(allows_streaming => 'logical');
$publisher->append_conf('postgresql.conf', "logical_decoding_work_mem = '64MB'");
$publisher->start;
my $subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$subscriber->init;
$subscriber->append_conf('postgresql.conf', q{
max_logical_replication_workers = 10
max_parallel_apply_workers_per_subscription = 3
log_min_messages = debug1
});
$subscriber->start;
$subscriber->safe_psql('postgres', 'CREATE EXTENSION injection_points');

if ($scenario eq 'stable-default')
{
    $publisher->safe_psql('postgres', q{
        CREATE TABLE lookup (id int PRIMARY KEY);
        CREATE TABLE target (id int PRIMARY KEY);
    });
    $subscriber->safe_psql('postgres', q{
        CREATE TABLE lookup (id int PRIMARY KEY);
        CREATE FUNCTION lookup_count() RETURNS int LANGUAGE sql STABLE
        AS 'SELECT count(*)::int FROM public.lookup';
        CREATE TABLE target (id int PRIMARY KEY, seen int DEFAULT lookup_count());
    });
}
elsif ($scenario eq 'numeric-key')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE target (id numeric PRIMARY KEY, v int);
        });
    }
}
elsif ($scenario eq 'fk-toast')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE parent (id int PRIMARY KEY, k text UNIQUE);
            CREATE TABLE child (id int PRIMARY KEY, k text REFERENCES parent(k), v int);
            ALTER TABLE child ALTER COLUMN k SET STORAGE EXTERNAL;
        });
    }
    $subscriber->safe_psql('postgres', q{
        DO $$ DECLARE r record; BEGIN
          FOR r IN SELECT tgrelid::regclass AS rel, tgname FROM pg_trigger
                   WHERE tgrelid IN ('parent'::regclass, 'child'::regclass)
          LOOP EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I', r.rel, r.tgname);
          END LOOP;
        END $$;
    });
}
elsif ($scenario eq 'one-sided-fk')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE parent (id int PRIMARY KEY);
            CREATE TABLE child (id int PRIMARY KEY, p int REFERENCES parent(id));
        });
    }
    $subscriber->safe_psql('postgres', q{
        DO $$ DECLARE r record; BEGIN
          FOR r IN SELECT tgname FROM pg_trigger WHERE tgrelid = 'child'::regclass
          LOOP EXECUTE format('ALTER TABLE child ENABLE ALWAYS TRIGGER %I', r.tgname);
          END LOOP;
        END $$;
    });
}
elsif ($scenario eq 'suspended-stream')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE target (id int, v text);
            ALTER TABLE target REPLICA IDENTITY FULL;
            CREATE TABLE bulk (id int, v text);
        });
    }
}
elsif ($scenario eq 'stream-abort-origin')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE target (id int PRIMARY KEY);
            CREATE TABLE bulk (id int PRIMARY KEY, v text);
        });
    }
    $publisher->append_conf('postgresql.conf', "logical_decoding_work_mem = '64kB'");
    $publisher->reload;
}
elsif ($scenario eq 'partition-truncate')
{
    $publisher->safe_psql('postgres', q{
        CREATE TABLE target (id int, value text, marker text);
        ALTER TABLE target REPLICA IDENTITY FULL;
    });
    $subscriber->safe_psql('postgres', q{
        CREATE TABLE target (id int, value text, marker text) PARTITION BY RANGE (id);
        ALTER TABLE target REPLICA IDENTITY FULL;
        CREATE TABLE target_leaf (value text, marker text, id int);
        ALTER TABLE target_leaf REPLICA IDENTITY FULL;
        ALTER TABLE target ATTACH PARTITION target_leaf FOR VALUES FROM (0) TO (1000);
    });
}
elsif ($scenario eq 'hidden-trigger-write')
{
    for my $node ($publisher, $subscriber)
    {
        $node->safe_psql('postgres', q{
            CREATE TABLE a (id int PRIMARY KEY, v int);
            CREATE TABLE b (id int PRIMARY KEY, v int);
            CREATE FUNCTION write_b() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                INSERT INTO public.b VALUES (NEW.id, NEW.v);
                RETURN NEW;
            END $$;
            CREATE TRIGGER write_b AFTER UPDATE ON a
                FOR EACH ROW EXECUTE FUNCTION write_b();
            ALTER TABLE a ENABLE ALWAYS TRIGGER write_b;
        });
    }
    $publisher->safe_psql('postgres', 'INSERT INTO a VALUES (1,0); INSERT INTO b VALUES (-1,0)');
}
else
{
    die "Unknown scenario $scenario";
}

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub FOR ALL TABLES');
$publisher->safe_psql('postgres', "ALTER PUBLICATION pub SET (publish='update')")
    if $scenario eq 'hidden-trigger-write';
my $connstr = $publisher->connstr('postgres');
$connstr =~ s/'/''/g;
my $streaming = $serial ? 'off' : 'parallel';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub CONNECTION '$connstr' PUBLICATION pub WITH (streaming = $streaming, disable_on_error = true)");
$subscriber->wait_for_subscription_sync($publisher, 'sub');

if ($serial)
{
    if ($scenario eq 'stable-default')
    {
        $publisher->safe_psql('postgres', 'INSERT INTO lookup VALUES (1)');
        $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1)');
        $publisher->wait_for_catchup('sub');
        is($subscriber->safe_psql('postgres', 'SELECT seen FROM target WHERE id=1'),
           '1', 'Serial control: STABLE default sees preceding committed row');
    }
    elsif ($scenario eq 'numeric-key')
    {
        $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1.0,1)');
        $publisher->safe_psql('postgres', 'UPDATE target SET id=2 WHERE id=1.0');
        $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1.00,2)');
        $publisher->wait_for_catchup('sub');
        is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM target'),
           '2', 'Serial control: numeric replacement succeeds');
    }
    elsif ($scenario eq 'one-sided-fk')
    {
        $publisher->safe_psql('postgres', 'INSERT INTO parent VALUES (1)');
        $publisher->safe_psql('postgres', 'INSERT INTO child VALUES (1,1)');
        $publisher->wait_for_catchup('sub');
        is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM child'),
           '1', 'Serial control: one-sided FK enablement succeeds');
    }
    elsif ($scenario eq 'hidden-trigger-write')
    {
        $publisher->safe_psql('postgres', 'UPDATE a SET v=1 WHERE id=1');
        $publisher->safe_psql('postgres', 'UPDATE b SET v=2 WHERE id=1');
        $publisher->wait_for_catchup('sub');
        is($subscriber->safe_psql('postgres', 'SELECT v FROM b WHERE id=1'),
           '2', 'Serial control: hidden trigger INSERT precedes subsequent UPDATE');
    }
    else { die 'Unsupported serial control'; }
}
elsif ($scenario eq 'stable-default')
{
    $publisher->safe_psql('postgres', 'INSERT INTO lookup VALUES (-1); INSERT INTO target VALUES (-1)');
    $publisher->wait_for_catchup('sub');
    $publisher->safe_psql('postgres', 'DELETE FROM target; DELETE FROM lookup');
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('parallel-worker-before-commit', 'wait')");
    $publisher->safe_psql('postgres', 'INSERT INTO lookup VALUES (1)');
    $subscriber->wait_for_event('logical replication parallel worker', 'parallel-worker-before-commit');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('parallel-worker-before-commit')");
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1)');
    $subscriber->wait_for_log(qr/wait for depended xid/, $offset);
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_wakeup('parallel-worker-before-commit')");
    $publisher->wait_for_catchup('sub');
    my $actual = $subscriber->safe_psql('postgres', 'SELECT seen FROM target WHERE id = 1');
    diag("REPRO stable-default: serial expected=1, parallel actual=$actual");
    is($actual, '0', 'BUG reproduced: STABLE default retains pre-wait snapshot');
}
elsif ($scenario eq 'numeric-key')
{
    $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1.0, 1)');
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('apply-update-before-open-indices', 'wait')");
    $publisher->safe_psql('postgres', 'UPDATE target SET id = 2 WHERE id = 1.0');
    $subscriber->wait_for_event('logical replication parallel worker', 'apply-update-before-open-indices');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('apply-update-before-open-indices')");
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1.00, 2)');
    $subscriber->wait_for_log(qr/duplicate key value|conflict detected.*insert_exists/s, $offset);
    ok($subscriber->poll_query_until('postgres', "SELECT NOT subenabled FROM pg_subscription WHERE subname='sub'"),
       'BUG reproduced: numeric equality mismatch raises parallel-only unique error');
    diag('REPRO numeric-key: publisher UPDATE 1.0->2 then INSERT 1.00 succeeds; subscriber disables on unique conflict');
}
elsif ($scenario eq 'one-sided-fk')
{
    $publisher->safe_psql('postgres', 'INSERT INTO parent VALUES (-1); INSERT INTO child VALUES (-1,-1)');
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('parallel-worker-before-commit', 'wait')");
    $publisher->safe_psql('postgres', 'INSERT INTO parent VALUES (1)');
    $subscriber->wait_for_event('logical replication parallel worker', 'parallel-worker-before-commit');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('parallel-worker-before-commit')");
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', 'INSERT INTO child VALUES (1,1)');
    $subscriber->wait_for_log(qr/violates foreign key constraint/, $offset);
    ok($subscriber->poll_query_until('postgres', "SELECT NOT subenabled FROM pg_subscription WHERE subname='sub'"),
       'BUG reproduced: enabling only child FK checks misses parent dependency');
}
elsif ($scenario eq 'fk-toast')
{
    $publisher->safe_psql('postgres', q{
        INSERT INTO parent VALUES (1, repeat('x', 2500));
        INSERT INTO child VALUES (1, repeat('x', 2500), 0);
    });
    $publisher->wait_for_catchup('sub');
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', 'UPDATE child SET v = 1 WHERE id = 1');
    $subscriber->wait_for_log(qr/TRAP: failed Assert.*LOGICALREP_COLUMN_UNCHANGED/s, $offset);
    diag('REPRO fk-toast: updating unrelated v with unchanged external FK column trips leader assertion');
    pass('BUG reproduced: unchanged non-RI TOAST FK value crashes assertion-enabled apply');
}
elsif ($scenario eq 'suspended-stream')
{
    $publisher->safe_psql('postgres', "INSERT INTO target VALUES (0, 'idle')");
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('parallel-worker-before-commit', 'wait')");
    $publisher->safe_psql('postgres', "INSERT INTO target VALUES (1, repeat('p',10*1024*1024))");
    $subscriber->wait_for_event('logical replication parallel worker', 'parallel-worker-before-commit');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('apply-update-before-open-indices','wait')");
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', q{
        BEGIN;
        INSERT INTO target VALUES (2, repeat('t',7*1024*1024));
        UPDATE target SET v='v1' WHERE id=0;
        COMMIT;
    });
    $subscriber->wait_for_log(qr/parallel apply suspended:/, $offset);
    $subscriber->safe_psql('postgres', q{
        SELECT injection_points_detach('parallel-worker-before-commit');
        SELECT injection_points_wakeup('parallel-worker-before-commit');
    });
    $subscriber->wait_for_event('logical replication parallel worker', 'apply-update-before-open-indices');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('apply-update-before-open-indices')");
    $publisher->append_conf('postgresql.conf', "logical_decoding_work_mem = '64kB'");
    $publisher->reload;
    $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', q{
        BEGIN;
        INSERT INTO bulk SELECT i, repeat('b',500) FROM generate_series(1,10000) i;
        UPDATE target SET v='v2' WHERE id=0;
        COMMIT;
    });
    $subscriber->wait_for_log(qr/conflict=update_missing/, $offset);
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_wakeup('apply-update-before-open-indices')");
    $publisher->wait_for_catchup('sub');
    my $actual = $subscriber->safe_psql('postgres', 'SELECT v FROM target WHERE id=0');
    diag("REPRO suspended-stream: publisher expected=v2, subscriber actual=$actual");
    is($actual, 'v1', 'BUG reproduced: suspended streamed replay loses subsequent UPDATE');
}
elsif ($scenario eq 'stream-abort-origin')
{
    $publisher->safe_psql('postgres', "INSERT INTO target VALUES (-1); INSERT INTO bulk VALUES (-1,'warm')");
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('parallel-worker-before-commit','wait')");
    $publisher->safe_psql('postgres', 'INSERT INTO target VALUES (1)');
    my $t1_lsn = $publisher->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
    $subscriber->wait_for_event('logical replication parallel worker', 'parallel-worker-before-commit');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('parallel-worker-before-commit')");
    my $stream = $publisher->background_psql('postgres');
    $stream->query_safe(q{
        BEGIN;
        INSERT INTO bulk SELECT i, repeat('s',500) FROM generate_series(1,10000) i;
    });
    ok($subscriber->poll_query_until('postgres', q{
        SELECT EXISTS (
            SELECT FROM pg_locks l JOIN pg_stat_activity a USING (pid)
            WHERE a.backend_type = 'logical replication parallel worker'
              AND l.relation = 'bulk'::regclass AND l.mode='RowExclusiveLock'
        )
    }), 'Streamed worker has applied changes before abort');
    $stream->query_safe('ROLLBACK');
    $stream->quit;
    ok($subscriber->poll_query_until('postgres',
        "SELECT EXISTS (SELECT FROM pg_replication_origin_status WHERE remote_lsn > '$t1_lsn'::pg_lsn)"),
       'Origin advanced beyond held ordinary transaction');
    $subscriber->safe_psql('postgres', 'ALTER SUBSCRIPTION sub DISABLE');
    ok($subscriber->poll_query_until('postgres', q{
        SELECT NOT EXISTS (SELECT FROM pg_stat_activity
            WHERE backend_type IN ('logical replication apply worker','logical replication parallel worker'))
    }), 'Apply group stopped while predecessor was uncommitted');
    $subscriber->safe_psql('postgres', 'ALTER SUBSCRIPTION sub ENABLE');
    $publisher->wait_for_catchup('sub');
    my $count = $subscriber->safe_psql('postgres', 'SELECT count(*) FROM target WHERE id=1');
    diag("REPRO stream-abort-origin: publisher target(1) committed, subscriber count after restart=$count");
    is($count, '0', 'BUG reproduced: streamed abort advances restart past uncommitted predecessor');
}
elsif ($scenario eq 'partition-truncate')
{
    $publisher->safe_psql('postgres', 'TRUNCATE target');
    $publisher->wait_for_catchup('sub');
    $publisher->safe_psql('postgres', "INSERT INTO target VALUES (1,'v','m')");
    $publisher->wait_for_catchup('sub');
    $publisher->safe_psql('postgres', 'UPDATE target SET id=99 WHERE id=1');
    $publisher->wait_for_catchup('sub');
    my $actual = $subscriber->safe_psql('postgres', 'SELECT id,value,marker FROM target');
    diag("CHECK partition-truncate: expected=99|v|m, actual=$actual");
    is($actual, '99|v|m', 'Refutation probe: TRUNCATE then UPDATE on reordered leaf');
}
elsif ($scenario eq 'hidden-trigger-write')
{
    $publisher->safe_psql('postgres', 'UPDATE b SET v=1 WHERE id=-1');
    $publisher->wait_for_catchup('sub');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_attach('apply-update-before-open-indices','wait')");
    $publisher->safe_psql('postgres', 'UPDATE a SET v=1 WHERE id=1');
    $subscriber->wait_for_event('logical replication parallel worker', 'apply-update-before-open-indices');
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_detach('apply-update-before-open-indices')");
    my $offset = -s $subscriber->logfile;
    $publisher->safe_psql('postgres', 'UPDATE b SET v=2 WHERE id=1');
    $subscriber->wait_for_log(qr/conflict detected on relation "public.b": conflict=update_missing/, $offset);
    $subscriber->safe_psql('postgres',
        "SELECT injection_points_wakeup('apply-update-before-open-indices')");
    $publisher->wait_for_catchup('sub');
    my $actual = $subscriber->safe_psql('postgres', 'SELECT v FROM b WHERE id=1');
    diag("REPRO hidden-trigger-write: publisher expected=2, subscriber actual=$actual");
    is($actual, '1', 'BUG reproduced: later UPDATE overtakes hidden trigger INSERT');
}

$subscriber->stop;
$publisher->stop;
done_testing();
