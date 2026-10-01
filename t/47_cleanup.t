use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use Mojo::JSON qw(encode_json);
use Mojo::File qw(path);
use File::Path qw(make_path remove_tree);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_UPLOAD_DIR} = '/tmp/fedivid-cleanup-test';

remove_tree('/tmp/fedivid-cleanup-test');
make_path('/tmp/fedivid-cleanup-test/alice/hls/999');

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

# Seed some data
my $db = $pg->db;

# Old completed delivery
$db->query(
    "INSERT INTO deliveries (username, inbox_url, activity, activity_id, completed_at)
     VALUES ('alice', 'https://x/inbox', '{}'::jsonb, 'a1', NOW() - INTERVAL '10 days')"
);
# Recent completed delivery
$db->query(
    "INSERT INTO deliveries (username, inbox_url, activity, activity_id, completed_at)
     VALUES ('alice', 'https://x/inbox', '{}'::jsonb, 'a2', NOW())"
);

# Old seen notification
$db->query(
    "INSERT INTO notifications (username, type, actor, seen_at, created_at)
     VALUES ('alice', 'follow', 'https://x', NOW() - INTERVAL '40 days', NOW() - INTERVAL '40 days')"
);
# Recent seen notification
$db->query(
    "INSERT INTO notifications (username, type, actor, seen_at, created_at)
     VALUES ('alice', 'follow', 'https://x', NOW(), NOW())"
);

# Old remote actor
$db->query(
    "INSERT INTO remote_actors (url, actor, public_key, fetched_at)
     VALUES ('https://old.test/users/x', '{}'::jsonb, 'key', NOW() - INTERVAL '40 days')"
);
# Recent remote actor
$db->query(
    "INSERT INTO remote_actors (url, actor, public_key, fetched_at)
     VALUES ('https://new.test/users/y', '{}'::jsonb, 'key', NOW())"
);

# An orphan upload file
path('/tmp/fedivid-cleanup-test/alice/orphan.mp4')->spurt('fake');
# A known upload file
my $known = '/tmp/fedivid-cleanup-test/alice/known.mp4';
path($known)->spurt('fake');
$db->query(
    "INSERT INTO videos
         (username, title, content_type, file_path, size_bytes, activity_id, transcode_status)
     VALUES ('alice', 'Known', 'video/mp4', ?, 10,
             'http://localhost:3000/users/alice/videos/known.mp4', 'ready')",
    $known
);

# --- Dry run leaves everything alone ---
{
    my $out = qx{$^X -Ilib script/cleanup.pl 2>&1};
    like $out, qr/DRY RUN/, 'dry run announced';
    ok -f '/tmp/fedivid-cleanup-test/alice/orphan.mp4', 'orphan file survives dry run';

    my $count = $db->query(
        "SELECT COUNT(*) AS n FROM deliveries WHERE completed_at IS NOT NULL AND completed_at < NOW() - INTERVAL '7 days'"
    )->hash->{n};
    is $count, 1, 'delivery survives dry run';
}

# --- Apply actually deletes ---
{
    my $out = qx{$^X -Ilib script/cleanup.pl --apply 2>&1};
    like $out, qr/APPLY MODE/, 'apply mode announced';

    my $del = $db->query(
        "SELECT COUNT(*) AS n FROM deliveries WHERE completed_at IS NOT NULL AND completed_at < NOW() - INTERVAL '7 days'"
    )->hash->{n};
    is $del, 0, 'old deliveries deleted';

    my $notif = $db->query(
        "SELECT COUNT(*) AS n FROM notifications WHERE seen_at IS NOT NULL AND seen_at < NOW() - INTERVAL '30 days'"
    )->hash->{n};
    is $notif, 0, 'old notifications deleted';

    my $actors = $db->query(
        "SELECT COUNT(*) AS n FROM remote_actors WHERE fetched_at < NOW() - INTERVAL '30 days'"
    )->hash->{n};
    is $actors, 0, 'old remote actors deleted';

    ok !-f '/tmp/fedivid-cleanup-test/alice/orphan.mp4', 'orphan file deleted';
    ok -f $known, 'known file survives';

    my $hls_dir = '/tmp/fedivid-cleanup-test/alice/hls/999';
    ok !-d $hls_dir, 'orphan HLS dir deleted';
}

remove_tree('/tmp/fedivid-cleanup-test');

done_testing();
